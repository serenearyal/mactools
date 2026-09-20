import Foundation

/// Whether this Mac has a keyboard backlight Vent can drive.
///
/// The path runs through a private framework, so every step can be missing on
/// a machine Vent has never seen. When it is, the whole section disappears
/// instead of showing a dead slider - and the reason says which step failed.
public enum BacklightAvailability: Sendable, Equatable {
    case available(keyboardIDs: [UInt64])
    case unavailable(reason: Reason)

    public enum Reason: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
        /// `CoreBrightness.framework` did not load.
        case frameworkMissing
        /// The framework loaded but `KeyboardBrightnessClient` is gone.
        case classMissing
        /// The class answered with no keyboard at all.
        case noKeyboard
        /// Only external keyboards answered, and those are not ours to dim.
        case notBuiltIn

        public var message: String {
            switch self {
            case .frameworkMissing:
                "This version of macOS does not offer the keyboard backlight API."
            case .classMissing:
                "This version of macOS does not offer the keyboard backlight API."
            case .noKeyboard:
                "This Mac has no keyboard with a backlight."
            case .notBuiltIn:
                "Only the built-in keyboard can be dimmed, and this Mac has none."
            }
        }
    }

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var keyboardIDs: [UInt64] {
        if case .available(let ids) = self { return ids }
        return []
    }

    public var reason: Reason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// An empty id list is not "available": there would be nothing to write
    /// to.
    public static func available(ids: [UInt64]) -> BacklightAvailability {
        ids.isEmpty ? .unavailable(reason: .noKeyboard) : .available(keyboardIDs: ids)
    }
}
