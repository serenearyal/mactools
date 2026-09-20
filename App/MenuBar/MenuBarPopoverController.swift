import AppKit
import SwiftUI

/// The dropdown behind a left click on the status item.
///
/// It is deliberately not the window: the window is a whole app coming to the
/// front, and a glance at the numbers should cost nothing. While the popover
/// is on screen it registers as a sampling consumer, so the stores sample as
/// if the window were open, and it gives that up the moment it closes.
@MainActor
final class MenuBarPopoverController: NSObject, NSPopoverDelegate {
    private let services: AppServices
    private let popover = NSPopover()
    private weak var anchor: NSStatusBarButton?
    private var escapeMonitor: Any?
    /// AppKit dismisses a popover on the mouse-down over its status item, so
    /// the click that should close it would open it again. The status item
    /// acts on the mouse-down for that reason, and this catches the case where
    /// the dismissal wins the race: a click that close to a close is the
    /// second half of that dismissal, not a new one.
    private var lastClose = Date.distantPast
    private static let reopenGuard: TimeInterval = 0.3
    /// `--no-activate`. A capture run shows the popover without taking the
    /// front from whatever the user is doing.
    private var activates = true

    var isShown: Bool { popover.isShown }

    /// The window the popover draws in, for `screencapture -l`. It only exists
    /// while the popover is on screen.
    var windowNumber: Int {
        popover.contentViewController?.view.window?.windowNumber ?? 0
    }

    init(services: AppServices) {
        self.services = services
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        // The first frame is drawn at this size and then grows to the content,
        // which is a visible jump if the guess is far out. Every section is
        // the same height, so this one is exact.
        popover.contentSize = CGSize(
            width: PopoverLayout.width,
            height: PopoverLayout.contentHeight + PopoverLayout.chromeHeight
        )
    }

    // MARK: - Showing

    func suppressActivation() {
        activates = false
    }

    func toggle(from button: NSStatusBarButton) {
        if isShown {
            close()
        } else if Date.now.timeIntervalSince(lastClose) > MenuBarPopoverController.reopenGuard {
            show(from: button)
        }
    }

    /// `sticky` keeps the popover on screen whatever happens around it. Only
    /// the `--show-popover` debug path uses it: a transient popover goes away
    /// on the first event anywhere else, and a capture run cannot depend on
    /// nobody touching the machine for ten seconds.
    func show(from button: NSStatusBarButton, sticky: Bool = false) {
        guard !isShown else { return }
        popover.behavior = sticky ? .applicationDefined : .transient
        // Before anything else, and above all before `NSApp.activate()`: the
        // Windows section acts on the window the user was working in, and from
        // the moment Vent is frontmost there is no other focused window left
        // to find.
        services.windows.captureTarget()

        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        anchor = button
        button.highlight(true)
        // Before the first frame: the stores restart sampling at once, so the
        // numbers on screen are never more than one interval old.
        services.setPopoverVisible(true)
        // An accessory app is not active, and a popover of an inactive app
        // gets no key events and does not always appear at all. This opens no
        // window: `NSApp.activate()` only touches windows already on screen.
        // It is also the one thing `--no-activate` must not do.
        if activates { NSApp.activate() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // `makeKey` is the other half of taking the front, so it goes with it.
        if activates { popover.contentViewController?.view.window?.makeKey() }
        if !sticky { watchForEscape() }
    }

    func close() {
        guard isShown else { return }
        popover.performClose(nil)
    }

    private var content: MenuBarPopoverView {
        let services = services
        return MenuBarPopoverView(
            services: services,
            actions: MenuBarPopoverActions(
                openTab: { [weak self] tab in
                    self?.close()
                    services.windowController.show(tab: tab)
                },
                // The section is remembered and it decides what the popover
                // samples, so it goes through the services, not through a
                // `@State` of the view.
                selectSection: { section in
                    services.popoverSection = section
                },
                lockKeyboard: { [weak self] in
                    // The overlay takes the whole screen; the popover would be
                    // under it and its sampling would outlive the click.
                    self?.close()
                    services.keyboardLock.lock()
                },
                // A tile click moves a window that is behind this panel, so
                // the panel goes first and the app it belongs to comes back.
                closePopover: { [weak self] in
                    self?.close()
                },
                startAuto: {
                    Task { await services.fans.restoreAllAuto() }
                },
                startFullBlast: {
                    Task { await services.fans.setAllFullBlast() }
                },
                quit: { NSApp.terminate(nil) }
            )
        )
    }

    /// `.transient` swallows Escape only while the popover owns the key
    /// window, which an accessory app cannot always give it.
    private func watchForEscape() {
        stopWatchingForEscape()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
    }

    private func stopWatchingForEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        lastClose = .now
        stopWatchingForEscape()
        anchor?.highlight(false)
        services.setPopoverVisible(false)
        // Drops the SwiftUI view and everything it observes.
        popover.contentViewController = nil
    }
}
