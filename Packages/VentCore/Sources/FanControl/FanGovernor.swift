import SMCKit
import Synchronization

/// The control loop, with every decision in one place and no I/O of its own.
///
/// Concurrency: a final class holding its state in a `Mutex`, like
/// `SMCConnection`. The hardware calls happen under that lock, so a snapshot
/// taken from an XPC queue waits for the tick in progress instead of seeing
/// half of it. A tick is a handful of SMC round trips, well under a
/// millisecond each.
///
/// Fail-safe rule, everywhere: whatever goes wrong, the fan ends up in Auto
/// and the reason ends up in the snapshot. A fan the governor cannot steer is
/// better off with the firmware curve than with the last number it was given.
public final class FanGovernor: Sendable {
    private struct State {
        var desired: [Int: FanMode] = [:]
        var smoothers: [Int: FanSmoother] = [:]
        /// The setpoint last written, per fan. nil means "the fan is in Auto
        /// as far as we are concerned".
        var written: [Int: Double] = [:]
        var faults: [Int: String] = [:]
        var sensorCelsius: [Int: Double] = [:]
        var interlock = ThermalInterlock()
        var fans: [FanReading] = []
        var readError: String?
    }

    private let hardware: any FanHardware
    private let interlockKeys: [String]
    private let state = Mutex(State())

    public init(hardware: any FanHardware, interlockSensorKeys: [String] = Fans.interlockSensorKeys) {
        self.hardware = hardware
        self.interlockKeys = interlockSensorKeys
    }

    // MARK: - What the outside asks

    /// True while at least one fan is not in Auto. The helper runs its 2 s
    /// timer only then, so an idle machine pays nothing for fan control.
    public var isActive: Bool {
        state.withLock { !$0.desired.values.allSatisfy(\.isAuto) }
    }

    public var desiredModes: [Int: FanMode] {
        state.withLock { $0.desired.filter { !$0.value.isAuto } }
    }

    /// Stores the wish and acts on it at once, so the UI does not wait for the
    /// next tick. The reply is the fault for that fan, or nil.
    @discardableResult
    public func setMode(_ mode: FanMode, forFan index: Int, now: Double = MonotonicTime.seconds) -> String? {
        state.withLock { state in
            state.desired[index] = mode
            state.smoothers[index] = nil
            state.sensorCelsius[index] = nil
            state.faults[index] = nil
            // The cached setpoint belongs to the mode that is going away.
            state.written[index] = nil
            step(&state, now: now)
            return state.faults[index]
        }
    }

    /// One control step: read, decide, write.
    public func tick(now: Double = MonotonicTime.seconds) {
        state.withLock { step(&$0, now: now) }
    }

    /// Hands every fan back to the firmware and forgets every wish.
    ///
    /// Best effort by design: this runs on the way out of the process, on a
    /// signal and on sleep, where there is nobody left to report an error to.
    public func restoreAllAuto() {
        state.withLock { state in
            state.desired = [:]
            state.smoothers = [:]
            state.sensorCelsius = [:]
            autoEverywhere(&state)
        }
    }

    /// Auto on every fan, every wish kept.
    ///
    /// The sleep path. The SMC drops the forced mode over a sleep anyway, and
    /// `reapplyDesired` puts the wishes back on wake.
    public func suspend() {
        state.withLock { state in
            state.smoothers = [:]
            autoEverywhere(&state)
        }
    }

    /// Writes every held mode again, whatever the cache says.
    ///
    /// The SMC forgets the forced mode across a sleep, so the wake path cannot
    /// trust "we already wrote that".
    public func reapplyDesired(now: Double = MonotonicTime.seconds) {
        state.withLock { state in
            state.written = [:]
            state.smoothers = [:]
            step(&state, now: now)
        }
    }

    public func snapshot() -> FanSnapshot {
        state.withLock { state in
            let count = state.fans.count
            return FanSnapshot(
                fans: state.fans.map { fan in
                    FanStatus(
                        index: fan.index,
                        name: FanNaming.name(index: fan.index, of: count),
                        actualRPM: fan.actual,
                        minimumRPM: fan.minimum,
                        maximumRPM: fan.maximum,
                        targetRPM: fan.target,
                        hardwareMode: fan.mode,
                        mode: state.desired[fan.index] ?? .auto,
                        sensorCelsius: state.sensorCelsius[fan.index]
                    )
                },
                faults: state.faults
                    .map { index, reason in FanFault(fanIndex: index, reason: reason) }
                    .sorted { $0.fanIndex < $1.fanIndex },
                interlockEngaged: state.interlock.isEngaged,
                hottestDieCelsius: state.interlock.hottestDie,
                readError: state.readError
            )
        }
    }

