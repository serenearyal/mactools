import FanControl
import Foundation
import Observation

import HelperProtocol

/// Where the fan state comes from. The app talks to the helper; the
/// `--fake-fans` screenshot path drives a real governor over fans that do not
/// exist.
protocol FanBackend: Sendable {
    func snapshot() async throws(HelperConnectionError) -> FanSnapshot
    func setMode(_ mode: FanMode, forFan index: Int) async throws(HelperConnectionError)
    func restoreAllAuto() async throws(HelperConnectionError)
}

/// The real one: XPC to the privileged helper.
///
/// Every call goes through the version gate first. An installed helper of
/// another build answers `ping` and then drops the connection on the first
/// method it does not export, so calling it at all would replace a clear
/// "reinstall it" with "The helper stopped while it was answering".
struct HelperFanBackend: FanBackend {
    private let connection = HelperConnection()

    func snapshot() async throws(HelperConnectionError) -> FanSnapshot {
        try checkVersion()
        return try await connection.fanSnapshot()
    }

    func setMode(_ mode: FanMode, forFan index: Int) async throws(HelperConnectionError) {
        try checkVersion()
        try await connection.setFanMode(mode, forFan: index)
    }

    func restoreAllAuto() async throws(HelperConnectionError) {
        try checkVersion()
        try await connection.restoreAllAuto()
    }

    private func checkVersion() throws(HelperConnectionError) {
        if let reason = HelperGate.shared.blockedReason { throw .refused(reason) }
    }
}

/// The Fans tab and everything behind it.
///
/// The wish for each fan is persisted, because the helper deliberately forgets
/// it: the fans go back to Auto the moment the last client disconnects, so the
/// app is the only place that remembers what the user chose. It writes the
/// modes again at launch and after every reconnect.
@MainActor
@Observable
final class FanStore {
    private(set) var snapshot: FanSnapshot?
    /// The last thing that went wrong while reading, for the banner. Every
    /// refresh overwrites it, including with nil.
    private(set) var failure: String?
    /// Why the last command was refused, kept until the next command works.
    ///
    /// Separate from `failure` on purpose: a refused write used to be written
    /// there and the poll two lines later replaced it with the read error of a
    /// perfectly healthy snapshot, which is nil, so the user saw nothing at
    /// all. Nothing but a command touches this.
    private(set) var lastCommandFailure: String?
    private(set) var isBusy = false
    /// Polls since launch, for the capture path. See `MetricsStore`.
    private(set) var pollCount = 0

    /// Only used by the `--fake-fans` path, which must not write the user's
    /// real fan configuration while it draws a screenshot.
    private var transientModes: [Int: FanMode] = [:]

    @ObservationIgnored private let backend: any FanBackend
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let persistsModes: Bool
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var demand = SamplingDemand()
    @ObservationIgnored private var hasApplied = false
    @ObservationIgnored private var pendingSends: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private let log = AppLog.fans

    /// While the tab or the popover is open. The helper reads the SMC for
    /// every snapshot, so this is the same cost as one line of the Sensors
    /// tab.
    private static let pollInterval = SamplingPlan.fanInterval
    private static let sendDelay: Duration = .milliseconds(200)
    /// How long the quit path waits for the helper to confirm Auto.
    private static let terminationWait: DispatchTimeInterval = .seconds(1)

    init(settings: AppSettings, backend: any FanBackend, persistsModes: Bool = true) {
        self.settings = settings
        self.backend = backend
        self.persistsModes = persistsModes
    }

    var fans: [FanStatus] { snapshot?.fans ?? [] }
    var isAvailable: Bool { snapshot != nil }
    var interlockEngaged: Bool { snapshot?.interlockEngaged ?? false }
    var hottestDie: Double? { snapshot?.hottestDieCelsius }
    var faults: [FanFault] { snapshot?.faults ?? [] }

    /// What the user picked, whether or not the helper is there to do it.
    func storedMode(forFan index: Int) -> FanMode {
        persistsModes ? settings.fanMode(forFan: index) : (transientModes[index] ?? .auto)
    }

    private func store(_ mode: FanMode, forFan index: Int) {
        if persistsModes {
            settings.setFanMode(mode, forFan: index)
        } else {
            transientModes[index] = mode
        }
    }

    // MARK: - Polling

