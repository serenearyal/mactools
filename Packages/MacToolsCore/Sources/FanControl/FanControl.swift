import SMCKit

/// The constants the governor, the helper, the CLI and the UI all share.
///
/// Every number here is a safety decision, so they live in one place instead
/// of being spelled out at each call site.
public enum Fans {
    /// Any CPU or GPU sensor at or above this value forces the fans back to
    /// Auto, whatever the user asked for.
    public static let thermalInterlockCelsius: Double = 100

    /// The interlock only lets go once the hottest die is below this. The gap
    /// keeps a die that hovers at 100 C from toggling the fans every tick.
    public static let thermalReleaseCelsius: Double = 90

    /// One control step. Slow enough to cost nothing, fast enough that a curve
    /// reacts before a die climbs 10 C.
    public static let tickSeconds: Double = 2

    /// A falling temperature must fall this far before the curve follows it.
    public static let hysteresisCelsius: Double = 0.5

    /// How fast a curve may move its setpoint. A constant speed is not slewed:
    /// the user asked for an exact number and a ramp would feel broken.
    public static let slewRPMPerSecond: Double = 200

    /// A setpoint that moved less than this is not worth an SMC write.
    public static let targetDeadbandRPM: Double = 10

    /// The dies the interlock watches.
    public static let interlockCategories: Set<SensorCategory> = [
        .cpuPerformance, .cpuEfficiency, .gpu,
    ]

    /// Keys of those dies, as the strings `FanHardware` takes.
    public static let interlockSensorKeys: [String] = SensorNaming
        .knownTemperatureKeys(in: interlockCategories)
        .map(\.stringValue)
}
