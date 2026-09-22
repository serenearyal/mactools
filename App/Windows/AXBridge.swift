import ApplicationServices
import CoreGraphics
import Foundation

/// The accessibility attribute names this app reads and writes.
///
/// Written out instead of the `kAX...` globals on purpose. Half of them are
/// mutable CoreFoundation globals that Swift 6 refuses to read from an actor,
/// two of them ("AXFullScreen", "AXEnhancedUserInterface") have no constant at
/// all, and the strings themselves are frozen API: they travel over the
/// accessibility IPC by name.
enum AXAttribute {
    static let focusedWindow = "AXFocusedWindow"
    static let mainWindow = "AXMainWindow"
    static let windows = "AXWindows"
    static let title = "AXTitle"
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let position = "AXPosition"
    static let size = "AXSize"
    static let minimized = "AXMinimized"
    /// No constant exists for this one. It is the full-screen flag of a window.
    static let fullScreen = "AXFullScreen"
    /// Set by assistive clients; an app that sees it reports its window frame
    /// in a coordinate space of its own until it is switched off again.
    static let enhancedUserInterface = "AXEnhancedUserInterface"

    static let standardWindowSubrole = "AXStandardWindow"
    static let dialogSubrole = "AXDialog"
    static let windowRole = "AXWindow"
}

/// The thin layer over `AXUIElement`: read an attribute, write one, ask whether
/// it may be written.
///
/// Nothing above this file speaks `CFTypeRef`.
enum AX {
    /// How long one call may wait for another app, in seconds.
    ///
    /// The system default is about six seconds, and every call here runs on
    /// the main thread: one hung app would freeze the menu bar for a minute
    /// across the ten reads a capture does. A healthy app answers in a few
    /// milliseconds.
    static let messagingTimeout: Float = 0.3

    /// Puts the short timeout on one element. It belongs to the element, not
    /// to the app, so every element that is read from is given it first.
    static func limitTimeout(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
    }

    /// One read with its error, for the callers that stop when the app does
    /// not answer (`.cannotComplete`) instead of asking it again.
    static func read(_ element: AXUIElement, _ attribute: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error == .success ? value : nil, error)
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        read(element, attribute).value
    }

    static func asElement(_ raw: CFTypeRef?) -> AXUIElement? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        value(element, attribute) as? Bool
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        asElement(value(element, attribute))
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let raw = value(element, attribute) as? [AnyObject] else { return [] }
        return raw.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return (item as! AXUIElement)
        }
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }

    @discardableResult
    static func setPoint(_ element: AXUIElement, _ attribute: String, _ point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    @discardableResult
    static func setSize(_ element: AXUIElement, _ attribute: String, _ size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    @discardableResult
    static func setBool(_ element: AXUIElement, _ attribute: String, _ flag: Bool) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            attribute as CFString,
            flag as CFBoolean
        ) == .success
    }

    /// The window frame in accessibility coordinates: the origin is the
    /// top-left corner of the primary display and y grows downwards.
    static func frame(_ window: AXUIElement) -> CGRect? {
        guard let origin = point(window, AXAttribute.position),
              let size = size(window, AXAttribute.size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// The `CGWindowID` behind an accessibility element.
    ///
    /// `_AXUIElementGetWindow` is private, so it is looked up by name and the
    /// caller falls back to the process and the title when it is absent. It
    /// has been in HIServices since 10.4 and every window manager uses it; the
    /// `dlsym` is what makes its disappearance a missing feature rather than a
    /// crash on launch.
    static func windowID(of window: AXUIElement) -> CGWindowID? {
        guard let getWindow = axUIElementGetWindow else { return nil }
        var id = CGWindowID(0)
        guard getWindow(window, &id) == .success, id != 0 else { return nil }
        return id
    }

    static var hasWindowIDLookup: Bool { axUIElementGetWindow != nil }
}

private typealias AXUIElementGetWindowFunction =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

/// Resolved once. `dlopen(nil, ...)` is the handle of everything already
/// loaded, and HIServices is part of every AppKit process.
private let axUIElementGetWindow: AXUIElementGetWindowFunction? = {
    guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
    defer { dlclose(handle) }
    guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(symbol, to: AXUIElementGetWindowFunction.self)
}()
