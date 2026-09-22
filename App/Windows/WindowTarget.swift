import AppKit
import ApplicationServices
import CoreGraphics
import WindowKit

/// One window of another app, as it was when we looked at it.
///
/// The popover has to take this picture BEFORE it opens: showing the popover
/// activates MacTools, and from that moment the frontmost app is MacTools itself and
/// the window the user was working in is no longer focused anywhere.
///
/// The element is kept alongside the copied values. The values are for the UI,
/// which must not talk to another process while it draws; the element is for
/// the mover, which re-reads everything before it writes.
@MainActor
struct WindowTarget {
    let pid: pid_t
    let appName: String
    let bundleIdentifier: String?
    let element: AXUIElement
    let title: String
    /// NS coordinates: the origin is the bottom-left corner of the primary
    /// display. The accessibility API answers in its own flipped space, and
    /// this is already converted.
    let frame: CGRect
    let subrole: String?
    let isMinimized: Bool
    let isFullScreen: Bool
    let isPositionSettable: Bool
    let isSizeSettable: Bool
    let windowID: CGWindowID?
    let screenID: UInt32?

    var displayName: String {
        screenID.map(ScreenList.name(of:)) ?? "Display"
    }

    /// "Safari - Inbox", the line the header card shows.
    ///
    /// `--demo-window-title <text>` replaces the real title in a capture run:
    /// a screenshot for the README must not publish what the user had open.
    var label: String {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--demo-window-title"), index + 1 < arguments.count {
            return "\(appName) - \(arguments[index + 1])"
        }
        return title.isEmpty ? appName : "\(appName) - \(title)"
    }

    var sizeText: String {
        "\(Int(frame.width.rounded())) x \(Int(frame.height.rounded())) pt"
    }

    var icon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }

    /// Why this window cannot be tiled, or nil when it can.
    ///
    /// A dialog is a standard-enough window to tile: Rectangle moves them too,
    /// and a sheet is not a window of its own. What is refused is a window with
    /// no subrole at all (a panel, a popover, a status window) and anything the
    /// app itself has nailed down.
    var refusal: WindowRefusal? {
        if pid == ProcessInfo.processInfo.processIdentifier { return .isMacTools }
        if isFullScreen { return .fullScreen }
        if isMinimized { return .minimized }
        if let subrole, subrole != AXAttribute.standardWindowSubrole, subrole != AXAttribute.dialogSubrole {
            return .notStandardWindow
        }
        if subrole == nil { return .notStandardWindow }
        if !isPositionSettable || !isSizeSettable { return .notMovable }
        return nil
    }

    // MARK: - Capture

    /// The focused window of one process.
    ///
    /// `AXFocusedWindow` is what the user is typing in. An app that has no
    /// focused window (every window closed, or a menu bar app) still has a main
    /// window or a window list, and the first of those is what the user sees.
    ///
    /// An app that does not answer the first read is not asked twice: the
    /// fallbacks would each wait out the timeout again.
    static func capture(pid: pid_t) -> WindowTarget? {
        guard pid > 0 else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AX.limitTimeout(application)
        let focused = AX.read(application, AXAttribute.focusedWindow)
        guard focused.error != .cannotComplete else { return nil }
        let window = AX.asElement(focused.value)
            ?? AX.element(application, AXAttribute.mainWindow)
            ?? AX.elements(application, AXAttribute.windows).first
        guard let window else { return nil }
        return make(window: window, pid: pid)
    }

    /// The frontmost app right now. The hotkeys use this: a shortcut acts on
    /// what is in front at the instant it is pressed, never on a memory.
    static func captureFrontmost() -> WindowTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return capture(pid: app.processIdentifier)
    }

    /// Reads every value off an element that is already in hand.
    ///
    /// Nil when the app does not answer the first read, so a hung app costs
    /// one short timeout instead of ten of them.
    static func make(window: AXUIElement, pid: pid_t) -> WindowTarget? {
        AX.limitTimeout(window)
        guard AX.read(window, AXAttribute.position).error != .cannotComplete else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        let axFrame = AX.frame(window) ?? .zero
        let frame = AXGeometry.fromAX(axFrame, primaryFrame: ScreenList.primaryFrame)
        return WindowTarget(
            pid: pid,
            appName: app?.localizedName ?? "App",
            bundleIdentifier: app?.bundleIdentifier,
            element: window,
            title: AX.string(window, AXAttribute.title) ?? "",
            frame: frame,
            subrole: AX.string(window, AXAttribute.subrole),
            isMinimized: AX.bool(window, AXAttribute.minimized) ?? false,
            isFullScreen: AX.bool(window, AXAttribute.fullScreen) ?? false,
            isPositionSettable: AX.isSettable(window, AXAttribute.position),
            isSizeSettable: AX.isSettable(window, AXAttribute.size),
            windowID: AX.windowID(of: window),
            screenID: ScreenList.screen(containing: frame)?.id
        )
    }

    /// The same window, read again. The mover does this before every write: the
    /// user may have moved or closed the window since the capture.
    func refreshed() -> WindowTarget? {
        guard AX.frame(element) != nil else { return nil }
        return WindowTarget.make(window: element, pid: pid)
    }

    /// Every window of one app, for `mactoolsctl window list` and the self test.
    static func windows(of pid: pid_t) -> [WindowTarget] {
        let application = AXUIElementCreateApplication(pid)
        AX.limitTimeout(application)
        return AX.elements(application, AXAttribute.windows).compactMap { make(window: $0, pid: pid) }
    }
}
