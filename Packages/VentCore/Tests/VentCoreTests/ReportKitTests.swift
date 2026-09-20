import Foundation
import Testing

import ReportKit

// MARK: - Numbers

@Test(
    "bytes are counted in 1024 for memory and 1000 for a disk",
    arguments: [
        (UInt64(0), "0 B", "0 B"),
        (512, "512 B", "512 B"),
        (1000, "1000 B", "1.0 KB"),
        (1024, "1.0 KB", "1.0 KB"),
        (1_048_576, "1.0 MB", "1.0 MB"),
        (1_288_490_189, "1.2 GB", "1.3 GB"),
        (17_179_869_184, "16.0 GB", "17.2 GB"),
        (384_000_000_000, "358 GB", "384 GB"),
        (1_099_511_627_776, "1.0 TB", "1.1 TB"),
    ]
)
func byteFormats(bytes: UInt64, memory: String, disk: String) {
    #expect(ReportFormat.bytes(bytes, style: .memory) == memory)
    #expect(ReportFormat.bytes(bytes, style: .disk) == disk)
}

@Test(
    "cpu keeps one decimal and never a comma",
    arguments: [
        (0.0, "0.0"),
        (0.04, "0.0"),
        (12.35, "12.3"),
        (99.99, "100.0"),
        (250.0, "250.0"),
        (-3.0, "0.0"),
        (Double.nan, "0.0"),
    ]
)
func cpuFormat(percent: Double, text: String) {
    #expect(ReportFormat.cpu(percent) == text)
}

@Test(
    "a date is the same on every Mac",
    arguments: [
        (1_789_862_400.0, "2026-09-20"),
        (1_767_225_600.0, "2026-01-01"),
        (1_735_689_600.0, "2025-01-01"),
        (0.0, "1970-01-01"),
    ]
)
func dateFormat(seconds: Double, text: String) {
    let date = Date(timeIntervalSince1970: seconds)
    #expect(ReportFormat.date(date, timeZone: TimeZone(secondsFromGMT: 0)!) == text)
}

/// The same instant is a different day either side of the date line, which is
/// exactly why the time zone is a parameter.
@Test("the date follows the time zone it is given")
func dateFollowsTheTimeZone() {
    let newYear = Date(timeIntervalSince1970: 1_767_225_600)
    #expect(ReportFormat.date(newYear, timeZone: TimeZone(secondsFromGMT: 0)!) == "2026-01-01")
    #expect(ReportFormat.date(newYear, timeZone: TimeZone(secondsFromGMT: -3600)!) == "2025-12-31")
}

@Test(
    "uptime drops the units that are zero at the front",
    arguments: [
        (0, "under 1m"),
        (59, "under 1m"),
        (60, "1m"),
        (3599, "59m"),
        (3600, "1h 0m"),
        (273_720, "3d 4h 2m"),
        (86_400, "1d 0h 0m"),
    ]
)
func uptimeFormat(seconds: Int, text: String) {
    #expect(ReportFormat.uptime(seconds: seconds) == text)
}

// MARK: - Cells

@Test(
    "a cell cannot break the table",
    arguments: [
        ("plain", "plain", "plain"),
        ("a|b", "a\\|b", "a|b"),
        ("a\tb", "a b", "a b"),
        ("a\nb", "a b", "a b"),
        ("a\r\nb", "a b", "a b"),
        ("a \t \n b", "a b", "a b"),
        ("  padded  ", "padded", "padded"),
        ("|", "\\|", "|"),
        ("", "", ""),
        ("a||b", "a\\|\\|b", "a||b"),
    ]
)
func sanitiserCases(input: String, markdown: String, tsv: String) {
    #expect(TextSanitiser.cell(input, format: .markdown) == markdown)
    #expect(TextSanitiser.cell(input, format: .tsv) == tsv)
}

@Test("a cell keeps the characters a file name is allowed to have")
func sanitiserKeepsNames() {
    let name = "Résumé (2026) - notes ·final·.pdf"
    #expect(TextSanitiser.cell(name, format: .markdown) == name)
}

@Test(
    "the home directory becomes a tilde, and only the home directory",
    arguments: [
        ("/Users/serenearyal", "~"),
        ("/Users/serenearyal/", "~/"),
        ("/Users/serenearyal/Downloads/a.dmg", "~/Downloads/a.dmg"),
        // Another account whose name starts the same way.
        ("/Users/serenearyal2/Downloads/a.dmg", "/Users/serenearyal2/Downloads/a.dmg"),
        ("/Users/serenearyalx", "/Users/serenearyalx"),
        ("/Applications/Xcode.app", "/Applications/Xcode.app"),
        ("", ""),
    ]
)
func tildeCases(path: String, expected: String) {
    #expect(PathAbbreviator.tilde(path, home: "/Users/serenearyal") == expected)
}

