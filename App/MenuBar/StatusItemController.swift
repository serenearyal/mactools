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

    private var lastCells: [MenuBarCell] = []
    private var lastStyle: MenuBarLabelStyle?
    private var lastIcon: Bool?
    private var lastScale: CGFloat = 0
    private var screenObserver: NSObjectProtocol?

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

    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu()
        menu.addItem(item(title: "Open Vent", action: #selector(openWindow)))
        menu.addItem(.separator())
        menu.addItem(item(title: "Fans: Full Blast", action: #selector(fansFullBlast)))
        menu.addItem(item(title: "Fans: Auto", action: #selector(fansAuto)))
        menu.addItem(item(title: "Lock Keyboard", action: #selector(lockKeyboard)))
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
            MainActor.assumeIsolated { self?.refresh(force: true) }
        }

        track()
    }

    // MARK: - Rendering

    /// Re-runs whenever a value the label shows changes, and never otherwise.
    private func track() {
        let state = withObservationTracking {
            (
                MenuBarLabel.cells(snapshot: store.snapshot, settings: settings),
                settings.labelStyle,
                settings.showMenuBarIcon
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        render(cells: state.0, style: state.1, icon: state.2, force: false)
    }

    private func refresh(force: Bool) {
        render(
            cells: MenuBarLabel.cells(snapshot: store.snapshot, settings: settings),
            style: settings.labelStyle,
            icon: settings.showMenuBarIcon,
            force: force
        )
    }

    /// The expensive part is `ImageRenderer`, so it only runs when a string,
    /// the style, the icon setting or the screen scale changed.
    private func render(cells: [MenuBarCell], style: MenuBarLabelStyle, icon: Bool, force: Bool) {
        let scale = statusItem.button?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        let unchanged = cells == lastCells
            && style == lastStyle
            && icon == lastIcon
            && scale == lastScale
        guard force || !unchanged else { return }
        lastCells = cells
        lastStyle = style
        lastIcon = icon
        lastScale = scale

        let renderer = ImageRenderer(
            content: MenuBarLabelView(cells: cells, style: style, showIcon: icon)
        )
        renderer.scale = scale
        guard let image = renderer.nsImage else { return }
        image.isTemplate = true
        lastImageSize = image.size
        statusItem.button?.image = image
        // A new image clears the pressed look, and the popover is still there.
        if popoverController.isShown { statusItem.button?.highlight(true) }
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
