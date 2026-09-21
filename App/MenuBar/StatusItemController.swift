import AppKit
import AwakeKit
import Observation
import SMCKit
import SwiftUI
import WindowKit

/// The status item: a template image built from the live metrics, a left
/// click that toggles the popover and a right click that opens a small menu.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let settings: AppSettings
    private let store: MetricsStore
    private let windowController: MainWindowController
    private let popoverController: MenuBarPopoverController
    private let tipController: MenuBarTipController

    private var lastKey: MenuBarLabelKey?
    /// The status light under the fan. A layer on the button and not part of
    /// the image: the image stays a template that the system tints for the
    /// menu bar, and the light keeps its own colour on top of it.
    private let ledLayer = CALayer()
    private var lastLED: AwakeLED?
    /// The fan glyph, for the same reason one step further: a layer can turn
    /// without anything being drawn again.
    private let fanIcon = FanIconLayer()
    /// The heat each metric was last drawn at, which is where the hysteresis
    /// of `HeatTint` lives.
    private var heatMemory: [MenuBarMetric: HeatLevel] = [:]
    /// The menu bar appearance the label's colours were resolved against. A
    /// tinted label is not a template image, so nothing tints it for us, and a
    /// wallpaper that flips the menu bar has to reach it.
    private var appearanceObservation: NSKeyValueObservation?
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var systemAsleep = false
    /// `--fake-cpu-temp` and `--fake-fan-rpm`, for the capture and measurement
    /// runs. Nil in every build the user ever launches by hand.
    private var fakeCelsius: Double?
    private var fakeFanRPM: Double?
    /// What the spin rule last decided, for the capture status file.
    private(set) var spinConditions = FanSpinConditions()
    /// True while the fan glyph is really turning.
    var isFanSpinning: Bool { fanIcon.isSpinning }
    /// One revolution in this many seconds, or nil while it stands still.
    var fanSpinSeconds: Double? { fanIcon.secondsPerRevolution }
    var fanAngle: CGFloat { fanIcon.currentAngle }
    /// The rendered labels, newest first. Small on purpose: the label of a Mac
    /// that is working changes every second, so this is only ever a hit on the
    /// values that repeat - a placeholder, a temperature that sits still, the
    /// idle percentage at night - and an unbounded cache of images for values
    /// that never come back would be a leak with a nice name.
    private var images = LRUCache<MenuBarLabelKey, NSImage>(capacity: 24)
    private var screenObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// What `isLabelOnScreen` last answered, so a move that changes nothing
    /// does not republish the demand.
    private var wasLabelOnScreen = true

    /// The size of the label the status item is showing, for the debug
    /// capture path: the menu bar of a notched Mac has little room.
    private(set) var lastImageSize: CGSize = .zero
    /// What the item really occupies in the menu bar, image plus the padding
    /// the system adds. `statusItem.length` stays at the variable-length
    /// sentinel, so the button window is the only honest source.
    var itemWidth: CGFloat { statusItem.button?.window?.frame.width ?? 0 }
    /// The button as it is drawn, light and glyph included, at 4x on the plate
    /// its own appearance would put it on: the status item's window belongs to
    /// the system and cannot be photographed.
    ///
    /// The plate follows the appearance on purpose. Everything the label draws
    /// in the menu bar's own colour is white on a dark bar, and a white glyph
    /// on a light grey plate is a picture of nothing.
    func debugButtonSnapshot() -> NSBitmapImageRep? {
        guard let button = statusItem.button, let layer = button.layer else { return nil }
        let dark = MenuBarLabelImage.templateColor(for: button.effectiveAppearance) == .white
        let scale: CGFloat = 4
        let size = button.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = context.cgContext
        cg.saveGState()
        cg.scaleBy(x: scale, y: scale)
        if button.isFlipped {
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
        }
        // The presentation layer, not the model one: a rotation that Core
        // Animation is running lives only there, and the model layer would
        // photograph the glyph upright however fast it is turning.
        (layer.presentation() ?? layer).render(in: cg)
        cg.restoreGState()
        // The plate goes in afterwards, underneath. The button's own backing
        // layer clears its bounds before it draws, so a plate laid down first
        // is wiped and the capture comes out transparent - which is what every
        // one of these files was until this line.
        cg.setBlendMode(.destinationOver)
        cg.setFillColor(NSColor(white: dark ? 0.13 : 0.85, alpha: 1).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        context.flushGraphics()
        return rep
    }

    var itemWindowNumber: Int { statusItem.button?.window?.windowNumber ?? 0 }
    /// The popover, for the debug capture path.
    var popoverWindowNumber: Int { popoverController.windowNumber }
    var isPopoverShown: Bool { popoverController.isShown }
    /// The first-close tip, for the debug capture path.
    var tipWindowNumber: Int { tipController.windowNumber }
    var isTipShown: Bool { tipController.isShown }
    /// What the tip checks before it points at the item.
    var isItemOnScreen: Bool {
        guard statusItem.isVisible, let window = statusItem.button?.window, window.frame.width > 0
        else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    /// Whether anything the label draws can be seen at all.
    ///
    /// The same question as `isItemOnScreen`, answered carefully the other way
    /// round: the tip may not point at an item it cannot find, and the
    /// samplers may not stop unless the item is certainly not there. A button
    /// window that does not exist yet - the first turn of the run loop after
    /// launch - counts as on screen, so the app never starts up blind.
    var isLabelOnScreen: Bool {
        guard statusItem.isVisible else { return false }
        guard let window = statusItem.button?.window, window.frame.width > 0 else { return true }
        return NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    /// The Window submenu: the same command list the tab and the popover draw,
    /// with the real key equivalents beside the names. It is rebuilt every
    /// time it opens, because what a row may do depends on the window that was
    /// in front and on how many displays are attached.
    private lazy var windowMenu: NSMenu = {
        let menu = NSMenu(title: "Window")
        menu.delegate = self
        menu.autoenablesItems = false
        return menu
    }()

    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu()
        menu.addItem(item(title: "Open MacTools", action: #selector(openWindow)))
        menu.addItem(.separator())
        let window = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        window.submenu = windowMenu
        menu.addItem(window)
        menu.addItem(.separator())
        menu.addItem(item(title: "Fans: Full Blast", action: #selector(fansFullBlast)))
        menu.addItem(item(title: "Fans: Auto", action: #selector(fansAuto)))
        menu.addItem(item(title: "Lock Keyboard", action: #selector(lockKeyboard)))
        menu.addItem(.separator())
        menu.addItem(item(title: "Copy Processes for AI", action: #selector(copyProcessesForAI)))
        menu.addItem(.separator())
        menu.addItem(item(title: "Settings...", action: #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(item(title: "Quit MacTools", action: #selector(quit), key: "q"))
        return menu
    }()

    init(
        settings: AppSettings,
        store: MetricsStore,
        windowController: MainWindowController,
        popoverController: MenuBarPopoverController
    ) {
        self.settings = settings
        self.store = store
        self.windowController = windowController
        self.popoverController = popoverController
        tipController = MenuBarTipController(settings: settings)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // Not `.removalAllowed`: dragging the item off the menu bar would
        // leave a running app with no way back.
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick)
            // The left button acts on the press, like a menu: AppKit closes an
            // open popover on that same press, and acting on the release would
            // reopen what the user just dismissed.
            button.sendAction(on: [.leftMouseDown, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("MacTools system metrics")
            button.wantsLayer = true
            ledLayer.zPosition = 1
            button.layer?.addSublayer(ledLayer)
            button.layer?.addSublayer(fanIcon.layer)
            // The menu bar is dark or light on its own account: it follows a
            // dark wallpaper in Light Mode too. A template image never had to
            // care; a tinted label and the glyph layer do.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                // AppKit changes an appearance on the main thread and nowhere
                // else, so this is already where it has to be; the hop is for
                // the day that stops being true.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.appearanceChanged() }
                } else {
                    DispatchQueue.main.async { self?.appearanceChanged() }
                }
            }
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh(force: true)
                self?.publishLabelVisibility()
            }
        }
        // The status item moves when the menu bar gains or loses an item, and
        // on a notched Mac that is how it ends up off the screen. There is no
        // notification for "your item is hidden now", but the window it lives
        // in does post its own move.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // The identity alone crosses into the isolated block: a
            // `Notification` is not `Sendable`, and an `ObjectIdentifier` is
            // all the comparison needs.
            let moved = (notification.object as? NSObject).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self,
                      let window = self.statusItem.button?.window,
                      moved == ObjectIdentifier(window)
                else { return }
                self.publishLabelVisibility()
            }
        }
        observeMotionAndPower()

        track()
    }

    /// The three pushes that stop the fan and never change a number: Reduce
    /// Motion, the sleep of the Mac, and the wake after it. Low Power Mode
    /// arrives through `KeepAwakeController`, which already holds the one
    /// subscription the app has for it.
    private func observeMotionAndPower() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspace.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    // Reduce Motion decides where the glyph is drawn, not only
                    // whether it turns, so the label itself is rebuilt.
                    self.refresh(force: true)
                }
            },
            workspace.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.systemAsleep = true
                    self?.refresh(force: false)
                }
            },
            workspace.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.systemAsleep = false
                    self?.refresh(force: false)
                }
            },
        ]
    }

    /// The menu bar flipped between light and dark: everything whose colour was
    /// resolved from it has to be drawn again.
    private func appearanceChanged() {
        AppLog.app.info(
            "menu bar appearance: \(self.statusItem.button?.effectiveAppearance.name.rawValue ?? "none", privacy: .public)"
        )
        refresh(force: true)
    }

    // MARK: - Rendering

    /// Everything one pass of the label is built from.
    private struct LabelState {
        var cells: [MenuBarCell] = []
        var style: MenuBarLabelStyle = .twoLine
        var icon = true
        var awake = false
        var led: AwakeLED = .green
        /// The heat of each cell, in the order of `cells`. Empty while nothing
        /// is hot, which is the template path.
        var tints: [HeatLevel] = []
        /// The fastest fan, when the glyph is allowed to turn with it.
        var fan: FanReading?
        var lowPowerMode = false
        /// The glyph is in the label at all.
        var showsGlyph = true
        /// The glyph is drawn by its own layer rather than into the bitmap.
        /// False is the old path, kept for everybody who has the spin off:
        /// a template image the system tints, with nothing to resolve.
        var glyphInLayer = true
    }

    /// Re-runs whenever a value the label shows changes, and never otherwise.
    ///
    /// The snapshot it reads is narrowed to the metrics the label draws, so a
    /// pass that only moved the disk throughput does not wake a label that
    /// shows the CPU and the temperature.
    private func track() {
        let state = withObservationTracking {
            labelState()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        apply(state, force: false)
    }

    /// One pass of the label, read out of the settings and the store.
    private func labelState() -> LabelState {
        let keepAwake = AppServices.shared.keepAwake
        let snapshot = labelSnapshot
        let cells = MenuBarLabel.cells(snapshot: snapshot, settings: settings)
        let showsGlyph = settings.showMenuBarIcon || cells.isEmpty
        let spins = settings.spinsFanIcon && !reduceMotion
        return LabelState(
            cells: cells,
            style: settings.labelStyle,
            icon: settings.showMenuBarIcon,
            awake: keepAwake.isOn,
            led: keepAwake.blocking.led,
            tints: MenuBarLabel.heatLevels(
                cells: cells,
                snapshot: snapshot,
                settings: settings,
                previous: heatMemory
            ),
            // Only read while the glyph may turn: with the spin off, nothing
            // in this controller ever looks at a fan.
            fan: showsGlyph && spins ? snapshot.fastestFan : nil,
            lowPowerMode: keepAwake.power.lowPowerMode,
            showsGlyph: showsGlyph,
            glyphInLayer: showsGlyph && spins
        )
    }

    /// Draws the pass: the bitmap, the status light, the glyph and its speed,
    /// in that order. The light and the glyph are placed against the image
    /// that was just set, so the image has to come first.
    private func apply(_ state: LabelState, force: Bool) {
        remember(state)
        render(state: state, force: force)
        placeLED(state.led, cells: state.cells, icon: state.icon)
        placeGlyph(state)
        spin(state)
    }

    /// The level each metric was drawn at, which the next pass compares
    /// against. An empty list means nothing was tinted at all.
    private func remember(_ state: LabelState) {
        guard !state.tints.isEmpty else {
            heatMemory.removeAll(keepingCapacity: true)
            return
        }
        for (index, cell) in state.cells.enumerated() where index < state.tints.count {
            heatMemory[cell.metric] = state.tints[index]
        }
    }

    /// Centred under the fan, in the button's coordinates. The button centres
    /// an image-only label, so the label's origin is half the slack in.
    private func placeLED(_ led: AwakeLED, cells: [MenuBarCell], icon: Bool) {
        guard let button = statusItem.button,
              let frame = MenuBarLabelImage.ledFrame(cells: cells, showIcon: icon) else {
            ledLayer.isHidden = true
            return
        }
        let origin = CGPoint(
            x: ((button.bounds.width - lastImageSize.width) / 2).rounded(),
            y: ((button.bounds.height - lastImageSize.height) / 2).rounded()
        )
        let y = button.isFlipped
            ? button.bounds.height - origin.y - frame.maxY
            : origin.y + frame.minY
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ledLayer.isHidden = false
        ledLayer.frame = CGRect(x: origin.x + frame.minX, y: y, width: frame.width, height: frame.height)
        ledLayer.cornerRadius = frame.width / 2
        ledLayer.backgroundColor = led.nsColor.cgColor
        CATransaction.commit()
        if led != lastLED {
            lastLED = led
            button.setAccessibilityLabel("MacTools system metrics, \(led.meaning)")
        }
    }

    /// The fan glyph, in the box the bitmap reserved for it, in the button's
    /// coordinates. The same arithmetic as the status light, because the two
    /// are placed against the same image.
    private func placeGlyph(_ state: LabelState) {
        guard let button = statusItem.button else { return }
        guard state.glyphInLayer,
              let frame = MenuBarLabelImage.iconFrame(
                  cells: state.cells,
                  style: state.style,
                  showIcon: state.icon,
                  awake: state.awake
              )
        else {
            fanIcon.place(
                box: nil,
                awake: false,
                solo: false,
                color: .black,
                scale: 1,
                geometryFlipped: button.isFlipped
            )
            return
        }
        let origin = CGPoint(
            x: ((button.bounds.width - lastImageSize.width) / 2).rounded(),
            y: ((button.bounds.height - lastImageSize.height) / 2).rounded()
        )
        let y = button.isFlipped
            ? button.bounds.height - origin.y - frame.maxY
            : origin.y + frame.minY
        fanIcon.place(
            box: CGRect(x: origin.x + frame.minX, y: y, width: frame.width, height: frame.height),
            awake: state.awake,
            solo: state.cells.isEmpty,
            color: MenuBarLabelImage.templateColor(for: statusItem.button?.effectiveAppearance),
            scale: backingScale,
            geometryFlipped: button.isFlipped
        )
    }

    /// Where the glyph's rotation centre sits, back in the label's own
    /// bottom-left coordinates.
    ///
    /// The capture path checks it against the point the bitmap draws the hub
    /// at: the glyph left the image, and the proof that it did not move is a
    /// number rather than a look.
    var glyphHubInLabel: CGPoint? {
        guard let button = statusItem.button, !fanIcon.layer.isHidden else { return nil }
        let origin = CGPoint(
            x: ((button.bounds.width - lastImageSize.width) / 2).rounded(),
            y: ((button.bounds.height - lastImageSize.height) / 2).rounded()
        )
        let position = fanIcon.layer.position
        return CGPoint(
            x: position.x - origin.x,
            y: button.isFlipped
                ? button.bounds.height - position.y - origin.y
                : position.y - origin.y
        )
    }

    /// How fast the glyph turns, or that it stands still.
    private func spin(_ state: LabelState) {
        let conditions = FanSpinConditions(
            rpm: state.fan?.actual,
            minimumRPM: state.fan?.minimum ?? 0,
            maximumRPM: state.fan?.maximum ?? 0,
            showsIcon: state.glyphInLayer,
            spinEnabled: settings.spinsFanIcon,
            reduceMotion: reduceMotion,
            labelOnScreen: isLabelOnScreen,
            systemAsleep: systemAsleep,
            lowPowerMode: state.lowPowerMode
        )
        spinConditions = conditions
        fanIcon.spin(secondsPerRevolution: FanSpin.secondsPerRevolution(conditions))
    }

    /// Only the domains the label draws.
    private var labelSnapshot: MetricsSnapshot {
        var snapshot = store.snapshot(
            for: SamplingPlan.menuBarRequest(
                metrics: settings.menuBarMetrics,
                chosenSensorScope: .labelled,
                spinsFanIcon: settings.spinsFanIcon
                    && (settings.showMenuBarIcon || settings.menuBarMetrics.isEmpty)
            )
        )
        if let fakeCelsius {
            snapshot.temperatures = [
                TemperatureReading(
                    key: "Tp01",
                    label: "CPU performance core 1",
                    category: .cpuPerformance,
                    celsius: fakeCelsius
                ),
            ]
        }
        if let fakeFanRPM {
            let real = snapshot.fastestFan
            snapshot.fans = [
                FanReading(
                    index: real?.index ?? 0,
                    actual: fakeFanRPM,
                    minimum: real?.minimum ?? 1200,
                    maximum: real?.maximum ?? 4000,
                    target: fakeFanRPM,
                    mode: real?.mode ?? .auto
                ),
            ]
        }
        return snapshot
    }

    /// `--fake-cpu-temp <celsius>`: a temperature this Mac will not reach on
    /// demand, so the heat tint can be photographed. It changes what the label
    /// draws for this run and nothing else; nothing is persisted, and no
    /// sensor is written.
    func overrideCPUTemperature(_ celsius: Double) {
        fakeCelsius = celsius
        refresh(force: true)
    }

    /// `--fake-fans --fake-fan-rpm <rpm>`: a fan speed for the glyph, on a Mac
    /// whose fans idle at 0 rpm and may never be commanded by a test. It feeds
    /// the label and the spin rule only.
    func overrideFanRPM(_ rpm: Double) {
        fakeFanRPM = rpm
        refresh(force: true)
    }

    /// The three lines the capture status file needs about the button itself.
    var isButtonFlipped: Bool { statusItem.button?.isFlipped ?? false }
    var buttonAppearanceName: String {
        statusItem.button?.effectiveAppearance.name.rawValue ?? "none"
    }

    var labelFanSummary: String {
        let fans = labelSnapshot.fans
        guard !fans.isEmpty else { return "none" }
        return fans
            .map { "\($0.index): \(Int($0.actual)) rpm of \(Int($0.minimum))-\(Int($0.maximum))" }
            .joined(separator: " | ")
    }

    private var backingScale: CGFloat {
        statusItem.button?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    private func refresh(force: Bool) {
        apply(labelState(), force: force)
    }

    /// Draws the label, and only when something it shows really changed.
    ///
    /// Two gates in front of the drawing: the key of what is on screen, which
    /// catches a pass that changed no string at all, and a small LRU of the
    /// images already drawn, which catches a value that comes back. What is
    /// left is drawn straight into a bitmap by `MenuBarLabelImage`;
    /// `ImageRenderer` used to do it and cost about thirty times as much,
    /// once a second, for ever.
    private func render(state: LabelState, force: Bool) {
        let scale = backingScale
        let appearance = statusItem.button?.effectiveAppearance
        let tinted = state.tints.contains(where: \.isTinted)
        let key = MenuBarLabelKey(
            cells: state.cells,
            style: state.style,
            icon: state.icon,
            awake: state.awake,
            scale: scale,
            tints: state.tints,
            // Only a tinted label carries colours of its own, so only a tinted
            // label has to be drawn again when the menu bar flips.
            appearance: tinted ? appearance?.name.rawValue : nil,
            drawsIcon: !state.glyphInLayer
        )
        guard force || key != lastKey else { return }
        lastKey = key

        let image: NSImage
        if let cached = images.value(forKey: key) {
            image = cached
        } else {
            guard let drawn = MenuBarLabelImage.image(
                cells: state.cells,
                style: state.style,
                showIcon: state.icon,
                awake: state.awake,
                scale: scale,
                tints: state.tints,
                baseColor: MenuBarLabelImage.templateColor(for: appearance),
                appearance: appearance,
                drawsIcon: !state.glyphInLayer
            ) else { return }
            images.insert(drawn, forKey: key)
            image = drawn
        }
        lastImageSize = image.size
        statusItem.button?.image = image
        // A new image clears the pressed look, and the popover is still there.
        if popoverController.isShown { statusItem.button?.highlight(true) }
    }

    /// Tells the services whether the label can be seen, which is what decides
    /// if the app samples anything at all with nothing else on screen.
    private func publishLabelVisibility() {
        let onScreen = isLabelOnScreen
        guard onScreen != wasLabelOnScreen else { return }
        wasLabelOnScreen = onScreen
        AppLog.app.notice("status item on screen: \(onScreen, privacy: .public)")
        AppServices.shared.refreshDemand()
        // A glyph the menu bar has parked behind the notch turns for nobody.
        refresh(force: false)
    }

    /// `--appearance dark|light` for the status item itself.
    ///
    /// The menu bar's own window belongs to the system and cannot be
    /// photographed, so a capture run gives the button the appearance it wants
    /// to see. It is our own view, nothing about the system changes, and it
    /// goes through the same KVO the real flip does: the capture is the proof
    /// that the observer fires and that the colours are resolved again.
    func overrideButtonAppearance(dark: Bool) {
        statusItem.button?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    /// `--no-activate`, for a capture run: the popover appears without taking
    /// the front from the app the user is working in, and no tip is ever
    /// popped at whoever is using the machine.
    func suppressActivation() {
        popoverController.suppressActivation()
        tipController.suppress()
    }

    /// A capture run shows and hides the window on its own; no tip belongs in
    /// a screenshot that did not ask for one.
    func suppressMenuBarTip() {
        tipController.suppress()
    }

    /// Everything the first-close tip needs. The window controller calls this
    /// the first time the window goes away.
    func showMenuBarTipIfNeeded() {
        tipController.showIfNeeded(from: statusItem)
    }

    /// `--show-menu-bar-tip`: let the tip appear even when it has been seen
    /// and even in a capture run. It still arrives the one way it ever does,
    /// when the window goes away, so the screenshot is of the real path.
    func allowMenuBarTip() {
        tipController.force()
    }

    /// The `--show-popover` debug path, and the way back when the window is
    /// hidden behind the notch.
    func showPopover(sticky: Bool = false) {
        guard let button = statusItem.button else { return }
        popoverController.show(from: button, sticky: sticky)
    }

    func closePopover() {
        popoverController.close()
    }

    /// `--popover-offscreen`: the popover's view tree and its sampling demand,
    /// without the activation a real popover needs. See the controller.
    func showOffscreenPopover() {
        popoverController.showOffscreen()
    }

    // MARK: - Clicks

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.type == .rightMouseDown
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            // Handing the menu to the status item keeps the button
            // highlighted while the menu is open; a bare popUp does not.
            popoverController.close()
            // Before the menu appears, while the user's own window is still
            // the frontmost one: the Window submenu acts on that window.
            AppServices.shared.windows.captureTarget()
            statusItem.menu = contextMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if let button = statusItem.button {
            popoverController.toggle(from: button)
        }
    }

    @objc private func openWindow() {
        windowController.show()
    }

    /// Straight from the menu bar: the point of the lock is to start it with
    /// the mouse alone, with the keyboard already under a cloth.
    @objc private func fansFullBlast() {
        Task { await AppServices.shared.fans.setAllFullBlast() }
    }

    @objc private func fansAuto() {
        Task { await AppServices.shared.fans.restoreAllAuto() }
    }

    @objc private func lockKeyboard() {
        AppServices.shared.keyboardLock.lock()
    }

    /// Straight from the menu bar, with nothing on screen: the table is not
    /// sampling, so the copy takes its own sample pair first and the paste is
    /// about a second behind the click.
    @objc private func copyProcessesForAI() {
        AppServices.shared.reports.copyProcesses(samplesFirst: true)
    }

    @objc private func openSettings() {
        windowController.show(tab: .settings)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func item(title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - The Window submenu

    /// A row of the command list, as a menu item.
    @objc private func performWindowAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = WindowAction(rawValue: raw)
        else { return }
        AppServices.shared.windows.apply(action, reactivate: true)
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === windowMenu else { return }
        menu.removeAllItems()
        let windows = AppServices.shared.windows
        for (index, group) in windows.commandGroups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for row in group.rows {
                menu.addItem(menuItem(for: row))
            }
        }
        if !windows.accessibilityGranted {
            menu.addItem(.separator())
            menu.addItem(item(title: "Grant Accessibility...", action: #selector(grantAccessibility)))
        }
    }

    private func menuItem(for row: WindowCommandRow) -> NSMenuItem {
        let item = NSMenuItem(
            title: row.title,
            action: #selector(performWindowAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = row.action.rawValue
        item.isEnabled = row.isAvailable
        item.image = WindowRegionImage.image(for: row.action)
        if let binding = row.binding, let equivalent = WindowMenuKey.equivalent(for: binding) {
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.modifiers
        }
        return item
    }

    @objc private func grantAccessibility() {
        AppServices.shared.windows.requestAccessibility()
    }
}
