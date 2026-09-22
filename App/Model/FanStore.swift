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
    /// Changes whenever the backend opened a new connection, so the store can
    /// tell a helper that restarted and forgot every mode.
    var connectionGeneration: Int { get async }
}

extension FanBackend {
    /// A backend without a connection never loses what it was told.
    var connectionGeneration: Int { get async { 0 } }
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

    var connectionGeneration: Int {
        get async { await connection.generation }
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
/// modes again at launch, after every reconnect and whenever the helper
/// reports a mode other than the stored one without a fault to explain it.
///
/// A fault the helper reports on a fan it put back to Auto goes the other
/// way: the store takes Auto for that fan, so every view shows what the fan
/// does and a broken mode is not sent again for ever.
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
    /// The interval `pollTask` runs at, nil while it does not run.
    @ObservationIgnored private var pollCadence: Duration?
    @ObservationIgnored private var demand = SamplingDemand()
    @ObservationIgnored private var hasApplied = false
    /// The backend connection the stored modes were last checked against.
    @ObservationIgnored private var knownGeneration: Int?
    /// The fans of the last snapshot. Kept when the helper goes away, so the
    /// watch knows whose stored mode to look at.
    @ObservationIgnored private var knownFans: [Int] = []
    @ObservationIgnored private var pendingSends: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private let log = AppLog.fans

    /// While the tab or the popover is open. The helper reads the SMC for
    /// every snapshot, so this is the same cost as one line of the Sensors
    /// tab.
    private static let pollInterval = SamplingPlan.fanInterval
    /// While nothing shows the fans but a stored mode is not Auto. Only a
    /// check that the helper still holds the wish, so it can be slow: a
    /// restarted helper runs the fans on Auto until the next one.
    private static let watchInterval: Duration = .seconds(10)
    /// The fans whose stored mode the watch looks at before the helper ever
    /// answered. No Mac has more.
    private static let probedFanCount = 4
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
        updatePolling()
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
        updatePolling()
    }

    /// Fast while the fans are on screen, slow while only a stored mode needs
    /// the helper to keep it, and not at all otherwise, which is the idle
    /// case of almost every user.
    private func updatePolling() {
        let cadence: Duration? = if SamplingPlan.pollsFans(demand) {
            FanStore.pollInterval
        } else if holdsWish {
            FanStore.watchInterval
        } else {
            nil
        }
        guard cadence != pollCadence else { return }
        pollTask?.cancel()
        pollTask = nil
        pollCadence = cadence
        guard let cadence else { return }
        // The watch starts with a sleep: it takes over from a fast poll or a
        // command that has just read the fans.
        let readsFirst = cadence == FanStore.pollInterval
        // `.utility`: a fan snapshot is an XPC round trip to the helper,
        // and nothing about it is user-interactive.
        pollTask = Task.detached(priority: .utility) { [weak self] in
            var reads = readsFirst
            while !Task.isCancelled {
                if reads {
                    guard let self else { return }
                    await self.refresh()
                    guard !Task.isCancelled else { return }
                }
                reads = true
                try? await Task.sleep(for: cadence, tolerance: SamplingPlan.tolerance(for: cadence))
            }
        }
    }

    /// True when a stored mode is not Auto, so the helper has to be told
    /// again if it restarts.
    private var holdsWish: Bool {
        let indices = knownFans.isEmpty ? Array(0..<FanStore.probedFanCount) : knownFans
        return indices.contains { !storedMode(forFan: $0).isAuto }
    }

    func refresh() async {
        pollCount += 1
        do {
            let fresh = try await backend.snapshot()
            let generation = await backend.connectionGeneration
            // A new connection may be a new helper process, which starts with
            // every fan on Auto.
            let reconnected = snapshot == nil || generation != knownGeneration
            knownGeneration = generation
            // Only on a change: a fan that holds 2000 rpm for a minute must
            // not invalidate the views that draw it thirty times.
            if fresh != snapshot { snapshot = fresh }
            if fresh.readError != failure { failure = fresh.readError }
            let indices = fresh.fans.map(\.index)
            if !indices.isEmpty, indices != knownFans { knownFans = indices }
            adoptFaults(of: fresh)
            // The helper forgets every mode when the last client leaves, so a
            // fresh connection is the moment to say what the fans should do.
            if reconnected || !hasApplied || drifts(fresh) {
                await applyStoredModes(to: fresh)
            }
        } catch {
            snapshot = nil
            hasApplied = false
            failure = error.errorDescription
        }
        // A helper that is not there yet still owes the stored modes, so the
        // watch starts on a failed read too.
        updatePolling()
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
        // A later choice replaced this one and is still on its way.
        if pendingSends[index] == send { pendingSends[index] = nil }
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

    /// A fan the helper faulted and put back to Auto is Auto here too. The
    /// fault stays in the snapshot and says why.
    ///
    /// A fan with a choice on its way is left alone: the snapshot still
    /// describes the mode that choice replaces.
    private func adoptFaults(of snapshot: FanSnapshot) {
        for fault in snapshot.faults where pendingSends[fault.fanIndex] == nil {
            guard let fan = snapshot.fans.first(where: { $0.index == fault.fanIndex }),
                  fan.mode.isAuto,
                  !storedMode(forFan: fan.index).isAuto
            else { continue }
            log.info("fan \(fan.index) faulted, storing Auto: \(fault.reason, privacy: .public)")
            store(.auto, forFan: fan.index)
        }
    }

    /// True when the helper runs a fan on a mode other than the stored one
    /// and no fault explains it: the helper restarted, or the wish was lost
    /// in some other way, and has to be sent again.
    private func drifts(_ snapshot: FanSnapshot) -> Bool {
        let faulted = Set(snapshot.faults.map(\.fanIndex))
        return snapshot.fans.contains { fan in
            pendingSends[fan.index] == nil
                && !faulted.contains(fan.index)
                && storedMode(forFan: fan.index) != fan.mode
        }
    }

    /// Writes the stored mode of every fan that is not already on it.
    ///
    /// One fan that refuses must not cost the others theirs, so the loop runs
    /// to the end and collects what failed, and `hasApplied` is only set when
    /// every fan took its mode: anything less is retried on the next poll.
    private func applyStoredModes(to snapshot: FanSnapshot) async {
        var failures: [(fan: Int, reason: String)] = []
        for fan in snapshot.fans where pendingSends[fan.index] == nil {
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
