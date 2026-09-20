import CoreGraphics

/// Grow or shrink a window around its centre.
///
/// The step is the change of the whole side, so the window keeps its centre
/// and moves by half a step on each edge. At the bounds the answer is the
/// frame itself, so holding the shortcut down stops instead of drifting.
public enum ResizeStep {
    public static let defaultStep: CGFloat = 30
    /// Smaller than this is not a usable window any more.
    public static let minimumSize = CGSize(width: 200, height: 120)

    public static func larger(
        frame: CGRect,
        in visible: CGRect,
        step: CGFloat = ResizeStep.defaultStep
    ) -> CGRect? {
        resize(frame: frame, in: visible, by: abs(step))
    }

    public static func smaller(
        frame: CGRect,
        in visible: CGRect,
        step: CGFloat = ResizeStep.defaultStep
    ) -> CGRect? {
        resize(frame: frame, in: visible, by: -abs(step))
    }

    /// Nil when the visible frame or the window frame is not a usable
    /// rectangle. A visible frame smaller than `minimumSize` lowers the
    /// minimum: nothing may be pushed outside the screen.
    static func resize(frame: CGRect, in visible: CGRect, by delta: CGFloat) -> CGRect? {
        guard Geometry.isFinite(frame), Geometry.isFinite(visible), delta.isFinite else { return nil }
        guard visible.width > 0, visible.height > 0 else { return nil }

        let minWidth = min(minimumSize.width, visible.width)
        let minHeight = min(minimumSize.height, visible.height)
        let width = min(max(frame.width + delta, minWidth), visible.width)
        let height = min(max(frame.height + delta, minHeight), visible.height)
        let x = min(max(frame.midX - width / 2, visible.minX), visible.maxX - width)
        let y = min(max(frame.midY - height / 2, visible.minY), visible.maxY - height)
        return Geometry.rounded(CGRect(x: x, y: y, width: width, height: height))
    }
}
