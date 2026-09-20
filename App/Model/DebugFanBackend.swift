import FanControl
import Foundation
import Synchronization

/// Fans that are not there, for the UI checks of a build agent.
///
/// It is only ever reached through the `--fake-fans` launch argument, the same
/// way `DebugCapture` works, and it is the only backend that needs no helper.
/// It drives a real `FanGovernor` over `InMemoryFanHardware`, so a screenshot
/// shows the shipping control path with the shipping clamps and not a mock of
/// the UI state.
struct DebugFanBackend: FanBackend {
    /// True when the app was started with `--fake-fans`.
    static var isRequested: Bool {
        CommandLine.arguments.contains("--fake-fans")
    }

    /// `--fan-mode 0=constant:2500`, `--fan-mode 1=curve:Tp01:45:85`,
    /// `--fan-mode 0=auto`. Only ever obeyed together with `--fake-fans`, so
    /// no command line can move a real fan.
    @MainActor
    static func applyLaunchArguments(_ arguments: [String], to store: FanStore) {
        guard isRequested else { return }
        for (index, token) in arguments.enumerated() where token == "--fan-mode" {
            guard index + 1 < arguments.count,
                  let (fan, mode) = parse(arguments[index + 1])
            else { continue }
            Task { await store.setMode(mode, forFan: fan) }
        }
    }

    private static func parse(_ text: String) -> (fan: Int, mode: FanMode)? {
        let halves = text.split(separator: "=", maxSplits: 1)
        guard halves.count == 2, let fan = Int(halves[0]) else { return nil }
        let parts = halves[1].split(separator: ":")
        switch parts.first {
        case "auto":
            return (fan, .auto)
        case "constant":
            guard parts.count == 2, let rpm = Int(parts[1]) else { return nil }
            return (fan, .constant(rpm: rpm))
        case "curve":
            guard parts.count == 4,
                  let start = Double(parts[2]),
                  let maximum = Double(parts[3])
            else { return nil }
            return (fan, .curve(sensorKey: String(parts[1]), startTemp: start, maxTemp: maximum))
        default:
            return nil
        }
    }

    private let driver = Driver()

    func snapshot() async throws(HelperConnectionError) -> FanSnapshot {
        driver.snapshot()
    }

    func setMode(_ mode: FanMode, forFan index: Int) async throws(HelperConnectionError) {
        if let fault = driver.setMode(mode, forFan: index) {
            throw .refused(fault)
        }
    }

    func restoreAllAuto() async throws(HelperConnectionError) {
        driver.restoreAllAuto()
    }

    /// The governor plus the pretend fans, behind a lock so the struct above
    /// can stay a value.
    private final class Driver: Sendable {
        private let hardware = InMemoryFanHardware.macBookPro()
        private let governor: FanGovernor
        private let clock = Mutex<Double>(0)

        init() {
            governor = FanGovernor(hardware: hardware, interlockSensorKeys: ["Tp01"])
            governor.tick(now: 0)
        }

        /// Time moves two seconds per poll, the cadence of the real helper.
        private func advance() -> Double {
            let now = clock.withLock { value -> Double in
                value += Fans.tickSeconds
                return value
            }
            hardware.advance(seconds: Fans.tickSeconds)
            governor.tick(now: now)
            return now
        }

        func snapshot() -> FanSnapshot {
            _ = advance()
            return governor.snapshot()
        }

        func setMode(_ mode: FanMode, forFan index: Int) -> String? {
            governor.setMode(mode, forFan: index, now: advance())
        }

        func restoreAllAuto() {
            governor.restoreAllAuto()
        }
    }
}
