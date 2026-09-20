import Foundation
import ReportKit
import ScanKit
import SysMetrics
import Testing

/// The app's half of Copy for AI: turning the rows the tables already hold
/// into the rows `ReportKit` prints.
///
/// `ReportKit` has its own golden tests for the text; these check the mapping
/// on this side of it, which is where a wrong column or a lost folder would
/// come from.
@Suite("Report builder")
struct ReportBuilderTests {
    private func process(
        _ name: String,
        pid: Int32,
        cpu: Double? = nil,
        memory: UInt64? = nil,
        path: String? = nil,
        uid: uid_t = 501,
        user: String = "serene"
    ) -> ProcessTableRow {
        ProcessTableRow(
            info: ProcessInfoRow(
                pid: pid,
                parentPID: 1,
                uid: uid,
                command: name,
                name: name,
                executablePath: path,
                startAbsoluteTime: nil,
                cpuPercent: cpu,
                cpuNanoseconds: nil,
                memoryBytes: memory
            ),
            userName: user
        )
    }

    // MARK: - Processes

    @Test("Every column of a table row reaches the report row")
    func processMapping() {
        let rows = ReportBuilder.processRows([
            process("Xcode", pid: 42, cpu: 180.5, memory: 8_000_000_000, path: "/Applications/Xcode.app/Contents/MacOS/Xcode")
        ])
        #expect(rows.count == 1)
        #expect(rows[0].name == "Xcode")
        #expect(rows[0].pid == 42)
        #expect(rows[0].user == "serene")
        #expect(rows[0].cpuPercent == 180.5)
        #expect(rows[0].memoryBytes == 8_000_000_000)
        #expect(rows[0].path == "/Applications/Xcode.app/Contents/MacOS/Xcode")
    }

    @Test("A process with no readable counters keeps its name and its nils")
    func restrictedProcessMapping() {
        let rows = ReportBuilder.processRows([process("launchd", pid: 1, uid: 0, user: "root")])
        #expect(rows[0].cpuPercent == nil)
        #expect(rows[0].memoryBytes == nil)
        #expect(rows[0].path == nil)
        #expect(rows[0].user == "root")
    }

    @Test("The selection is the union of the two tops, not the CPU list alone")
    func unionSelection() {
        // One row burns a core and holds nothing; one holds 8 GB at 0 %.
        // A report that shows only the first hides the memory hog, which is
        // the whole reason the union exists.
        var rows = (1...50).map { index in
            process("busy\(index)", pid: Int32(index), cpu: Double(100 - index), memory: 1_000_000)
        }
        rows.append(process("bloat", pid: 999, cpu: 0, memory: 8_000_000_000))
        let picked = ReportBuilder.selectedProcessRows(rows, limit: 60)
        #expect(picked.contains { $0.name == "bloat" })
        // The top 40 by CPU, plus the one row the memory list adds that the
        // CPU list did not already hold.
        #expect(picked.count == 41)
    }

    @Test("The limit caps the rows, and the count above them stays the whole table")
    func limitAndTotals() {
        let rows = (1...100).map { index in
            process("p\(index)", pid: Int32(index), cpu: Double(index), memory: 1_000_000)
        }
        #expect(ReportBuilder.selectedProcessRows(rows, limit: 10).count == 10)
        let totals = ReportBuilder.totals(rows: rows, memory: nil)
        #expect(totals.processCount == 100)
        #expect(totals.totalCPUPercent == 5050)
    }

    @Test("Without a memory sample the totals say so instead of lying about zero")
    func totalsWithoutMemory() {
        let totals = ReportBuilder.totals(rows: [], memory: nil)
        #expect(totals.memoryTotalBytes == 0)
        #expect(totals.pressure == "unknown")
    }

    // MARK: - Files

    @Test("A file row carries its folder, which is the column the report is for")
    func fileMapping() {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = ReportBuilder.fileRows([
            ScanEntry(
                path: "/Users/serene/Movies/holiday.mov",
                allocated: 4_000_000_000,
                logical: 4_000_000_001,
                modified: modified
            )
        ])
        #expect(rows.count == 1)
        #expect(rows[0].name == "holiday.mov")
        #expect(rows[0].folder == "/Users/serene/Movies")
        #expect(rows[0].allocatedBytes == 4_000_000_000)
        #expect(rows[0].logicalBytes == 4_000_000_001)
        #expect(rows[0].modified == modified)
    }

    @Test("Without a volume the scan's own figures stand in for the disk line")
    func storageContextFromVolume() {
        var tally = ScanTally()
        tally.files = 1_234
        tally.allocated = 99
        let result = ScanResult(
            root: "/System/Volumes/Data",
            entries: [
                ScanEntry(path: "/a/b.bin", allocated: 10, logical: 10, modified: .now)
            ],
            tally: tally,
            homeFolders: [],
            rootFolders: [],
            started: Date(timeIntervalSince1970: 0),
            finished: Date(timeIntervalSince1970: 100),
            wasCancelled: false
        )
        let context = ReportBuilder.storageContext(result: result, volume: nil, shownCount: 1)
        #expect(context.filesScanned == 1_234)
        #expect(context.totalInList == 1)
        #expect(context.shownCount == 1)
        #expect(context.scanDate == Date(timeIntervalSince1970: 100))
        // No volume: the scan's own figures stand in, and the name is the root.
        #expect(context.usedBytes == 99)
    }

    // MARK: - Wording

    @Test("The confirmation counts in the singular and the plural")
    func confirmationWording() {
        // "processs" is what an "s" bolted onto the singular gives, and it is
        // the one string the user sees after every copy.
        #expect(ReportBuilder.confirmation(count: 1, noun: .process) == "Copied 1 process")
        #expect(ReportBuilder.confirmation(count: 60, noun: .process) == "Copied 60 processes")
        #expect(ReportBuilder.confirmation(count: 1, noun: .file) == "Copied 1 file")
        #expect(ReportBuilder.confirmation(count: 0, noun: .file) == "Copied 0 files")
    }

    @Test("The options carry the three menu items through unchanged")
    func optionMapping() {
        let plain = ReportBuilder.options(includeQuestion: false, format: .tsv, limit: 7)
        #expect(!plain.includePreamble)
        #expect(plain.format == .tsv)
        #expect(plain.limit == 7)
    }
}
