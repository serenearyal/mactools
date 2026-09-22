import AppKit
import Foundation
import Observation
import ScanKit

/// One row of the largest-files table.
struct StorageRow: Identifiable, Hashable, Sendable {
    let entry: ScanEntry
    /// False when the file is gone since the scan: trashed, moved or deleted
    /// somewhere else. The row is dimmed rather than removed, so the ranking
    /// does not jump under the pointer.
    var exists = true

    var id: String { entry.path }
    var path: String { entry.path }
    var name: String { entry.name }
    var parent: String { entry.parentPath }
    var allocated: UInt64 { entry.allocated }
    var logical: UInt64 { entry.logical }
    var modified: Date { entry.modified }

    /// The logical size, but only when it is worth showing: a sparse file, an
    /// APFS clone or a compressed file. Every file differs by a little - the
    /// tail block, the extended attributes - and a number on every row would
    /// say nothing, so the note needs a full percent of difference.
    var logicalNote: String? {
        let difference = allocated > logical ? allocated - logical : logical - allocated
        guard difference > max(Scan.blockSize * 16, allocated / 100) else { return nil }
        return Fmt.storageSize(logical)
    }
}

/// The Storage tab: the cached ranking, the running scan and the two actions
/// that touch files.
///
/// The scan itself lives on its own thread inside `ScanCoordinator`; this
/// class only consumes its event stream, so the main thread never waits on a
/// directory read.
@MainActor
@Observable
final class StorageStore {
    private(set) var result: ScanResult?
    private(set) var rows: [StorageRow] = []
    private(set) var progress: ScanProgress?
    private(set) var isScanning = false
    /// The last thing that happened, for the line next to the Scan button.
    private(set) var message: String?
    private(set) var hasFullDiskAccess = true

    var searchText = ""
    var sortOrder = [KeyPathComparator(\StorageRow.allocated, order: .reverse)]

    /// The rows the table has selected.
    ///
    /// Not a plain stored property: the last message is about the selection it
    /// acted on, so a new selection makes it stale and the status line goes
    /// back to "Scanned 2 h ago". `trash` subtracts what it moved before it
    /// writes its own message, so its message survives.
    var selection: Set<StorageRow.ID> {
        get { selectedIDs }
        set {
            guard newValue != selectedIDs else { return }
            selectedIDs = newValue
            message = nil
        }
    }

    private var selectedIDs: Set<StorageRow.ID> = []

    @ObservationIgnored private let cache = ScanCache()
    @ObservationIgnored private var coordinator: ScanCoordinator?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private(set) var root = Scan.dataVolumePath

    // MARK: - What the table shows

