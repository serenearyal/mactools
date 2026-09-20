import Foundation

/// "Copy for AI" for the largest files.
public enum StorageReport {
    public static let preamble = """
        Here are the largest files on my Mac. For each one, tell me what created it, whether \
        deleting it loses data I cannot get back, and a safer alternative when there is one. \
        Flag the files that belong to the system, and the sparse files and virtual disks whose \
        size on disk is far below their logical size. Do not suggest anything that needs sudo.
        """

    static let headers = ["File", "Folder", "Size on disk", "Logical", "Modified"]

    public static func render(
        rows: [FileReportRow],
        context: StorageReportContext,
        system: SystemContext?,
        options: ReportOptions = ReportOptions(limit: 100),
        home: String = "",
        timeZone: TimeZone = .current
    ) -> String {
        let shown = Array(rows.prefix(max(0, options.limit)))
        var blocks: [String] = []
        if options.includePreamble { blocks.append(preamble) }

        var lines: [String] = []
        if let system { lines.append(ReportLines.mac(system)) }
        lines.append(diskLine(context))
        lines.append(scanLine(context, timeZone: timeZone))
        lines.append(rowsLine(shown: shown.count, context: context))
        blocks.append(lines.joined(separator: "\n"))

        let cells = shown.map { row in
            [
                row.name,
                PathAbbreviator.tilde(row.folder, home: home),
                ReportFormat.bytes(row.allocatedBytes, style: .disk),
                ReportFormat.bytes(row.logicalBytes, style: .disk),
                ReportFormat.date(row.modified, timeZone: timeZone),
            ]
        }
        blocks.append(ReportTable.render(headers: headers, rows: cells, format: options.format))
        return blocks.joined(separator: "\n\n")
    }

    static func diskLine(_ context: StorageReportContext) -> String {
        "Disk: \(context.volumeName) - \(ReportFormat.bytes(context.usedBytes, style: .disk)) of "
            + "\(ReportFormat.bytes(context.totalBytes, style: .disk)) used, "
            + "\(ReportFormat.bytes(context.freeBytes, style: .disk)) free"
    }

    static func scanLine(_ context: StorageReportContext, timeZone: TimeZone) -> String {
        "Scan: \(ReportFormat.date(context.scanDate, timeZone: timeZone)), "
            + "\(context.filesScanned) files scanned"
    }

    /// Two shapes, because "Copy selected" prints a few rows out of the list
    /// and the count alone would then be a lie about what was ranked.
    static func rowsLine(shown: Int, context: StorageReportContext) -> String {
        let tail = "sorted by size on disk. Size on disk is what deleting frees; a much larger "
            + "logical size means a sparse file or a virtual disk."
        if shown == context.shownCount {
            return "Rows: top \(shown) of \(context.totalInList) largest files, " + tail
        }
        return "Rows: \(shown) of the \(context.shownCount) files shown, out of "
            + "\(context.totalInList) ranked, " + tail
    }
}
