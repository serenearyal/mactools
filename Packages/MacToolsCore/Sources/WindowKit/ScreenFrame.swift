import CoreGraphics

/// One display, in NS coordinates: the origin is the bottom-left corner of the
/// primary screen and y grows upwards. A screen left of or above the primary
/// one therefore has a negative origin.
///
/// `visibleFrame` is the part without the menu bar and the Dock. Every tile is
/// computed inside it; `frame` is only used for the orientation and for the
/// drag zones, which reach over the menu bar.
public struct ScreenFrame: Sendable, Equatable, Hashable, Codable, Identifiable {
    /// `CGDirectDisplayID`.
    public let id: UInt32
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    public var isPortrait: Bool { frame.height > frame.width }

    /// The order the display moves walk: left to right, then bottom to top.
    /// `id` breaks a tie so two stacked displays keep one fixed order.
    public static func ordered(_ screens: [ScreenFrame]) -> [ScreenFrame] {
        screens.sorted { left, right in
            if left.frame.minX != right.frame.minX { return left.frame.minX < right.frame.minX }
            if left.frame.minY != right.frame.minY { return left.frame.minY < right.frame.minY }
            return left.id < right.id
        }
    }
}
