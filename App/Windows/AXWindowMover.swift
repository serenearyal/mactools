import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import WindowKit

/// What one action did to one window.
enum WindowMoveResult: Equatable {
    /// The frame the window ended up with, in NS coordinates.
    case moved(CGRect)
    case refused(WindowRefusal)
    /// The action was fine but there was nothing to do: no restore point, a
    /// second display that does not exist, a screen too small for the gap.
    case unavailable(String)

    var refusal: WindowRefusal? {
        if case .refused(let reason) = self { return reason }
        return nil
    }

    /// One line for the UI and for the self test.
    var message: String? {
        switch self {
        case .moved: nil
        case .refused(let reason): reason.message
        case .unavailable(let text): text
        }
    }
}

/// The one place that writes to another app's window.
///
/// The geometry is not here: `WindowLayout`, `CycleLadder`, `ResizeStep` and
/// `DisplayMove` decide where a window goes, and this class does the awkward
/// part - the refusals, the coordinate flip, the accessibility write order and
/// the apps that answer with a different frame than the one they were given.
@MainActor
final class AXWindowMover {
    let restoreMemory = RestoreMemory()
    private var ladder = CycleLadder()
    private let log = AppLog.windows

    /// The last frame this mover asked for, for the self test and the debug
    /// status file.
    private(set) var lastIntendedFrame: CGRect?

    func resetCycle() {
        ladder.reset()
    }

    /// Move and resize one window.
    ///
    /// `target` may be minutes old (the popover captured it before it opened),
    /// so everything is read again here before anything is written.
    @discardableResult
    func apply(
        _ action: WindowAction,
        to target: WindowTarget,
        gap: CGFloat = 0,
        enhancedUserInterfaceWorkaround: Bool = true,
        now: Date = .now
    ) -> WindowMoveResult {
        guard AXIsProcessTrusted() else { return .refused(.accessibilityMissing) }
        guard let live = target.refreshed() else { return .refused(.noWindow) }
        if let refusal = live.refusal { return .refused(refusal) }

        let current = live.frame
        guard let screen = ScreenList.screen(containing: current) else {
            return .unavailable("No display was found for this window.")
        }

        let plan = plan(action: action, live: live, screen: screen, gap: gap, now: now)
        switch plan {
        case .failure(let result):
            return result
        case .success(let intended):
            lastIntendedFrame = intended
            if action != .restore {
                restoreMemory.remember(current, for: live)
            }
            let applied = write(intended, to: live, screen: screen, gap: gap, workaround: enhancedUserInterfaceWorkaround)
            if action == .restore { restoreMemory.forget(live) }
            // The ladder has to follow the window that refused the frame it
            // was given, otherwise the next press looks like a fresh one.
            ladder.rememberApplied(frame: applied)
            log.info(
                """
                \(action.rawValue, privacy: .public) on \(live.appName, privacy: .private): \
                \(String(describing: intended), privacy: .public) -> \
                \(String(describing: applied), privacy: .public)
                """
            )
            return .moved(applied)
        }
    }

    // MARK: - Where it goes

    private enum Plan {
        case success(CGRect)
        case failure(WindowMoveResult)
    }

    private func plan(
        action: WindowAction,
        live: WindowTarget,
        screen: ScreenFrame,
        gap: CGFloat,
        now: Date
    ) -> Plan {
        let current = live.frame
        switch action {
        case .restore:
            ladder.reset()
            guard let frame = restoreMemory.frame(for: live) else {
                return .failure(.unavailable("MacTools has not moved this window yet, so there is nothing to restore."))
            }
            return .success(frame)

        case .larger, .smaller:
            ladder.reset()
            let visible = screen.visibleFrame
            let step = action == .larger
                ? ResizeStep.larger(frame: current, in: visible)
                : ResizeStep.smaller(frame: current, in: visible)
            guard let step else {
                return .failure(.unavailable("This window cannot be resized on this display."))
            }
            return .success(step)

        case .nextDisplay, .previousDisplay:
            ladder.reset()
            let screens = ScreenList.all
            guard screens.count > 1 else {
                return .failure(.unavailable("Only one display is connected."))
            }
            let direction: DisplayMove.Direction = action == .nextDisplay ? .next : .previous
            guard let move = DisplayMove.target(
                screens: screens,
                current: screen.id,
                direction: direction,
                frame: current
            ) else {
                return .failure(.unavailable("This window cannot be sent to another display."))
            }
            return .success(move.frame)

        default:
            guard let frame = ladder.resolve(
                action: action,
                on: screen,
                current: current,
                gap: gap,
                now: now
            ) else {
                return .failure(.unavailable("This display is too small for that layout."))
            }
            return .success(frame)
        }
    }