@Test("a home that is not a home changes nothing")
func tildeWithoutAHome() {
    #expect(PathAbbreviator.tilde("/Users/x/a", home: "") == "/Users/x/a")
    #expect(PathAbbreviator.tilde("/Users/x/a", home: "/") == "/Users/x/a")
}

// MARK: - Which rows go in

private func row(
    _ name: String,
    _ pid: Int32,
    cpu: Double? = nil,
    memory: UInt64? = nil
) -> ProcessReportRow {
    ProcessReportRow(name: name, pid: pid, user: "me", cpuPercent: cpu, memoryBytes: memory)
}

@Test("the selection is the union of both tops")
func selectionUnion() {
    let rows = [
        row("busy", 1, cpu: 90, memory: 1),
        row("fat", 2, cpu: 0, memory: 8_000_000_000),
        row("idle", 3, cpu: 0, memory: 1),
        row("warm", 4, cpu: 10, memory: 2),
    ]
    let picked = RowSelection.processes(rows, limit: 60, perList: 2)
    #expect(picked.map(\.pid) == [1, 4, 2])
}

@Test("a process appears once, however many lists it wins")
func selectionDedupes() {
    let rows = [
        row("both", 1, cpu: 90, memory: 8_000_000_000),
        row("small", 2, cpu: 1, memory: 1),
    ]
    let picked = RowSelection.processes(rows, limit: 60, perList: 2)
    #expect(picked.count == 2)
    #expect(picked.map(\.pid) == [1, 2])
}

/// The two lists are the same ranking here, so the union is one list long and
/// the limit is never reached: it is a cap, not a target.
@Test("one ranking gives one list")
func selectionOfOneRanking() {
    let rows = (1...100).map { row("p\($0)", Int32($0), cpu: Double($0), memory: UInt64($0)) }
    let picked = RowSelection.processes(rows, limit: 60, perList: 40)
    #expect(picked.count == 40)
    #expect(picked.first?.pid == 100)
    #expect(RowSelection.processes(rows, limit: 60, perList: 20).count == 20)
}

@Test("the limit cuts the union, keeping the busiest")
func selectionLimit() {
    // The busiest use the least memory, so the two lists share nothing and
    // the union is 80 rows long.
    let rows = (1...100).map {
        row("p\($0)", Int32($0), cpu: Double($0), memory: UInt64(101 - $0))
    }
    let picked = RowSelection.processes(rows, limit: 60, perList: 40)
    #expect(picked.count == 60)
    #expect(picked.first?.pid == 100)
    #expect(picked.map(\.pid).prefix(40) == Array((61...100).reversed())[...])
    #expect(picked.last?.pid == 21)
}

@Test("a row without counters comes last, and only if there is room")
func selectionNilCounters() {
    let rows = [
        row("ghost", 1),
        row("busy", 2, cpu: 50, memory: 100),
        row("warm", 3, cpu: 10, memory: 100),
    ]
    #expect(RowSelection.processes(rows, limit: 60, perList: 40).map(\.pid) == [2, 3, 1])
    #expect(RowSelection.processes(rows, limit: 2, perList: 40).map(\.pid) == [2, 3])
}

@Test("a row with only one counter is still ranked")
func selectionHalfCounted() {
    let rows = [
        row("cpuOnly", 1, cpu: 50),
        row("memoryOnly", 2, memory: 8_000_000_000),
        row("ghost", 3),
    ]
    #expect(RowSelection.processes(rows, limit: 60, perList: 40).map(\.pid) == [1, 2, 3])
}

@Test("the order does not depend on the order the sampler found them")
func selectionIsDeterministic() {
    let rows = (1...50).map {
        row("p\($0)", Int32($0), cpu: Double($0 % 7), memory: UInt64($0 % 5))
    }
    let expected = RowSelection.processes(rows).map(\.pid)
    for _ in 0..<10 {
        #expect(RowSelection.processes(rows.shuffled()).map(\.pid) == expected)
    }
}

@Test("ties are broken by the pid, so two samples agree")
func selectionTieBreak() {
    let rows = [row("b", 20, cpu: 5, memory: 100), row("a", 10, cpu: 5, memory: 100)]
    #expect(RowSelection.processes(rows).map(\.pid) == [10, 20])
}

@Test("nothing in, nothing out")
func selectionOfNothing() {
    #expect(RowSelection.processes([]).isEmpty)
    #expect(RowSelection.processes([row("a", 1, cpu: 1)], limit: 0).isEmpty)
    #expect(RowSelection.processes([row("a", 1, cpu: 1)], perList: 0).isEmpty)
}
