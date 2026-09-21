import Foundation
import Testing

import ReportKit

// MARK: - The fixture

private let home = "/Users/serenearyal"
private let utc = TimeZone(secondsFromGMT: 0)!

private let mac = SystemContext(
    modelName: "MacBook Pro 14-inch",
    modelID: "Mac15,3",
    chip: "Apple M3",
    performanceCores: 4,
    efficiencyCores: 4,
    ramBytes: 17_179_869_184,
    osVersion: "26.1",
    osBuild: "25B74",
    uptimeSeconds: 273_720,
    batteryPercent: 72,
    onBattery: true
)

private let totals = ReportTotals(
    processCount: 587,
    totalCPUPercent: 23.42,
    memoryUsedBytes: 12_348_030_976,
    memoryTotalBytes: 17_179_869_184,
    swapUsedBytes: 1_288_490_189,
    pressure: "Normal"
)

private let processRows = [
    ProcessReportRow(
        name: "WindowServer",
        pid: 178,
        user: "_windowserver",
        cpuPercent: 18.4,
        memoryBytes: 1_288_490_189,
        path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
    ),
    ProcessReportRow(
        name: "Xcode",
        pid: 4711,
        user: "serenearyal",
        cpuPercent: 4.2,
        memoryBytes: 8_589_934_592,
        path: "/Applications/Xcode.app/Contents/MacOS/Xcode"
    ),
    // A name with a pipe, a path with a tab, and no counters at all.
    ProcessReportRow(
        name: "weird | name",
        pid: 99,
        user: "serenearyal",
        cpuPercent: nil,
        memoryBytes: nil,
        path: "/Users/serenearyal/Library/Application Support/weird\tname"
    ),
]

private let storage = StorageReportContext(
    volumeName: "Macintosh HD",
    usedBytes: 384_000_000_000,
    totalBytes: 494_384_795_648,
    freeBytes: 110_384_795_648,
    scanDate: Date(timeIntervalSince1970: 1_789_862_400),
    filesScanned: 1_284_391,
    shownCount: 2,
    totalInList: 500
)

private let fileRows = [
    FileReportRow(
        name: "Ventura.dmg",
        folder: "/Users/serenearyal/Downloads",
        allocatedBytes: 4_300_000_000,
        logicalBytes: 4_300_000_000,
        modified: Date(timeIntervalSince1970: 1_767_225_600)
    ),
    FileReportRow(
        name: "Docker.raw",
        folder: "/Users/serenearyal/Library/Containers/com.docker.docker/Data/vms/0",
        allocatedBytes: 12_500_000_000,
        logicalBytes: 68_719_476_736,
        modified: Date(timeIntervalSince1970: 1_735_689_600)
    ),
]

// MARK: - The golden strings

@Test("the process report in markdown")
func processReportMarkdown() {
    let report = ProcessReport.render(
        rows: processRows,
        totals: totals,
        context: mac,
        options: ReportOptions(includePreamble: false, format: .markdown, limit: 60),
        home: home
    )
    let expected = """
        Mac: MacBook Pro 14-inch (Mac15,3), Apple M3 with 4P+4E cores, 16.0 GB RAM, macOS 26.1 (25B74), up 3d 4h 2m
        Now: CPU 23.4 % of 800 % across 8 cores, memory 11.5 GB of 16.0 GB used, swap 1.2 GB, pressure Normal, battery 72 % on battery
        Rows: top 3 of 587 processes, the highest by CPU joined with the highest by memory, sorted by CPU. CPU % is per core, so 100 % is one core fully busy.

        | Process | PID | User | CPU % | Memory | Path |
        |---|---|---|---|---|---|
        | WindowServer | 178 | _windowserver | 18.4 | 1.2 GB | /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer |
        | Xcode | 4711 | serenearyal | 4.2 | 8.0 GB | /Applications/Xcode.app/Contents/MacOS/Xcode |
        | weird \\| name | 99 | serenearyal | - | - | ~/Library/Application Support/weird name |
        """
    #expect(report == expected)
}

