import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app: no Dock icon, no menu bar owner. LSUIElement already
        // does this, setting it here keeps the policy explicit and survives a
        // plist mistake.
        NSApp.setActivationPolicy(.accessory)
    }
}
