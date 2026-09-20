import Foundation
import ReportKit
import SysMetrics

/// The one line every report prints about this Mac.
///
/// Seven sysctls and one power-source read, about 6 ms in total, so a report
/// never waits for it and it is taken fresh every time rather than cached: an
/// uptime and a battery charge that are an hour old would be worse than none.
enum SystemContextReader {
    static func read(now: Date = .now) -> SystemContext {
        SystemContextParser.context(from: raw(), now: now)
    }

    static func raw() -> SystemContextRaw {
        let battery = PowerSourceReader.read()
        return SystemContextRaw(
            model: Sysctl.string("hw.model") ?? "",
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "",
            // Apple Silicon numbers the fast cluster 0 and the efficient one 1;
            // an Intel Mac has neither key and falls back to `hw.logicalcpu`.
            performanceCores: Sysctl.integer("hw.perflevel0.logicalcpu") ?? 0,
            efficiencyCores: Sysctl.integer("hw.perflevel1.logicalcpu") ?? 0,
            logicalCores: Sysctl.integer("hw.logicalcpu") ?? 0,
            memoryBytes: Sysctl.uint64("hw.memsize") ?? 0,
            osVersion: Sysctl.string("kern.osproductversion") ?? "",
            osBuild: Sysctl.string("kern.osversion") ?? "",
            bootTime: bootTime(),
            batteryPercent: battery.percent,
            onBattery: battery.hasBattery ? battery.onBattery : nil
        )
    }

    /// `kern.boottime` is a `timeval`, not a number, so it needs the struct
    /// read rather than `Sysctl.uint64`.
    private static func bootTime() -> Date? {
        guard let value: timeval = Sysctl.value("kern.boottime"), value.tv_sec > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000)
    }
}
