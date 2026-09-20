import CoreGraphics

/// The flip between the two coordinate systems of macOS.
///
/// NS puts the origin at the bottom-left corner of the PRIMARY screen with y
/// upwards; the accessibility API puts it at the top-left corner of the same
/// screen with y downwards. Both use the primary screen, never the screen the
/// window is on, which is why a display above the primary one has a negative
/// y in NS and a smaller y in AX.
///
/// `axY = primary.maxY - (nsY + height)`, and the same formula reads back:
/// the flip is its own inverse, so a round trip is exact.
public enum AXGeometry {
    public static func toAX(_ rect: CGRect, primaryFrame: CGRect) -> CGRect {
        flip(rect, primaryFrame: primaryFrame)
    }

    public static func fromAX(_ rect: CGRect, primaryFrame: CGRect) -> CGRect {
        flip(rect, primaryFrame: primaryFrame)
    }

    private static func flip(_ rect: CGRect, primaryFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryFrame.maxY - (rect.minY + rect.height),
            width: rect.width,
            height: rect.height
        )
    }
}
