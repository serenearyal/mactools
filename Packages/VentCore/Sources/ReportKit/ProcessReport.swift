import Foundation

/// "Copy for AI" for the process list.
///
/// The header lines exist so the paste stands on its own: without them a chat
/// model has no idea which Mac this is, how many processes were left out, or
/// that 180 % CPU is normal on a ten-core machine.
public enum ProcessReport {
    public static let preamble = """
        Here is a snapshot of the processes running on my Mac. Tell me which of them I can safely \
        quit, which are system-critical and must keep running, and which app I should reconfigure \
        so it stops using this much CPU or memory. Group your answer by how sure you are, and do \
        not suggest anything that needs sudo.
        """

    static let headers = ["Process", "PID", "User", "CPU %", "Memory", "Path"]

    public static func render(
        rows: [ProcessReportRow],
        totals: ReportTotals,
        context: SystemContext?,
        options: ReportOptions = ReportOptions(),
        home: String = ""
    ) -> String {
        let shown = Array(rows.prefix(max(0, options.limit)))
        var blocks: [String] = []
        if options.includePreamble { blocks.append(preamble) }

        var lines: [String] = []
        if let context { lines.append(ReportLines.mac(context)) }
        lines.append(nowLine(totals: totals, context: context))
        lines.append(rowsLine(shown: shown.count, total: totals.processCount))
        blocks.append(lines.joined(separator: "\n"))

        let cells = shown.map { row in
            [
                row.name,
                String(row.pid),
                row.user,
                row.cpuPercent.map(ReportFormat.cpu) ?? "-",
                row.memoryBytes.map { ReportFormat.bytes($0, style: .memory) } ?? "-",
                row.path.map { PathAbbreviator.tilde($0, home: home) } ?? "-",
            ]
        }
        blocks.append(ReportTable.render(headers: headers, rows: cells, format: options.format))
        return blocks.joined(separator: "\n\n")
    }

    static func nowLine(totals: ReportTotals, context: SystemContext?) -> String {
        var parts: [String] = []
        if let context, context.coreCount > 0 {
            let ceiling = context.coreCount * 100
            parts.append(
                "CPU \(ReportFormat.cpu(totals.totalCPUPercent)) % of \(ceiling) % "
                    + "across \(context.coreCount) cores"
            )
        } else {
            parts.append("CPU \(ReportFormat.cpu(totals.totalCPUPercent)) % in total")
        }
        parts.append(
            "memory \(ReportFormat.bytes(totals.memoryUsedBytes, style: .memory)) of "
                + "\(ReportFormat.bytes(totals.memoryTotalBytes, style: .memory)) used"
        )
        parts.append("swap \(ReportFormat.bytes(totals.swapUsedBytes, style: .memory))")
        parts.append("pressure \(totals.pressure)")
        if let battery = ReportLines.battery(context) { parts.append(battery) }
        return "Now: " + parts.joined(separator: ", ")
    }

    static func rowsLine(shown: Int, total: Int) -> String {
        "Rows: top \(shown) of \(total) processes, the highest by CPU joined with the highest by "
            + "memory, sorted by CPU. CPU % is per core, so 100 % is one core fully busy."
    }
}

/// The lines both reports share.
enum ReportLines {
    static func mac(_ context: SystemContext) -> String {
        "Mac: \(context.modelName) (\(context.modelID)), \(context.chip) with "
            + "\(context.performanceCores)P+\(context.efficiencyCores)E cores, "
            + "\(ReportFormat.bytes(context.ramBytes, style: .memory)) RAM, "
            + "macOS \(context.osVersion) (\(context.osBuild)), "
            + "up \(ReportFormat.uptime(seconds: context.uptimeSeconds))"
    }

    /// Nil on a Mac without a battery, and on one whose charge did not read.
    static func battery(_ context: SystemContext?) -> String? {
        guard let context, let percent = context.batteryPercent else { return nil }
        guard let onBattery = context.onBattery else { return "battery \(percent) %" }
        return "battery \(percent) % \(onBattery ? "on battery" : "on power")"
    }
}
