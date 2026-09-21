/// The command list: every action, grouped, with its chord and whether it can
/// run right now.
///
/// One model for the three places that draw it - the Windows tab, the popover
/// and the status item's Window submenu - so the three cannot drift. The
/// groups and their order are Rectangle's menu: halves, corners, thirds, the
/// whole-screen actions, the displays.
public struct WindowCommandRow: Sendable, Equatable, Identifiable {
    public let action: WindowAction
    /// The chord of the chosen set, or nil when there is no set, the action
    /// has no default chord, or the user switched this one off.
    public let binding: HotKeyBinding?
    /// False when the action would do nothing: no window to act on, or a
    /// display move on a Mac with one display. The row is drawn dim.
    public let isAvailable: Bool

    public init(action: WindowAction, binding: HotKeyBinding?, isAvailable: Bool) {
        self.action = action
        self.binding = binding
        self.isAvailable = isAvailable
    }

    public var id: WindowAction { action }
    public var title: String { action.title }
    /// "⌃⌥←", or nil when this row shows no chord.
    public var shortcutDisplay: String? { binding?.display }
}

public struct WindowCommandGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let rows: [WindowCommandRow]

    public init(id: String, rows: [WindowCommandRow]) {
        self.id = id
        self.rows = rows
    }
}

public enum WindowCommandList {
    /// The groups, in Rectangle's own order. Every action is in exactly one.
    public static let groupedActions: [(id: String, actions: [WindowAction])] = [
        ("halves", [.leftHalf, .rightHalf, .centerHalf, .topHalf, .bottomHalf]),
        ("corners", [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        ("thirds", [.firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds]),
        ("screen", [.maximize, .almostMaximize, .maximizeHeight, .smaller, .larger, .center, .restore]),
        ("displays", [.nextDisplay, .previousDisplay]),
    ]

    /// Every action exactly once, in the order the list draws them.
    public static let actions: [WindowAction] = groupedActions.flatMap(\.actions)

    /// The rows for one state of the app.
    ///
    /// - Parameters:
    ///   - set: the live shortcut set, or nil when the shortcuts are off.
    ///   - disabled: the actions whose chord the user switched off.
    ///   - canAct: there is a window in front that Vent may move.
    ///   - screenCount: how many displays are attached.
    public static func groups(
        set: ShortcutSet?,
        disabled: Set<WindowAction> = [],
        canAct: Bool = true,
        screenCount: Int = 1
    ) -> [WindowCommandGroup] {
        groupedActions.map { group in
            WindowCommandGroup(
                id: group.id,
                rows: group.actions.map { action in
                    WindowCommandRow(
                        action: action,
                        binding: disabled.contains(action) ? nil : set?.binding(for: action),
                        isAvailable: canAct && (!action.needsSecondDisplay || screenCount > 1)
                    )
                }
            )
        }
    }
}
