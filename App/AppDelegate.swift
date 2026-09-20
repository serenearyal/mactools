import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app: no Dock icon, no menu bar owner. LSUIElement already
        // does this, setting it here keeps the policy explicit and survives a
        // plist mistake.
        NSApp.setActivationPolicy(.accessory)

        let services = AppServices.shared
        services.store.start()
        let controller = StatusItemController(
            settings: services.settings,
            store: services.store,
            windowController: services.windowController
        )
        statusItemController = controller
        services.statusItemController = controller

        applyLaunchArguments(services: services)
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
        if arguments.contains("--show-window") {
            services.windowController.show()
        }
        // `--scan-root <path>` fills the Storage table at launch, so a
        // screenshot run does not need a click or a whole-disk scan.
        if let index = arguments.firstIndex(of: "--scan-root"), index + 1 < arguments.count {
            services.storage.startScan(root: arguments[index + 1])
        }
        DebugCapture.run(arguments: arguments, services: services)
    }
}
