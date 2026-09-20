/// The two writes a machine may need before it accepts a forced fan.
public protocol FanUnlockHardware: Sendable {
    /// True when the SMC has `Ftst`. Apple silicon does not.
    var hasForceTargets: Bool { get }
    /// `F%dMd = 1`, read back.
    func writeManualMode(fan index: Int) throws(FanHardwareError)
    /// `Ftst = 1`, the Intel unlock.
    func writeForceTargets() throws(FanHardwareError)
}

/// How to get a fan out of firmware control.
///
/// The direct write is all an M1 Pro needs, and it is tried first everywhere.
/// Some Intel machines refuse it until `Ftst` is set, and then take a moment
/// to change their mind, hence the retry window. That path cannot be tested on
/// this machine, so it is kept to these few lines and nothing else depends on
/// it.
public enum FanUnlockStrategy {
    /// How long the `Ftst` path keeps retrying.
    public static let retryWindowSeconds: Double = 10
    /// Between retries.
    public static let retryIntervalSeconds: Double = 0.5

    public static func enableManualMode(
        fan index: Int,
        using hardware: some FanUnlockHardware,
        sleep: (Double) -> Void
    ) throws(FanHardwareError) {
        do {
            try hardware.writeManualMode(fan: index)
            return
        } catch {
            guard hardware.hasForceTargets else { throw error }
        }

        try hardware.writeForceTargets()
        var waited: Double = 0
        while true {
            do {
                try hardware.writeManualMode(fan: index)
                return
            } catch {
                guard waited < retryWindowSeconds else { throw error }
                sleep(retryIntervalSeconds)
                waited += retryIntervalSeconds
            }
        }
    }
}
