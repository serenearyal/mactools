import CoreGraphics

public struct DisplayMoveResult: Sendable, Equatable {
    public let screen: ScreenFrame
    public let frame: CGRect

    public init(screen: ScreenFrame, frame: CGRect) {
        self.screen = screen
        self.frame = frame
    }
}

/// Send a window to the next or the previous display.
///
/// The frame is remapped proportionally: a window on the right half of a
/// 1512 pt screen lands on the right half of a 2560 pt one, at the same share
/// of its size. Nothing else keeps a tiled window tiled across two displays
/// with different scales.
public enum DisplayMove {
    public enum Direction: String, Sendable, Codable, CaseIterable {
        case next
        case previous
    }

    /// Nil with fewer than two displays, when `current` is not among them, or
    /// when a visible frame is empty.
    public static func target(
        screens: [ScreenFrame],
        current: UInt32,
        direction: Direction,
        frame: CGRect
    ) -> DisplayMoveResult? {
        let ordered = ScreenFrame.ordered(screens)
        guard ordered.count > 1, Geometry.isFinite(frame) else { return nil }
        guard let index = ordered.firstIndex(where: { $0.id == current }) else { return nil }

        let step = direction == .next ? 1 : ordered.count - 1
        let source = ordered[index]
        let destination = ordered[(index + step) % ordered.count]
        guard let remapped = remap(frame, from: source.visibleFrame, to: destination.visibleFrame) else {
            return nil
        }
        return DisplayMoveResult(screen: destination, frame: remapped)
    }

    /// The same share of the destination, then clamped so the window stays
    /// inside it.
    static func remap(_ frame: CGRect, from source: CGRect, to destination: CGRect) -> CGRect? {
        guard source.width > 0, source.height > 0 else { return nil }
        guard destination.width > 0, destination.height > 0 else { return nil }

        let scaleX = destination.width / source.width
        let scaleY = destination.height / source.height
        let width = min(frame.width * scaleX, destination.width)
        let height = min(frame.height * scaleY, destination.height)
        let x = destination.minX + (frame.minX - source.minX) * scaleX
        let y = destination.minY + (frame.minY - source.minY) * scaleY
        return Geometry.rounded(
            CGRect(
                x: min(max(x, destination.minX), destination.maxX - width),
                y: min(max(y, destination.minY), destination.maxY - height),
                width: width,
                height: height
            )
        )
    }
}
