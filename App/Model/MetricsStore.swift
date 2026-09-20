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
