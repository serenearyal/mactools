import Foundation
import ReportKit
import ScanKit
import SysMetrics

/// What the app's own rows look like once they are a report.
///
/// The whole of Copy for AI outside the pasteboard call is here, and all of it
/// is a pure mapping over values: `ProcessTableRow` in, `ProcessReportRow` out.
/// The stores, the tables and the CLI all go through this one path, so the
/// paste is the same text whichever button produced it.
enum ReportBuilder {
    // MARK: - Processes

    static func processRows(_ rows: [ProcessTableRow]) -> [ProcessReportRow] {
        rows.map { row in
            ProcessReportRow(
                name: row.name,
                pid: row.pid,
                user: row.userName,
                cpuPercent: row.cpuPercent,
                memoryBytes: row.memoryBytes,
                path: row.executablePath
            )
        }
    }

    /// The sums above the table.
    ///
    /// `processCount` is the whole table, not the rows the report prints: the
    /// header line says "top 60 of 583", and the 583 has to be honest even when
    /// the user copied four selected rows.
    static func totals(rows: [ProcessTableRow], memory: MemorySnapshot?) -> ReportTotals {
        ReportTotals(
            processCount: rows.count,
            totalCPUPercent: ProcessTable.totalCPUPercent(rows),
            memoryUsedBytes: memory?.used ?? 0,
            memoryTotalBytes: memory?.total ?? 0,
            swapUsedBytes: memory?.swap.used ?? 0,
            pressure: memory?.pressure?.label ?? "unknown"
        )
    }

    /// The rows a "Copy All" prints: the union of the two tops, trimmed to the
    /// limit. A selection skips this and keeps the user's own order.
    static func selectedProcessRows(_ rows: [ProcessTableRow], limit: Int) -> [ProcessReportRow] {
        RowSelection.processes(processRows(rows), limit: limit)
    }

    // MARK: - Files

    static func fileRows(_ entries: [ScanEntry]) -> [FileReportRow] {
        entries.map { entry in
            FileReportRow(
                name: entry.name,
                // The folder, because the user asked for it by name: a list of
                // 100 files called "data.bin" is useless without one.
                folder: PathMapper.display(entry.parentPath),
                allocatedBytes: entry.allocated,
                logicalBytes: entry.logical,
                modified: entry.modified
            )
        }
    }

    /// The disk and scan lines above the file table.
    ///
    /// `shownCount` is what the table on screen holds after its search filter,
    /// and `totalInList` is what the scan ranked, so "12 of the 500 files
    /// shown, out of 500 ranked" stays true for a copied selection.
    static func storageContext(
        result: ScanResult,
        volume: VolumeInfo?,
        shownCount: Int
    ) -> StorageReportContext {
        StorageReportContext(
            volumeName: volume?.name ?? PathMapper.display(result.root),
            usedBytes: volume?.used ?? result.tally.allocated,
            totalBytes: volume?.total ?? 0,
            freeBytes: volume?.available ?? 0,
            scanDate: result.finished,
            filesScanned: result.tally.files,
            shownCount: shownCount,
            totalInList: result.entries.count
        )
    }

    // MARK: - Options

    /// What the four menu items add up to.
    static func options(
        includeQuestion: Bool,
        format: TableFormat,
        limit: Int
    ) -> ReportOptions {
        ReportOptions(includePreamble: includeQuestion, format: format, limit: limit)
    }

    /// "Copied 60 processes", "Copied 1 file". The confirmation line of every
    /// surface, so the popover and the two tabs word it the same way.
    ///
    /// Both forms are given rather than an "s" bolted on: "processs" is what
    /// that shortcut produces, and this is the one string the user sees after
    /// every copy.
    static func confirmation(count: Int, noun: String, plural: String) -> String {
        "Copied \(count) \(count == 1 ? noun : plural)"
    }

    static func confirmation(count: Int, noun: Noun) -> String {
        confirmation(count: count, noun: noun.singular, plural: noun.plural)
    }

    /// The two nouns Copy for AI ever counts.
    enum Noun {
        case process
        case file

        var singular: String {
            switch self {
            case .process: "process"
            case .file: "file"
            }
        }

        var plural: String {
            switch self {
            case .process: "processes"
            case .file: "files"
            }
        }
    }
}
