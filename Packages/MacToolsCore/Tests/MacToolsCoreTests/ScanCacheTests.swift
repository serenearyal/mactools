import Foundation
import Testing

@testable import ScanKit

@Suite("scan cache")
struct ScanCacheTests {
    private func makeResult(root: String = "/", cancelled: Bool = false) -> ScanResult {
        var tally = ScanTally()
        tally.files = 4_412_332
        tally.directories = 812_004
        tally.allocated = 358_000_000_000
        tally.logical = 356_000_000_000
        tally.dataless = 9_912
        tally.hardLinkDuplicates = 4_004
        tally.unreadable = 61
        tally.skippedDirectories = 7
        return ScanResult(
            root: root,
            entries: [
                ScanEntry(
                    path: "/Users/x/Movies/a.mov",
                    allocated: 12_884_901_888,
                    logical: 12_884_901_000,
                    modified: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                ScanEntry(
                    path: "/private/var/vm/sleepimage",
                    allocated: 8_589_934_592,
                    logical: 8_589_934_592,
                    modified: Date(timeIntervalSince1970: 1_720_000_000.5)
                ),
            ],
            tally: tally,
            homeFolders: [FolderUsage(path: "/Users/x/Movies", name: "Movies", allocated: 99, files: 1)],
            rootFolders: [FolderUsage(path: "/private/var", name: "var", allocated: 42, files: 2)],
            started: Date(timeIntervalSince1970: 1_730_000_000),
            finished: Date(timeIntervalSince1970: 1_730_000_142),
            wasCancelled: cancelled
        )
    }

    private func makeCache() throws -> ScanCache {
        let directory = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "mactools-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        return ScanCache(directory: directory)
    }

    @Test("a result survives a round trip through the file")
    func roundTrip() throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        let result = makeResult()
        let url = try cache.save(result, volume: "TEST-UUID")
        #expect(url.lastPathComponent == "scan-TEST-UUID.json")
        #expect(FileManager.default.fileExists(atPath: url.path))

        let loaded = try cache.load(volume: "TEST-UUID")
        #expect(loaded == result)
        #expect(loaded?.duration == 142)
    }

    @Test("a cancelled scan keeps its partial ranking")
    func cancelledResult() throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }

        try cache.save(makeResult(cancelled: true), volume: "V")
        let loaded = try cache.load(volume: "V")
        #expect(loaded?.wasCancelled == true)
        #expect(loaded?.entries.count == 2)
    }

    @Test("nothing cached is nil, not an error")
    func missingFile() throws {
        let cache = try makeCache()
        #expect(try cache.load(volume: "never-written") == nil)
    }

    @Test("a damaged file is reported, not silently swallowed")
    func damagedFile() throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        try FileManager.default.createDirectory(
            at: cache.directory,
            withIntermediateDirectories: true
        )
        try Data("{ not json".utf8).write(to: cache.url(volume: "V"))

        #expect(throws: ScanError.self) { try cache.load(volume: "V") }
    }

    @Test("a file from another version is ignored")
    func otherVersion() throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        try cache.save(makeResult(), volume: "V")

        let url = cache.url(volume: "V")
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"version\":1", with: "\"version\":99")
        try Data(text.utf8).write(to: url)

        #expect(try cache.load(volume: "V") == nil)
    }

    @Test("each volume keeps its own file")
    func perVolume() throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        try cache.save(makeResult(root: "/"), volume: "A")
        try cache.save(makeResult(root: "/Volumes/Backup"), volume: "B")

        #expect(try cache.load(volume: "A")?.root == "/")
        #expect(try cache.load(volume: "B")?.root == "/Volumes/Backup")
        cache.remove(volume: "A")
        #expect(try cache.load(volume: "A") == nil)
        #expect(try cache.load(volume: "B") != nil)
    }

    @Test("the boot volume has a UUID, and the same path always gives the same one")
    func volumeIdentifier() {
        let first = ScanCache.volumeIdentifier(for: Scan.dataVolumePath)
        #expect(!first.isEmpty)
        #expect(first == ScanCache.volumeIdentifier(for: Scan.dataVolumePath))
        #expect(!first.contains("/"))
    }

    @Test("the cache lives under Application Support")
    func defaultDirectory() {
        let directory = ScanCache.defaultDirectory()
        #expect(directory.lastPathComponent == "MacTools")
        #expect(directory.path.contains("Application Support"))
    }
}
