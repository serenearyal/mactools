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
struct HelperFanBackend: FanBackend {
    private let connection = HelperConnection()

    func snapshot() async throws(HelperConnectionError) -> FanSnapshot {
        try await connection.fanSnapshot()
    }

    func setMode(_ mode: FanMode, forFan index: Int) async throws(HelperConnectionError) {
        try await connection.setFanMode(mode, forFan: index)
    }

    func restoreAllAuto() async throws(HelperConnectionError) {
        try await connection.restoreAllAuto()
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
    /// The last thing that went wrong, for the banner.
    private(set) var failure: String?
    private(set) var isBusy = false

    /// Only used by the `--fake-fans` path, which must not write the user's
    /// real fan configuration while it draws a screenshot.
    private var transientModes: [Int: FanMode] = [:]

    @ObservationIgnored private let backend: any FanBackend
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let persistsModes: Bool
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var hasApplied = false
    @ObservationIgnored private let log = AppLog.fans

    /// While the tab is open. The helper reads the SMC for every snapshot, so
    /// this is the same cost as one line of the Sensors tab.
    private static let pollInterval: Duration = .seconds(2)
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

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                try? await Task.sleep(for: FanStore.pollInterval)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
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

    func setMode(_ mode: FanMode, forFan index: Int) async {
        store(mode, forFan: index)
        isBusy = true
        defer { isBusy = false }
        do {
            try await backend.setMode(mode, forFan: index)
            failure = nil
        } catch {
            failure = error.errorDescription
            log.error("fan \(index) refused: \(error.localizedDescription, privacy: .public)")
        }
        await refresh()
    }

    func restoreAllAuto() async {
        for index in fans.map(\.index) {
            store(.auto, forFan: index)
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await backend.restoreAllAuto()
            failure = nil
        } catch {
            failure = error.errorDescription
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

    private func applyStoredModes(to snapshot: FanSnapshot) async {
        hasApplied = true
        for fan in snapshot.fans {
            let stored = storedMode(forFan: fan.index)
            guard stored != fan.mode else { continue }
            log.info("re-applying \(stored.summary, privacy: .public) to fan \(fan.index)")
            do {
                try await backend.setMode(stored, forFan: fan.index)
            } catch {
                failure = error.errorDescription
                return
            }
        }
        if let fresh = try? await backend.snapshot() { self.snapshot = fresh }
    }
}
