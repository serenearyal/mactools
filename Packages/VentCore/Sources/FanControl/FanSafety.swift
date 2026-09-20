/// The two rules that stand between a request and the hardware.
public enum FanSafety {
    /// `rpm` inside the limits the firmware reports, or nil when those limits
    /// are not a usable range.
    ///
    /// A fan whose `F%dMn`/`F%dMx` did not answer reads 0/0 here, and writing
    /// a setpoint into that range would stop the fan. nil is a fault.
    public static func clamp(_ rpm: Double, minimum: Double, maximum: Double) -> Double? {
        guard rpm.isFinite, minimum.isFinite, maximum.isFinite else { return nil }
        guard maximum > 0, minimum >= 0, maximum >= minimum else { return nil }
        return min(max(rpm, minimum), maximum)
    }

    /// True while the dies are too hot for anything but the firmware curve.
    ///
    /// Two thresholds, because one would toggle the fans every tick at exactly
    /// 100 C. `hottest` is nil when no die answered; the state then stays as
    /// it is, since neither tripping nor releasing on missing data is safe.
    public static func interlockEngaged(wasEngaged: Bool, hottestDie: Double?) -> Bool {
        guard let hottest = hottestDie, hottest.isFinite else { return wasEngaged }
        if wasEngaged { return hottest >= Fans.thermalReleaseCelsius }
        return hottest >= Fans.thermalInterlockCelsius
    }
}

/// The interlock with its one bit of memory.
public struct ThermalInterlock: Sendable, Equatable {
    public private(set) var isEngaged: Bool
    /// The reading that decided the current state, for the UI banner.
    public private(set) var hottestDie: Double?

    public init(isEngaged: Bool = false) {
        self.isEngaged = isEngaged
    }

    @discardableResult
    public mutating func update(hottestDie: Double?) -> Bool {
        isEngaged = FanSafety.interlockEngaged(wasEngaged: isEngaged, hottestDie: hottestDie)
        if let hottestDie, hottestDie.isFinite { self.hottestDie = hottestDie }
        return isEngaged
    }
}
