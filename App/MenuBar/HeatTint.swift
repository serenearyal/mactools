import Foundation

/// How hot the temperature in one cell of the status item label is.
///
/// Four steps, because a colour that changes on every degree is noise: normal,
/// then amber, orange and red. The rank is the whole ordering, so a cell can be
/// compared with the one the label drew last pass.
enum HeatLevel: Int, CaseIterable, Comparable, Hashable, Sendable {
    /// Below the first threshold. The label stays a template image.
    case normal = 0
    /// 70 C and up.
    case warm = 1
    /// 80 C and up.
    case hot = 2
    /// 90 C and up.
    case critical = 3

    static func < (lhs: HeatLevel, rhs: HeatLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The Celsius at which this level starts; nil for `normal`, which starts
    /// nowhere.
    var threshold: Double? {
        switch self {
        case .normal: nil
        case .warm: HeatTint.warmCelsius
        case .hot: HeatTint.hotCelsius
        case .critical: HeatTint.criticalCelsius
        }
    }

    /// True for the levels that need a colour, which is what decides whether
    /// the label can stay the template image it has always been.
    var isTinted: Bool { self != .normal }

    /// One word, for the label key, the log and the capture files.
    var name: String {
        switch self {
        case .normal: "normal"
        case .warm: "warm"
        case .hot: "hot"
        case .critical: "critical"
        }
    }
}

/// When a temperature in the menu bar label turns amber, orange and red.
///
/// Pure arithmetic over Celsius, whatever unit the label draws: a user in
/// Fahrenheit gets the colour at the same die temperature as everybody else.
enum HeatTint {
    static let warmCelsius = 70.0
    static let hotCelsius = 80.0
    static let criticalCelsius = 90.0

    /// How far a value has to fall back under the threshold that raised it
    /// before the colour goes down a step again.
    ///
    /// Without it a die sitting at 70.0 would flicker between black and amber
    /// once a second, which is the one thing a menu bar must never do. Two
    /// degrees is about the size of the jitter a CPU die shows at rest.
    static let hysteresis = 2.0

    /// The level a temperature has on its own, with no memory of the last one.
    static func level(celsius: Double) -> HeatLevel {
        guard celsius.isFinite else { return .normal }
        if celsius >= criticalCelsius { return .critical }
        if celsius >= hotCelsius { return .hot }
        if celsius >= warmCelsius { return .warm }
        return .normal
    }

    /// The level a temperature has after the one the label is already showing.
    ///
    /// Up is immediate: 90 C is red at once. Down waits for `hysteresis` under
    /// the threshold that raised the colour, and it can fall through several
    /// steps at once, which is what a fan that has just caught up really does.
    static func level(celsius: Double, previous: HeatLevel) -> HeatLevel {
        guard celsius.isFinite else { return .normal }
        let rising = level(celsius: celsius)
        guard rising < previous, let threshold = previous.threshold else { return rising }
        if celsius >= threshold - hysteresis { return previous }
        return level(
            celsius: celsius,
            previous: HeatLevel(rawValue: previous.rawValue - 1) ?? .normal
        )
    }
}
