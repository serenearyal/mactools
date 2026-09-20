import Foundation
import WindowKit

/// Which set of global shortcuts is live.
///
/// Off by default, and that is not timidity: Rectangle owns ⌃⌥ on the machine
/// this was written on, and a window manager that silently claims half of
/// another one's chords at first launch is a bug the user cannot see.
enum WindowShortcutChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case rectangle
    case alternate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .rectangle: "Rectangle layout"
        case .alternate: "Alternate layout"
        }
    }

    /// The chords of this choice, in the order the table shows them.
    var set: ShortcutSet? {
        switch self {
        case .off: nil
        case .rectangle: .rectangle
        case .alternate: .alternate
        }
    }

    var detail: String {
        switch self {
        case .off: "No global shortcut. The popover and this tab still work."
        case .rectangle: "Rectangle's own chords: ⌃⌥ for the tiles, ⌃⌥⌘ for the rest."
        case .alternate: "The same keys with ⇧ added, for a Mac where another app owns ⌃⌥."
        }
    }

    /// `--shortcut-set <name>`, case and separator tolerant.
    init?(argument: String) {
        let name = argument.lowercased().filter { $0 != "-" && $0 != "_" }
        guard let match = WindowShortcutChoice.allCases.first(where: { $0.rawValue == name })
        else { return nil }
        self = match
    }
}

/// Everything the window manager remembers, as one value inside the settings.
///
/// One nested key rather than five flat ones: the settings file gains a single
/// entry, and a build that does not know this feature keeps it untouched.
struct WindowSettingsData: Codable, Equatable, Sendable {
    var shortcutChoice: WindowShortcutChoice = .off
    /// The raw values of the actions the user switched off. Strings, so a
    /// renamed or removed action cannot make the whole settings file undecodable.
    var disabledActions: [String] = []
    /// The space between two tiled windows and the screen edge, 0 to 40 pt.
    var gap: Double = 0
    /// Switch `AXEnhancedUserInterface` off around a write. On by default:
    /// without it a window of iTerm2, Firefox or Preview lands tens of points
    /// away from where it was sent.
    var enhancedUserInterfaceWorkaround: Bool = true
    /// After a click on a tile in the popover, bring the app whose window moved
    /// back to the front, so the user carries on where they were.
    var reactivatesAfterTile: Bool = true

    var disabled: Set<WindowAction> {
        Set(disabledActions.compactMap(WindowAction.init(rawValue:)))
    }

    func isEnabled(_ action: WindowAction) -> Bool {
        !disabledActions.contains(action.rawValue)
    }

    mutating func setEnabled(_ enabled: Bool, for action: WindowAction) {
        if enabled {
            disabledActions.removeAll { $0 == action.rawValue }
        } else if !disabledActions.contains(action.rawValue) {
            disabledActions.append(action.rawValue)
        }
    }
}
