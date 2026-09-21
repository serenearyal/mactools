import AppKit
import Observation
import SwiftUI

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
    /// The rendered labels, newest first. Small on purpose: the label of a Mac
    /// that is working changes every second, so this is only ever a hit on the
    /// values that repeat - a placeholder, a temperature that sits still, the
    /// idle percentage at night - and an unbounded cache of images for values
    /// that never come back would be a leak with a nice name.
    private var images = LRUCache<MenuBarLabelKey, NSImage>(capacity: 24)
    private var screenObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
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

    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu()
        menu.addItem(item(title: "Open Vent", action: #selector(openWindow)))
        menu.addItem(.separator())
        menu.addItem(item(title: "Fans: Full Blast", action: #selector(fansFullBlast)))
        menu.addItem(item(title: "Fans: Auto", action: #selector(fansAuto)))
        menu.addItem(item(title: "Lock Keyboard", action: #selector(lockKeyboard)))
        menu.addItem(.separator())
        menu.addItem(item(title: "Copy Processes for AI", action: #selector(copyProcessesForAI)))
        menu.addItem(.separator())
        menu.addItem(item(title: "Settings...", action: #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(item(title: "Quit Vent", action: #selector(quit), key: "q"))
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
            button.setAccessibilityLabel("Vent system metrics")
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

        track()
    }

    // MARK: - Rendering

    /// Re-runs whenever a value the label shows changes, and never otherwise.
    ///
    /// The snapshot it reads is narrowed to the metrics the label draws, so a
    /// pass that only moved the disk throughput does not wake a label that
    /// shows the CPU and the temperature.
    private func track() {
        let state = withObservationTracking {
            (
                MenuBarLabel.cells(snapshot: labelSnapshot, settings: settings),
                settings.labelStyle,
                settings.showMenuBarIcon,
                AppServices.shared.keepAwake.isOn
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        render(cells: state.0, style: state.1, icon: state.2, awake: state.3, force: false)
    }

    /// Only the domains the label draws.
    private var labelSnapshot: MetricsSnapshot {
        store.snapshot(
            for: SamplingPlan.menuBarRequest(
                metrics: settings.menuBarMetrics,
                chosenSensorScope: .labelled
            )
        )
    }

    private func refresh(force: Bool) {
        render(
            cells: MenuBarLabel.cells(snapshot: labelSnapshot, settings: settings),
            style: settings.labelStyle,
            icon: settings.showMenuBarIcon,
            awake: AppServices.shared.keepAwake.isOn,
            force: force
        )
    }

    /// Draws the label, and only when something it shows really changed.
    ///
    /// Two gates in front of the drawing: the key of what is on screen, which
    /// catches a pass that changed no string at all, and a small LRU of the
    /// images already drawn, which catches a value that comes back. What is
    /// left is drawn straight into a bitmap by `MenuBarLabelImage`;
    /// `ImageRenderer` used to do it and cost about thirty times as much,
    /// once a second, for ever.
    private func render(
        cells: [MenuBarCell],
        style: MenuBarLabelStyle,
        icon: Bool,
        awake: Bool,
        force: Bool
    ) {
        let scale = statusItem.button?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        let key = MenuBarLabelKey(cells: cells, style: style, icon: icon, awake: awake, scale: scale)
        guard force || key != lastKey else { return }
        lastKey = key

        let image: NSImage
        if let cached = images.value(forKey: key) {
            image = cached
        } else {
            guard let drawn = MenuBarLabelImage.image(
                cells: cells,
                style: style,
                showIcon: icon,
                awake: awake,
                scale: scale
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
}
