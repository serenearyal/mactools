import Foundation
import Observation
import SysMetrics

/// The sampling side of the Processes tab, off the main thread.
///
/// Two passes make one table: the local libproc pass sees every process but
/// gets EPERM on the counters of about 219 of them, and the helper fills those
/// in as root. The helper is optional at every step; without it the table is
/// the local pass with dashes where the numbers would be.
actor ProcessFeed {
    struct Sample: Sendable {
        let rows: [ProcessInfoRow]
        /// How many rows the helper contributed, 0 when it did not answer.
        let helperRows: Int
        let helperFailure: String?
    }

    private let sampler = ProcessSampler()
    /// One second, not the usual five: the table refreshes every three, and a
    /// helper that needs longer than that is one the tab is better off drawing
    /// without.
    private let helper = HelperConnection(timeout: .seconds(1))
    private var nextHelperAttempt = Date.distantPast
    private var lastFailure: String?

    /// Without an installed helper every call is a connection launchd cannot
    /// satisfy, so a failure buys 30 s of local-only samples.
    private static let retryInterval: TimeInterval = 30

    func sample() async -> Sample {
        let local = (try? sampler.sample()) ?? []
        // An installed helper of another build would answer this call by
        // dropping the connection, so it is not called at all.
        if let blocked = HelperGate.shared.blockedReason {
            lastFailure = blocked
            return Sample(rows: local, helperRows: 0, helperFailure: blocked)
        }
        guard Date.now >= nextHelperAttempt else {
            return Sample(rows: local, helperRows: 0, helperFailure: lastFailure)
        }
        do {
            let privileged = try await helper.processSnapshot()
            lastFailure = nil
            nextHelperAttempt = .distantPast
            return Sample(
                rows: ProcessSampler.merge(local: local, privileged: privileged),
                helperRows: privileged.count,
                helperFailure: nil
            )
        } catch {
            lastFailure = error.errorDescription
            nextHelperAttempt = Date.now.addingTimeInterval(ProcessFeed.retryInterval)
            return Sample(rows: local, helperRows: 0, helperFailure: lastFailure)
        }
    }

    /// The signal path for a process this user does not own.
    func signal(_ signal: ProcessSignal, pid: Int32) async -> String? {
        if let blocked = HelperGate.shared.blockedReason { return blocked }
        do {
            try await helper.signalProcess(pid: pid, signal: signal)
            return nil
        } catch {
            return error.errorDescription ?? "the helper refused the signal"
        }
    }
}

/// The Processes tab and the top lists of the popover: the merged table, what
/// the user filtered it down to, and the two signals the UI can send.
@MainActor
@Observable
final class ProcessStore {
    /// The rows, filtered, sorted and topped once per sample. Never inside a
    /// `body`: see `ProcessRows`.
    private(set) var derived = ProcessRows()
    private(set) var helperRowCount = 0
    private(set) var helperFailure: String?
    /// The result of the last action, for the footer.
    private(set) var message: String?
    /// Passes since launch, for the capture path. See `MetricsStore`.
    private(set) var sampleCount = 0

    var selection: Set<ProcessTableRow.ID> = []

    /// The three things the user can change about the table. Each one derives
    /// the rows again on the spot, so the change is one pass over the sample
    /// rather than one per layout.
    var searchText: String {
        get { query }
        set {
            guard query != newValue else { return }
            query = newValue
            derive()
        }
    }

    var scope: ProcessFilterScope {
        get { filterScope }
        set {
            guard filterScope != newValue else { return }
            filterScope = newValue
            derive()
        }
    }

    var sortOrder: [ProcessComparator] {
        get { order }
        set {
            guard order != newValue else { return }
            order = newValue
            derive()
        }
    }

    private var query = ""
    private var filterScope: ProcessFilterScope = .all
    private var order = [ProcessComparator(key: .cpu, order: .reverse)]

    @ObservationIgnored private let feed = ProcessFeed()
    @ObservationIgnored private let names = UserNameCache.shared
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var demand = SamplingDemand()

    /// The uid of this process. Its rows can be signalled without the helper.
    static let currentUID = getuid()


    // MARK: - What the table shows

    var rows: [ProcessTableRow] { derived.all }
    var visibleRows: [ProcessTableRow] { derived.visible }
    var topByCPU: [ProcessTableRow] { derived.topByCPU }
    var topByMemory: [ProcessTableRow] { derived.topByMemory }
    var restrictedCount: Int { derived.restrictedCount }
    var totalCPUPercent: Double { derived.totalCPUPercent }

    var selectedRows: [ProcessTableRow] {
        derived.all.filter { selection.contains($0.id) }
    }

    var helperIsAnswering: Bool { helperRowCount > 0 }

    /// True when the table holds rows a report can print.
    ///
    /// Two passes, not one: the first pass has no CPU baseline to subtract, so
    /// its whole CPU column is nil and a report made from it would say nothing
    /// about load at all.
    var hasReportableSample: Bool { sampleCount >= 2 && !derived.all.isEmpty }

