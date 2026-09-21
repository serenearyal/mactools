import Foundation
import WindowKit

/// Which set of global shortcuts is live.
///
/// Rectangle's own layout by default. A window manager whose shortcuts are off
/// until the user finds a picker in a tab is a window manager that does not
/// work, which is exactly how it was reported. The banner still names another
/// manager that is running and offers the alternate set in one click, so the
/// polite behaviour is kept where it belongs: in front of the user, not in the
/// default.
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
        case .off: "No global shortcut. The list above and the popover still work."
        case .rectangle:
            "Rectangle's own defaults, key for key: ⌃⌥ for the tiles, ⌃⌥⇧↑ for Maximize Height, ⌃⌥⌘ for the displays."
        case .alternate:
            "The same keys one tier up, for a Mac where another manager still owns ⌃⌥. No chord is shared with it."
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
    /// Rectangle's layout out of the box. See `WindowShortcutChoice`.
    var shortcutChoice: WindowShortcutChoice = .rectangle
    /// True once the user picked a set themselves, in the tab, in the popover
    /// or with a button of the conflict banner.
    ///
    /// It is what tells a deliberate "Off" from the old default. Builds up to
    /// this one shipped with the shortcuts off and wrote that choice into the
    /// settings file the first time anything else on the tab was touched, so
    /// without this marker a migration could not tell the two apart and would
    /// either leave the feature dead or overrule a user who really wants it
    /// quiet.
    var shortcutChoiceIsUserChoice: Bool = false
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

    init() {}

    /// Every key is optional, so a file written by an older build keeps what
    /// it does hold, and the stored choice goes through the migration.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = WindowSettingsData()
        shortcutChoice = try container.decodeIfPresent(
            WindowShortcutChoice.self,
            forKey: .shortcutChoice
        ) ?? fallback.shortcutChoice
        shortcutChoiceIsUserChoice = try container.decodeIfPresent(
            Bool.self,
            forKey: .shortcutChoiceIsUserChoice
        ) ?? fallback.shortcutChoiceIsUserChoice
        disabledActions = try container.decodeIfPresent([String].self, forKey: .disabledActions)
            ?? fallback.disabledActions
        gap = try container.decodeIfPresent(Double.self, forKey: .gap) ?? fallback.gap
        enhancedUserInterfaceWorkaround = try container.decodeIfPresent(
            Bool.self,
            forKey: .enhancedUserInterfaceWorkaround
        ) ?? fallback.enhancedUserInterfaceWorkaround
        reactivatesAfterTile = try container.decodeIfPresent(Bool.self, forKey: .reactivatesAfterTile)
            ?? fallback.reactivatesAfterTile
        migrateShortcutChoice()
    }

    /// An "Off" nobody chose becomes Rectangle's layout.
    ///
    /// Idempotent and pure: it runs on every read, and the only thing that
    /// stops it is the user saying "off" themselves, which sets the marker.
    mutating func migrateShortcutChoice() {
        guard !shortcutChoiceIsUserChoice, shortcutChoice == .off else { return }
        shortcutChoice = .rectangle
    }

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
