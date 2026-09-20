import CoreGraphics
import Foundation

/// What the last accepted press did, so the next one can tell a repeat from a
/// fresh press.
public struct CycleState: Sendable, Equatable {
    public let action: WindowAction
    public let slot: WindowSlot
    /// The frame the window was given. A repeat only counts while the window
    /// is still there.
    public let frame: CGRect
    public let screenID: UInt32
    public let time: Date

    public init(action: WindowAction, slot: WindowSlot, frame: CGRect, screenID: UInt32, time: Date) {
        self.action = action
        self.slot = slot
        self.frame = frame
        self.screenID = screenID
        self.time = time
    }
}

/// Pressing the same shortcut again walks a ladder of sizes, the way Rectangle
/// does: a half becomes two thirds, then one third, then the half again.
/// Thirds walk first -> center -> last.
///
/// Anything else starts the ladder over: a different action, another screen,
/// more than `window` seconds since the last press, or a window the user has
/// moved away from where we put it.
public struct CycleLadder: Sendable, Equatable {
    public static let defaultWindow: TimeInterval = 2
    /// The AX write and the read back can differ by a point on a scaled
    /// display, so "unmoved" is not "identical".
    public static let defaultTolerance: CGFloat = 2

    public let window: TimeInterval
    public let tolerance: CGFloat
    public private(set) var state: CycleState?

    public init(
        window: TimeInterval = CycleLadder.defaultWindow,
        tolerance: CGFloat = CycleLadder.defaultTolerance
    ) {
        self.window = window
        self.tolerance = tolerance
    }

    public mutating func reset() {
        state = nil
    }

    /// The window did not take the frame it was given, so the ladder remembers
    /// where it really landed.
    ///
    /// A window with a minimum size refuses the narrow rungs; without this the
    /// next press would see a window that is not where the ladder put it, call
    /// that "the user moved it" and start the ladder over on every press.
    public mutating func rememberApplied(frame: CGRect) {
        guard let state, Geometry.isFinite(frame) else { return }
        self.state = CycleState(
            action: state.action,
            slot: state.slot,
            frame: frame,
            screenID: state.screenID,
            time: state.time
        )
    }

    /// The frame for this press, and the new state. `current` is where the
    /// window is now; a nil current cannot be a repeat.
    public mutating func resolve(
        action: WindowAction,
        on screen: ScreenFrame,
        current: CGRect?,
        gap: CGFloat = 0,
        now: Date
    ) -> CGRect? {
        guard let steps = Self.steps(for: action, on: screen) else {
            state = nil
            return WindowLayout.target(action: action, on: screen, current: current, gap: gap)
        }

        var index = 0
        if let state, isRepeat(of: state, action: action, screen: screen, current: current, now: now),
           let previous = steps.firstIndex(of: state.slot) {
            index = (previous + 1) % steps.count
        }

        let slot = steps[index]
        guard let frame = WindowLayout.target(slot: slot, on: screen, gap: gap) else {
            state = nil
            return nil
        }
        state = CycleState(action: action, slot: slot, frame: frame, screenID: screen.id, time: now)
        return frame
    }

    func isRepeat(
        of state: CycleState,
        action: WindowAction,
        screen: ScreenFrame,
        current: CGRect?,
        now: Date
    ) -> Bool {
        guard state.action == action, state.screenID == screen.id else { return false }
        let elapsed = now.timeIntervalSince(state.time)
        guard elapsed >= 0, elapsed < window else { return false }
        guard let current else { return false }
        return Self.matches(current, state.frame, tolerance: tolerance)
    }

    /// The ladder of an action, or nil when the action does not cycle. Only
    /// the halves and the thirds do; two thirds is a rung, not a start.
    static func steps(for action: WindowAction, on screen: ScreenFrame) -> [WindowSlot]? {
        guard let slot = action.slot(on: screen) else { return nil }
        switch action {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf:
            let spans: [WindowSlot.Span] = [.half, .twoThirds, .third]
            return spans.map {
                WindowSlot(axis: slot.axis, position: slot.position, span: $0)
            }
        case .firstThird, .centerThird, .lastThird:
            let order: [WindowSlot.Position] = [.first, .center, .last]
            guard let start = order.firstIndex(of: slot.position) else { return nil }
            return (0..<order.count).map {
                WindowSlot(axis: slot.axis, position: order[($0 + start) % order.count], span: .third)
            }
        default:
            return nil
        }
    }

    static func matches(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        guard Geometry.isFinite(lhs), Geometry.isFinite(rhs) else { return false }
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.maxX - rhs.maxX) <= tolerance
            && abs(lhs.maxY - rhs.maxY) <= tolerance
    }
}
