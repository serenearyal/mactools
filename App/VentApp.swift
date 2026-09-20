import SwiftUI

@main
struct VentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Runs when the scene graph is built, which is the only moment the
        // app has `openWindow` outside a window that may not exist yet.
        let _ = AppServices.shared.windowController.setOpenAction {
            openWindow(id: MainWindowController.windowID)
        }

        Window("Vent", id: MainWindowController.windowID) {
            MainWindowView()
                .environment(AppServices.shared)
                .background(
                    WindowAccessor { AppServices.shared.windowController.attach($0) }
                )
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        // A menu bar app starts with no window on screen.
        .defaultLaunchBehavior(.suppressed)
    }
}