    // MARK: - The write

    /// Size, then position, then size again, and a re-read at the end.
    ///
    /// The order matters. A window that is wider than the screen it is moving
    /// to would be clamped by the app if the position came first, and a window
    /// that grows before it moves can be pushed back by the Dock, so the size
    /// is written on both sides of the move. What the window ends up with is
    /// read back, never assumed: an app with a minimum size takes the position
    /// and refuses the size.
    private func write(
        _ frame: CGRect,
        to target: WindowTarget,
        screen: ScreenFrame,
        gap: CGFloat,
        workaround: Bool
    ) -> CGRect {
        let element = target.element
        let primary = ScreenList.primaryFrame
        let axFrame = AXGeometry.toAX(frame, primaryFrame: primary)

        withEnhancedUserInterfaceOff(pid: target.pid, enabled: workaround) {
            AX.setSize(element, AXAttribute.size, axFrame.size)
            AX.setPoint(element, AXAttribute.position, axFrame.origin)
            AX.setSize(element, AXAttribute.size, axFrame.size)
        }

        guard let readBack = AX.frame(element) else { return frame }
        var applied = AXGeometry.fromAX(readBack, primaryFrame: primary)

        // The app refused to shrink. It kept the position it was given, which
        // leaves it hanging over its neighbour; pinning it back to the edges
        // the layout asked for is the closest thing to what the user wanted.
        let refusedWidth = applied.width - frame.width > 1
        let refusedHeight = applied.height - frame.height > 1
        guard refusedWidth || refusedHeight else { return applied }

        let pinned = repin(actual: applied, intended: frame, screen: screen, gap: gap)
        guard pinned != applied else { return applied }
        withEnhancedUserInterfaceOff(pid: target.pid, enabled: workaround) {
            AX.setPoint(
                element,
                AXAttribute.position,
                AXGeometry.toAX(pinned, primaryFrame: primary).origin
            )
        }
        if let second = AX.frame(element) {
            applied = AXGeometry.fromAX(second, primaryFrame: primary)
        }
        return applied
    }

    /// The actual size, put back against the edges the intended frame touched.
    ///
    /// A left half that came back too wide stays flush left, a right half stays
    /// flush right, and a centre column stays centred on the column it was
    /// given. Everything is kept inside the visible frame at the end, so a
    /// window can never be pushed under the menu bar by this.
    func repin(actual: CGRect, intended: CGRect, screen: ScreenFrame, gap: CGFloat) -> CGRect {
        let field = screen.visibleFrame.insetBy(dx: WindowLayout.clampGap(gap), dy: WindowLayout.clampGap(gap))
        let tolerance: CGFloat = 1

        var x = intended.midX - actual.width / 2
        if abs(intended.minX - field.minX) <= tolerance {
            x = intended.minX
        } else if abs(intended.maxX - field.maxX) <= tolerance {
            x = intended.maxX - actual.width
        }
        var y = intended.midY - actual.height / 2
        if abs(intended.minY - field.minY) <= tolerance {
            y = intended.minY
        } else if abs(intended.maxY - field.maxY) <= tolerance {
            y = intended.maxY - actual.height
        }

        let visible = screen.visibleFrame
        x = min(max(x, visible.minX), max(visible.maxX - actual.width, visible.minX))
        y = min(max(y, visible.minY), max(visible.maxY - actual.height, visible.minY))
        return CGRect(x: x.rounded(), y: y.rounded(), width: actual.width, height: actual.height)
    }

    // MARK: - AXEnhancedUserInterface

    /// The known offset bug, and the known workaround.
    ///
    /// An app that has `AXEnhancedUserInterface` set (iTerm2, Firefox and
    /// Preview all do) reports and accepts window frames in a space of its own,
    /// so a move lands tens of points off. Switching the flag off around the
    /// write is what every window manager does.
    ///
    /// It is switched off only when it was on, put back exactly as it was, and
    /// never touched while VoiceOver runs: VoiceOver is the reason the flag
    /// exists, and taking it away would silence the screen reader.
    private func withEnhancedUserInterfaceOff(pid: pid_t, enabled: Bool, _ body: () -> Void) {
        guard enabled, !NSWorkspace.shared.isVoiceOverEnabled else {
            body()
            return
        }
        let application = AXUIElementCreateApplication(pid)
        let wasOn = AX.bool(application, AXAttribute.enhancedUserInterface) ?? false
        if wasOn {
            AX.setBool(application, AXAttribute.enhancedUserInterface, false)
        }
        body()
        if wasOn {
            AX.setBool(application, AXAttribute.enhancedUserInterface, true)
        }
    }
}
