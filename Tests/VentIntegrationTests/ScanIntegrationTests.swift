import Darwin
import Foundation
import XCTest

import ScanKit

/// The scan against a real directory tree on the machine that runs the tests.
///
/// The reference numbers are computed a second time here with plain `lstat`
/// over `FileManager`, which shares no code with `fts`, so the two have to
/// agree by being right rather than by being the same bug.
final class ScanIntegrationTests: XCTestCase {
    /// The repository's `Packages` folder: a few thousand files, a build
    /// directory with large ones, and it is always there next to this file.
    private var packagesDirectory: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Packages", directoryHint: .isDirectory)
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

    func testTheWalkerAgreesWithLstatOnTheRepository() throws {
        let root = packagesDirectory
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.path),
            "the Packages folder must sit next to the test sources"
        )
        let expected = try reference(at: root)
        XCTAssertGreaterThan(expected.files, 10, "the fixture tree is suspiciously empty")

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
        let coordinator = ScanCoordinator(
            configuration: ScanCoordinator.Configuration(
                root: packagesDirectory.path,
                limit: 20,
                progressInterval: 0.001,
                // The default is one tick per 4096 entries, which a tree of a
                // few dozen source files never reaches.
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
        XCTAssertGreaterThan(progressCount, 0, "a scan of a few thousand files must tick at least once")
        XCTAssertLessThanOrEqual(scan.entries.count, 20)
        XCTAssertEqual(scan.entries.first?.allocated, try XCTUnwrap(reference(at: packagesDirectory).largest).allocated)
        XCTAssertFalse(scan.rootFolders.isEmpty)
    }

    /// A cancel has to land inside a second, whatever the tree is doing.
    func testCancelStopsTheScanWithinASecond() async throws {
        let coordinator = ScanCoordinator(
            configuration: ScanCoordinator.Configuration(root: Scan.dataVolumePath, limit: 50)
        )
        let started = Date()
        var cancelledAt: Date?
        var result: ScanResult?

        for await event in coordinator.run() {
            switch event {
            case .progress:
                if cancelledAt == nil, Date().timeIntervalSince(started) > 0.5 {
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
    }

    /// The cache the app reads at launch, against the real Application
    /// Support directory layout but under a directory of its own.
    func testTheCacheKeepsAResultForTheBootVolume() throws {
        let directory = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "vent-scan-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ScanCache(directory: directory)

        var accumulator = ScanAccumulator(limit: 5, homeDirectory: NSHomeDirectory())
        let outcome = try FTSWalker.walk(root: packagesDirectory.path) { accumulator.add($0) }
        let result = ScanResult(
            root: packagesDirectory.path,
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
