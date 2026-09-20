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

    /// Frees the per-process CPU baselines while the table is off screen.
    func reset() {
        sampler.reset()
        nextHelperAttempt = .distantPast
    }

    /// The signal path for a process this user does not own.
    func signal(_ signal: ProcessSignal, pid: Int32) async -> String? {
        do {
            try await helper.signalProcess(pid: pid, signal: signal)
            return nil
        } catch {
            return error.errorDescription ?? "the helper refused the signal"
        }
    }
}

/// The Processes tab: the merged table, what the user filtered it down to, and
/// the two signals the UI can send.
@MainActor
@Observable
final class ProcessStore {
    private(set) var rows: [ProcessTableRow] = []
    /// Rows with no readable counters. They are the reason for the helper.
    private(set) var restrictedCount = 0
    private(set) var helperRowCount = 0
    private(set) var helperFailure: String?
    /// The result of the last action, for the footer.
    private(set) var message: String?

    var searchText = ""
    var scope: ProcessFilterScope = .all
    var sortOrder = [ProcessComparator(key: .cpu, order: .reverse)]
    var selection: Set<ProcessTableRow.ID> = []

    @ObservationIgnored private let feed = ProcessFeed()
    @ObservationIgnored private let names = UserNameCache.shared
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var windowVisible = false
    @ObservationIgnored private var tabActive = false

    /// The uid of this process. Its rows can be signalled without the helper.
    static let currentUID = getuid()

    /// Activity Monitor's own default, and slow enough that one libproc pass
    /// over 580 processes stays under a percent of a core.
    private static let interval: Duration = .seconds(3)

    // MARK: - What the table shows

    var visibleRows: [ProcessTableRow] {
        ProcessTable
            .filter(rows, scope: scope, currentUID: ProcessStore.currentUID, query: searchText)
            .sorted(using: sortOrder)
    }

    var selectedRows: [ProcessTableRow] {
        rows.filter { selection.contains($0.id) }
    }

    var topByCPU: [ProcessTableRow] {
        ProcessTable.sorted(rows, by: .cpu, ascending: false)
    }

    var topByMemory: [ProcessTableRow] {
        ProcessTable.sorted(rows, by: .memory, ascending: false)
    }

    var totalCPUPercent: Double { ProcessTable.totalCPUPercent(rows) }

    var helperIsAnswering: Bool { helperRowCount > 0 }

    // MARK: - Cadence

    func setWindowVisible(_ visible: Bool) {
        guard windowVisible != visible else { return }
        windowVisible = visible
        updateSampling()
    }

    func setActiveTab(_ tab: MainTab) {
        let active = tab == .processes
        guard tabActive != active else { return }
        tabActive = active
        updateSampling()
    }

    /// The process table costs one libproc round trip per process, so it only
    /// runs while the tab is on screen.
    private func updateSampling() {
        let wanted = windowVisible && tabActive
        if wanted, task == nil {
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let sample = await feed.sample()
                    guard !Task.isCancelled else { return }
                    apply(sample)
                    try? await Task.sleep(for: ProcessStore.interval)
                }
            }
        } else if !wanted, task != nil {
            task?.cancel()
            task = nil
            rows = []
            restrictedCount = 0
            helperRowCount = 0
            Task { [feed] in await feed.reset() }
        }
    }

    private func apply(_ sample: ProcessFeed.Sample) {
        rows = sample.rows.map { ProcessTableRow(info: $0, userName: names.name(for: $0.uid)) }
        restrictedCount = ProcessTable.restrictedCount(rows)
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
        let live = Set(rows.map(\.id))
        selection = selection.filter { live.contains($0) }
    }

    // MARK: - Actions

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
