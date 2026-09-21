import Foundation
import IOKit
import IOKit.ps

/// The battery, read through IOKit and nothing else.
///
/// Two sources, because neither one has the whole answer. `IOPS` owns the
/// state the system agrees on - the percentage, charging, the time the battery
/// menu itself shows - and it is the only place that knows when a time is still
/// being calculated. The `AppleSmartBattery` registry entry owns the hardware
/// detail: cycles, capacity against the design capacity, the cell temperature
/// and the current flowing in or out.
///
/// Nothing here shells out to `pmset` or `system_profiler`: both are processes
/// to spawn, and `system_profiler SPPowerDataType` takes seconds.
public enum BatterySampler {
    /// nil on a Mac with no battery.
    ///
    /// Not an error: a Mac mini is a supported machine, and the section that
    /// draws this simply is not there.
    public static func read() -> BatteryReading? {
        guard let powerSource = internalBatteryDescription() else { return nil }
        return BatteryParser.reading(
            powerSource: powerSource,
            smartBattery: smartBatteryProperties(),
            adapter: adapterDetails(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// The description of the internal battery, out of every power source the
    /// system lists. A UPS is a power source too, and it is not this app's
    /// battery.
    private static func internalBatteryDescription() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        let descriptions = sources.compactMap { source in
            IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
        }
        return descriptions.first { description in
            description[BatteryParser.typeKey] as? String == BatteryParser.internalBatteryType
        }
    }

    /// Every property of the `AppleSmartBattery` service, or an empty
    /// dictionary where there is none: an Apple silicon Mac in a virtual
    /// machine publishes the `IOPS` half and not this one.
    private static func smartBatteryProperties() -> [String: Any] {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else { return [:] }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        let status = IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
        guard status == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return [:] }
        return properties
    }

    /// The rating of the connected adapter. Empty while nothing is plugged in.
    private static func adapterDetails() -> [String: Any] {
        IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] ?? [:]
    }
}
