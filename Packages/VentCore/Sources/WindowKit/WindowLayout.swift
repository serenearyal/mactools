import CoreGraphics

/// Where a window goes. The only place that knows the tile arithmetic.
///
/// Gap model: the visible frame is inset by `gap` on all four sides, and each
/// tile is then inset by `gap / 2` on its INTERNAL edges only. Two neighbours
/// are therefore exactly `gap` apart and exactly `gap` from the screen edge.
///
/// Every result is rounded on its four edges, never on origin plus size: the
/// rounding of an edge two tiles share is then the same in both, so the gap
/// survives the rounding to the point.
public enum WindowLayout {
    /// Wider gaps waste more screen than they help, and Rectangle stops here.
    public static let gapRange: ClosedRange<CGFloat> = 0...40

    /// Clamped to `gapRange` and rounded to a whole point. A fractional gap
    /// would break the adjacency guarantee at the rounding step.
    public static func clampGap(_ gap: CGFloat) -> CGFloat {
        guard gap.isFinite else { return 0 }
        return min(max(gap, gapRange.lowerBound), gapRange.upperBound).rounded()
    }

    /// The target frame, or nil when this action needs more than the screen
    /// (`restore`, `larger`, `smaller`, the display moves), when `current` is
    /// missing for an action that keeps part of the window, or when the screen
    /// is too small for the gap.
    public static func target(
        action: WindowAction,
        on screen: ScreenFrame,
        current: CGRect? = nil,
        gap: CGFloat = 0
    ) -> CGRect? {
        let gap = clampGap(gap)
        guard let field = field(of: screen, gap: gap) else { return nil }

        switch action {
        case .maximize:
            return Geometry.rounded(field)

        case .almostMaximize:
            // 90 % of the field, centred in it.
            let width = field.width * 0.9
            let height = field.height * 0.9
            return Geometry.rounded(
                CGRect(
                    x: field.midX - width / 2,
                    y: field.midY - height / 2,
                    width: width,
                    height: height
                )
            )

        case .center:
            // Keeps the size and ignores the gap: centring is about the
            // visible frame, not about tiling next to something.
            guard let current, Geometry.isFinite(current) else { return nil }
            let visible = screen.visibleFrame
            guard visible.width > 0, visible.height > 0 else { return nil }
            let width = min(current.width, visible.width)
            let height = min(current.height, visible.height)
            return Geometry.rounded(
                CGRect(
                    x: visible.midX - width / 2,
                    y: visible.midY - height / 2,
                    width: width,
                    height: height
                )
            )

        case .maximizeHeight:
            // Keeps x and width, takes the full height of the field.
            guard let current, Geometry.isFinite(current) else { return nil }
            return Geometry.rounded(
                CGRect(x: current.minX, y: field.minY, width: current.width, height: field.height)
            )

        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let left = action == .topLeft || action == .bottomLeft
            let top = action == .topLeft || action == .topRight
            return tile(
                field: field,
                x: left ? (0, 0.5) : (0.5, 1),
                y: top ? (0, 0.5) : (0.5, 1),
                gap: gap
            )

        default:
            guard let slot = action.slot(on: screen) else { return nil }
            return self.target(slot: slot, on: screen, gap: gap)
        }
    }

    /// The frame of one slot: the slot's share of its axis, the whole field on
    /// the other axis.
    public static func target(slot: WindowSlot, on screen: ScreenFrame, gap: CGFloat = 0) -> CGRect? {
        let gap = clampGap(gap)
        guard let field = field(of: screen, gap: gap) else { return nil }
        let share = slot.fraction
        let full = (0.0, 1.0)
        return tile(
            field: field,
            x: slot.axis == .horizontal ? (share.start, share.end) : full,
            y: slot.axis == .vertical ? (share.start, share.end) : full,
            gap: gap
        )
    }

    /// The visible frame minus the gap on all four sides. Nil when nothing is
    /// left of it, which is what a zero-sized screen or a 40 pt gap on a tiny
    /// screen gives.
    static func field(of screen: ScreenFrame, gap: CGFloat) -> CGRect? {
        let visible = screen.visibleFrame
        guard Geometry.isFinite(visible), visible.size.width > 0, visible.size.height > 0 else {
            return nil
        }
        // The size is checked before the rectangle is built: `CGRect.width`
        // answers with the standardized width, so a rectangle made with a
        // negative size looks perfectly healthy afterwards.
        let width = visible.width - 2 * gap
        let height = visible.height - 2 * gap
        guard width > 0, height > 0 else { return nil }
        return CGRect(x: visible.minX + gap, y: visible.minY + gap, width: width, height: height)
    }

    /// `x` runs from the left edge of the field, `y` from the TOP edge, both
    /// as a share of the field. An edge that is not 0 or 1 is internal and
    /// gets half the gap.
    private static func tile(
        field: CGRect,
        x: (Double, Double),
        y: (Double, Double),
        gap: CGFloat
    ) -> CGRect? {
        let half = gap / 2
        let minX = x.0 > 0 ? field.minX + field.width * x.0 + half : field.minX
        let maxX = x.1 < 1 ? field.minX + field.width * x.1 - half : field.maxX
        let maxY = y.0 > 0 ? field.maxY - field.height * y.0 - half : field.maxY
        let minY = y.1 < 1 ? field.maxY - field.height * y.1 + half : field.minY
        guard maxX > minX, maxY > minY else { return nil }
        return Geometry.rounded(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }
}

enum Geometry {
    static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
    }

    /// Rounds the four edges, not the origin and the size: a shared edge then
    /// rounds the same way in both tiles, which keeps them exactly `gap`
    /// apart because `round(v + n) == round(v) + n` for a whole `n`.
    static func rounded(_ rect: CGRect) -> CGRect {
        let minX = rect.minX.rounded()
        let minY = rect.minY.rounded()
        return CGRect(
            x: minX,
            y: minY,
            width: rect.maxX.rounded() - minX,
            height: rect.maxY.rounded() - minY
        )
    }
}
