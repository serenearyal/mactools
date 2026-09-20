import Foundation

/// The brightness ladder of the keyboard backlight.
///
/// The hardware keys move in sixteenths, and the slider has to land on the
/// same rungs: a value between two of them makes the next key press look like
/// it did nothing. 16 steps means 17 values, 0 and 1 included.
public enum BacklightScale {
    public static let steps = 16

    public static let levels: [Double] = (0...steps).map { Double($0) / Double(steps) }

    /// 0...1. An infinity still has a side to fall off, so it clamps to the
    /// bound; a value that is not a number has none and reads as off.
    public static func clamp(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return min(max(value, 0), 1)
    }

    /// The rung at `index`, clamped to the ladder.
    public static func level(at index: Int) -> Double {
        Double(min(max(index, 0), steps)) / Double(steps)
    }

    /// The nearest rung to an arbitrary value.
    public static func index(for value: Double) -> Int {
        Int((clamp(value) * Double(steps)).rounded())
    }

    /// The next rung strictly above `value`, or 1 at the top. A value that is
    /// already on a rung moves one step, not zero: the epsilon covers the
    /// rounding of 0.0625 coming back from the framework.
    public static func nextUp(from value: Double) -> Double {
        let scaled = clamp(value) * Double(steps)
        let step = Int((scaled + 1e-6).rounded(.down))
        return level(at: step + 1)
    }

    /// The next rung strictly below `value`, or 0 at the bottom.
    public static func nextDown(from value: Double) -> Double {
        let scaled = clamp(value) * Double(steps)
        let step = Int((scaled - 1e-6).rounded(.up))
        return level(at: step - 1)
    }

    /// "6%", "100%". Whole percent: a decimal here means nothing to the eye.
    public static func percentText(_ value: Double) -> String {
        "\(Int((clamp(value) * 100).rounded()))%"
    }
}