@Test("the process report as tab separated text")
func processReportTSV() {
    let report = ProcessReport.render(
        rows: processRows,
        totals: totals,
        context: mac,
        options: ReportOptions(includePreamble: false, format: .tsv, limit: 60),
        home: home
    )
    let expected = """
        Mac: MacBook Pro 14-inch (Mac15,3), Apple M3 with 4P+4E cores, 16.0 GB RAM, macOS 26.1 (25B74), up 3d 4h 2m
        Now: CPU 23.4 % of 800 % across 8 cores, memory 11.5 GB of 16.0 GB used, swap 1.2 GB, pressure Normal, battery 72 % on battery
        Rows: top 3 of 587 processes, the highest by CPU joined with the highest by memory, sorted by CPU. CPU % is per core, so 100 % is one core fully busy.

        Process\tPID\tUser\tCPU %\tMemory\tPath
        WindowServer\t178\t_windowserver\t18.4\t1.2 GB\t/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
        Xcode\t4711\tserenearyal\t4.2\t8.0 GB\t/Applications/Xcode.app/Contents/MacOS/Xcode
        weird | name\t99\tserenearyal\t-\t-\t~/Library/Application Support/weird name
        """
    #expect(report == expected)
}

/// The preamble is the whole difference between the two options, and it comes
/// first with one blank line under it.
@Test("the preamble is a paragraph in front of the same report", arguments: TableFormat.allCases)
func processReportPreamble(format: TableFormat) {
    let withPreamble = ProcessReport.render(
        rows: processRows,
        totals: totals,
        context: mac,
        options: ReportOptions(includePreamble: true, format: format),
        home: home
    )
    let without = ProcessReport.render(
        rows: processRows,
        totals: totals,
        context: mac,
        options: ReportOptions(includePreamble: false, format: format),
        home: home
    )
    #expect(withPreamble == ProcessReport.preamble + "\n\n" + without)
}

@Test("the process preamble asks the questions the user wants answered")
func processPreambleContent() {
    let text = ProcessReport.preamble
    #expect(text.contains("safely"))
    #expect(text.contains("system-critical"))
    #expect(text.contains("reconfigure"))
    #expect(text.contains("sudo"))
    #expect(text.contains("\n") == false)
}

@Test("the storage report in markdown")
func storageReportMarkdown() {
    let report = StorageReport.render(
        rows: fileRows,
        context: storage,
        system: mac,
        options: ReportOptions(includePreamble: false, format: .markdown, limit: 100),
        home: home,
        timeZone: utc
    )
    let expected = """
        Mac: MacBook Pro 14-inch (Mac15,3), Apple M3 with 4P+4E cores, 16.0 GB RAM, macOS 26.1 (25B74), up 3d 4h 2m
        Disk: Macintosh HD - 384 GB of 494 GB used, 110 GB free
        Scan: 2026-09-20, 1284391 files scanned
        Rows: top 2 of 500 largest files, sorted by size on disk. Size on disk is what deleting frees; a much larger logical size means a sparse file or a virtual disk.

        | File | Folder | Size on disk | Logical | Modified |
        |---|---|---|---|---|
        | Ventura.dmg | ~/Downloads | 4.3 GB | 4.3 GB | 2026-01-01 |
        | Docker.raw | ~/Library/Containers/com.docker.docker/Data/vms/0 | 12.5 GB | 68.7 GB | 2025-01-01 |
        """
    #expect(report == expected)
}

@Test("the storage report as tab separated text")
func storageReportTSV() {
    let report = StorageReport.render(
        rows: fileRows,
        context: storage,
        system: nil,
        options: ReportOptions(includePreamble: false, format: .tsv, limit: 100),
        home: home,
        timeZone: utc
    )
    let expected = """
        Disk: Macintosh HD - 384 GB of 494 GB used, 110 GB free
        Scan: 2026-09-20, 1284391 files scanned
        Rows: top 2 of 500 largest files, sorted by size on disk. Size on disk is what deleting frees; a much larger logical size means a sparse file or a virtual disk.

        File\tFolder\tSize on disk\tLogical\tModified
        Ventura.dmg\t~/Downloads\t4.3 GB\t4.3 GB\t2026-01-01
        Docker.raw\t~/Library/Containers/com.docker.docker/Data/vms/0\t12.5 GB\t68.7 GB\t2025-01-01
        """
    #expect(report == expected)
}