    // MARK: - Cadence

    func setDemand(_ demand: SamplingDemand) {
        guard self.demand != demand else { return }
        self.demand = demand
        updateSampling()
    }

    /// The table costs one libproc round trip per process, so it only runs
    /// while the tab or the popover is on screen.
    ///
    /// The rows and the CPU baselines survive a stop. They cost about 50 kB
    /// and they buy the popover a first paint with real numbers: a kept
    /// baseline makes the first pass after the gap an average over the gap,
    /// where a dropped one would make it a column of dashes.
    private func updateSampling() {
        let wanted = SamplingPlan.samplesProcesses(demand)
        if wanted, task == nil {
            // `.utility`, and the libproc pass itself runs on the feed actor:
            // the main actor only ever sees the finished sample.
            let feed = feed
            task = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    let sample = await feed.sample()
                    guard !Task.isCancelled, let self else { return }
                    let interval = await self.applyAndWait(sample)
                    try? await Task.sleep(for: interval, tolerance: SamplingPlan.tolerance(for: interval))
                }
            }
        } else if !wanted, task != nil {
            task?.cancel()
            task = nil
        }
    }

    /// The main-actor half of one pass: publish it, and say how long the loop
    /// sleeps before the next one. The tab is worth three seconds, the three
    /// rows in the popover are not.
    private func applyAndWait(_ sample: ProcessFeed.Sample) -> Duration {
        apply(sample)
        return SamplingPlan.processInterval(demand)
    }

    /// Derives the rows from what is already sampled. The filter, the search
    /// box and the column header land here.
    private func derive() {
        derived = ProcessRows.make(
            rows: derived.all,
            scope: filterScope,
            currentUID: ProcessStore.currentUID,
            query: query,
            sortOrder: order
        )
    }

    private func apply(_ sample: ProcessFeed.Sample) {
        sampleCount += 1
        derived = ProcessRows.make(
            rows: sample.rows.map { ProcessTableRow(info: $0, userName: names.name(for: $0.uid)) },
            scope: filterScope,
            currentUID: ProcessStore.currentUID,
            query: query,
            sortOrder: order
        )
        helperRowCount = sample.helperRows
        // Only the transitions, so a helper that is not installed does not
        // write a line every three seconds.
        if sample.helperFailure != helperFailure {
            if let failure = sample.helperFailure {
                AppLog.procs.error("the helper did not answer: \(failure, privacy: .public)")
            } else {
                AppLog.procs.notice("the helper filled in \(sample.helperRows, privacy: .public) rows")
            }
        }
        helperFailure = sample.helperFailure
        // A process that ended keeps no place in the selection, so the next
        // Quit cannot land on a pid the kernel has handed to somebody else.
        let live = Set(derived.all.map(\.id))
        let kept = selection.filter { live.contains($0) }
        if kept != selection { selection = kept }
    }

    /// One sample pair for a copy from the popover or the status item menu.
    ///
    /// Those two surfaces can be the first thing the user opens, and the table
    /// only samples while somebody is looking at it, so a report taken there
    /// would have an empty CPU column. Two passes a second apart is the
    /// shortest honest answer; the sleep carries a tolerance so the wakeup can
    /// ride with one the system already has.
    func sampleForReport() async {
        guard !hasReportableSample else { return }
        apply(await feed.sample())
        try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(200))
        apply(await feed.sample())
    }

    // MARK: - Actions

    /// The status line of the tab, for an action that did not come from here:
    /// a Copy for AI from the toolbar says so in the same place a Force Quit
    /// does, instead of inventing a second line for it.
    func showMessage(_ text: String) {
        message = text
    }

    /// Quit or Force Quit. The processes of this user go through `kill(2)`
    /// here; the rest need the helper, which is the only thing on the machine
    /// allowed to signal them.
    func send(_ signal: ProcessSignal, to targets: [ProcessTableRow]) {
        guard !targets.isEmpty else { return }
        let summary = targets.count == 1
            ? "\(targets[0].name) (pid \(targets[0].pid))"
            : "\(targets.count) processes"
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failures: [String] = []
            for row in targets {
                let failure: String? = row.uid == ProcessStore.currentUID
                    ? ProcessSignalPolicy.send(pid: row.pid, signal: signal.rawValue)
                    : await feed.signal(signal, pid: row.pid)
                // The name is the user's business, the outcome is the app's:
                // this is the one action of the tab that ends somebody's work.
                AppLog.procs.notice(
                    """
                    \(signal.name, privacy: .public) to \(row.name, privacy: .private) \
                    pid \(row.pid, privacy: .public): \(failure ?? "sent", privacy: .public)
                    """
                )
                if let failure {
                    failures.append("\(row.name) (pid \(row.pid)): \(failure)")
                }
            }
            message = failures.isEmpty
                ? "\(signal.name) sent to \(summary)"
                : failures.joined(separator: " · ")
        }
    }

    func clearMessage() {
        message = nil
    }
}
