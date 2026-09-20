import AppKit
import SysMetrics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app: no Dock icon, no menu bar owner. LSUIElement already
        // does this, setting it here keeps the policy explicit and survives a
        // plist mistake.
        NSApp.setActivationPolicy(.accessory)

        let services = AppServices.shared
        AppLog.app.notice(
            """
            Vent \(HelperBundle.version, privacy: .public) started from \
            \(Bundle.main.bundlePath, privacy: .private)
            """
        )
        if !LaunchLocationBanner.isInPlace {
            AppLog.app.error("not running from /Applications; the helper and the TCC grants are bound to this path")
        }
        services.store.start()
        // The four grants of the setup card are granted in System Settings, so
        // every return to the front is a reason to read them again.
        services.setup.observeActivation()
        services.setup.refresh()
        // One pass at launch, so a fan mode the user chose last time is back
        // before the window is even opened. The helper deliberately forgot it.
        Task { await services.fans.refresh() }
        let controller = StatusItemController(
            settings: services.settings,
            store: services.store,
            windowController: services.windowController,
            popoverController: MenuBarPopoverController(services: services)
        )
        statusItemController = controller
        services.statusItemController = controller

        applyLaunchArguments(services: services)
    }

    /// Last chance to give the keyboard, the fans and the disk back.
    ///
    /// The order is the order of the damage. A locked keyboard that outlives
    /// the app would leave the user unable to type, so it goes first and
    /// synchronously. A running scan holds a thread that walks the volume, so
    /// it is told to stop before anything blocks. The fans go last, with a
    /// bounded wait: the helper restores Auto by itself when this connection
    /// dies, so this is a courtesy that makes it immediate, never a promise
    /// the quit path depends on.
    func applicationWillTerminate(_ notification: Notification) {
        let services = AppServices.shared
        AppLog.app.notice("terminating: keyboard released, scan cancelled, fans back to Auto")
        services.keyboardLock.releaseForTermination()
        services.storage.cancelScan()
        services.fans.restoreAllAutoOnTermination()
    }

    /// Closing the window leaves the status item running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Launching the app again while it runs, from Spotlight, Finder or
    /// `open`, shows the window. It is the way back when the menu bar is full
    /// and the system hides the status item behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppServices.shared.windowController.show()
        return true
    }

    /// `open -a Vent --args --show-window [--tab sensors]`, so a screenshot
    /// run needs no click.
    private func applyLaunchArguments(services: AppServices) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--tab"), index + 1 < arguments.count {
            let name = arguments[index + 1].lowercased()
            if let tab = MainTab.allCases.first(where: { $0.rawValue.lowercased() == name }) {
                services.selectedTab = tab
            }
        }
        // `--no-activate` first of all: every path below that shows something
        // must obey it, so a capture run never takes the front from the user.
        if arguments.contains("--no-activate") {
            services.windowController.suppressActivation()
            services.statusItemController?.suppressActivation()
        }
        // `--window-size 760x480` before `--show-window`, so the window is
        // built at the size a capture run asked for instead of resizing on
        // screen. 760 x 480 is the minimum the layout allows.
        if let index = arguments.firstIndex(of: "--window-size"), index + 1 < arguments.count,
           let size = parseSize(arguments[index + 1]) {
            services.windowController.forceContentSize(size)
        }
        if arguments.contains("--show-window") {
            services.windowController.show()
        }
        // `--show-popover` opens the dropdown without a click, and keeps it
        // open whatever else takes the front, so a capture run can photograph
        // it. The window stays closed: that is the whole point of the popover.
        if arguments.contains("--show-popover") {
            // After the launch, not during it: a popover shown from
            // `applicationDidFinishLaunching` never reaches the screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                services.statusItemController?.showPopover(sticky: true)
            }
            // `--popover-seconds <n>` closes it again, which is how a run can
            // show that the sampling of the popover stops with it.
            if let index = arguments.firstIndex(of: "--popover-seconds"),
               index + 1 < arguments.count,
               let seconds = Double(arguments[index + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    services.statusItemController?.closePopover()
                }
            }
        }
        // `--setup-checklist show|hide` draws the Overview with and without
        // the setup card for a screenshot run, and writes nothing: what the
        // user chose stays as it is.
        if let index = arguments.firstIndex(of: "--setup-checklist"), index + 1 < arguments.count {
            services.setup.setVisibilityOverride(arguments[index + 1].lowercased() != "hide")
        }
        // `--processes-sort name` opens the table on another column, so a
        // capture run can check that the order of a column that does not
        // change between samples really does not move.
        if let index = arguments.firstIndex(of: "--processes-sort"),
           index + 1 < arguments.count,
           let key = ProcessSortKey(rawValue: arguments[index + 1].lowercased()) {
            services.processes.sortOrder = [ProcessComparator(key: key, order: key == .cpu ? .reverse : .forward)]
        }
        // `--scan-root <path>` fills the Storage table at launch, so a
        // screenshot run does not need a click or a whole-disk scan.
        if let index = arguments.firstIndex(of: "--scan-root"), index + 1 < arguments.count {
            services.storage.startScan(root: arguments[index + 1])
        }
        // `--overlay-preview <seconds>` draws the lock overlay and creates no
        // event tap at all, so a screenshot run can never hold the keyboard.
        if let index = arguments.firstIndex(of: "--overlay-preview"),
           index + 1 < arguments.count,
           let seconds = Int(arguments[index + 1]) {
            services.keyboardLock.previewOverlay(seconds: min(max(seconds, 1), 30))
        }
        // `--lock-test <seconds>` is the only way to engage a real lock from
        // the command line, and it is clamped to 10 s so an automated run can
        // never trap the user behind a locked keyboard.
        if let index = arguments.firstIndex(of: "--lock-test"),
           index + 1 < arguments.count,
           let seconds = Int(arguments[index + 1]) {
            services.keyboardLock.lock(seconds: LockTimeout.clampDebug(seconds))
        }
        DebugFanBackend.applyLaunchArguments(arguments, to: services.fans)
        DebugCapture.run(arguments: arguments, services: services)
    }

    /// `760x480`, the only format `--window-size` takes.
    private func parseSize(_ text: String) -> CGSize? {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
