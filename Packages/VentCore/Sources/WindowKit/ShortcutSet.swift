/// A complete set of shortcuts: every action has exactly one chord.
///
/// Two sets ship. Rectangle owns ⌃⌥ on this machine, so the user can move
/// Vent to the second set instead of quitting Rectangle, and no chord of the
/// second set may then be one Rectangle holds.
///
/// Both sets come from one table: the same key for the same action, on two
/// modifier tiers. The alternate set adds ⇧ to every chord, which is what
/// makes the two sets disjoint by construction.
///
/// One deviation from Rectangle's defaults: Rectangle puts Maximize Height on
/// ⌃⌥⇧↑ and Almost Maximize on ⌃⌥⇧↩. Vent puts them on the ⌘ tier (⌃⌥⌘↑ and
/// ⌃⌥⌘↩). On ⌃⌥⇧ they would sit exactly where the alternate set needs Top
/// Half and Maximize, so the two sets would overlap on the two chords
/// Rectangle already holds - the one thing the alternate set exists to avoid.
public struct ShortcutSet: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let bindings: [HotKeyBinding]

    public init(id: String, name: String, bindings: [HotKeyBinding]) {
        self.id = id
        self.name = name
        self.bindings = bindings
    }

    public func binding(for action: WindowAction) -> HotKeyBinding? {
        bindings.first { $0.action == action }
    }

    public var chords: Set<HotKeyChord> {
        Set(bindings.map(\.chord))
    }

    /// Rectangle's own layout: ⌃⌥ for the tiles, ⌃⌥⌘ for the extras.
    public static let rectangle = ShortcutSet(
        id: "rectangle",
        name: "Rectangle",
        bindings: layout.map { entry in
            HotKeyBinding(
                action: entry.action,
                keyCode: entry.keyCode,
                modifiers: entry.tier == .base ? [.control, .option] : [.control, .option, .command]
            )
        }
    )

    /// The same table with ⇧ added, for a Mac where another app holds ⌃⌥.
    public static let alternate = ShortcutSet(
        id: "alternate",
        name: "Alternate",
        bindings: layout.map { entry in
            HotKeyBinding(
                action: entry.action,
                keyCode: entry.keyCode,
                modifiers: entry.tier == .base
                    ? [.control, .option, .shift]
                    : [.control, .option, .shift, .command]
            )
        }
    )

    public static let all: [ShortcutSet] = [.rectangle, .alternate]

    enum Tier: Sendable {
        case base
        case extra
    }

    struct LayoutEntry: Sendable {
        let action: WindowAction
        let keyCode: UInt32
        let tier: Tier
    }

    /// The key of every action, once. Both sets read it.
    static let layout: [LayoutEntry] = [
        LayoutEntry(action: .leftHalf, keyCode: KeyCode.left, tier: .base),
        LayoutEntry(action: .rightHalf, keyCode: KeyCode.right, tier: .base),
        LayoutEntry(action: .topHalf, keyCode: KeyCode.up, tier: .base),
        LayoutEntry(action: .bottomHalf, keyCode: KeyCode.down, tier: .base),
        LayoutEntry(action: .topLeft, keyCode: KeyCode.u, tier: .base),
        LayoutEntry(action: .topRight, keyCode: KeyCode.i, tier: .base),
        LayoutEntry(action: .bottomLeft, keyCode: KeyCode.j, tier: .base),
        LayoutEntry(action: .bottomRight, keyCode: KeyCode.k, tier: .base),
        LayoutEntry(action: .maximize, keyCode: KeyCode.returnKey, tier: .base),
        LayoutEntry(action: .center, keyCode: KeyCode.c, tier: .base),
        LayoutEntry(action: .firstThird, keyCode: KeyCode.d, tier: .base),
        LayoutEntry(action: .centerThird, keyCode: KeyCode.f, tier: .base),
        LayoutEntry(action: .lastThird, keyCode: KeyCode.g, tier: .base),
        LayoutEntry(action: .firstTwoThirds, keyCode: KeyCode.e, tier: .base),
        LayoutEntry(action: .lastTwoThirds, keyCode: KeyCode.t, tier: .base),
        LayoutEntry(action: .restore, keyCode: KeyCode.delete, tier: .base),
        LayoutEntry(action: .smaller, keyCode: KeyCode.minus, tier: .base),
        LayoutEntry(action: .larger, keyCode: KeyCode.equal, tier: .base),
        LayoutEntry(action: .previousDisplay, keyCode: KeyCode.left, tier: .extra),
        LayoutEntry(action: .nextDisplay, keyCode: KeyCode.right, tier: .extra),
        LayoutEntry(action: .maximizeHeight, keyCode: KeyCode.up, tier: .extra),
        LayoutEntry(action: .almostMaximize, keyCode: KeyCode.returnKey, tier: .extra),
    ]
}
