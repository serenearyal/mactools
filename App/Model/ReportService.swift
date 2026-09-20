import AppKit
import Foundation
import Observation
import ReportKit
import ScanKit
import SysMetrics

/// Copy for AI: the one place that turns what is on screen into a paste.
///
/// Every surface - the two toolbars, the two context menus, the popover, the
/// status item menu and `--copy-report` - comes through here, so the text is
/// the same whichever one the user pressed, and the confirmation is worded once.
@MainActor
@Observable
final class ReportService {
    /// All of the table, or only what the user picked in it.
    enum Scope: Equatable, Sendable {
        case all
        case selection
    }

    /// The most rows a report prints. The process limit is `RowSelection`'s
    /// own: the union of the top 40 by CPU and the top 40 by memory, capped.
    static let processLimit = 60
    static let fileLimit = 100

    /// True while a one-shot sample pair runs for a copy from the popover.
    /// The button shows a spinner for the second it takes.
    private(set) var isPreparing = false
    /// The transient line the popover shows after a copy. It clears itself.
    private(set) var confirmation: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let processes: ProcessStore
    @ObservationIgnored private let storage: StorageStore
    @ObservationIgnored private let store: MetricsStore
    @ObservationIgnored private var confirmationTask: Task<Void, Never>?

    /// Long enough to read, short enough that it is gone before the next look.
    private static let confirmationSeconds = 2.5

    init(
        settings: AppSettings,
        processes: ProcessStore,
        storage: StorageStore,
        store: MetricsStore
    ) {
        self.settings = settings
        self.processes = processes
        self.storage = storage
        self.store = store
    }

    // MARK: - What the UI asks

    /// True when a file report can be produced at all. The popover button is
    /// disabled with "Scan first" until it is.
    var canReportFiles: Bool { storage.result != nil }

    /// Processes, from any surface.
    ///
    /// `samplesFirst` is for the popover and the status menu: they can be the
    /// first thing the user opens, and a CPU percentage needs two passes about
    /// a second apart. The Processes tab is already sampling, so it passes
    /// false and the copy is instant.
    func copyProcesses(
        scope: Scope = .all,
        format: TableFormat = .markdown,
        samplesFirst: Bool = false,
        announce: Bool = true
    ) {
        guard !isPreparing else { return }
        Task { [weak self] in
            guard let self else { return }
            if samplesFirst, !processes.hasReportableSample {
                isPreparing = true
                await processes.sampleForReport()
                isPreparing = false
            }
            let rows = scope == .selection ? processes.selectedRows : processes.rows
            guard !rows.isEmpty else {
                announceFailure("Nothing to copy yet", to: .processes, announce: announce)
                return
            }
            let text = processReport(rows: rows, scope: scope, format: format)
            write(text)
            let count = min(rows.count, scope == .selection ? rows.count : ReportService.processLimit)
            announceSuccess(
                ReportBuilder.confirmation(count: count, noun: .process),
                to: .processes,
                announce: announce
            )
        }
    }

    func copyFiles(
        scope: Scope = .all,
        format: TableFormat = .markdown,
        announce: Bool = true
    ) {
        storage.loadCacheIfNeeded()
        guard let result = storage.result else {
            announceFailure("Scan the disk first", to: .files, announce: announce)
            return
        }
        let rows = scope == .selection ? storage.selectedRows : storage.visibleRows
        guard !rows.isEmpty else {
            announceFailure("Nothing to copy yet", to: .files, announce: announce)
            return
        }
        write(fileReport(rows: rows, result: result, format: format))
        let count = min(rows.count, scope == .selection ? rows.count : ReportService.fileLimit)
        announceSuccess(
            ReportBuilder.confirmation(count: count, noun: .file),
            to: .files,
            announce: announce
        )
    }

    // MARK: - The text

    func processReport(
        rows: [ProcessTableRow],
        scope: Scope,
        format: TableFormat
    ) -> String {
        // A selection is what the user picked, in the order the table had it;
        // only "Copy All" goes through the CPU-and-memory union.
        let reportRows = scope == .selection
            ? ReportBuilder.processRows(rows)
            : ReportBuilder.selectedProcessRows(rows, limit: ReportService.processLimit)
        return ProcessReport.render(
            rows: reportRows,
            totals: ReportBuilder.totals(rows: processes.rows, memory: memory),
            context: SystemContextReader.read(),
            options: ReportBuilder.options(
                includeQuestion: settings.reportIncludesQuestion,
                format: format,
                limit: scope == .selection ? rows.count : ReportService.processLimit
            ),
            home: NSHomeDirectory()
        )
    }

    func fileReport(
        rows: [StorageRow],
        result: ScanResult,
        format: TableFormat
    ) -> String {
        StorageReport.render(
            rows: ReportBuilder.fileRows(rows.map(\.entry)),
            context: ReportBuilder.storageContext(
                result: result,
                // The same reason as `memory`: the Tools section of the
                // popover asks for no disk figures at all, so the snapshot has
                // none and the "402 GB of 494 GB used" line would be missing.
                volume: store.snapshot.bootVolume
                    ?? DiskSpaceSampler.sample().first { $0.isBootVolume },
                shownCount: storage.visibleRows.count
            ),
            system: SystemContextReader.read(),
            options: ReportBuilder.options(
                includeQuestion: settings.reportIncludesQuestion,
                format: format,
                limit: ReportService.fileLimit
            ),
            home: NSHomeDirectory()
        )
    }

    /// The memory line above the table.
    ///
    /// The snapshot when there is one, and one `host_statistics64` call when
    /// there is not. A copy from the status item menu runs with nothing on
    /// screen, so the metrics pass is reading the CPU for the menu bar label
    /// and nothing else - and a report that says "memory 0 B of 0 B used" is
    /// worse than one that took 50 us to find out.
    private var memory: MemorySnapshot? {
        store.snapshot.memory ?? (try? MemorySampler.sample())
    }

    // MARK: - Pasteboard

    /// `clearContents` first: a pasteboard keeps every type that was on it, and
    /// pasting into a chat would otherwise hand over the old RTF instead.
    private func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Confirmations

    private enum Surface {
        case processes
        case files
    }

    private func announceSuccess(_ text: String, to surface: Surface, announce: Bool) {
        AppLog.app.notice("copy for AI: \(text, privacy: .public)")
        guard announce else { return }
        switch surface {
        case .processes: processes.showMessage(text)
        case .files: storage.showMessage(text)
        }
        flash(text)
    }

    private func announceFailure(_ text: String, to surface: Surface, announce: Bool) {
        AppLog.app.error("copy for AI: \(text, privacy: .public)")
        guard announce else { return }
        switch surface {
        case .processes: processes.showMessage(text)
        case .files: storage.showMessage(text)
        }
        flash(text)
    }

    /// The popover's own confirmation: it replaces the second line of the row
    /// it belongs to and fades out again, so nothing in the panel moves.
    private func flash(_ text: String) {
        confirmationTask?.cancel()
        confirmation = text
        confirmationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .seconds(ReportService.confirmationSeconds),
                tolerance: .milliseconds(250)
            )
            guard !Task.isCancelled else { return }
            self?.confirmation = nil
        }
    }
}
