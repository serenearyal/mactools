import AppKit
import Foundation
import Observation
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

/// The one source of live numbers for the menu bar, the popover and the
/// window.
///
/// Sampling runs on `MetricsSampler`, an actor, so nothing touches the main
/// thread but the finished snapshot. The cadence follows the demand: the user
/// interval while the window or the popover is on screen, 5 s when neither is
/// and the menu bar shows nothing, and no sampling at all while the machine
/// sleeps. `SamplingPlan` holds those rules.
@MainActor
@Observable
final class MetricsStore {
    private(set) var snapshot = MetricsSnapshot()
    private(set) var history = MetricsHistory()
    private(set) var topology = CoreTopology.current()
    /// How many passes the sampler has run. Nothing draws it; the capture path
    /// writes it, so a consumer that leaked its timer shows up as a counter
    /// that keeps moving after everything is off screen.
    private(set) var sampleCount = 0

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let sampler = MetricsSampler()
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    @ObservationIgnored private var lastVolumeSample = Date.distantPast
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    @ObservationIgnored private var demand = SamplingDemand()

    /// Disk capacity moves slowly and the scan walks every mount point.
    private static let volumeInterval: TimeInterval = 5

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAsleep(true) }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAsleep(false) }
            },
        ]
        trackSettings()
        restartSampling()
    }

    func stop() {
        sampleTask?.cancel()
        sampleTask = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers = []
    }

    // MARK: - What the UI needs

    /// The window, the popover and the tab they are on, in one value. A change
    /// takes effect on the next pass, not after the current sleep.
    func setDemand(_ demand: SamplingDemand) {
        guard self.demand != demand else { return }
        self.demand = demand
        restartSampling()
    }

    // MARK: - Cadence

    private func setAsleep(_ value: Bool) {
        guard asleep != value else { return }
        asleep = value
        restartSampling()
    }

    /// A settings change takes effect at once instead of after the current
    /// sleep, so the menu bar reacts while the user is in Settings.
    private func trackSettings() {
        withObservationTracking {
            _ = settings.refreshInterval
            _ = settings.menuBarMetrics
            _ = settings.showUnlabelledSensors
            _ = settings.sensorKey
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                trackSettings()
                restartSampling()
            }
        }
    }

    private var interval: Duration {
        SamplingPlan.metricsInterval(
            demand: demand,
            refreshSeconds: settings.refreshInterval.seconds,
            menuBarMetrics: settings.menuBarMetrics
        )
    }

    private func restartSampling() {
        sampleTask?.cancel()
        guard !asleep else {
            sampleTask = nil
            return
        }
        sampleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let sample = await sampler.sample(nextRequest())
                guard !Task.isCancelled else { return }
                apply(sample)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func nextRequest() -> SampleRequest {
        var request = SamplingPlan.metricsRequest(
            demand: demand,
            menuBarMetrics: settings.menuBarMetrics,
            chosenSensorScope: scopeForChosenSensor(),
            showsUnlabelledSensors: settings.showUnlabelledSensors
        )
        if request.diskSpace, Date.now.timeIntervalSince(lastVolumeSample) < MetricsStore.volumeInterval {
            request.diskSpace = false
        }
        return request
    }

    /// A chosen CPU sensor needs the cheap CPU scope, anything else needs the
    /// labelled set.
    private func scopeForChosenSensor() -> TemperatureScope {
        guard let key = SMCFourCC(code: settings.sensorKey) else { return .labelled }
        let category = SensorNaming.descriptor(for: key).category
        return category == .cpuPerformance || category == .cpuEfficiency ? .cpu : .labelled
    }

    private func apply(_ sample: MetricsSample) {
        sampleCount += 1
        if sample.volumes != nil { lastVolumeSample = sample.date }
        snapshot.apply(sample)
        history.append(sample, snapshot: snapshot)
    }
}
