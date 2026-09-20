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

/// Which part of the window is on screen. It decides what the sampler reads.
enum MainTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case fans
    case sensors
    case processes
    case storage
    case keyboardLock
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .fans: "Fans"
        case .sensors: "Sensors"
        case .processes: "Processes"
        case .storage: "Storage"
        case .keyboardLock: "Keyboard Lock"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .fans: "fan"
        case .sensors: "thermometer.medium"
        case .processes: "list.bullet.rectangle"
        case .storage: "internaldrive"
        case .keyboardLock: "keyboard"
        case .settings: "gearshape"
        }
    }
}

/// The one source of live numbers for the menu bar and the window.
///
/// Sampling runs on `MetricsSampler`, an actor, so nothing touches the main
/// thread but the finished snapshot. The cadence follows the window: the user
/// interval while it is open, 5 s when it is closed and the menu bar shows
/// nothing, and no sampling at all while the machine sleeps.
@MainActor
@Observable
final class MetricsStore {
    private(set) var snapshot = MetricsSnapshot()
    private(set) var history = MetricsHistory()
    private(set) var processes: [ProcessInfoRow] = []
    private(set) var topology = CoreTopology.current()

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let sampler = MetricsSampler()
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    @ObservationIgnored private var processTask: Task<Void, Never>?
    @ObservationIgnored private var lastVolumeSample = Date.distantPast
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    @ObservationIgnored private var windowVisible = false
    @ObservationIgnored private var activeTab: MainTab = .overview

    /// Disk capacity moves slowly and the scan walks every mount point.
    private static let volumeInterval: TimeInterval = 5
    private static let processInterval: Duration = .seconds(3)

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
        processTask?.cancel()
        processTask = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers = []
    }

    // MARK: - What the UI needs

    func setWindowVisible(_ visible: Bool) {
        guard windowVisible != visible else { return }
        windowVisible = visible
        restartSampling()
        updateProcessSampling()
    }

    func setActiveTab(_ tab: MainTab) {
        guard activeTab != tab else { return }
        activeTab = tab
        restartSampling()
        updateProcessSampling()
    }

    // MARK: - Cadence

    private func setAsleep(_ value: Bool) {
        guard asleep != value else { return }
        asleep = value
        restartSampling()
        updateProcessSampling()
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
        if windowVisible { return .seconds(settings.refreshInterval.seconds) }
        if settings.menuBarMetrics.isEmpty { return .seconds(5) }
        return .seconds(settings.refreshInterval.seconds)
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
        var request = windowVisible ? windowRequest() : menuBarRequest()
        if request.diskSpace, Date.now.timeIntervalSince(lastVolumeSample) < MetricsStore.volumeInterval {
            request.diskSpace = false
        }
        return request
    }

    private func windowRequest() -> SampleRequest {
        var request = SampleRequest.everything
        if activeTab == .sensors, settings.showUnlabelledSensors {
            request.temperatures = .everything
        }
        return request
    }

    /// Only what the menu bar shows. CPU stays on either way: one mach call,
    /// and it keeps the history graph continuous.
    private func menuBarRequest() -> SampleRequest {
        var request = SampleRequest()
        for metric in settings.menuBarMetrics {
            switch metric {
            case .cpuUsage:
                request.cpu = true
            case .memoryUsed, .memoryPercent:
                request.memory = true
            case .diskUsedPercent, .diskFree:
                request.diskSpace = true
            case .diskIO:
                request.diskIO = true
            case .cpuTemperature:
                request.temperatures = max(request.temperatures, .cpu)
            case .sensorTemperature:
                request.temperatures = max(request.temperatures, scopeForChosenSensor())
            case .fanSpeed:
                request.fans = true
            case .systemPower:
                request.power = max(request.power, .system)
            }
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
        if sample.volumes != nil { lastVolumeSample = sample.date }
        snapshot.apply(sample)
        history.append(sample, snapshot: snapshot)
    }

    // MARK: - Processes

    /// The process table costs one libproc round trip per process, so it only
    /// runs while the list is on screen.
    private func updateProcessSampling() {
        let wanted = windowVisible && !asleep && activeTab == .processes
        if wanted, processTask == nil {
            processTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let rows = await sampler.sampleProcesses()
                    guard !Task.isCancelled else { return }
                    processes = rows
                    try? await Task.sleep(for: MetricsStore.processInterval)
                }
            }
        } else if !wanted, processTask != nil {
            processTask?.cancel()
            processTask = nil
            processes = []
            Task { [sampler] in await sampler.resetProcesses() }
        }
    }
}
