import Foundation

import ReportKit
import ScanKit
import SysMetrics

/// `ventctl report processes|files`: the same text the app's Copy for AI puts
/// on the pasteboard, on stdout instead.
///
/// The same `ReportKit` path and the same `ReportBuilder` mapping, so a change
/// to the wording of a report shows up here without a second implementation to
/// keep in step - and so the report can be diffed against `top` and `du`
/// without a GUI.
enum ReportCommands {
    static func processes(includePreamble: Bool, format: TableFormat, limit: Int) throws {
        // Two passes a second apart: the first has no baseline to subtract
        // from, so every CPU percentage in it would be nil.
        let sampler = ProcessSampler()
        _ = try sampler.sample()
        Thread.sleep(forTimeInterval: 1)
        let sampled = try sampler.sample()
        guard !sampled.isEmpty else { throw CLIError("the process table is empty") }

        let names = UserNameCache.shared
        let rows = sampled.map { ProcessTableRow(info: $0, userName: names.name(for: $0.uid)) }
        let memory = try? MemorySampler.sample()

        print(
            ProcessReport.render(
                rows: ReportBuilder.selectedProcessRows(rows, limit: limit),
                totals: ReportBuilder.totals(rows: rows, memory: memory),
                context: SystemContextReader.read(),
                options: ReportBuilder.options(
                    includeQuestion: includePreamble,
                    format: format,
                    limit: limit
                ),
                home: NSHomeDirectory()
            )
        )
    }

    /// The files come from the cache the app writes, not from a fresh scan: a
    /// whole-volume walk is minutes, and `ventctl scan` is the command for it.
    static func files(includePreamble: Bool, format: TableFormat, limit: Int) throws {
        let root = Scan.dataVolumePath
        let cache = ScanCache()
        guard let result = try cache.load(volume: ScanCache.volumeIdentifier(for: root)) else {
            throw CLIError(
                "no cached scan for this volume; run 'ventctl scan' or scan once in the app"
            )
        }
        let rows = ReportBuilder.fileRows(result.entries)
        print(
            StorageReport.render(
                rows: rows,
                context: ReportBuilder.storageContext(
                    result: result,
                    volume: DiskSpaceSampler.sample().first { $0.isBootVolume },
                    shownCount: min(rows.count, limit)
                ),
                system: SystemContextReader.read(),
                options: ReportBuilder.options(
                    includeQuestion: includePreamble,
                    format: format,
                    limit: limit
                ),
                home: NSHomeDirectory()
            )
        )
    }
}
