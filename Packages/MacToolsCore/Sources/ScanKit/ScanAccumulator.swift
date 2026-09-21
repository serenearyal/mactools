import Foundation

/// Turns the file stream of the walker into the ranking and the "what takes
/// the space" breakdown.
///
/// Pure and allocation-light: one heap of `limit` entries plus two small
/// dictionaries, whatever the size of the volume. A test drives it without a
/// disk.
public struct ScanAccumulator {
    private var heap: TopNHeap<ScanEntry>
    private var root: [String: Bucket] = [:]
    private var home: [String: Bucket] = [:]
    private let homeDirectory: String

    private struct Bucket {
        var allocated: UInt64 = 0
        var files: UInt64 = 0
    }

    /// - Parameter homeDirectory: display path of the home folder, so the
    ///   breakdown can split "~/Library" out of "/Users".
    public init(limit: Int = Scan.resultLimit, homeDirectory: String = NSHomeDirectory()) {
        heap = TopNHeap(capacity: limit) { $0.allocated }
        self.homeDirectory = PathMapper.display(homeDirectory)
    }

    public mutating func add(_ file: WalkedFile) {
        heap.insert(
            ScanEntry(
                path: file.path,
                allocated: file.allocated,
                logical: file.logical,
                modified: file.modified
            )
        )
        add(file.allocated, to: &root, key: PathMapper.rootBucket(of: file.path))
        if let bucket = PathMapper.homeBucket(of: file.path, home: homeDirectory) {
            add(file.allocated, to: &home, key: bucket)
        }
    }

    public var entries: [ScanEntry] { heap.sortedDescending() }
    public var rootFolders: [FolderUsage] { folders(root) }
    public var homeFolders: [FolderUsage] { folders(home) }

    /// The size a file has to beat to enter the ranking, nil while the heap
    /// still has room.
    public var threshold: UInt64? { heap.threshold }

    private func add(_ allocated: UInt64, to buckets: inout [String: Bucket], key: String) {
        var bucket = buckets[key] ?? Bucket()
        bucket.allocated += allocated
        bucket.files += 1
        buckets[key] = bucket
    }

    private func folders(_ buckets: [String: Bucket]) -> [FolderUsage] {
        buckets
            .map {
                FolderUsage(
                    path: $0.key,
                    name: PathMapper.name(of: $0.key),
                    allocated: $0.value.allocated,
                    files: $0.value.files
                )
            }
            .sorted { $0.allocated > $1.allocated }
    }
}

/// Lets at most one event through per `interval`.
///
/// Separate and pure so the 10 Hz rule is a test rather than a hope: the
/// coordinator emits from inside the walk loop, where a clock read per file
/// would cost more than the progress is worth.
public struct ProgressThrottle: Sendable {
    public let interval: Double
    private var last: Double

    /// - Parameter start: the clock at the moment the scan began, so the
    ///   first tick still has to wait one interval.
    public init(interval: Double = Scan.progressInterval, start: Double) {
        self.interval = interval
        last = start
    }

    public mutating func shouldEmit(at now: Double) -> Bool {
        guard now - last >= interval else { return false }
        last = now
        return true
    }
}
