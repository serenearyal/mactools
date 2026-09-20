import AppKit
import CoreGraphics
import WindowKit

/// The bridge from `NSScreen` to the pure `ScreenFrame` the geometry speaks.
///
/// Everything is measured against `NSScreen.screens[0]`, the primary display:
/// that is the one both coordinate systems agree on, and it is not always the
/// one the window is on.
@MainActor
enum ScreenList {
    /// The primary display, the origin of both coordinate systems.
    static var primaryFrame: CGRect {
        NSScreen.screens.first?.frame ?? .zero
    }

    static func displayID(of screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func frame(of screen: NSScreen) -> ScreenFrame {
        ScreenFrame(
            id: displayID(of: screen),
            frame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
    }

    static var all: [ScreenFrame] {
        NSScreen.screens.map(frame(of:))
    }

    static var count: Int { NSScreen.screens.count }

    static func name(of id: UInt32) -> String {
        guard let screen = NSScreen.screens.first(where: { displayID(of: $0) == id }) else {
            return "Display"
        }
        return screen.localizedName
    }

    /// The screen a window belongs to: the one that holds most of it.
    ///
    /// Not the one under the origin. A window dragged half off the left edge of
    /// the second display has its origin on the first one, and tiling it there
    /// would throw it across the desk.
    static func screen(containing frame: CGRect) -> ScreenFrame? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let best = screens.max { left, right in
            area(of: frame.intersection(left.frame)) < area(of: frame.intersection(right.frame))
        }
        guard let best, area(of: frame.intersection(best.frame)) > 0 else {
            // Entirely off screen: the display with the nearest centre, so a
            // window that was left behind by an unplugged display comes back.
            let nearest = screens.min { left, right in
                distance(frame.center, left.frame.center) < distance(frame.center, right.frame.center)
            }
            return nearest.map(self.frame(of:))
        }
        return self.frame(of: best)
    }

    private static func area(of rect: CGRect) -> CGFloat {
        guard !rect.isNull, !rect.isEmpty else { return 0 }
        return rect.width * rect.height
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
