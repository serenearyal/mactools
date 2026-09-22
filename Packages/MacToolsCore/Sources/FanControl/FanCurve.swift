/// The linear ramp between two temperatures.
///
/// Every failure is nil, never a guessed speed. A nil makes the governor put
/// that fan back to Auto and report the fault, which is the only safe answer
/// when the input is not trustworthy: the firmware curve is always better
/// than a number this code invented.
public enum FanCurve {
    /// The setpoint for `temp`, or nil when the inputs make no curve.
    ///
    /// - `temp` at or below `start` gives `minimum`.
    /// - `temp` at or above `maxTemp` gives `maximum`.
    /// - In between the speed rises linearly.
    /// - `start == maxTemp` is a step: below is `minimum`, at or above is
    ///   `maximum`.
    /// - An inverted range, an inverted fan range or any value that is not a
    ///   finite number gives nil.
    public static func targetRPM(
        temp: Double,
        min minimum: Double,
        max maximum: Double,
        start: Double,
        maxTemp: Double
    ) -> Double? {
        guard temp.isFinite, start.isFinite, maxTemp.isFinite else { return nil }
        guard minimum.isFinite, maximum.isFinite, maximum > 0, maximum >= minimum, minimum >= 0 else {
            return nil
        }
        guard maxTemp >= start else { return nil }

        // The order matters for the step case, where the two bounds are equal:
        // the fan is at full speed from the moment the sensor reaches them.
        if temp >= maxTemp { return maximum }
        if temp <= start { return minimum }
        let fraction = (temp - start) / (maxTemp - start)
        return minimum + (maximum - minimum) * fraction
    }

    /// True when the fan should spin on the ramp, false when it should be off.
    ///
    /// Below the start temperature the fan is held at 0 rpm. Handing it to
    /// the firmware there is not the same: macOS keeps a fan that was
    /// spinning at about 40 % for minutes (measured on an M1 Pro), so the
    /// start would not mean "quiet until here". A spinning fan stops only
    /// `Fans.curveReleaseCelsius` below the start.
    public static func spinsFan(temp: Double, start: Double, wasSpinning: Bool) -> Bool {
        if wasSpinning { return temp > start - Fans.curveReleaseCelsius }
        return temp >= start
    }
}
