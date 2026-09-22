import Darwin
import AppKit
import Foundation
import XCTest

import ScanKit

/// The scan against a real directory tree on the machine that runs the tests.
///
/// The reference numbers are computed a second time here with plain `lstat`
/// over `FileManager`, which shares no code with `fts`, so the two have to
/// agree by being right rather than by being the same bug.
final class ScanIntegrationTests: XCTestCase {
    /// Directories made by this test case, removed in `tearDown`.
    private var fixtures: [URL] = []

    override func tearDownWithError() throws {
        for fixture in fixtures {
            try? FileManager.default.removeItem(at: fixture)
        }
        fixtures = []
    }

    /// An empty directory of its own under the temporary folder, with the
    /// symlinks resolved so the walker and `FileManager` print the same path.
    private func makeFixtureDirectory(_ name: String) throws -> URL {
        let base = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "mactools-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fixtures.append(base)
        let resolved = try XCTUnwrap(realpath(base.path, nil))
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
    }

    /// A small tree that holds every case the walker treats apart: nested
    /// folders, files of distinct sizes with one clear largest, a hidden
    /// file, an empty file and folder, a hard link, and symlinks to a file
    /// and to a folder, neither of which may be followed.
    ///
    /// It lives in the temporary folder rather than the repository, so a
    /// build writing next to the tests cannot change it while it is walked.
    private func makeSmallTree() throws -> URL {
        let root = try makeFixtureDirectory("scan-fixture")
        let manager = FileManager.default
        var index = 0
        for folder in ["a", "a/b", "a/b/c", "d", "e/f", "empty"] {
            let directory = root.appending(path: folder, directoryHint: .isDirectory)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard folder != "empty" else { continue }
            for _ in 0..<4 {
                index += 1
                // Distinct sizes that each cross a block boundary.
                let data = Data(repeating: UInt8(index % 251), count: index * 5_000)
                try data.write(to: directory.appending(path: "file-\(index).bin"))
            }
        }
        try Data(repeating: 7, count: 1_000_000).write(to: root.appending(path: "a/b/largest.bin"))
        try Data("hidden".utf8).write(to: root.appending(path: "d/.hidden"))
        try Data().write(to: root.appending(path: "d/empty.txt"))
        try manager.linkItem(
            at: root.appending(path: "a/file-1.bin"),
            to: root.appending(path: "d/hard-link.bin")
        )
        try manager.createSymbolicLink(
            at: root.appending(path: "d/link-to-largest"),
            withDestinationURL: root.appending(path: "a/b/largest.bin")
        )
        try manager.createSymbolicLink(
            at: root.appending(path: "e/link-to-a"),
            withDestinationURL: root.appending(path: "a", directoryHint: .isDirectory)
        )
        return root
    }

    /// A wide tree of empty files: enough entries that the walk is still
    /// running when the test cancels it at the first progress tick.
    private func makeLargeTree(folders: Int, filesPerFolder: Int) throws -> URL {
        let root = try makeFixtureDirectory("scan-cancel")
        for folder in 0..<folders {
            let directory = root.appending(path: "folder-\(folder)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            for file in 0..<filesPerFolder {
                let descriptor = open(directory.appending(path: "f\(file)").path, O_CREAT | O_WRONLY, 0o644)
                guard descriptor >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                close(descriptor)
            }
        }
        return root
    }

    private struct Reference {
        var files = 0
        var allocated: UInt64 = 0
        var largest: (path: String, allocated: UInt64)?
    }

