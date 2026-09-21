import Foundation
import IOKit

import HelperProtocol

/// The real `SleepDisabled` system power setting, the one `pmset disablesleep`
/// writes.
///
/// `IOPMSetSystemPowerSetting` and `IOPMCopySystemPowerSettings` are exported
/// by IOKit and declared in no public header, so both are reached through
/// `dlsym` rather than by redeclaring the symbols: a wrong redeclaration is a
/// link error at best and a crash at worst. This is the same way the app reads
/// the flag in `PowerAssertions.sleepDisabled()`, and the same pair of calls
/// `pmset` itself makes. Shelling out to `pmset` would mean a subprocess as
/// root for one integer.
///
/// The write needs root, which the daemon has and nothing else here does.
///
/// This file belongs to the helper target alone, exactly like
/// `HelperService.daemon()` and `SMCFanHardware`: the test bundle compiles
/// `HelperService.swift` to exercise the XPC path, and with the construction
/// of the real setting out of that file there is no way for a test to disable
/// sleep on the machine it runs on.
struct SystemSleepSetting: SystemSleepSwitch {
    /// `kIOPMSleepDisabledKey`, from `IOPMLibPrivate.h`.
    static let key = "SleepDisabled"

    private typealias Copy = @convention(c) () -> Unmanaged<CFDictionary>?
    private typealias Set = @convention(c) (CFString, CFTypeRef) -> IOReturn

    func read() throws -> Bool {
        guard let symbol = Self.symbol("IOPMCopySystemPowerSettings") else {
            throw SleepSwitchError("IOPMCopySystemPowerSettings is not in this IOKit")
        }
        let copy = unsafeBitCast(symbol, to: Copy.self)
        guard let settings = copy()?.takeRetainedValue() as? [String: Any] else {
            throw SleepSwitchError("the power manager returned no system settings")
        }
        // A Mac that has never had the flag written has no such key, and that
        // is a clear flag, not a failure.
        guard let value = settings[Self.key] as? NSNumber else { return false }
        return value.boolValue
    }

    func write(_ disabled: Bool) throws {
        guard let symbol = Self.symbol("IOPMSetSystemPowerSetting") else {
            throw SleepSwitchError("IOPMSetSystemPowerSetting is not in this IOKit")
        }
        let set = unsafeBitCast(symbol, to: Set.self)
        let result = set(Self.key as CFString, disabled ? kCFBooleanTrue : kCFBooleanFalse)
        guard result == kIOReturnSuccess else {
            throw SleepSwitchError("IOPMSetSystemPowerSetting returned 0x\(String(result, radix: 16))")
        }
        // The setting is written through configd, which answers before the
        // kernel has necessarily taken it. A read back is what the governor
        // reports afterwards, so nothing here has to wait.
    }

    /// `RTLD_DEFAULT`, which Swift does not name.
    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }
}
