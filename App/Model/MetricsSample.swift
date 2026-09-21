import Foundation
import SMCKit
import SysMetrics

/// Which temperature sensors one sample should read.
///
/// The SMC key catalog costs 0.8 s, so the app never loads it at launch: the
/// two cheap scopes read the labelled keys of `SensorNaming` directly.
enum TemperatureScope: Sendable, Equatable, Comparable {
    case none
    /// The CPU dies only: what the menu bar needs for "hottest CPU sensor".
    case cpu
    /// The CPU dies and the GPU: what the popover draws, and about a third of
    /// the keys of the labelled set. Every SMC read is a driver round trip, so
    /// the difference is the most expensive thing about an open popover.
    case cpuGPU
    /// Every labelled sensor.
    case labelled
    /// Every `flt ` key with a "T" prefix, which needs the catalog.
    case everything

    /// True for a pass that reads every sensor of its own set. Only such a
    /// pass may say that a sensor it did not read is gone; the two narrow
    /// scopes read what the menu bar asked for and nothing else.
    var namesEverySensor: Bool { self == .labelled || self == .everything }
}

enum PowerScope: Sendable, Equatable, Comparable {
    case none
    /// `PSTR` only.
    case system
    /// Every labelled power rail.
    case labelled
}

/// What one pass of the sampler should read. The store narrows this down when
/// the window is closed, so an idle app only pays for what the menu bar shows.
struct SampleRequest: Sendable, Equatable {
    var cpu = true
    var memory = false
    var diskSpace = false
    var diskIO = false
    var temperatures: TemperatureScope = .none
    var fans = false
    var power: PowerScope = .none

    static let everything = SampleRequest(
        cpu: true,
        memory: true,
        diskSpace: true,
        diskIO: true,
        temperatures: .labelled,
        fans: true,
        power: .labelled
    )

    /// What a tab or a popover section that shows no live number asks for.
    /// The CPU is off here on purpose: the menu bar request turns it back on
    /// when the label needs it, and this value must add nothing of its own.
    static let nothing = SampleRequest(cpu: false)

    /// True when a pass for this request would read no counter at all.
    var readsNothing: Bool {
        self == SampleRequest.nothing
    }

    /// One line for the status file of a capture run.
    var summary: String {
        var parts: [String] = []
        if cpu { parts.append("cpu") }
        if memory { parts.append("memory") }
        if diskSpace { parts.append("disk") }
        if diskIO { parts.append("diskIO") }
        if temperatures != .none { parts.append("temperatures(\(temperatures))") }
        if fans { parts.append("fans") }
        if power != .none { parts.append("power(\(power))") }
        return parts.isEmpty ? "nothing" : parts.joined(separator: " + ")
    }
}

/// One immutable pass of the sampler, produced off the main thread.
///
/// A field is nil or empty when the request did not ask for it; the store
/// keeps the previous value in that case.
struct MetricsSample: Sendable {
    var date: Date = .now
    var cpu: CPUSample?
    var memory: MemorySnapshot?
    var volumes: [VolumeInfo]?
    var diskIO: DiskIORates?
    var temperatures: [TemperatureReading]?
    /// Which sensors this pass asked for. The history needs it to tell a full
    /// pass, which names every sensor that answers, from a narrow one.
    var temperatureScope: TemperatureScope = .none
    var fans: [FanReading]?
    var power: [PowerReading]?
    /// nil while the SMC connection has not been tried, false when it failed.
    var smcAvailable: Bool?
}

/// The newest value of every metric, merged across samples.
struct MetricsSnapshot: Sendable {
    var date: Date = .distantPast
    var cpu: CPUSample?
    var memory: MemorySnapshot?
    var volumes: [VolumeInfo] = []
    var diskIO: DiskIORates?
    var temperatures: [TemperatureReading] = []
    var fans: [FanReading] = []
    var power: [PowerReading] = []
    var smcAvailable = true

    var bootVolume: VolumeInfo? {
        volumes.first { $0.isBootVolume } ?? volumes.first
    }

    var hottestCPU: TemperatureReading? {
        temperatures
            .filter { $0.category == .cpuPerformance || $0.category == .cpuEfficiency }
            .max { $0.celsius < $1.celsius }
    }

    func hottest(in category: SensorCategory) -> TemperatureReading? {
        temperatures.filter { $0.category == category }.max { $0.celsius < $1.celsius }
    }

    func temperature(forKey key: SMCFourCC) -> TemperatureReading? {
        temperatures.first { $0.key == key }
    }

    var fastestFan: FanReading? {
        fans.max { $0.actual < $1.actual }
    }

    var systemPower: PowerReading? {
        power.first { $0.key == "PSTR" } ?? power.first
    }

    /// Read plus write bytes per second.
    var diskThroughput: Double {
        guard let diskIO else { return 0 }
        return diskIO.bytesReadPerSecond + diskIO.bytesWrittenPerSecond
    }

    mutating func apply(_ sample: MetricsSample) {
        date = sample.date
        if let cpu = sample.cpu { self.cpu = cpu }
        if let memory = sample.memory { self.memory = memory }
        if let volumes = sample.volumes { self.volumes = volumes }
        if let diskIO = sample.diskIO { self.diskIO = diskIO }
        if let temperatures = sample.temperatures { self.temperatures = temperatures }
        if let fans = sample.fans { self.fans = fans }
        if let power = sample.power { self.power = power }
        if let available = sample.smcAvailable { smcAvailable = available }
    }
}
