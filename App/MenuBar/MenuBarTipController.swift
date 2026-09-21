import AppKit
import SwiftUI

/// The one-time tip that explains where the window went.
///
/// It appears the first time the window closes, once ever, as a small popover
/// from the status item. Two ways out: "Got it", or the Dock icon for somebody
/// who would rather have one.
///
/// If the status item cannot be seen - hidden by the user, or pushed behind
/// the notch by a full menu bar - the tip is not shown at all and nothing is
/// turned on. A tip that points at an icon the user cannot find is worse than
/// no tip, and the app is never unreachable: opening MacTools again from Spotlight
/// or the Finder brings the window back (`applicationShouldHandleReopen`). The
/// flag is left unset in that case, so the tip still arrives on the first
/// close where the item is visible.
@MainActor
final class MenuBarTipController: NSObject, NSPopoverDelegate {
    private let settings: AppSettings
    private let popover = NSPopover()
    /// False under `--no-activate` and in a capture run: an agent taking a
    /// screenshot must never pop a tip at the user. `--show-menu-bar-tip`
    /// turns it back on.
    private var allowed = true
    /// True under `--show-menu-bar-tip`: show it whatever the flag says.
    private var forced = false

    var isShown: Bool { popover.isShown }
    var windowNumber: Int { popover.contentViewController?.view.window?.windowNumber ?? 0 }

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    func suppress() {
        allowed = false
    }

    /// `--show-menu-bar-tip`, for the capture run that photographs it.
    func force() {
        allowed = true
        forced = true
    }

    /// Called every time the window goes away. Everything but the first call
    /// returns at once.
    func showIfNeeded(from statusItem: NSStatusItem) {
        guard allowed, forced || !settings.menuBarTipShown, !popover.isShown else { return }
        guard let button = visibleButton(of: statusItem) else {
            AppLog.app.notice("menu bar tip skipped: the status item is not on screen")
            return
        }
        // A forced tip writes nothing: a capture run shares the settings file
        // with the user's own instance, and it must not tick a flag there.
        if !forced { settings.menuBarTipShown = true }
        // A capture run cannot depend on nobody touching the machine, so the
        // forced tip stays until the run quits.
        popover.behavior = forced ? .applicationDefined : .transient
        let host = NSHostingController(
            rootView: MenuBarTipView(
                gotIt: { [weak self] in self?.close() },
                showDockIcon: { [weak self] in
                    self?.settings.showDockIcon = true
                    self?.close()
                }
            )
        )
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    /// The status item as the user sees it: switched on, with a button window
    /// that really sits on a screen. A notched Mac with a full menu bar keeps
    /// `isVisible` true and parks the button off screen.
    private func visibleButton(of statusItem: NSStatusItem) -> NSStatusBarButton? {
        guard statusItem.isVisible, let button = statusItem.button, let window = button.window,
              window.frame.width > 0,
              NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) })
        else { return nil }
        return button
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}

struct MenuBarTipView: View {
    let gotIt: () -> Void
    let showDockIcon: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "menubar.arrow.up.rectangle")
                    .foregroundStyle(.tint)
                Text("MacTools keeps running here.\nClick the icon to open it.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Show Dock icon instead", action: showDockIcon)
                Button("Got it", action: gotIt)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        // Nobody tabs through a two-button tip, and the ring SwiftUI draws
        // around the first button reads as an error.
        .focusEffectDisabled()
    }
}
