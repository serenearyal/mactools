import SMCKit
import Synchronization

/// Fans that exist only in this process.
///
/// It is shipped rather than duplicated in each test target because three
/// places need the same double: the unit tests of the governor, the XPC
/// round-trip test of the helper, and the `--fake-fans` screenshot path of the
/// app, which drives a real `FanGovernor` so the UI shows the real code and
/// not a mock of it. It writes to nothing and reads no hardware.
public final class InMemoryFanHardware: FanHardware, Sendable {
    public struct Fan: Sendable, Equatable {
        public var minimum: Double
        public var maximum: Double
        public var actual: Double
        public var target: Double
        public var manual: Bool

        public init(minimum: Double, maximum: Double, actual: Double? = nil) {
            self.minimum = minimum
            self.maximum = maximum
            self.actual = actual ?? minimum
            target = 0
            manual = false
        }
    }

    /// Every call the governor made, in order, so a test can assert on the
    /// writes and not only on the end state.
    public enum Call: Sendable, Equatable {
        case readFans
        case readTemperature(String)
        case setAuto(Int)
        case setManual(Int, Double)
    }

    private struct State {
        var fans: [Fan]
        var temperatures: [String: Double]
        var calls: [Call] = []
        var failingWrites: Set<Int> = []
        var missingSensors: Set<String> = []
        var readFansError: String?
    }

    private let state: Mutex<State>

    public init(fans: [Fan], temperatures: [String: Double] = [:]) {
        state = Mutex(State(fans: fans, temperatures: temperatures))
    }

    /// The two fans of a MacBookPro18,3.
    public static func macBookPro() -> InMemoryFanHardware {
        InMemoryFanHardware(
            fans: [
                Fan(minimum: 1200, maximum: 5779),
                Fan(minimum: 1200, maximum: 6241),
            ],
            temperatures: ["Tp01": 52, "Tp09": 49, "Tg05": 46]
        )
    }

    // MARK: - What a test or the debug path changes

    public var calls: [Call] { state.withLock { $0.calls } }
    public var fans: [Fan] { state.withLock { $0.fans } }

    public func clearCalls() {
        state.withLock { $0.calls = [] }
    }

    public func setTemperature(_ celsius: Double, forKey key: String) {
        state.withLock { $0.temperatures[key] = celsius }
    }

    /// Writes to these fans throw.
    public func failWrites(forFan index: Int, _ failing: Bool = true) {
        state.withLock {
            if failing { $0.failingWrites.insert(index) } else { $0.failingWrites.remove(index) }
        }
    }

    /// Reads of these keys throw, even when a value is stored.
    public func hideSensor(_ key: String) {
        state.withLock { _ = $0.missingSensors.insert(key) }
    }

    public func failReadFans(_ reason: String?) {
        state.withLock { $0.readFansError = reason }
    }

    /// Moves every fan a step towards its setpoint, the way a real one would.
    /// Only the `--fake-fans` path uses it; the tests assert on setpoints.
    public func advance(seconds: Double) {
        state.withLock { state in
            for index in state.fans.indices {
                let fan = state.fans[index]
                let goal = fan.manual ? fan.target : fan.minimum
                let step = min(abs(goal - fan.actual), 600 * seconds)
                state.fans[index].actual = fan.actual + (goal > fan.actual ? step : -step)
            }
        }
    }

    // MARK: - FanHardware

    public func readFans() throws(FanHardwareError) -> [FanReading] {
        let result: Result<[FanReading], FanHardwareError> = state.withLock { state in
            state.calls.append(.readFans)
            if let reason = state.readFansError { return .failure(FanHardwareError(reason)) }
            return .success(
                state.fans.enumerated().map { index, fan in
                    FanReading(
                        index: index,
                        actual: fan.actual,
                        minimum: fan.minimum,
                        maximum: fan.maximum,
                        target: fan.target,
                        mode: fan.manual ? .forced : .auto
                    )
                }
            )
        }
        return try result.get()
    }

    public func readTemperature(key: String) throws(FanHardwareError) -> Double {
        let value: Double? = state.withLock { state in
            state.calls.append(.readTemperature(key))
            guard !state.missingSensors.contains(key) else { return nil }
            return state.temperatures[key]
        }
        guard let value else { throw FanHardwareError("sensor \(key) is not answering") }
        return value
    }

    public func setAuto(fan index: Int) throws(FanHardwareError) {
        let failure: FanHardwareError? = state.withLock { state in
            state.calls.append(.setAuto(index))
            guard state.fans.indices.contains(index) else {
                return FanHardwareError("there is no fan \(index)")
            }
            guard !state.failingWrites.contains(index) else {
                return FanHardwareError("the SMC refused the write to fan \(index)")
            }
            state.fans[index].manual = false
            state.fans[index].target = 0
            return nil
        }
        if let failure { throw failure }
    }

    public func setManual(fan index: Int, rpm: Double) throws(FanHardwareError) {
        let failure: FanHardwareError? = state.withLock { state in
            state.calls.append(.setManual(index, rpm))
            guard state.fans.indices.contains(index) else {
                return FanHardwareError("there is no fan \(index)")
            }
            guard !state.failingWrites.contains(index) else {
                return FanHardwareError("the SMC refused the write to fan \(index)")
            }
            state.fans[index].manual = true
            state.fans[index].target = rpm
            return nil
        }
        if let failure { throw failure }
    }
}

/// A `Result` cannot be thrown through a typed-throws function directly.
extension Result where Failure == FanHardwareError {
    fileprivate func get() throws(FanHardwareError) -> Success {
        switch self {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}
