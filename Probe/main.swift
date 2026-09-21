import AppKit
import ApplicationServices

/// A window to push around.
///
/// `MacToolsAXProbe` exists so the window mover can be tested against a real
/// accessibility server without ever touching a window of the user's. It is an
/// accessory app with one titled window, almost transparent, that never takes
/// the focus and quits by itself after a minute.
///
/// Arguments:
///   --title <text>          the window title the test looks for
///   --frame x,y,w,h         where it starts, in NS screen coordinates
///   --eui                   set `AXEnhancedUserInterface` on itself, to prove
///                           the mover's workaround on the offset it causes
///   --seconds <n>           how long it lives, 60 by default and 300 at most

/// Never key, never main: the user is working on this machine, and a test
/// window that steals a keystroke would be worse than no test.
final class ProbeWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: ProbeWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let title = value(of: "--title", in: arguments) ?? "MacTools AX Probe"
        let seconds = value(of: "--seconds", in: arguments).flatMap(Double.init) ?? 60
        let frame = value(of: "--frame", in: arguments).flatMap(ProbeDelegate.parse)
            ?? NSRect(x: 120, y: 120, width: 700, height: 520)

        let window = ProbeWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        // The minimum the mover has to discover the hard way: a third of a
        // wide screen with a gap is narrower than this.
        window.contentMinSize = NSSize(width: 500, height: 400)
        window.isReleasedWhenClosed = false
        // Visible to the window server and to the accessibility API, and
        // almost invisible to whoever is looking at the screen.
        window.alphaValue = 0.05
        window.setFrame(frame, display: false)
        window.contentView = ProbeView()
        // Front without activation: this must never take the focus.
        window.orderFrontRegardless()
        self.window = window

        if arguments.contains("--eui") {
            let application = AXUIElementCreateApplication(getpid())
            AXUIElementSetAttributeValue(
                application,
                "AXEnhancedUserInterface" as CFString,
                kCFBooleanTrue
            )
        }

        // The hard stop. A probe that outlived its test would be a window the
        // user cannot explain.
        Timer.scheduledTimer(withTimeInterval: min(max(seconds, 1), 300), repeats: false) { _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func value(of name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    /// "x,y,w,h" in NS screen coordinates.
    static func parse(_ text: String) -> NSRect? {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
        return NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
}

/// Something to look at, in case anybody does.
final class ProbeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.withAlphaComponent(0.6).setFill()
        bounds.fill()
    }
}

let delegate = ProbeDelegate()
let app = NSApplication.shared
// An accessory app has no Dock icon and no menu bar, and it is never activated.
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
