/// The modifier keys of a shortcut.
///
/// Own bits, not Carbon's: the stored settings must not depend on a framework
/// constant. `carbonFlags` converts for `RegisterEventHotKey`.
public struct HotKeyModifiers: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let control = HotKeyModifiers(rawValue: 1 << 0)
    public static let option = HotKeyModifiers(rawValue: 1 << 1)
    public static let shift = HotKeyModifiers(rawValue: 1 << 2)
    public static let command = HotKeyModifiers(rawValue: 1 << 3)

    /// The masks from Carbon's `Events.h`: they are plain numbers and have not
    /// changed since Mac OS 8.
    public var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.control) { flags |= 0x1000 }
        if contains(.option) { flags |= 0x0800 }
        if contains(.shift) { flags |= 0x0200 }
        if contains(.command) { flags |= 0x0100 }
        return flags
    }

    /// The symbols in the order macOS writes them: ⌃⌥⇧⌘.
    public var display: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

/// The ANSI virtual key codes this app binds. They are the hardware positions,
/// so they hold on a non-US layout.
public enum KeyCode {
    public static let c: UInt32 = 8
    public static let d: UInt32 = 2
    public static let e: UInt32 = 14
    public static let f: UInt32 = 3
    public static let g: UInt32 = 5
    public static let i: UInt32 = 34
    public static let j: UInt32 = 38
    public static let k: UInt32 = 40
    public static let t: UInt32 = 17
    public static let u: UInt32 = 32
    public static let minus: UInt32 = 27
    public static let equal: UInt32 = 24
    public static let returnKey: UInt32 = 36
    public static let delete: UInt32 = 51
    public static let left: UInt32 = 123
    public static let right: UInt32 = 124
    public static let down: UInt32 = 125
    public static let up: UInt32 = 126

    /// What the shortcut table prints for a key.
    public static func display(_ keyCode: UInt32) -> String {
        switch keyCode {
        case c: "C"
        case d: "D"
        case e: "E"
        case f: "F"
        case g: "G"
        case i: "I"
        case j: "J"
        case k: "K"
        case t: "T"
        case u: "U"
        case minus: "-"
        case equal: "="
        case returnKey: "↩"
        case delete: "⌫"
        case left: "←"
        case right: "→"
        case down: "↓"
        case up: "↑"
        default: "Key \(keyCode)"
        }
    }
}

public struct HotKeyBinding: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let action: WindowAction
    public let keyCode: UInt32
    public let modifiers: HotKeyModifiers

    public init(action: WindowAction, keyCode: UInt32, modifiers: HotKeyModifiers) {
        self.action = action
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var id: WindowAction { action }

    /// "⌃⌥←". The chord without the action name.
    public var display: String {
        modifiers.display + KeyCode.display(keyCode)
    }

    /// Two bindings collide when the chord is the same, whatever they do.
    public var chord: HotKeyChord {
        HotKeyChord(keyCode: keyCode, modifiers: modifiers)
    }
}

public struct HotKeyChord: Sendable, Equatable, Hashable, Codable {
    public let keyCode: UInt32
    public let modifiers: HotKeyModifiers

    public init(keyCode: UInt32, modifiers: HotKeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}