@Test("the storage preamble names the traps", arguments: TableFormat.allCases)
func storageReportPreamble(format: TableFormat) {
    let withPreamble = StorageReport.render(
        rows: fileRows,
        context: storage,
        system: mac,
        options: ReportOptions(includePreamble: true, format: format, limit: 100),
        home: home,
        timeZone: utc
    )
    let without = StorageReport.render(
        rows: fileRows,
        context: storage,
        system: mac,
        options: ReportOptions(includePreamble: false, format: format, limit: 100),
        home: home,
        timeZone: utc
    )
    #expect(withPreamble == StorageReport.preamble + "\n\n" + without)
    #expect(StorageReport.preamble.contains("sparse"))
    #expect(StorageReport.preamble.contains("sudo"))
}

// MARK: - The lines above the table

@Test("a Mac without a battery says nothing about one")
func reportWithoutABattery() {
    let desktop = SystemContext(
        modelName: "Mac mini",
        modelID: "Mac16,10",
        chip: "Apple M4",
        performanceCores: 4,
        efficiencyCores: 6,
        ramBytes: 17_179_869_184,
        osVersion: "26.1",
        osBuild: "25B74",
        uptimeSeconds: 3600
    )
    let report = ProcessReport.render(
        rows: [],
        totals: totals,
        context: desktop,
        options: ReportOptions(includePreamble: false),
        home: home
    )
    #expect(report.contains("battery") == false)
    #expect(report.contains("up 1h 0m"))
    #expect(report.contains("4P+6E"))
}

@Test("a report without the machine still stands on its own")
func reportWithoutContext() {
    let report = ProcessReport.render(
        rows: processRows,
        totals: totals,
        context: nil,
        options: ReportOptions(includePreamble: false),
        home: home
    )
    #expect(report.hasPrefix("Now: CPU 23.4 % in total,"))
    #expect(report.contains("Mac:") == false)
}

@Test("a few selected rows say so instead of claiming to be the top")
func storageReportOfASelection() {
    let report = StorageReport.render(
        rows: [fileRows[1]],
        context: storage,
        system: nil,
        options: ReportOptions(includePreamble: false, limit: 100),
        home: home,
        timeZone: utc
    )
    #expect(report.contains("Rows: 1 of the 2 files shown, out of 500 ranked, sorted by size on disk."))
}

@Test("the limit cuts the table, and the count says how many are left")
func reportLimit() {
    let report = ProcessReport.render(
        rows: processRows,
        totals: totals,
        context: mac,
        options: ReportOptions(includePreamble: false, format: .markdown, limit: 1),
        home: home
    )
    #expect(report.contains("Rows: top 1 of 587 processes"))
    #expect(report.contains("WindowServer"))
    #expect(report.contains("Xcode") == false)
}

@Test("an empty table is still a table")
func reportWithNoRows() {
    let report = ProcessReport.render(
        rows: [],
        totals: totals,
        context: nil,
        options: ReportOptions(includePreamble: false),
        home: home
    )
    #expect(report.hasSuffix("| Process | PID | User | CPU % | Memory | Path |\n|---|---|---|---|---|---|"))
}

@Test("the same rows always give the same report")
func reportIsDeterministic() {
    let first = ProcessReport.render(
        rows: RowSelection.processes(processRows),
        totals: totals,
        context: mac,
        options: ReportOptions(),
        home: home
    )
    for _ in 0..<5 {
        let again = ProcessReport.render(
            rows: RowSelection.processes(processRows.shuffled()),
            totals: totals,
            context: mac,
            options: ReportOptions(),
            home: home
        )
        #expect(again == first)
    }
}