    /// Reads the fans once so a snapshot has numbers before the first tick.
    public func refresh() {
        state.withLock { _ = readFans(into: &$0) }
    }

    // MARK: - The loop

    private func step(_ state: inout State, now: Double) {
        // Nothing can be decided without the limits and the current mode.
        guard readFans(into: &state) else { return }

        let engaged = state.interlock.update(hottestDie: hottestDie())
        for fan in state.fans {
            apply(fan: fan, interlockEngaged: engaged, now: now, &state)
        }
    }

    /// A `do`/`catch` inside a `withLock` closure catches `any Error`, because
    /// the thrown type of the closure is still being inferred there. These two
    /// keep the typed catches in plain methods.
    @discardableResult
    private func readFans(into state: inout State) -> Bool {
        do {
            state.fans = try hardware.readFans()
            state.readError = nil
            return true
        } catch {
            state.readError = error.description
            return false
        }
    }

    /// Auto on every fan the hardware admits to, the outcome recorded.
    private func autoEverywhere(_ state: inout State) {
        readFans(into: &state)
        for fan in state.fans {
            do {
                try hardware.setAuto(fan: fan.index)
                state.faults[fan.index] = nil
            } catch {
                state.faults[fan.index] = error.description
            }
        }
        state.written = [:]
    }

    /// The hottest die the interlock watches, or nil when none answered.
    private func hottestDie() -> Double? {
        var hottest: Double?
        for key in interlockKeys {
            guard let value = try? hardware.readTemperature(key: key), value.isFinite else { continue }
            hottest = max(hottest ?? value, value)
        }
        return hottest
    }

    private func apply(fan: FanReading, interlockEngaged: Bool, now: Double, _ state: inout State) {
        let index = fan.index
        // The wish is kept while the interlock holds, so the fan goes back to
        // the curve by itself once the die cools down.
        let effective: FanMode = interlockEngaged ? .auto : (state.desired[index] ?? .auto)

        switch effective {
        case .auto:
            restore(fan: index, hardwareMode: fan.mode, &state)

        case .constant(let rpm):
            guard let target = FanSafety.clamp(Double(rpm), minimum: fan.minimum, maximum: fan.maximum) else {
                fail(fan: index, reason: "fan \(index) reports no usable speed range", &state)
                return
            }
            write(target: target, fan: fan, &state)

        case .curve(let key, let start, let maxTemp):
            guard let raw = try? hardware.readTemperature(key: key), raw.isFinite else {
                fail(fan: index, reason: "sensor \(key) did not answer", &state)
                return
            }
            state.sensorCelsius[index] = raw
            var smoother = state.smoothers[index] ?? FanSmoother()
            let temperature = smoother.temperature(raw)
            guard let curved = FanCurve.targetRPM(
                temp: temperature,
                min: fan.minimum,
                max: fan.maximum,
                start: start,
                maxTemp: maxTemp
            ) else {
                fail(fan: index, reason: "the curve for sensor \(key) is not usable", &state)
                return
            }
            let target = smoother.slew(toward: curved, now: now)
            state.smoothers[index] = smoother
            write(target: target, fan: fan, &state)
        }
    }

    /// Back to the firmware. Only writes when the fan is, or might be, forced.
    private func restore(fan index: Int, hardwareMode: SMCFanMode, _ state: inout State) {
        guard hardwareMode != .auto || state.written[index] != nil else {
            state.faults[index] = nil
            return
        }
        do {
            try hardware.setAuto(fan: index)
            state.written[index] = nil
            state.smoothers[index] = nil
            state.sensorCelsius[index] = nil
            state.faults[index] = nil
        } catch {
            state.faults[index] = error.description
        }
    }

    private func write(target: Double, fan: FanReading, _ state: inout State) {
        let index = fan.index
        // The deadband saves an SMC write per tick under a curve. It never
        // applies when the firmware has taken the fan back, because then the
        // cached setpoint is not what the fan is doing.
        if fan.mode == .forced, let written = state.written[index],
           abs(target - written) < Fans.targetDeadbandRPM {
            state.faults[index] = nil
            return
        }
        do {
            try hardware.setManual(fan: index, rpm: target)
            state.written[index] = target
            state.faults[index] = nil
        } catch {
            fail(fan: index, reason: error.description, &state)
        }
    }

    /// A fan that cannot be steered goes back to Auto and stays there until
    /// the user picks a mode again. Retrying a broken configuration every two
    /// seconds would only write to the SMC for ever.
    private func fail(fan index: Int, reason: String, _ state: inout State) {
        state.desired[index] = .auto
        state.smoothers[index] = nil
        state.sensorCelsius[index] = nil
        try? hardware.setAuto(fan: index)
        state.written[index] = nil
        state.faults[index] = "\(reason); the fan is back to Auto"
    }
}
