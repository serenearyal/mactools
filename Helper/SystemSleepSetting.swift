import Foundation
import IOKit

import HelperProtocol

/// The real `SleepDisabled` system power setting, the one `pmset disablesleep`
/// writes.
///
/// `IOPMSetSystemPowerSetting` and `IOPMCopySystemPowerSettings` are exported
/// by IOKit and declared in no public header, so both are reached through
/// `dlsym` rather than by redeclaring the symbols: a wrong redeclaration is a
/// link error at best and a crash at worst. They are the same pair of calls
/// `pmset` itself makes. Shelling out to `pmset` would mean a subprocess as
/// root for one integer.
///
/// The read is `SystemSleepFlag.read()` in `HelperProtocol`, which the app's
/// Keep Awake tab calls too: one unsupported symbol lookup, in one place.
/// Only the write lives here, because only the write needs root and only the
/// write can change how this Mac behaves.
///
/// This file belongs to the helper target alone, exactly like
/// `HelperService.daemon()` and `SMCFanHardware`: the test bundle compiles
/// `HelperService.swift` to exercise the XPC path, and with the construction
/// of the real setting out of that file there is no way for a test to disable
/// sleep on the machine it runs on.
struct SystemSleepSetting: SystemSleepSwitch {
    private typealias Set = @convention(c) (CFString, CFTypeRef) -> IOReturn

    func read() throws -> Bool {
        try SystemSleepFlag.read()
    }

    func write(_ disabled: Bool) throws {
        guard let symbol = Self.symbol("IOPMSetSystemPowerSetting") else {
            throw SleepSwitchError("IOPMSetSystemPowerSetting is not in this IOKit")
        }
        let set = unsafeBitCast(symbol, to: Set.self)
        let result = set(SystemSleepFlag.key as CFString, disabled ? kCFBooleanTrue : kCFBooleanFalse)
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
