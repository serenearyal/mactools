import Foundation
import ReportKit

/// The sysctl values a report needs, exactly as the kernel hands them over.
///
/// A struct rather than a pile of arguments, so the pure half below can be fed
/// a machine it will never run on: an Intel Mac with no `hw.perflevel*`, a Mac
/// mini with no battery, a model the marketing table has never seen.
struct SystemContextRaw: Equatable, Sendable {
    /// `hw.model`, for example "MacBookPro18,3".
    var model = ""
    /// `machdep.cpu.brand_string`, for example "Apple M1 Pro".
    var chip = ""
    /// `hw.perflevel0.logicalcpu`. Apple Silicon numbers the fast cluster 0.
    var performanceCores = 0
    /// `hw.perflevel1.logicalcpu`. Zero on a Mac with one cluster.
    var efficiencyCores = 0
    /// `hw.logicalcpu`, the fallback when neither perflevel answers.
    var logicalCores = 0
    /// `hw.memsize`.
    var memoryBytes: UInt64 = 0
    /// `kern.osproductversion`, for example "26.1".
    var osVersion = ""
    /// `kern.osversion`, the build, for example "25B78".
    var osBuild = ""
    /// `kern.boottime`, as a date.
    var bootTime: Date?
    /// Nil on a Mac with no battery, and on one whose charge did not read.
    var batteryPercent: Int?
    /// Nil on a Mac with no battery.
    var onBattery: Bool?
}

/// The raw strings, turned into the one line a report prints about the Mac.
///
/// Pure on purpose: `SystemContextReader` does nothing but read, so every
/// decision about a missing, odd or unknown value is made here where a test
/// can reach it.
enum SystemContextParser {
    static func context(from raw: SystemContextRaw, now: Date = .now) -> SystemContext {
        let cores = clusters(from: raw)
        return SystemContext(
            modelName: marketingName(forModel: raw.model),
            modelID: raw.model.isEmpty ? "unknown" : raw.model,
            chip: raw.chip.isEmpty ? "an unknown chip" : raw.chip,
            performanceCores: cores.performance,
            efficiencyCores: cores.efficiency,
            ramBytes: raw.memoryBytes,
            osVersion: raw.osVersion.isEmpty ? "unknown" : raw.osVersion,
            osBuild: raw.osBuild.isEmpty ? "unknown" : raw.osBuild,
            uptimeSeconds: uptimeSeconds(bootTime: raw.bootTime, now: now),
            batteryPercent: raw.batteryPercent,
            onBattery: raw.onBattery
        )
    }

    /// The two clusters, or the whole logical count as "performance" on a Mac
    /// that reports no cluster at all. A report that says "0P+0E cores" would
    /// be worse than one that says the total.
    static func clusters(from raw: SystemContextRaw) -> (performance: Int, efficiency: Int) {
        let performance = max(0, raw.performanceCores)
        let efficiency = max(0, raw.efficiencyCores)
        if performance + efficiency > 0 { return (performance, efficiency) }
        return (max(0, raw.logicalCores), 0)
    }

    /// Whole seconds since the boot. A clock that has been set back since the
    /// boot would give a negative number, and "up -3h" helps nobody.
    static func uptimeSeconds(bootTime: Date?, now: Date) -> Int {
        guard let bootTime else { return 0 }
        return max(0, Int(now.timeIntervalSince(bootTime)))
    }

    /// "MacBookPro18,3" becomes "MacBook Pro".
    ///
    /// Only the family, never the year: a table of every model identifier goes
    /// stale with the next Mac, and the report prints the identifier next to
    /// this anyway, so "MacBook Pro (MacBookPro18,3)" already says which one it
    /// is. An identifier the table has never seen keeps its own text.
    static func marketingName(forModel model: String) -> String {
        guard !model.isEmpty else { return "Mac" }
        let family = model.prefix { !$0.isNumber }
        switch family {
        case "MacBookPro": return "MacBook Pro"
        case "MacBookAir": return "MacBook Air"
        case "MacBook": return "MacBook"
        case "Macmini": return "Mac mini"
        case "MacPro": return "Mac Pro"
        case "MacStudio": return "Mac Studio"
        case "iMac", "iMacPro": return family == "iMacPro" ? "iMac Pro" : "iMac"
        case "VirtualMac": return "Virtual Mac"
        // "Mac16,10" and its like: Apple dropped the family from the newest
        // identifiers, so the identifier in brackets is all there is to say.
        case "Mac": return "Mac"
        default: return String(family)
        }
    }
}
