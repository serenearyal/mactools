import Foundation

/// One file in the ranking.
///
/// `path` is the display path: the `/System/Volumes/Data` prefix is already
/// stripped, so it is what the user knows and what Finder accepts.
public struct ScanEntry: Sendable, Codable, Hashable, Identifiable {
    public let path: String
    /// `st_blocks * 512`: what the file costs on the volume, which is the
    /// number that frees up when it goes.
    public let allocated: UInt64
    /// `st_size`. Larger than `allocated` for a sparse file or an APFS clone,
    /// smaller when the tail block is padded.
    public let logical: UInt64
    public let modified: Date

    public init(path: String, allocated: UInt64, logical: UInt64, modified: Date) {
        self.path = path
        self.allocated = allocated
        self.logical = logical
        self.modified = modified
    }

    public var id: String { path }
    public var name: String { PathMapper.name(of: path) }
    public var parentPath: String { PathMapper.parent(of: path) }
}

/// One bucket of the "what takes the space" breakdown.
public struct FolderUsage: Sendable, Codable, Equatable, Identifiable {
    public let path: String
    public let name: String
    public let allocated: UInt64
    public let files: UInt64

    public init(path: String, name: String, allocated: UInt64, files: UInt64) {
        self.path = path
        self.name = name
        self.allocated = allocated
        self.files = files
    }

    public var id: String { path }
}

/// Everything the walk counted, ranking aside.
public struct ScanTally: Sendable, Codable, Equatable {
    public var files: UInt64 = 0
    public var directories: UInt64 = 0
    public var allocated: UInt64 = 0
    public var logical: UInt64 = 0
    /// Files carrying `SF_DATALESS`: iCloud and File Provider placeholders.
    /// They are counted and never touched, so nothing downloads.
    public var dataless: UInt64 = 0
    /// Extra links to an inode whose blocks were already counted.
    public var hardLinkDuplicates: UInt64 = 0
    /// `FTS_DNR`, `FTS_ERR` and `FTS_NS` together: no permission, or the
    /// entry disappeared while the scan ran.
    public var unreadable: UInt64 = 0
    /// Directories the skip list cut off.
    public var skippedDirectories: UInt64 = 0

    public init() {}
}

/// A live tick of a running scan.
public struct ScanProgress: Sendable, Equatable {
    public let files: UInt64
    public let allocated: UInt64
    /// Display path of the directory the walk is in.
    public let currentDirectory: String
    public let unreadable: UInt64
    public let elapsed: TimeInterval

    public init(
        files: UInt64,
        allocated: UInt64,
        currentDirectory: String,
        unreadable: UInt64,
        elapsed: TimeInterval
    ) {
        self.files = files
        self.allocated = allocated
        self.currentDirectory = currentDirectory
        self.unreadable = unreadable
        self.elapsed = elapsed
    }
}

/// What a finished or cancelled scan produced. A cancelled scan keeps its
/// partial ranking: it is still the largest files seen so far.
public struct ScanResult: Sendable, Codable, Equatable {
    public let root: String
    public let entries: [ScanEntry]
    public let tally: ScanTally
    public let homeFolders: [FolderUsage]
    public let rootFolders: [FolderUsage]
    public let started: Date
    public let finished: Date
    public let wasCancelled: Bool

    public init(
        root: String,
        entries: [ScanEntry],
        tally: ScanTally,
        homeFolders: [FolderUsage],
        rootFolders: [FolderUsage],
        started: Date,
        finished: Date,
        wasCancelled: Bool
    ) {
        self.root = root
        self.entries = entries
        self.tally = tally
        self.homeFolders = homeFolders
        self.rootFolders = rootFolders
        self.started = started
        self.finished = finished
        self.wasCancelled = wasCancelled
    }

    public var duration: TimeInterval { finished.timeIntervalSince(started) }
}

/// Progress at about 10 Hz, then exactly one terminal event.
public enum ScanEvent: Sendable {
    case progress(ScanProgress)
    case finished(ScanResult)
    case failed(ScanError)
}
