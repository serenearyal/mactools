import Foundation

/// Everything that decides whether the fan glyph in the menu bar turns, and
/// how fast.
///
/// One value with every input in it, so the rule is a pure function and every
/// reason to stand still can be checked without a menu bar.
struct FanSpinConditions: Equatable, Sendable {
    /// The live speed of the fastest fan. nil when no fan has been read at
    /// all - a Mac with no helper, a pass that did not ask for fans, or a
    /// fanless Mac.
    var rpm: Double?
    /// The limits of that same fan, which are what the speed is mapped over.
    var minimumRPM: Double = 0
    var maximumRPM: Double = 0
    /// The glyph is in the label at all ("Show icon", or no metric at all).
    var showsIcon = true
    /// "Spin the fan icon".
    var spinEnabled = true
    /// `NSWorkspace.accessibilityDisplayShouldReduceMotion`.
    var reduceMotion = false
    /// The status item is on a screen. The menu bar of a notched Mac parks
    /// what does not fit off the edge, and nobody is watching that.
    var labelOnScreen = true
    var systemAsleep = false
    var lowPowerMode = false
}

/// The speed of the menu bar fan, as arithmetic.
enum FanSpin {
    /// One revolution in four seconds at the slowest speed the fan reports,
    /// and in one and a half at its maximum.
    static let slowestSeconds = 4.0
    static let fastestSeconds = 1.5

    /// The glyph turns in steps, this many a second. See `FanIconLayer`.
    ///
    /// The symbol has four blades, so a step of 45 degrees or more would read
    /// as standing still or as turning backwards. At the fastest speed a step
    /// is 360 / (8 x 1.5) = 30 degrees, which is why the fastest revolution is
    /// one and a half seconds and not half a second.
    static let framesPerSecond = 8.0

    /// Steps in one revolution at this speed, never fewer than eight.
    static func steps(secondsPerRevolution seconds: Double) -> Int {
        max(8, Int((seconds * framesPerSecond).rounded()))
    }

    /// How far the speed has to move before the animation is replaced.
    ///
    /// Every re-issue is a new `CABasicAnimation` and a handover through the
    /// presentation layer; a fan that wanders by twenty rpm must not cost one.
    static let reissueTolerance = 0.1

    /// Seconds per revolution, or nil to stand still.
    static func secondsPerRevolution(_ conditions: FanSpinConditions) -> Double? {
        guard conditions.showsIcon,
              conditions.spinEnabled,
              !conditions.reduceMotion,
              conditions.labelOnScreen,
              !conditions.systemAsleep,
              !conditions.lowPowerMode,
              let rpm = conditions.rpm
        else { return nil }
        return secondsPerRevolution(
            rpm: rpm,
            minimum: conditions.minimumRPM,
            maximum: conditions.maximumRPM
        )
    }

    /// The linear map from `minimum`...`maximum` rpm onto
    /// `slowestSeconds`...`fastestSeconds`. nil at a standstill: this M1 Pro
    /// idles at 0 rpm, and a glyph that turns while the fans do not is a lie.
    static func secondsPerRevolution(rpm: Double, minimum: Double, maximum: Double) -> Double? {
        guard rpm.isFinite, rpm > 0 else { return nil }
        guard minimum.isFinite, maximum.isFinite, maximum > minimum else { return slowestSeconds }
        let fraction = ((rpm - minimum) / (maximum - minimum)).clampedToUnitRange
        return slowestSeconds + fraction * (fastestSeconds - slowestSeconds)
    }

    /// True when the animation on screen has to be replaced by the new speed.
    ///
    /// Starting and stopping always count. Between two speeds it is the ratio
    /// that decides, so the rule reads the same whether it is applied to the
    /// period or to the revolutions per second.
    static func reissues(current: Double?, next: Double?) -> Bool {
        switch (current, next) {
        case (nil, nil):
            false
        case (nil, _), (_, nil):
            true
        case let (current?, next?):
            current > 0 && next > 0
                ? max(current, next) / min(current, next) > 1 + reissueTolerance
                : current != next
        }
    }
}

extension Double {
    fileprivate var clampedToUnitRange: Double { Swift.min(Swift.max(self, 0), 1) }
}
