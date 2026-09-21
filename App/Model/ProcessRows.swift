import Foundation
import SysMetrics

/// Everything the Processes tab and the popover draw, derived from one sample.
///
/// It used to be four computed properties on the store, and SwiftUI evaluated
/// them inside `body`: filtering and sorting 580 rows on every pass of the
/// layout, several times per sample. The work is the same, it just belongs to
/// the sample rather than to the drawing, so this is derived once when the rows
/// land and once when the user changes the filter, the search or the column.
///
/// Pure values in, pure values out: no store, no observation, no AppKit.
struct ProcessRows: Equatable, Sendable {
    /// Every row of the last sample, in the order libproc gave them.
    var all: [ProcessTableRow] = []
    /// What the table shows: the scope and the search box applied, then the
    /// column the user sorted by.
    var visible: [ProcessTableRow] = []
    /// The two top lists, heaviest first.
    var topByCPU: [ProcessTableRow] = []
    var topByMemory: [ProcessTableRow] = []
    /// Rows with no readable counters. They are the reason for the helper.
    var restrictedCount = 0
    var totalCPUPercent: Double = 0

    static func make(
        rows: [ProcessTableRow],
        scope: ProcessFilterScope,
        currentUID: uid_t,
        query: String,
        sortOrder: [ProcessComparator]
    ) -> ProcessRows {
        ProcessRows(
            all: rows,
            visible: ProcessTable
                .filter(rows, scope: scope, currentUID: currentUID, query: query)
                .sorted(using: sortOrder),
            topByCPU: ProcessTable.sorted(rows, by: .cpu, ascending: false),
            topByMemory: ProcessTable.sorted(rows, by: .memory, ascending: false),
            restrictedCount: ProcessTable.restrictedCount(rows),
            totalCPUPercent: ProcessTable.totalCPUPercent(rows)
        )
    }
}
