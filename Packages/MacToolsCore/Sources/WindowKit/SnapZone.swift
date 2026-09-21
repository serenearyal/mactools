import CoreGraphics

/// Which tile the pointer asks for while a window is dragged to an edge.
///
/// Pure, and not used yet: drag snapping is a later batch. The zones follow
/// Rectangle: side edges give halves, their ends give the quarters, the top
/// edge maximizes and the bottom edge is split into thirds.
///
/// The zones are measured against `frame`, not `visibleFrame`: the pointer at
/// the top edge sits on the menu bar, which is outside the visible frame.
public enum SnapZone {
    /// How far a corner reaches along the side edge, as a share of the side.
    public static let cornerFraction: CGFloat = 0.25

    public static func action(for point: CGPoint, in screen: ScreenFrame, margin: CGFloat = 12) -> WindowAction? {
        let frame = screen.frame
        guard Geometry.isFinite(frame), frame.width > 0, frame.height > 0 else { return nil }
        guard margin > 0, point.x.isFinite, point.y.isFinite else { return nil }
        // CGRect.contains excludes the top and right edges, where the pointer
        // really is when it hits them.
        guard point.x >= frame.minX, point.x <= frame.maxX,
              point.y >= frame.minY, point.y <= frame.maxY else { return nil }

        let atLeft = point.x - frame.minX <= margin
        let atRight = frame.maxX - point.x <= margin
        if atLeft || atRight {
            let corner = frame.height * cornerFraction
            let atTop = frame.maxY - point.y <= corner
            let atBottom = point.y - frame.minY <= corner
            if atLeft {
                return atTop ? .topLeft : (atBottom ? .bottomLeft : .leftHalf)
            }
            return atTop ? .topRight : (atBottom ? .bottomRight : .rightHalf)
        }

        if frame.maxY - point.y <= margin { return .maximize }
        if point.y - frame.minY <= margin {
            let share = (point.x - frame.minX) / frame.width
            if share < 1.0 / 3 { return .firstThird }
            return share < 2.0 / 3 ? .centerThird : .lastThird
        }
        return nil
    }
}
