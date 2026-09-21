import AppKit
import SysMetrics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    /// `--no-activate`: a capture run never takes the front, not even when the
    /// activation policy changes under it.
    private var activates = true
    /// `--dock-icon-test`: the Dock icon for one run, with the settings file
    /// left exactly as the user wrote it.
    private var dockIconOverride: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app: no Dock icon, no menu bar owner. LSUIElement already
        // does this, setting it here keeps the policy explicit and survives a
        // plist mistake.
        NSApp.setActivationPolicy(.accessory)

        let services = AppServices.shared
        AppLog.app.notice(
            """
            MacTools \(HelperBundle.version, privacy: .public) started from \
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
        // Keep Awake starts off every launch by design; this only subscribes
        // it to the battery pushes its guard needs.
        services.keepAwake.start()
        // Claims the chords of the chosen set. Off by default, so this is one
        // conflict scan and nothing else until the user picks a set.
        services.windows.start()
        let controller = StatusItemController(
            settings: services.settings,
            store: services.store,
            windowController: services.windowController,
            popoverController: MenuBarPopoverController(services: services)
        )
        statusItemController = controller
        services.statusItemController = controller
        // The first time the window goes away, the status item explains where
        // it went. Once ever, and never during a capture run.
        services.windowController.onHidden = { [weak controller] in
            controller?.showMenuBarTipIfNeeded()
        }
        // Now that the status item exists: what the label draws and what the
        // battery says both decide how much the app samples.
        services.startObservingEnvironment()
        // The Dock icon is a setting, so the policy above is only the default.
        applyActivationPolicy(services: services)
        trackDockIconSetting(services: services)

        applyLaunchArguments(services: services)
    }

    // MARK: - Dock icon

    /// `.regular` gives MacTools a Dock icon, an app switcher entry and a menu
    /// bar; `.accessory` is the menu bar app it is by default.
    ///
    /// Live: the toggle in Settings lands here. Switching to `.regular` needs
    /// a re-activation, otherwise the app owns the menu bar without drawing
    /// it. Switching back to `.accessory` resigns the front, and AppKit orders
    /// the window out with it, so a window that was on screen is put back.
    private func applyActivationPolicy(services: AppServices) {
        let wanted: NSApplication.ActivationPolicy =
            (dockIconOverride ?? services.settings.showDockIcon) ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        let hadWindow = services.windowController.isVisible
        NSApp.setActivationPolicy(wanted)
        AppLog.app.notice("activation policy: \(wanted == .regular ? "regular" : "accessory", privacy: .public)")
        if wanted == .regular {
            // A `.regular` app that is not activated owns a menu bar it does
            // not draw. `--no-activate` is the one case that must not.
            if activates {
                NSApp.activate()
                NSRunningApplication.current.activate(options: [.activateAllWindows])
            }
        } else if hadWindow {
            // Resigning the front takes the window with it on the way back to
            // `.accessory`; a window that was on screen stays on screen.
            services.windowController.show()
        }
    }

    private func trackDockIconSetting(services: AppServices) {
        withObservationTracking {
            _ = services.settings.showDockIcon
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                applyActivationPolicy(services: services)
                trackDockIconSetting(services: services)
            }
        }
    }

    /// Last chance to give the keyboard, the sleep, the fans and the disk back.
    ///
    /// The order is the order of the damage. A locked keyboard that outlives
    /// the app would leave the user unable to type, so it goes first and
    /// synchronously. The sleep assertion goes next: it costs nothing and a
    /// Mac that will not sleep is the most annoying thing to leave behind. A
    /// running scan holds a thread that walks the volume, so it is told to
    /// stop before anything blocks. The fans go last, with a bounded wait: the
    /// helper restores Auto by itself when this connection dies, so this is a
    /// courtesy that makes it immediate, never a promise the quit path depends
    /// on.
    func applicationWillTerminate(_ notification: Notification) {
        let services = AppServices.shared
        AppLog.app.notice(
            "terminating: keyboard released, keep awake released, scan cancelled, fans back to Auto"
        )
        services.keyboardLock.releaseForTermination()
        services.keepAwake.releaseForTermination()
        // Every chord goes back to the system, so the next app that asks for
        // it gets it instead of `eventHotKeyExistsErr`.
        services.windows.stop()
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

    /// `open -a MacTools --args --show-window [--tab sensors]`, so a screenshot
    /// run needs no click.
    private func applyLaunchArguments(services: AppServices) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--tab"), index + 1 < arguments.count,
           let tab = MainTab(argument: arguments[index + 1]) {
            services.selectedTab = tab
        }
        // `--popover-section dashboard|windows|tools`. An override: the
        // section the user chose stays in the settings file untouched.
        if let index = arguments.firstIndex(of: "--popover-section"), index + 1 < arguments.count,
           let section = PopoverSection(argument: arguments[index + 1]) {
            services.overridePopoverSection(section)
        }
        // `--no-activate` first of all: every path below that shows something
        // must obey it, so a capture run never takes the front from the user.
        if arguments.contains("--no-activate") {
            activates = false
            services.windowController.suppressActivation()
            services.statusItemController?.suppressActivation()
        }
        // `--dock-icon-test <seconds>`: switch the Dock icon on at that second
        // and off five seconds later, through the same call the Settings
        // toggle makes. It proves both directions, and above all that the
        // window survives the way back to `.accessory`.
        if let index = arguments.firstIndex(of: "--dock-icon-test"), index + 1 < arguments.count,
           let seconds = Double(arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, 0)) { [weak self] in
                self?.dockIconOverride = true
                self?.applyActivationPolicy(services: services)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, 0) + 5) { [weak self] in
                self?.dockIconOverride = false
                self?.applyActivationPolicy(services: services)
            }
        }
        if arguments.contains("--capture") {
            services.statusItemController?.suppressMenuBarTip()
        }
        // `--window-size 760x480` before `--show-window`, so the window is
        // built at the size a capture run asked for instead of resizing on
        // screen. 760 x 480 is the minimum the layout allows.
        if let index = arguments.firstIndex(of: "--window-size"), index + 1 < arguments.count,
           let size = parseSize(arguments[index + 1]) {
            services.windowController.forceContentSize(size)
        }
        // `--menu-bar-label on|off`: pretend the status item label is drawing
        // numbers, or is not, whatever the menu bar has room for today. The
        // measurement script needs both states on purpose.
        if let index = arguments.firstIndex(of: "--menu-bar-label"), index + 1 < arguments.count {
            services.overrideLabelVisibility(arguments[index + 1].lowercased() == "on")
        }
        // `--power-rules off`: sample as if the Mac were on wall power, out of
        // Low Power Mode and cool, whatever it really is. A budget measured on
        // a laptop in Low Power Mode would otherwise only hold there.
        if let index = arguments.firstIndex(of: "--power-rules"), index + 1 < arguments.count {
            services.overridePowerRules(arguments[index + 1].lowercased() != "off")
        }
        // `--window-front`: order the window on top without activating, for
        // `scripts/measure_idle.sh`. A window that is ordered back sits under
        // the user's own windows, which makes it occluded, and an occluded
        // window samples at the idle cadence and is not drawn at all.
        if arguments.contains("--window-front") {
            services.windowController.orderFrontWithoutActivation()
        }
        if arguments.contains("--show-window") {
            services.windowController.show()
        }
        // `--popover-offscreen`: the popover's SwiftUI content and its sampling
        // demand in a borderless window off the corner of the screen, because a
        // real popover never appears for an app that is not active. The
        // measurement script is the only caller.
        if arguments.contains("--popover-offscreen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                services.statusItemController?.showOffscreenPopover()
            }
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
        // `--show-menu-bar-tip` lets the one-time tip appear whatever the
        // settings say, which is the only way it shows up in a capture run. It
        // still comes from the window closing, and it writes nothing back.
        if arguments.contains("--show-menu-bar-tip") {
            services.statusItemController?.allowMenuBarTip()
        }
        // `--hide-window-after <seconds>` presses "Hide to Menu Bar" for a
        // capture run: the same call the toolbar button makes, so the status
        // file shows what a user who closes the window gets.
        if let index = arguments.firstIndex(of: "--hide-window-after"),
           index + 1 < arguments.count,
           let seconds = Double(arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, 0)) {
                services.windowController.hide()
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
        // R2, R3 and R4 debug arguments, grouped so a merge sees one block.
        //
        // `--copy-report processes|files` runs the menu item itself, which is
        // the only way to check the clipboard path end to end. It overwrites
        // the pasteboard, so it is never on by default.
        if let index = arguments.firstIndex(of: "--copy-report"), index + 1 < arguments.count {
            let subject = arguments[index + 1].lowercased()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if subject == "files" {
                    services.reports.copyFiles(announce: false)
                } else {
                    services.reports.copyProcesses(samplesFirst: true, announce: false)
                }
            }
        }
        // `--keep-awake-test <seconds>`: a real assertion with a one minute
        // timeout, released after that many seconds. Nothing is persisted.
        if let index = arguments.firstIndex(of: "--keep-awake-test"),
           index + 1 < arguments.count,
           let seconds = Int(arguments[index + 1]) {
            services.keepAwake.debugTest(seconds: min(max(seconds, 1), 120))
        }
        // `--backlight-probe` writes one log line with everything the
        // hardened Release build managed to read out of CoreBrightness.
        if arguments.contains("--backlight-probe") {
            services.backlight.probe()
        }
        // `--backlight-selftest`: one ladder step and back through the slider
        // path, then quit. The exit code is the verdict.
        if arguments.contains("--backlight-selftest") {
            services.backlight.selfTest { passed in
                exit(passed ? 0 : 1)
            }
        }
        // `--shortcut-set off|rectangle|alternate`: claim one set for this run
        // and write nothing back. It is how a run proves which chords another
        // app already owns, without pressing a key.
        if let index = arguments.firstIndex(of: "--shortcut-set"), index + 1 < arguments.count,
           let choice = WindowShortcutChoice(argument: arguments[index + 1]) {
            services.windows.overrideChoice(choice)
        }
        // `--window-selftest <probe.app>`: move a window of our own probe app
        // through every action and check the result against `WindowKit`. It
        // touches no other window, and it quits when the table is written.
        if let index = arguments.firstIndex(of: "--window-selftest"), index + 1 < arguments.count {
            let output = arguments.firstIndex(of: "--window-selftest-out")
                .flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            WindowSelfTest.run(
                probePath: arguments[index + 1],
                outputDirectory: output,
                services: services
            )
        }
        // `--label-bench <directory>`: what one menu bar label costs through
        // `ImageRenderer` and through the direct draw, plus the pixel
        // difference between the two. It is the evidence behind the choice.
        if let index = arguments.firstIndex(of: "--label-bench"), index + 1 < arguments.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                DebugCapture.benchmarkLabel(directory: arguments[index + 1], services: services)
            }
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
