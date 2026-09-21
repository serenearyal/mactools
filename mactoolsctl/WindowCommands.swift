import AppKit
import ApplicationServices
import Foundation

/// The read-only half of the window manager, from the command line.
///
/// It moves nothing. Accessibility is granted per binary, so this needs the
/// grant on the terminal that runs it, and says so plainly when it is missing
/// instead of printing an empty list.
enum WindowCommands {
    static func list() throws {
        guard AXIsProcessTrusted() else {
            throw CLIError(
                """
                this terminal has no Accessibility permission, so no window is visible. \
                Grant it in System Settings > Privacy & Security > Accessibility, \
                or read the same list from MacTools' Windows tab.
                """
            )
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw CLIError("no app is in front")
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let windows = AX.elements(element, AXAttribute.windows)
        print("\(app.localizedName ?? "app") (pid \(app.processIdentifier)): \(windows.count) window(s)")
        // Straight from the accessibility API: the origin is the top-left
        // corner of the primary display and y grows downwards. The app flips
        // them; this prints what the API said.
        print("  frames in accessibility coordinates: x,y wxh")
        for window in windows {
            let frame = AX.frame(window) ?? .zero
            let title = AX.string(window, AXAttribute.title) ?? ""
            let subrole = AX.string(window, AXAttribute.subrole) ?? "-"
            let movable = AX.isSettable(window, AXAttribute.position)
                && AX.isSettable(window, AXAttribute.size)
            print(
                "  \(title.isEmpty ? "(no title)" : title)"
                    + "  \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
                    + "  \(subrole)\(movable ? "" : "  not movable")"
                    + "\(AX.bool(window, AXAttribute.minimized) == true ? "  minimized" : "")"
                    + "\(AX.bool(window, AXAttribute.fullScreen) == true ? "  full screen" : "")"
            )
        }
    }
}
