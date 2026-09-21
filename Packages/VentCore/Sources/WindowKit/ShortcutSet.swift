/// A complete set of shortcuts: one chord for an action, or none.
///
/// Two sets ship.
///
/// `rectangle` is Rectangle's own default layout, key for key, as its menu
/// prints it: ⌃⌥ for the tiles, ⌃⌥⇧↑ for Maximize Height, ⌃⌥⌘ for the two
/// display moves, and no chord at all for Center Half and Almost Maximize.
/// That is the set Vent registers out of the box, so a user who came from
/// Rectangle presses what their fingers already know.
///
/// `alternate` is for a Mac where another manager still runs and holds every
/// one of those chords. It may not share a single chord with the first set,
/// which rules out "the same keys with ⇧ added": ⌃⌥⇧↑ is Rectangle's own
/// Maximize Height. So the alternate set adds ⇧ AND ⌘ to the tiles, and moves
/// the three chords that would then collide with a tile onto ⌃⇧⌘, which
/// carries no ⌥ and therefore cannot touch the first set either.
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

    /// The actions Rectangle ships without a default chord. They are on every
    /// list and in every menu; only the key column is empty.
    public static let unbound: Set<WindowAction> = [.centerHalf, .almostMaximize]

    /// Rectangle's own layout, exactly as its menu prints it.
    public static let rectangle = ShortcutSet(
        id: "rectangle",
        name: "Rectangle",
        bindings: layout.map { entry in
            HotKeyBinding(
                action: entry.action,
                keyCode: entry.keyCode,
                modifiers: entry.tier.rectangleModifiers
            )
        }
    )

    /// The same keys one tier up, for a Mac where another app owns ⌃⌥.
    public static let alternate = ShortcutSet(
        id: "alternate",
        name: "Alternate",
        bindings: layout.map { entry in
            HotKeyBinding(
                action: entry.action,
                keyCode: entry.keyCode,
                modifiers: entry.tier.alternateModifiers
            )
        }
    )

    public static let all: [ShortcutSet] = [.rectangle, .alternate]

    /// The three modifier tiers of Rectangle's defaults, and what the
    /// alternate set puts in their place.
    enum Tier: Sendable {
        /// ⌃⌥: every tile.
        case tile
        /// ⌃⌥⇧: Maximize Height, on its own.
        case shift
        /// ⌃⌥⌘: the two display moves.
        case command

        var rectangleModifiers: HotKeyModifiers {
            switch self {
            case .tile: [.control, .option]
            case .shift: [.control, .option, .shift]
            case .command: [.control, .option, .command]
            }
        }

        /// The tiles gain ⇧ and ⌘. The other two tiers would then land on a
        /// tile of their own set (↑ is Top Half, ← and → are the side halves),
        /// so they drop ⌥ instead: no chord of the first set is without it.
        var alternateModifiers: HotKeyModifiers {
            switch self {
            case .tile: [.control, .option, .shift, .command]
            case .shift, .command: [.control, .shift, .command]
            }
        }
    }

    struct LayoutEntry: Sendable {
        let action: WindowAction
        let keyCode: UInt32
        let tier: Tier
    }

    /// The key of every action that has one, once. Both sets read it.
    ///
    /// The order is the order of Rectangle's menu, which is the order the
    /// command list draws.
    static let layout: [LayoutEntry] = [
        LayoutEntry(action: .leftHalf, keyCode: KeyCode.left, tier: .tile),
        LayoutEntry(action: .rightHalf, keyCode: KeyCode.right, tier: .tile),
        LayoutEntry(action: .topHalf, keyCode: KeyCode.up, tier: .tile),
        LayoutEntry(action: .bottomHalf, keyCode: KeyCode.down, tier: .tile),
        LayoutEntry(action: .topLeft, keyCode: KeyCode.u, tier: .tile),
        LayoutEntry(action: .topRight, keyCode: KeyCode.i, tier: .tile),
        LayoutEntry(action: .bottomLeft, keyCode: KeyCode.j, tier: .tile),
        LayoutEntry(action: .bottomRight, keyCode: KeyCode.k, tier: .tile),
        LayoutEntry(action: .firstThird, keyCode: KeyCode.d, tier: .tile),
        LayoutEntry(action: .centerThird, keyCode: KeyCode.f, tier: .tile),
        LayoutEntry(action: .lastThird, keyCode: KeyCode.g, tier: .tile),
        LayoutEntry(action: .firstTwoThirds, keyCode: KeyCode.e, tier: .tile),
        LayoutEntry(action: .lastTwoThirds, keyCode: KeyCode.t, tier: .tile),
        LayoutEntry(action: .maximize, keyCode: KeyCode.returnKey, tier: .tile),
        LayoutEntry(action: .maximizeHeight, keyCode: KeyCode.up, tier: .shift),
        LayoutEntry(action: .smaller, keyCode: KeyCode.minus, tier: .tile),
        LayoutEntry(action: .larger, keyCode: KeyCode.equal, tier: .tile),
        LayoutEntry(action: .center, keyCode: KeyCode.c, tier: .tile),
        LayoutEntry(action: .restore, keyCode: KeyCode.delete, tier: .tile),
        LayoutEntry(action: .nextDisplay, keyCode: KeyCode.right, tier: .command),
        LayoutEntry(action: .previousDisplay, keyCode: KeyCode.left, tier: .command),
    ]
}
