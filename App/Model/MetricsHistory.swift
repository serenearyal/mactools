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
