import Foundation
import SMCKit

/// A refusal from the hardware, already worded for a human.
///
/// The governor only ever reports it, so it carries text and not a case per
/// SMC result code.
public struct FanHardwareError: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// Everything the governor may do to the fans.
///
/// A protocol and not the SMC type directly, so every rule in `FanGovernor`
/// can be tested against `InMemoryFanHardware`: no root, no fan, no machine.
public protocol FanHardware: Sendable {
    /// Speed, limits and firmware mode of every fan.
    func readFans() throws(FanHardwareError) -> [FanReading]

    /// One temperature sensor, by its four-character key.
    func readTemperature(key: String) throws(FanHardwareError) -> Double

    /// Hand the fan back to the firmware: mode 0 and target 0.
    func setAuto(fan index: Int) throws(FanHardwareError)

    /// Force the fan and give it a setpoint: mode 1, then the target.
    /// Implementations read every write back.
    func setManual(fan index: Int, rpm: Double) throws(FanHardwareError)
}

/// What to call a fan in the UI.
public enum FanNaming {
    public static func name(index: Int, of count: Int) -> String {
        switch (count, index) {
        case (1, _): "Fan"
        case (2, 0): "Left fan"
        case (2, 1): "Right fan"
        default: "Fan \(index + 1)"
        }
    }
}

/// The monotonic seconds the governor ticks on.
///
/// Never a wall clock: a time change, a leap second or an NTP step must not
/// move a fan.
public enum MonotonicTime {
    public static var seconds: Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
