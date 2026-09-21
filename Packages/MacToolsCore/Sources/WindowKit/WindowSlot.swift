/// A share of one axis of the screen: the vocabulary the cycle ladder speaks.
///
/// The action list has no "top two thirds", so the ladder cannot be written in
/// actions alone. A slot says the same thing in a form that works on both
/// axes: `first` is the left end of the horizontal axis and the TOP end of the
/// vertical one, so "first third" reads the same way on a portrait screen.
public struct WindowSlot: Sendable, Equatable, Hashable, Codable {
    public enum Axis: String, Sendable, Codable, CaseIterable {
        case horizontal
        case vertical
    }

    public enum Position: String, Sendable, Codable, CaseIterable {
        case first
        case center
        case last
    }

    public enum Span: String, Sendable, Codable, CaseIterable {
        case half
        case twoThirds
        case third
    }

    public let axis: Axis
    public let position: Position
    public let span: Span

    public init(axis: Axis, position: Position, span: Span) {
        self.axis = axis
        self.position = position
        self.span = span
    }

    /// The share of the axis, measured from the first end.
    ///
    /// Written out instead of derived, so that a boundary two slots share is
    /// the same Double in both: `1 - 1.0/3` and `2.0/3` differ by one bit.
    var fraction: (start: Double, end: Double) {
        switch (span, position) {
        case (.half, .first): (0, 0.5)
        case (.half, .center): (0.25, 0.75)
        case (.half, .last): (0.5, 1)
        case (.twoThirds, .first): (0, 2.0 / 3)
        case (.twoThirds, .center): (1.0 / 6, 5.0 / 6)
        case (.twoThirds, .last): (1.0 / 3, 1)
        case (.third, .first): (0, 1.0 / 3)
        case (.third, .center): (1.0 / 3, 2.0 / 3)
        case (.third, .last): (2.0 / 3, 1)
        }
    }
}
