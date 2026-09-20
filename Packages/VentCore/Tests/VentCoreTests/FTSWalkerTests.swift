import Darwin
import Foundation
import Testing

@testable import ScanKit

/// A throwaway directory tree with known sizes.
///
/// Random bytes, not zeros: a run of zeros is the one thing a file system may
/// decide to store sparsely, and the point of the fixture is that
/// `st_blocks * 512` is predictable.
private final class Fixture {
    let root: URL

    init(name: String = UUID().uuidString) throws {
        root = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "vent-walk-\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ relativePath: String, bytes: Int) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            arc4random_buf(base, buffer.count)
        }
        try data.write(to: url)
        return url
    }

    func directory(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: root.appending(path: relativePath, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    func hardLink(_ relativePath: String, to existing: String) throws {
        try FileManager.default.linkItem(
            at: root.appending(path: existing),
            to: root.appending(path: relativePath)
        )
    }

    func symlink(_ relativePath: String, to existing: String) throws {
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: relativePath),
            withDestinationURL: root.appending(path: existing)
        )
    }
}

@Suite("fts walker")
struct FTSWalkerTests {
    /// The tree every test in this suite walks:
    ///
    ///     big.bin              256 KB
    ///     small.bin            4 KB
    ///     nested/medium.bin    64 KB
    ///     nested/link.bin      hard link to medium.bin
    ///     link-to-big          symlink to big.bin
    ///     .fseventsd/noise.bin 1 MB, skipped
    ///     deep/.Spotlight-V100/index.bin 1 MB, skipped
    private func makeTree() throws -> Fixture {
        let fixture = try Fixture()
        try fixture.write("big.bin", bytes: 256 * 1024)
        try fixture.write("small.bin", bytes: 4 * 1024)
        try fixture.write("nested/medium.bin", bytes: 64 * 1024)
        try fixture.hardLink("nested/link.bin", to: "nested/medium.bin")
        try fixture.symlink("link-to-big", to: "big.bin")
        try fixture.write(".fseventsd/noise.bin", bytes: 1024 * 1024)
        try fixture.write("deep/.Spotlight-V100/index.bin", bytes: 1024 * 1024)
        return fixture
    }

    @Test("every regular file is counted once, with its size on disk")
    func countsFiles() throws {
        let fixture = try makeTree()
        var files: [WalkedFile] = []
        let outcome = try FTSWalker.walk(root: fixture.root.path) { files.append($0) }

        #expect(!outcome.wasCancelled)
        #expect(outcome.tally.files == 3)
        #expect(files.count == 3)

        let byName = Dictionary(uniqueKeysWithValues: files.map { (PathMapper.name(of: $0.path), $0) })
        #expect(byName["big.bin"]?.logical == 256 * 1024)
        #expect(byName["small.bin"]?.logical == 4 * 1024)
        #expect(byName["medium.bin"]?.logical == 64 * 1024)
        for file in files {
            #expect(file.allocated >= file.logical, "\(file.path) allocates less than it holds")
            #expect(file.allocated % Scan.blockSize == 0)
        }
        #expect(outcome.tally.allocated == files.reduce(0) { $0 + $1.allocated })
        #expect(outcome.tally.logical == 256 * 1024 + 4 * 1024 + 64 * 1024)
    }

    @Test("a hard link is counted once, and the duplicate is tallied")
    func hardLinkDedupe() throws {
        let fixture = try makeTree()
        var paths: [String] = []
        let outcome = try FTSWalker.walk(root: fixture.root.path) { paths.append($0.path) }

        #expect(outcome.tally.hardLinkDuplicates == 1)
        let linked = paths.filter { $0.hasSuffix("medium.bin") || $0.hasSuffix("link.bin") }
        #expect(linked.count == 1, "one of the two links must be counted, not both")
    }

    @Test("a symlink is never followed and holds no file")
    func symlinkIsNotFollowed() throws {
        let fixture = try makeTree()
        var paths: [String] = []
        _ = try FTSWalker.walk(root: fixture.root.path) { paths.append($0.path) }
        #expect(!paths.contains { $0.hasSuffix("link-to-big") })
        #expect(paths.count { $0.hasSuffix("big.bin") } == 1)
    }

    @Test("a skip-list directory is cut off wherever it sits")
    func skipList() throws {
        let fixture = try makeTree()
        var paths: [String] = []
        let outcome = try FTSWalker.walk(root: fixture.root.path) { paths.append($0.path) }

        #expect(outcome.tally.skippedDirectories == 2)
        #expect(!paths.contains { $0.contains(".fseventsd") })
        #expect(!paths.contains { $0.contains(".Spotlight-V100") })

        // Without the list the same tree yields the two big files.
        var all: [String] = []
        let full = try FTSWalker.walk(root: fixture.root.path, skip: .none) { all.append($0.path) }
        #expect(full.tally.files == 5)
        #expect(full.tally.skippedDirectories == 0)
    }

    @Test("a directory with no read permission is counted as unreadable")
    func unreadableDirectory() throws {
        let fixture = try Fixture()
        try fixture.write("visible.bin", bytes: 1024)
        try fixture.write("locked/hidden.bin", bytes: 1024)
        let locked = fixture.root.appending(path: "locked", directoryHint: .isDirectory)
        #expect(chmod(locked.path, 0) == 0)
        defer { chmod(locked.path, 0o755) }

        var paths: [String] = []
        let outcome = try FTSWalker.walk(root: fixture.root.path) { paths.append($0.path) }
        #expect(outcome.tally.unreadable == 1)
        #expect(outcome.tally.files == 1)
        #expect(paths.count == 1)
    }

    @Test("the tick stops the walk and marks it cancelled")
    func cancellation() throws {
        let fixture = try Fixture()
        for index in 0..<200 { try fixture.write("f\(index).bin", bytes: 512) }

        var ticks = 0
        var seen = 0
        let outcome = try FTSWalker.walk(
            root: fixture.root.path,
            tickInterval: 1,
            onTick: { _, _ in
                ticks += 1
                return ticks < 10
            },
            onFile: { _ in seen += 1 }
        )
        #expect(outcome.wasCancelled)
        #expect(ticks == 10)
        #expect(seen < 200, "the walk stopped before the end of the tree")
    }

    @Test("the tick reports the directory the walk is in")
    func tickReportsDirectory() throws {
        let fixture = try Fixture()
        try fixture.write("deep/deeper/a.bin", bytes: 1024)

        var directories: Set<String> = []
        _ = try FTSWalker.walk(
            root: fixture.root.path,
            tickInterval: 1,
            onTick: { _, directory in
                directories.insert(directory)
                return true
            },
            onFile: { _ in }
        )
        #expect(directories.contains { $0.hasSuffix("deep/deeper") })
    }

    @Test("a root that is not there fails instead of reporting an empty scan")
    func missingRoot() {
        #expect(throws: ScanError.self) {
            try FTSWalker.walk(root: "/nope-\(UUID().uuidString)") { _ in }
        }
    }

    @Test("the dataless I/O policy applies to the calling thread")
    func datalessPolicy() {
        #expect(FTSWalker.disableDatalessMaterialisation())
    }
}
