/// The memory of one fan under a curve: a temperature that does not chase
/// noise, and a setpoint that does not jump.
///
/// Time is a parameter, never a clock read, so every rule here is testable
/// without waiting. The caller passes monotonic seconds.
public struct FanSmoother: Sendable, Equatable {
    private var heldTemperature: Double?
    private var lastTarget: Double?
    private var lastTime: Double?

    public init() {}

    /// The temperature the curve should use.
    ///
    /// A rise is followed at once. A fall is ignored until it is at least
    /// `Fans.hysteresisCelsius` below the value being held, so a die that
    /// flickers by a tenth of a degree does not modulate the fan.
    public mutating func temperature(_ raw: Double) -> Double {
        guard raw.isFinite else { return heldTemperature ?? raw }
        guard let held = heldTemperature else {
            heldTemperature = raw
            return raw
        }
        if raw >= held || held - raw >= Fans.hysteresisCelsius {
            heldTemperature = raw
            return raw
        }
        return held
    }

    /// The setpoint to write, limited to `Fans.slewRPMPerSecond`.
    ///
    /// The first call after a mode change jumps straight to the target: the
    /// fan was under firmware control until then, and there is no previous
    /// setpoint of ours to ramp from.
    public mutating func slew(toward target: Double, now: Double) -> Double {
        defer { lastTime = now }
        guard let previous = lastTarget, let last = lastTime, now >= last else {
            lastTarget = target
            return target
        }
        let limit = Fans.slewRPMPerSecond * (now - last)
        let step = min(max(target - previous, -limit), limit)
        let value = previous + step
        lastTarget = value
        return value
    }
}