    /// Every regular file under `root`, without following a symlink and
    /// without the skip-list directories, measured with `lstat`.
    private func reference(at root: URL, skip: SkipList = .default) throws -> Reference {
        var result = Reference()
        var seen: Set<UInt64> = []
        let enumerator = try XCTUnwrap(
            // No options: hidden files count, and the enumerator does not
            // descend into a symlinked directory, which matches FTS_PHYSICAL.
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: []
            )
        )
        for case let url as URL in enumerator {
            let path = url.path
            var status = stat()
            guard lstat(path, &status) == 0 else { continue }
            if status.st_mode & S_IFMT == S_IFDIR {
                if skip.skips(displayPath: path, name: url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard status.st_mode & S_IFMT == S_IFREG else { continue }
            guard status.st_flags & UInt32(SF_DATALESS) == 0 else { continue }
            if status.st_nlink > 1, !seen.insert(status.st_ino).inserted { continue }
            let allocated = UInt64(max(0, status.st_blocks)) * Scan.blockSize
            result.files += 1
            result.allocated += allocated
            if allocated > (result.largest?.allocated ?? 0) {
                result.largest = (path, allocated)
            }
        }
        return result
    }

    func testTheWalkerAgreesWithLstatOnAFixtureTree() throws {
        let root = try makeSmallTree()
        let expected = try reference(at: root)
        // 20 sized files, largest.bin, .hidden and empty.txt; the hard link
        // counts once and neither symlink is followed.
        XCTAssertEqual(expected.files, 23, "the fixture tree is not what the test built")

        var accumulator = ScanAccumulator(limit: 10, homeDirectory: NSHomeDirectory())
        let outcome = try FTSWalker.walk(root: root.path) { accumulator.add($0) }

        XCTAssertFalse(outcome.wasCancelled)
        XCTAssertEqual(Int(outcome.tally.files), expected.files)
        XCTAssertEqual(outcome.tally.allocated, expected.allocated)

        let top = try XCTUnwrap(accumulator.entries.first)
        let largest = try XCTUnwrap(expected.largest)
        XCTAssertEqual(top.allocated, largest.allocated)
        XCTAssertEqual(top.path, PathMapper.display(largest.path))
        XCTAssertEqual(
            accumulator.entries.map(\.allocated),
            accumulator.entries.map(\.allocated).sorted(by: >),
            "the ranking must come out biggest first"
        )
    }

    /// The whole coordinator: its own thread, the progress stream, the
    /// terminal event and a result that matches the walker.
    func testTheCoordinatorStreamsProgressAndFinishes() async throws {
        let root = try makeSmallTree()
        let coordinator = ScanCoordinator(
            configuration: ScanCoordinator.Configuration(
                root: root.path,
                limit: 20,
                // A tree of a few dozen entries is walked in well under a
                // millisecond, so every tick has to be let through.
                progressInterval: 0,
                // The default is one tick per 4096 entries, which a tree of a
                // few dozen entries never reaches.
                tickInterval: 4
            )
        )

        var progressCount = 0
        var result: ScanResult?
        for await event in coordinator.run() {
            switch event {
            case .progress: progressCount += 1
            case .finished(let value): result = value
            case .failed(let error): XCTFail("the scan failed: \(error)")
            }
        }

        let scan = try XCTUnwrap(result)
        XCTAssertFalse(scan.wasCancelled)
        XCTAssertGreaterThan(scan.tally.files, 10)
        XCTAssertGreaterThan(progressCount, 0, "a scan of a few dozen entries must tick at least once")
        XCTAssertLessThanOrEqual(scan.entries.count, 20)
        XCTAssertEqual(scan.entries.first?.allocated, try XCTUnwrap(reference(at: root).largest).allocated)
        XCTAssertFalse(scan.rootFolders.isEmpty)
    }

    /// A cancel has to land inside a second, whatever the tree is doing.
    ///
    /// The tree is a local fixture of 40 000 files, so the test neither walks
    /// the whole disk nor asks for Full Disk Access, and the walk is still
    /// running when the first progress tick arrives and cancels it.
    func testCancelStopsTheScanWithinASecond() async throws {
        let folders = 200
        let filesPerFolder = 200
        let root = try makeLargeTree(folders: folders, filesPerFolder: filesPerFolder)
        let coordinator = ScanCoordinator(
            configuration: ScanCoordinator.Configuration(
                root: root.path,
                limit: 50,
                progressInterval: 0,
                tickInterval: 64
            )
        )
        var cancelledAt: Date?
        var result: ScanResult?

        for await event in coordinator.run() {
            switch event {
            case .progress:
                if cancelledAt == nil {
                    cancelledAt = Date()
                    coordinator.cancel()
                }
            case .finished(let value): result = value
            case .failed(let error): XCTFail("the scan failed: \(error)")
            }
        }

        let scan = try XCTUnwrap(result)
        let requested = try XCTUnwrap(cancelledAt)
        XCTAssertTrue(scan.wasCancelled)
        XCTAssertLessThan(
            scan.finished.timeIntervalSince(requested),
            1,
            "cancel must stop the walk inside a second"
        )
        XCTAssertGreaterThan(scan.tally.files, 0, "a cancelled scan still keeps what it found")
        XCTAssertLessThan(Int(scan.tally.files), folders * filesPerFolder, "the cancel came after the walk ended")
    }

    /// The cache the app reads at launch, against the real Application
    /// Support directory layout but under a directory of its own.
    func testTheCacheKeepsAResultForTheBootVolume() throws {
        let directory = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "mactools-scan-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ScanCache(directory: directory)

        let root = try makeSmallTree()
        var accumulator = ScanAccumulator(limit: 5, homeDirectory: NSHomeDirectory())
        let outcome = try FTSWalker.walk(root: root.path) { accumulator.add($0) }
        let result = ScanResult(
            root: root.path,
            entries: accumulator.entries,
            tally: outcome.tally,
            homeFolders: accumulator.homeFolders,
            rootFolders: accumulator.rootFolders,
            started: Date(),
            finished: Date(),
            wasCancelled: false
        )

        let volume = ScanCache.volumeIdentifier(for: Scan.dataVolumePath)
        try cache.save(result, volume: volume)
        XCTAssertEqual(try cache.load(volume: volume), result)
    }
}

final class SettingsLinkTests: XCTestCase {
    /// A misspelled scheme has no handler, and macOS then offers the App Store.
    func testFullDiskAccessLinkHasAHandler() throws {
        let url = try XCTUnwrap(URL(string: FullDiskAccess.settingsURLString))
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        XCTAssertNotNil(NSWorkspace.shared.urlForApplication(toOpen: url))
    }
}
