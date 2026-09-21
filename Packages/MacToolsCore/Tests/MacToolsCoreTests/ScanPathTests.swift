import Darwin
import Foundation
import Testing

@testable import ScanKit

@Suite("display paths and skip list")
struct ScanPathTests {
    @Test("the data-volume prefix is stripped for display")
    func stripsPrefix() {
        #expect(PathMapper.display("/System/Volumes/Data/Users/x/a.pdf") == "/Users/x/a.pdf")
        #expect(PathMapper.display("/System/Volumes/Data") == "/")
        #expect(PathMapper.display("/Users/x/a.pdf") == "/Users/x/a.pdf")
        #expect(PathMapper.display("/Applications") == "/Applications")
    }

    @Test("a path that only starts with the same characters is left alone")
    func nearMiss() {
        #expect(PathMapper.display("/System/Volumes/DataBackup/x") == "/System/Volumes/DataBackup/x")
        #expect(PathMapper.display("/System/Volumes/Recovery") == "/System/Volumes/Recovery")
    }

    @Test("both forms of a firmlinked path reach the same inode")
    func firmlinkIsTheSameFile() throws {
        let display = PathMapper.display("/System/Volumes/Data/Users")
        #expect(display == "/Users")

        var long = stat()
        var short = stat()
        #expect(lstat("/System/Volumes/Data/Users", &long) == 0)
        #expect(lstat(PathMapper.fileSystem(display), &short) == 0)
        #expect(long.st_ino == short.st_ino)
        #expect(long.st_dev == short.st_dev)
    }

    @Test("name and parent split an absolute path")
    func nameAndParent() {
        #expect(PathMapper.name(of: "/Users/x/a.pdf") == "a.pdf")
        #expect(PathMapper.parent(of: "/Users/x/a.pdf") == "/Users/x")
        #expect(PathMapper.name(of: "/a.pdf") == "a.pdf")
        #expect(PathMapper.parent(of: "/a.pdf") == "/")
        #expect(PathMapper.name(of: "/") == "/")
        #expect(PathMapper.parent(of: "bare") == "")
    }

    @Test("the root bucket takes two components under a shared container")
    func rootBuckets() {
        #expect(PathMapper.rootBucket(of: "/Users/x/Documents/a.pdf") == "/Users/x")
        #expect(PathMapper.rootBucket(of: "/Users/shared.txt") == "/Users")
        #expect(PathMapper.rootBucket(of: "/Applications/Xcode.app/Contents/a") == "/Applications")
        #expect(PathMapper.rootBucket(of: "/private/var/vm/swapfile0") == "/private/var")
        #expect(PathMapper.rootBucket(of: "/Library/Caches/a") == "/Library")
        #expect(PathMapper.rootBucket(of: "/loose.txt") == "/")
    }

    @Test("the home bucket is the folder right under the home directory")
    func homeBuckets() {
        let home = "/Users/x"
        #expect(PathMapper.homeBucket(of: "/Users/x/Library/Caches/a", home: home) == "/Users/x/Library")
        #expect(PathMapper.homeBucket(of: "/Users/x/a.pdf", home: home) == "/Users/x")
        #expect(PathMapper.homeBucket(of: "/Users/y/a.pdf", home: home) == nil)
        #expect(PathMapper.homeBucket(of: "/Applications/a", home: home) == nil)
        #expect(PathMapper.homeBucket(of: "/Users/xerox/a", home: home) == nil)
    }

    @Test("the skip list matches by name at any depth and by whole path")
    func skipMatching() {
        let skip = SkipList.default
        #expect(skip.skips(displayPath: "/Users/x/.Spotlight-V100", name: ".Spotlight-V100"))
        #expect(skip.skips(displayPath: "/.fseventsd", name: ".fseventsd"))
        #expect(skip.skips(displayPath: "/private/var/folders", name: "folders"))
        #expect(skip.skips(displayPath: "/private/var/db/uuidtext", name: "uuidtext"))
        #expect(skip.skips(displayPath: "/Volumes", name: "Volumes"))
    }

    @Test("swap, the sleep image and the Trash are not skipped")
    func doesNotSkipRealSpace() {
        let skip = SkipList.default
        #expect(!skip.skips(displayPath: "/private/var/vm", name: "vm"))
        #expect(!skip.skips(displayPath: "/.Trashes", name: ".Trashes"))
        #expect(!skip.skips(displayPath: "/Users/x/.Trash", name: ".Trash"))
        #expect(!skip.skips(displayPath: "/Users/x/Library/Mobile Documents", name: "Mobile Documents"))
        // A folder that only shares the name of a skipped path stays in.
        #expect(!skip.skips(displayPath: "/Users/x/folders", name: "folders"))
    }
}

@Suite("full disk access probe")
struct FullDiskAccessTests {
    @Test("a file that is not there is absent, not a refusal")
    func missingFile() {
        #expect(FullDiskAccess.probe("/tmp/mactools-does-not-exist-\(UUID().uuidString)") == .absent)
    }

    @Test("a readable file is granted")
    func readableFile() throws {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "mactools-fda-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FullDiskAccess.probe(url.path) == .granted)
    }

    @Test("a file with no read permission is denied")
    func unreadableFile() throws {
        let url = URL(filePath: NSTemporaryDirectory()).appending(path: "mactools-fda-\(UUID().uuidString)")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(chmod(url.path, 0) == 0)
        #expect(FullDiskAccess.probe(url.path) == .denied)
    }
}
