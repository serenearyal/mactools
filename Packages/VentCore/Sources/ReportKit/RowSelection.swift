import Foundation

/// Which processes go into the report.
///
/// A list sorted by CPU alone hides the 8 GB app that sits at 0 %, and a list
/// sorted by memory alone hides the one burning a core. The union of both tops
/// is what a human would have picked by hand.
public enum RowSelection {
    public static func processes(
        _ rows: [ProcessReportRow],
        limit: Int = 60,
        perList: Int = 40
    ) -> [ProcessReportRow] {
        guard limit > 0, perList > 0 else { return [] }

        let counted = rows.filter { $0.cpuPercent != nil || $0.memoryBytes != nil }
        let byCPU = counted.sorted(by: order).prefix(perList)
        let byMemory = counted.sorted(by: memoryOrder).prefix(perList)

        var seen = Set<Int32>()
        var picked: [ProcessReportRow] = []
        for row in byCPU + byMemory where seen.insert(row.pid).inserted {
            picked.append(row)
        }
        picked.sort(by: order)
        var result = Array(picked.prefix(limit))

        // A row without any counter is a last resort: it says nothing about
        // load, so it only takes a place nothing else wants.
        if result.count < limit {
            let rest = rows
                .filter { $0.cpuPercent == nil && $0.memoryBytes == nil }
                .sorted { left, right in
                    if left.name != right.name { return left.name < right.name }
                    return left.pid < right.pid
                }
            result += rest.prefix(limit - result.count)
        }
        return result
    }

    /// CPU first, then memory, then pid. A missing counter counts as less than
    /// zero, so those rows land at the end. The pid makes the order total, so
    /// two samples of the same machine give the same report.
    static func order(_ left: ProcessReportRow, _ right: ProcessReportRow) -> Bool {
        let leftCPU = left.cpuPercent ?? -1
        let rightCPU = right.cpuPercent ?? -1
        if leftCPU != rightCPU { return leftCPU > rightCPU }
        return memoryOrder(left, right)
    }

    static func memoryOrder(_ left: ProcessReportRow, _ right: ProcessReportRow) -> Bool {
        let leftMemory = left.memoryBytes.map(Double.init) ?? -1
        let rightMemory = right.memoryBytes.map(Double.init) ?? -1
        if leftMemory != rightMemory { return leftMemory > rightMemory }
        return left.pid < right.pid
    }
}