    /// Polling follows the demand, not the lifetime of the Fans view: a window
    /// that is ordered out keeps its SwiftUI views alive, and this is what
    /// stops the XPC round trips when nobody can see them.
    ///
    /// The last snapshot is kept when polling stops, so the popover opens on
    /// the fan speeds of a moment ago instead of on dashes.
    func setDemand(_ demand: SamplingDemand) {
        guard self.demand != demand else { return }
        self.demand = demand
        let wanted = SamplingPlan.pollsFans(demand)
        if wanted, pollTask == nil {
            pollTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await refresh()
                    try? await Task.sleep(for: FanStore.pollInterval)
                }
            }
        } else if !wanted {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    func refresh() async {
        pollCount += 1
        do {
            let fresh = try await backend.snapshot()
            let reconnected = snapshot == nil
            snapshot = fresh
            failure = fresh.readError
            // The helper forgets every mode when the last client leaves, so a
            // fresh connection is the moment to say what the fans should do.
            if reconnected || !hasApplied {
                await applyStoredModes(to: fresh)
            }
        } catch {
            snapshot = nil
            hasApplied = false
            failure = error.errorDescription
        }
    }

    // MARK: - Changing a mode

    /// The choice shows in the UI at once; the helper hears about it after a
    /// short quiet period, and only the latest choice per fan is sent. A slider
    /// drag calls this for every step, and each send is a verified SMC write.
    func setMode(_ mode: FanMode, forFan index: Int) async {
        store(mode, forFan: index)
        pendingSends[index]?.cancel()
        let send = Task { @MainActor [weak self] in
            try? await Task.sleep(for: FanStore.sendDelay)
            guard !Task.isCancelled, let self else { return }
            await self.send(mode, forFan: index)
        }
        pendingSends[index] = send
        await send.value
    }

    private func send(_ mode: FanMode, forFan index: Int) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await backend.setMode(mode, forFan: index)
            lastCommandFailure = nil
        } catch {
            lastCommandFailure = error.errorDescription
            log.error("fan \(index) refused: \(error.localizedDescription, privacy: .public)")
            // The helper put the fan back to Auto; the controls must say so.
            if storedMode(forFan: index) == mode { store(.auto, forFan: index) }
        }
        await refresh()
    }

    /// The banner's dismiss button. The next refused command brings it back.
    func clearCommandFailure() {
        lastCommandFailure = nil
    }

    /// Every fan at its maximum, as a constant setpoint.
    func setAllFullBlast() async {
        // The menu bar can ask before the Fans tab ever polled.
        if snapshot == nil { await refresh() }
        for fan in fans {
            await setMode(.constant(rpm: Int(fan.maximumRPM.rounded())), forFan: fan.index)
        }
    }

    func restoreAllAuto() async {
        for index in fans.map(\.index) {
            store(.auto, forFan: index)
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await backend.restoreAllAuto()
            lastCommandFailure = nil
        } catch {
            lastCommandFailure = error.errorDescription
            log.error("restoring Auto was refused: \(error.localizedDescription, privacy: .public)")
        }
        await refresh()
    }

    /// Best effort on the way out. The helper covers a crash by itself, this
    /// covers the ordinary quit and gets there before the connection dies.
    ///
    /// The wait is bounded at one second. macOS gives a terminating app only a
    /// few seconds in total, and the last-client-leaves guarantee in the
    /// helper covers everything this call misses, so blocking longer would
    /// trade a visible hang for nothing.
    func restoreAllAutoOnTermination() {
        let backend = self.backend
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            try? await backend.restoreAllAuto()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + FanStore.terminationWait) == .timedOut {
            log.error("the helper did not confirm Auto in time; the connection dropping restores it")
        }
    }

    // MARK: - Re-applying what the user chose

    /// Writes the stored mode of every fan that is not already on it.
    ///
    /// One fan that refuses must not cost the others theirs, so the loop runs
    /// to the end and collects what failed, and `hasApplied` is only set when
    /// every fan took its mode: anything less is retried on the next poll.
    private func applyStoredModes(to snapshot: FanSnapshot) async {
        var failures: [(fan: Int, reason: String)] = []
        for fan in snapshot.fans {
            let stored = storedMode(forFan: fan.index)
            guard stored != fan.mode else { continue }
            log.info("re-applying \(stored.summary, privacy: .public) to fan \(fan.index)")
            do {
                try await backend.setMode(stored, forFan: fan.index)
            } catch {
                log.error(
                    "fan \(fan.index) refused the stored mode: \(error.localizedDescription, privacy: .public)"
                )
                failures.append((fan.index, error.errorDescription ?? "the helper refused it"))
            }
        }
        hasApplied = failures.isEmpty
        if !failures.isEmpty {
            lastCommandFailure = FanStore.summary(of: failures)
        }
        if let fresh = try? await backend.snapshot() { self.snapshot = fresh }
    }

    /// Every fan usually fails for the same reason, and repeating a sentence
    /// per fan makes a banner nobody reads.
    private static func summary(of failures: [(fan: Int, reason: String)]) -> String {
        let fans = failures.map { "Fan \($0.fan + 1)" }.joined(separator: ", ")
        let reasons = Set(failures.map(\.reason))
        guard reasons.count == 1, let reason = reasons.first else {
            return failures.map { "Fan \($0.fan + 1): \($0.reason)" }.joined(separator: " · ")
        }
        return "\(fans): \(reason)"
    }
}
