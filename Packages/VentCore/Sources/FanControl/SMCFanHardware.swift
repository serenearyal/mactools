import Foundation
import SMCKit
import Synchronization

/// The real fans, over the SMC. Only the privileged helper ever builds one:
/// every write here comes back as `SMCError.notPrivileged` without root.
///
/// Every write is read back. The SMC accepts a write to a key it will not act
/// on, and a fan that silently stayed in Auto while the UI said "2500 rpm"
/// would be the worst kind of bug in this app.
public final class SMCFanHardware: FanHardware, FanUnlockHardware, Sendable {
    private let smc: SMCConnection
    private let capabilities: FanCapabilities
    /// Key info is fixed for the life of the machine, and a cached one saves a
    /// driver round trip per read.
    private let keyInfo = Mutex<[SMCFourCC: SMCKeyInfo]>([:])

    /// The largest difference between a written and a read-back setpoint that
    /// still counts as the same value: `flt ` is a 32-bit float, and the SMC
    /// rounds.
    private static let verifyToleranceRPM: Double = 1

    public var fanCount: Int { capabilities.fanCount }
    public var hasForceTargets: Bool { capabilities.hasForceTargets }

    public init(smc: SMCConnection) throws(FanHardwareError) {
        self.smc = smc
        do {
            capabilities = try smc.fanCapabilities()
        } catch {
            throw FanHardwareError("the SMC did not describe its fans: \(error.description)")
        }
        guard capabilities.fanCount > 0 else {
            throw FanHardwareError("the SMC reports no fan")
        }
        guard capabilities.modeSuffix != nil else {
            throw FanHardwareError("the SMC has no fan mode key, so no fan can be forced")
        }
    }

    // MARK: - FanHardware

    public func readFans() throws(FanHardwareError) -> [FanReading] {
        var readings: [FanReading] = []
        for index in 0..<capabilities.fanCount {
            let mode: Double? = try? value(fan: index, suffix: capabilities.modeSuffix ?? FanKeys.mode)
            let target: Double? = try? value(fan: index, suffix: FanKeys.target)
            readings.append(
                FanReading(
                    index: index,
                    actual: try required(fan: index, suffix: FanKeys.actual),
                    minimum: try required(fan: index, suffix: FanKeys.minimum),
                    maximum: try required(fan: index, suffix: FanKeys.maximum),
                    target: target ?? 0,
                    mode: mode.map { $0 == 0 ? SMCFanMode.auto : .forced } ?? .unknown
                )
            )
        }
        return readings
    }

    public func readTemperature(key: String) throws(FanHardwareError) -> Double {
        guard let code = SMCFourCC(code: key) else {
            throw FanHardwareError("'\(key)' is not a four-character SMC key")
        }
        guard let celsius = try read(code) else {
            throw FanHardwareError("key \(key) does not hold a number")
        }
        return celsius
    }

    public func setAuto(fan index: Int) throws(FanHardwareError) {
        try write(0, fan: index, suffix: capabilities.modeSuffix ?? FanKeys.mode)
        // The target follows the mode: a stale setpoint left in `F%dTg` is
        // what makes a fan jump back to it the next time anything forces it.
        try? write(0, fan: index, suffix: FanKeys.target)
    }

    public func setManual(fan index: Int, rpm: Double) throws(FanHardwareError) {
        try FanUnlockStrategy.enableManualMode(fan: index, using: self) { seconds in
            Thread.sleep(forTimeInterval: seconds)
        }
        try write(rpm, fan: index, suffix: FanKeys.target)
    }

    // MARK: - FanUnlockHardware

    public func writeManualMode(fan index: Int) throws(FanHardwareError) {
        try write(1, fan: index, suffix: capabilities.modeSuffix ?? FanKeys.mode)
    }

    public func writeForceTargets() throws(FanHardwareError) {
        do {
            try smc.write(.number(1), to: FanKeys.forceTargets)
        } catch {
            throw FanHardwareError("cannot set \(FanKeys.forceTargets): \(error.description)")
        }
    }

    // MARK: - Keys

    private func key(fan index: Int, suffix: String) throws(FanHardwareError) -> SMCFourCC {
        guard let key = FanKeys.key(fan: index, suffix: suffix) else {
            throw FanHardwareError("fan \(index) has no '\(suffix)' key")
        }
        return key
    }

    private func info(for key: SMCFourCC) throws(FanHardwareError) -> SMCKeyInfo {
        if let cached = keyInfo.withLock({ $0[key] }) { return cached }
        do {
            let fresh = try smc.keyInfo(for: key)
            keyInfo.withLock { $0[key] = fresh }
            return fresh
        } catch {
            throw FanHardwareError("the SMC has no key \(key): \(error.description)")
        }
    }

    private func read(_ key: SMCFourCC) throws(FanHardwareError) -> Double? {
        let info = try info(for: key)
        do {
            return info.type.decode(try smc.readBytes(key, info: info)).doubleValue
        } catch {
            throw FanHardwareError("cannot read \(key): \(error.description)")
        }
    }

    private func value(fan index: Int, suffix: String) throws(FanHardwareError) -> Double? {
        try read(try key(fan: index, suffix: suffix))
    }

    private func required(fan index: Int, suffix: String) throws(FanHardwareError) -> Double {
        guard let value = try value(fan: index, suffix: suffix) else {
            throw FanHardwareError("key F\(index)\(suffix) does not hold a number")
        }
        return value
    }

    /// Writes and reads back. A value the SMC did not take is an error, not a
    /// silent no-op.
    private func write(_ value: Double, fan index: Int, suffix: String) throws(FanHardwareError) {
        let key = try key(fan: index, suffix: suffix)
        let info = try info(for: key)
        guard let payload = info.type.encode(.number(value)) else {
            throw FanHardwareError("\(value) does not fit the \(info.type.code) encoding of \(key)")
        }
        do {
            try smc.writeBytes(payload, to: key, info: info)
        } catch {
            throw FanHardwareError("cannot write \(key): \(error.description)")
        }
        guard let readBack = try read(key) else {
            throw FanHardwareError("key \(key) does not hold a number")
        }
        guard abs(readBack - value) <= SMCFanHardware.verifyToleranceRPM else {
            throw FanHardwareError(
                "the SMC did not take \(Int(value.rounded())) for \(key); it still reads \(Int(readBack.rounded()))"
            )
        }
    }
}
