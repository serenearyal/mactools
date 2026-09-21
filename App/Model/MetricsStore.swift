import AppKit
import Foundation
import Observation
import SMCKit
import SysMetrics

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
    // One property per domain, and each one is only written when the value it
    // holds really changed.
    //
    // This is what keeps a pass narrow on the view side as well as on the
    // sampling side: the menu bar pass reads the CPU alone, so it invalidates
    // the CPU card and nothing else, and a storage card whose volume has not
    // moved in five minutes is not redrawn five hundred times. `snapshot` is
    // still there for the paths that genuinely need every domain at once - the
    // report, the capture file - and reading it observes all of them.
    private(set) var cpu: CPUSample?
    private(set) var memory: MemorySnapshot?
    private(set) var volumes: [VolumeInfo] = []
    private(set) var diskIO: DiskIORates?
    private(set) var temperatures: [TemperatureReading] = []
    private(set) var fans: [FanReading] = []
    private(set) var power: [PowerReading] = []
    private(set) var smcAvailable = true
    private(set) var history = MetricsHistory()
    private(set) var topology = CoreTopology.current()
    /// When the last pass landed. Not observed: it moves on every pass, and a
    /// view that tracked it would be invalidated by every pass in the app.
    @ObservationIgnored private(set) var date: Date = .distantPast
    /// How many passes the sampler has run. Nothing draws it; the capture path
    /// writes it, so a consumer that leaked its timer shows up as a counter
    /// that keeps moving after everything is off screen.
    private(set) var sampleCount = 0

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let sampler = MetricsSampler()
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    @ObservationIgnored private var lastVolumeSample = Date.distantPast
    @ObservationIgnored private var lastTemperatureSample = Date.distantPast
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    @ObservationIgnored private var demand = SamplingDemand()
    @ObservationIgnored private var conditions = PowerConditions()

    /// Disk capacity moves slowly and the scan walks every mount point.
    private static let volumeInterval: TimeInterval = 5

    // MARK: - What the views read

    /// Every domain in one value. Reading it observes all of them, which is
    /// why the views that draw one card read the narrow properties instead.
    var snapshot: MetricsSnapshot {
        MetricsSnapshot(
            date: date,
            cpu: cpu,
            memory: memory,
            volumes: volumes,
            diskIO: diskIO,
            temperatures: temperatures,
            fans: fans,
            power: power,
            smcAvailable: smcAvailable
        )
    }

    /// Only the domains one request covers.
    ///
    /// The menu bar label is the caller: it draws at most four numbers, and
    /// with this it is only woken by a pass that changed one of them.
    func snapshot(for request: SampleRequest) -> MetricsSnapshot {
        MetricsSnapshot(
            date: .distantPast,
            cpu: request.cpu ? cpu : nil,
            memory: request.memory ? memory : nil,
            volumes: request.diskSpace ? volumes : [],
            diskIO: request.diskIO ? diskIO : nil,
            temperatures: request.temperatures == .none ? [] : temperatures,
            fans: request.fans ? fans : [],
            power: request.power == .none ? [] : power,
            smcAvailable: smcAvailable
        )
    }

    var bootVolume: VolumeInfo? { volumes.first { $0.isBootVolume } ?? volumes.first }
    var hottestCPU: TemperatureReading? {
        temperatures
            .filter { $0.category == .cpuPerformance || $0.category == .cpuEfficiency }
            .max { $0.celsius < $1.celsius }
    }

    func hottest(in category: SensorCategory) -> TemperatureReading? {
        temperatures.filter { $0.category == category }.max { $0.celsius < $1.celsius }
    }

    var systemPower: PowerReading? {
        power.first { $0.key == "PSTR" } ?? power.first
    }

    /// Read plus write bytes per second.
    var diskThroughput: Double {
        guard let diskIO else { return 0 }
        return diskIO.bytesReadPerSecond + diskIO.bytesWrittenPerSecond
    }

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

    /// The battery, Low Power Mode and the thermal state, from the one
    /// subscription `KeepAwakeController` holds. Push only; nothing polls.
    func setPowerConditions(_ conditions: PowerConditions) {
        guard self.conditions != conditions else { return }
        self.conditions = conditions
        AppLog.app.info(
            """
            power conditions: battery \(conditions.onBattery, privacy: .public), \
            low power \(conditions.lowPowerMode, privacy: .public), \
            thermal \(conditions.thermalState.rawValue, privacy: .public)
            """
        )
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
            // The spinning fan glyph is the one part of the label that asks
            // for a metric of its own, so switching it changes what a pass
            // reads and the loop has to be rebuilt.
            _ = settings.spinsFanIcon
            _ = settings.showMenuBarIcon
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
            menuBarMetrics: settings.menuBarMetrics,
            showsUnlabelledSensors: settings.showUnlabelledSensors,
            conditions: conditions
        )
    }

    /// True while anything on screen, the menu bar label included, needs a
    /// number. False means no loop at all, not a loop that reads nothing.
    private var samplesAnything: Bool {
        SamplingPlan.samplesMetrics(
            demand: demand,
            menuBarMetrics: settings.menuBarMetrics,
            chosenSensorScope: scopeForChosenSensor(),
            showsUnlabelledSensors: settings.showUnlabelledSensors,
            spinsFanIcon: spinsFanIcon
        )
    }

    /// True when the label draws a fan glyph that is allowed to turn, which is
    /// the only reason the closed app ever reads a fan.
    private var spinsFanIcon: Bool {
        settings.spinsFanIcon && (settings.showMenuBarIcon || settings.menuBarMetrics.isEmpty)
    }

    /// The loop is not isolated to the main actor: the pass runs on
    /// `MetricsSampler` at `.utility`, and the only two main-actor hops are
    /// the request it starts from and the apply step it ends with.
    private func restartSampling() {
        sampleTask?.cancel()
        sampleTask = nil
        guard !asleep, samplesAnything else { return }
        let sampler = sampler
        // Detached on purpose: a `Task` started here would inherit the main
        // actor, and the loop would hold it for the whole pass. Detached, the
        // only main-actor work is the two hops below.
        sampleTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let request = await self?.beginPass() else { return }
                let sample = await sampler.sample(request)
                guard !Task.isCancelled, let interval = await self?.finishPass(sample) else { return }
                try? await Task.sleep(for: interval, tolerance: SamplingPlan.tolerance(for: interval))
            }
        }
    }

    /// The main-actor half at the start of a pass: what to read.
    private func beginPass() -> SampleRequest {
        nextRequest()
    }

    /// The main-actor half at the end of a pass: publish it, and say how long
    /// the loop should sleep before the next one.
    private func finishPass(_ sample: MetricsSample) -> Duration {
        apply(sample)
        return interval
    }

    private func nextRequest() -> SampleRequest {
        var request = SamplingPlan.metricsRequest(
            demand: demand,
            menuBarMetrics: settings.menuBarMetrics,
            chosenSensorScope: scopeForChosenSensor(),
            showsUnlabelledSensors: settings.showUnlabelledSensors,
            spinsFanIcon: spinsFanIcon
        )
        if request.diskSpace, Date.now.timeIntervalSince(lastVolumeSample) < MetricsStore.volumeInterval {
            request.diskSpace = false
        }
        // Every sensor is a driver round trip, and a die does not move in a
        // second. The two tabs that graph sensors are exempt.
        if request.temperatures != .none,
           SamplingPlan.throttlesTemperatures(
               demand: demand,
               sinceLastRead: .seconds(Date.now.timeIntervalSince(lastTemperatureSample))
           ) {
            request.temperatures = .none
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

    /// Publishes one pass, one domain at a time.
    ///
    /// A domain the pass did not read keeps its old value, and a domain whose
    /// value did not change is not written at all: an `@Observable` property
    /// that is assigned invalidates every view that read it, whether or not
    /// the new value differs from the old one.
    private func apply(_ sample: MetricsSample) {
        sampleCount += 1
        date = sample.date
        if let value = sample.cpu, value != cpu { cpu = value }
        if let value = sample.memory, value != memory { memory = value }
        if let value = sample.volumes {
            lastVolumeSample = sample.date
            if value != volumes { volumes = value }
        }
        if let value = sample.diskIO, value != diskIO { diskIO = value }
        if let value = sample.temperatures {
            lastTemperatureSample = sample.date
            if value != temperatures { temperatures = value }
        }
        if let value = sample.fans, value != fans { fans = value }
        if let value = sample.power, value != power { power = value }
        if let value = sample.smcAvailable, value != smcAvailable { smcAvailable = value }
        history.append(sample, snapshot: snapshot)
    }
}
