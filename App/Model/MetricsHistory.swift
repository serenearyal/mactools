import Foundation
import SMCKit
import SysMetrics

/// One sensor over time: the live value plus the extremes since launch.
struct SensorTrace: Sendable, Identifiable {
    let key: SMCFourCC
    let label: String
    let category: SensorCategory
    var current: Double
    var minimum: Double
    var maximum: Double
    var values: RingBuffer<Double>

    var id: UInt32 { key.rawValue }

    init(reading: TemperatureReading, capacity: Int) {
        key = reading.key
        label = reading.label
        category = reading.category
        current = reading.celsius
        minimum = reading.celsius
        maximum = reading.celsius
        values = RingBuffer(capacity: capacity)
        values.append(reading.celsius)
    }

    mutating func append(_ celsius: Double) {
        current = celsius
        minimum = Swift.min(minimum, celsius)
        maximum = Swift.max(maximum, celsius)
        values.append(celsius)
    }
}

/// One battery read, for the 24 h chart of the Battery tab.
///
/// The date comes with it because these points are minutes apart, not one
/// interval apart like the ring buffers: the battery has a 30 s floor under it
/// and the tab can be off screen for hours, so the chart has to plot against
/// real time and show the gaps as gaps.
struct BatteryPoint: Sendable, Equatable {
    let date: Date
    /// 0...100.
    let percent: Int
    let isCharging: Bool
}

/// The graph history. 300 samples is 5 minutes at the 1 s interval.
///
/// Its own file, away from `MetricsStore`: the store is an `@Observable` class
/// that the test bundle cannot link, and these are plain rules over values.
struct MetricsHistory: Sendable {
    static let capacity = 300

    var cpuTotal = RingBuffer<Double>(capacity: capacity)
    var cpuCores = RingBuffer<[Double]>(capacity: capacity)
    var memoryUsed = RingBuffer<Double>(capacity: capacity)
    var hottestCPU = RingBuffer<Double>(capacity: capacity)
    var systemPower = RingBuffer<Double>(capacity: capacity)
    var diskRead = RingBuffer<Double>(capacity: capacity)
    var diskWrite = RingBuffer<Double>(capacity: capacity)
    var sensors: [SMCFourCC: SensorTrace] = [:]

    /// A day of battery reads, one per read rather than one per pass: the
    /// battery has a 30 s floor under it, so this is about 2880 points.
    ///
    /// Memory only. Nothing is written to disk, so the chart starts again after
    /// a relaunch, and a day is what it can ever show.
    static let batteryWindow: TimeInterval = 24 * 60 * 60
    /// The guard on the memory if anything ever reads the battery faster than
    /// the floor allows: 24 h at 30 s is 2880, and this is room to spare.
    static let batteryCapacity = 4_000

    var battery: [BatteryPoint] = []

    mutating func append(_ sample: MetricsSample, snapshot: MetricsSnapshot) {
        if let cpu = sample.cpu {
            cpuTotal.append(cpu.total.percent)
            cpuCores.append(cpu.cores.map(\.percent))
        }
        if let memory = sample.memory {
            memoryUsed.append(memory.usedFraction * 100)
        }
        if let readings = sample.temperatures {
            for reading in readings {
                if var trace = sensors[reading.key] {
                    trace.append(reading.celsius)
                    sensors[reading.key] = trace
                } else {
                    sensors[reading.key] = SensorTrace(
                        reading: reading,
                        capacity: MetricsHistory.capacity
                    )
                }
            }
            prune(keeping: readings, scope: sample.temperatureScope)
            if let hottest = snapshot.hottestCPU {
                hottestCPU.append(hottest.celsius)
            }
        }
        if let watts = sample.power?.first(where: { $0.key == "PSTR" })?.watts {
            systemPower.append(watts)
        }
        if let rates = sample.diskIO {
            diskRead.append(rates.bytesReadPerSecond)
            diskWrite.append(rates.bytesWrittenPerSecond)
        }
        // `batteryRead` and not the value: a pass that did not ask for the
        // battery carries the old reading, and plotting it again would draw a
        // flat line through a gap the tab was not on screen for.
        if sample.batteryRead, let reading = sample.battery {
            appendBattery(reading, at: sample.date)
        }
    }

    /// One battery read, with everything older than a day dropped.
    private mutating func appendBattery(_ reading: BatteryReading, at date: Date) {
        battery.append(
            BatteryPoint(date: date, percent: reading.percent, isCharging: reading.isCharging)
        )
        let cutoff = date.addingTimeInterval(-MetricsHistory.batteryWindow)
        // One `removeFirst(_:)` rather than one per point: dropping from the
        // front of an array moves every element that is left.
        let stale = battery.prefix { $0.date < cutoff }.count
        if stale > 0 { battery.removeFirst(stale) }
        if battery.count > MetricsHistory.batteryCapacity {
            battery.removeFirst(battery.count - MetricsHistory.batteryCapacity)
        }
    }

    /// Drops the traces a full pass did not read.
    ///
    /// A pass that names every sensor of its scope is the only one allowed to
    /// remove a row: turning "Show unlabelled sensors" off narrows the scope to
    /// the labelled keys, and without this the unlabelled rows would sit frozen
    /// in the table, the fan sensor column and the curve picker for ever. A
    /// narrow menu-bar-only pass reads one sensor, so it may never wipe the
    /// rest, and neither may a full pass that answered with nothing at all.
    private mutating func prune(keeping readings: [TemperatureReading], scope: TemperatureScope) {
        guard scope.namesEverySensor, !readings.isEmpty else { return }
        let present = Set(readings.map(\.key))
        sensors = sensors.filter { present.contains($0.key) }
    }

    /// Traces in a stable order: by category, then by label.
    var orderedSensors: [SensorTrace] {
        sensors.values.sorted { lhs, rhs in
            if lhs.category != rhs.category {
                return categoryOrder(lhs.category) < categoryOrder(rhs.category)
            }
            return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
    }

    private func categoryOrder(_ category: SensorCategory) -> Int {
        SensorCategory.allCases.firstIndex(of: category) ?? SensorCategory.allCases.count
    }
}
