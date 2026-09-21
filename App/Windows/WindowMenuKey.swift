import AppKit
import WindowKit

/// A chord as an `NSMenuItem` key equivalent.
///
/// The status item's Window submenu shows the real thing - the same glyphs
/// AppKit draws for a main menu item - rather than a string in the title, so a
/// user reading the menu sees exactly what they have to press.
enum WindowMenuKey {
    /// The key equivalent and its modifier mask, or nil when the key is not
    /// one a menu can print.
    static func equivalent(for binding: HotKeyBinding) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard let key = key(for: binding.keyCode) else { return nil }
        return (key, modifiers(binding.modifiers))
    }

    /// The characters AppKit expects. The arrows are the function-key scalars
    /// from `NSEvent.h`; a menu draws them as ← ↑ → ↓.
    private static func key(for keyCode: UInt32) -> String? {
        switch keyCode {
        case KeyCode.c: "c"
        case KeyCode.d: "d"
        case KeyCode.e: "e"
        case KeyCode.f: "f"
        case KeyCode.g: "g"
        case KeyCode.i: "i"
        case KeyCode.j: "j"
        case KeyCode.k: "k"
        case KeyCode.t: "t"
        case KeyCode.u: "u"
        case KeyCode.minus: "-"
        case KeyCode.equal: "="
        case KeyCode.returnKey: "\r"
        // U+0008, the backspace character: what AppKit draws as ⌫.
        case KeyCode.delete: "\u{8}"
        case KeyCode.left: scalar(NSLeftArrowFunctionKey)
        case KeyCode.right: scalar(NSRightArrowFunctionKey)
        case KeyCode.up: scalar(NSUpArrowFunctionKey)
        case KeyCode.down: scalar(NSDownArrowFunctionKey)
        default: nil
        }
    }

    private static func scalar(_ value: Int) -> String? {
        UnicodeScalar(UInt32(value)).map { String(Character($0)) }
    }

    private static func modifiers(_ modifiers: HotKeyModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }
}
