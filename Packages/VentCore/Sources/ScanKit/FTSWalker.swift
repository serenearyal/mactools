import Darwin
import Foundation

/// One regular file the walk counted.
public struct WalkedFile: Sendable, Equatable {
    /// Display path: the data-volume prefix is already stripped.
    public let path: String
    public let allocated: UInt64
    public let logical: UInt64
    public let modified: Date

    public init(path: String, allocated: UInt64, logical: UInt64, modified: Date) {
        self.path = path
        self.allocated = allocated
        self.logical = logical
        self.modified = modified
    }
}

/// A depth-first walk of a volume with `fts`.
///
/// `fts` is the only interface that gives one `stat` per entry with no extra
/// syscall and no Foundation allocation per file, which is what makes a
/// 4.4 M inode volume finish in minutes instead of an hour.
public enum FTSWalker {
    /// Must be the FIRST thing the scan thread does.
    ///
    /// Without it, `stat` on an iCloud or File Provider placeholder makes the
    /// provider fetch the file, which would turn a scan into a multi-gigabyte
    /// download. The policy is per thread, so it has to run on the thread
    /// that calls `fts_read`, not on the one that started it.
    @discardableResult
    public static func disableDatalessMaterialisation() -> Bool {
        setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        ) == 0
    }

    public struct Outcome: Sendable, Equatable {
        public let tally: ScanTally
        public let wasCancelled: Bool
    }

    /// A hard link counts one time. Only links with `st_nlink > 1` are
    /// remembered, so the set stays small on a volume where almost every file
    /// has a single link.
    private struct INode: Hashable {
        let device: dev_t
        let inode: UInt64
    }

    /// Walks `root` and reports every regular file.
    ///
    /// - Parameters:
    ///   - onTick: called every `tickInterval` entries with the running
    ///     tally and the directory the walk is in. Returning false stops the
    ///     walk and marks the outcome cancelled.
    ///   - onFile: called for every regular file that is neither a dataless
    ///     placeholder nor a second link to an inode already counted.
    public static func walk(
        root: String,
        skip: SkipList = .default,
        tickInterval: Int = Scan.cancelCheckInterval,
        onTick: (ScanTally, String) -> Bool = { _, _ in true },
        onFile: (WalkedFile) -> Void
    ) throws(ScanError) -> Outcome {
        // FTS_PHYSICAL: never follow a symlink, so nothing is counted twice
        // and no loop can trap the walk.
        // FTS_XDEV: stay on one file system, which is what keeps the firmlink
        // from `/System/Volumes/Data` back into `/` from doubling the count.
        // FTS_NOCHDIR: leave the working directory of the process alone; the
        // app walks on a background thread while the rest of it runs.
        let options = FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR
        let handle = root.withCString { cRoot -> UnsafeMutablePointer<FTS>? in
            var argv: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer(mutating: cRoot), nil]
            return argv.withUnsafeMutableBufferPointer { fts_open($0.baseAddress, options, nil) }
        }
        guard let handle else { throw ScanError.openFailed(root, errno) }
        defer { fts_close(handle) }

        var tally = ScanTally()
        var currentDirectory = PathMapper.display(root)
        var seen: Set<INode> = []
        var entries = 0
        var cancelled = false

        while let entry = fts_read(handle) {
            entries += 1
            if entries % tickInterval == 0, !onTick(tally, currentDirectory) {
                cancelled = true
                break
            }

            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                // `fts_name` is a C flexible array member, which Swift
                // imports as a single character. The last component of
                // `fts_path` is the same string.
                let path = PathMapper.display(String(cString: entry.pointee.fts_path))
                if skip.skips(displayPath: path, name: PathMapper.name(of: path)) {
                    fts_set(handle, entry, FTS_SKIP)
                    tally.skippedDirectories += 1
                    continue
                }
                currentDirectory = path
                tally.directories += 1

            case FTS_F:
                guard let status = entry.pointee.fts_statp?.pointee else {
                    tally.unreadable += 1
                    continue
                }
                guard status.st_flags & UInt32(SF_DATALESS) == 0 else {
                    tally.dataless += 1
                    continue
                }
                if status.st_nlink > 1 {
                    let inode = INode(device: status.st_dev, inode: status.st_ino)
                    guard seen.insert(inode).inserted else {
                        tally.hardLinkDuplicates += 1
                        continue
                    }
                }
                let allocated = UInt64(max(0, status.st_blocks)) * Scan.blockSize
                let logical = UInt64(max(0, status.st_size))
                tally.files += 1
                tally.allocated += allocated
                tally.logical += logical
                onFile(
                    WalkedFile(
                        path: PathMapper.display(String(cString: entry.pointee.fts_path)),
                        allocated: allocated,
                        logical: logical,
                        modified: Date(
                            timeIntervalSince1970: Double(status.st_mtimespec.tv_sec)
                                + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000
                        )
                    )
                )

            // No permission, unreadable directory, or the entry went away
            // while the scan ran. Counted and stepped over - unless it is the
            // root itself, where there is nothing to scan and the caller has
            // to hear about it: `fts_open` succeeds on a path that is not
            // there and only `fts_read` finds out.
            case FTS_DNR, FTS_ERR, FTS_NS:
                guard entry.pointee.fts_level > 0 else {
                    throw ScanError.openFailed(root, entry.pointee.fts_errno)
                }
                tally.unreadable += 1

            default:
                // FTS_DP (the second visit to a directory), FTS_SL, FTS_DC
                // and the device nodes. None of them holds blocks a user can
                // free by deleting a file.
                break
            }
        }

        return Outcome(tally: tally, wasCancelled: cancelled)
    }
}