    var visibleRows: [StorageRow] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty
            ? rows
            : rows.filter { $0.path.localizedCaseInsensitiveContains(query) }
        return matching.sorted(using: sortOrder)
    }

    var selectedRows: [StorageRow] {
        rows.filter { selection.contains($0.id) }
    }

    var selectedAllocated: UInt64 {
        selectedRows.reduce(0) { $0 + $1.allocated }
    }

    var lastScanDescription: String? {
        guard let result else { return nil }
        let when = result.finished.formatted(.relative(presentation: .named))
        return result.wasCancelled ? "Stopped \(when), partial result" : "Scanned \(when)"
    }

    // MARK: - Cache

    /// Reads the cached ranking once, when the tab first appears. Both the
    /// file read and the existence check run off the main thread.
    func loadCacheIfNeeded() {
        hasFullDiskAccess = FullDiskAccess.isGranted()
        guard !loaded else { return }
        loaded = true
        let cache = cache
        let root = root
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                let volume = ScanCache.volumeIdentifier(for: root)
                return try? cache.load(volume: volume)
            }.value
            guard let self, let loaded, result == nil else { return }
            apply(loaded)
        }
    }

    // MARK: - Scanning

    func startScan(root: String? = nil) {
        guard !isScanning else { return }
        if let root { self.root = (root as NSString).expandingTildeInPath }
        hasFullDiskAccess = FullDiskAccess.isGranted()
        AppLog.scan.notice(
            """
            scan started on \(self.root, privacy: .private), \
            full disk access \(self.hasFullDiskAccess, privacy: .public)
            """
        )
        message = nil
        progress = nil
        isScanning = true

        let coordinator = ScanCoordinator(
            configuration: ScanCoordinator.Configuration(root: self.root)
        )
        self.coordinator = coordinator
        scanTask = Task { [weak self] in
            for await event in coordinator.run() {
                guard let self else { return }
                switch event {
                case .progress(let value):
                    progress = value
                case .finished(let value):
                    finish(value)
                case .failed(let error):
                    message = error.description
                    AppLog.scan.error("scan failed: \(error.description, privacy: .public)")
                }
            }
            guard let self else { return }
            isScanning = false
            progress = nil
            self.coordinator = nil
        }
    }

    /// Safe at any time, including from the quit path: with no scan running it
    /// does nothing at all.
    func cancelScan() {
        guard let coordinator else { return }
        AppLog.scan.notice("scan cancelled")
        coordinator.cancel()
    }

    private func finish(_ result: ScanResult) {
        AppLog.scan.notice(
            """
            scan finished: \(result.tally.files, privacy: .public) files, \
            \(result.tally.allocated, privacy: .public) bytes, \
            cancelled \(result.wasCancelled, privacy: .public)
            """
        )
        apply(result)
        let cache = cache
        let root = root
        Task.detached(priority: .utility) {
            try? cache.save(result, volume: ScanCache.volumeIdentifier(for: root))
        }
    }

    private func apply(_ result: ScanResult) {
        self.result = result
        rows = result.entries.map { StorageRow(entry: $0) }
        selection = selection.filter { id in rows.contains { $0.id == id } }
        refreshExistence()
    }

    /// 500 `stat` calls, off the main thread, so a stale cache shows its dead
    /// rows dimmed instead of offering to reveal a file that is gone.
    private func refreshExistence() {
        let paths = rows.map(\.path)
        Task { [weak self] in
            let missing = await Task.detached(priority: .utility) {
                Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
            }.value
            guard let self, !missing.isEmpty else { return }
            rows = rows.map { row in
                var row = row
                row.exists = !missing.contains(row.path)
                return row
            }
        }
    }

    // MARK: - Actions on files

    func revealInFinder(_ ids: Set<StorageRow.ID>) {
        let urls = rows
            .filter { ids.contains($0.id) && $0.exists }
            .map { URL(filePath: PathMapper.fileSystem($0.path)) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Moves the selection to the Trash. Reversible by design: the app never
    /// deletes a file outright.
    func trash(_ ids: Set<StorageRow.ID>) {
        let victims = rows.filter { ids.contains($0.id) && $0.exists }
        guard !victims.isEmpty else { return }
        let outcome = TrashService.trash(victims.map(\.path))
        // Only what actually went: after a partial trash, the rows that
        // failed are still on disk and still in the cached tally.
        let freed = victims
            .filter { outcome.trashed.keys.contains($0.path) }
            .reduce(0) { $0 + $1.allocated }
        for path in outcome.trashed.keys {
            AppLog.scan.notice("moved to the Trash: \(path, privacy: .private)")
        }
        for (path, reason) in outcome.failed {
            AppLog.scan.error(
                "could not trash \(path, privacy: .private): \(reason, privacy: .public)"
            )
        }

        rows.removeAll { outcome.trashed.keys.contains($0.path) }
        selection.subtract(outcome.trashed.keys)
        pruneCache(removing: Set(outcome.trashed.keys), freed: freed)

        let moved = outcome.trashed.count
        if outcome.failed.isEmpty {
            message = "Moved \(moved) \(moved == 1 ? "item" : "items") to the Trash, \(Fmt.storageSize(freed)) freed"
        } else {
            let reason = outcome.failed.values.first ?? "unknown error"
            message = "Moved \(moved) of \(victims.count): \(reason)"
        }
    }

    /// Keeps the cached result in step with what the table now shows, so a
    /// relaunch does not resurrect the rows.
    private func pruneCache(removing paths: Set<String>, freed: UInt64) {
        guard let current = result, !paths.isEmpty else { return }
        let entries = current.entries.filter { !paths.contains($0.path) }
        var tally = current.tally
        tally.files -= UInt64(min(paths.count, Int(tally.files)))
        tally.allocated -= min(freed, tally.allocated)
        let pruned = ScanResult(
            root: current.root,
            entries: entries,
            tally: tally,
            homeFolders: current.homeFolders,
            rootFolders: current.rootFolders,
            started: current.started,
            finished: current.finished,
            wasCancelled: current.wasCancelled
        )
        result = pruned
        let cache = cache
        let root = root
        Task.detached(priority: .utility) {
            try? cache.save(pruned, volume: ScanCache.volumeIdentifier(for: root))
        }
    }

    /// The status line of the tab, for an action that did not come from here.
    /// A Copy for AI from the toolbar lands in the same place "Scanned 2 h ago"
    /// does, and is cleared by the same dismiss button.
    func showMessage(_ text: String) {
        message = text
    }

    /// The dismiss button of the status line, and the selection change and the
    /// scan that make the message stale. Without it "Moved 3 items to the
    /// Trash" hid "Scanned 2 h ago" for the rest of the session.
    func clearMessage() {
        message = nil
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: FullDiskAccess.settingsURLString) else { return }
        NSWorkspace.shared.open(url)
    }
}
