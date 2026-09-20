/// Namespace for the largest-files scan: bounded heap, `fts` walker,
/// coordinator, cache.
public enum Scan {
    /// Volume the whole-disk scan walks. Everything the user can write to
    /// lives here; `/` is a read-only system snapshot firmlinked over it.
    public static let dataVolumePath = "/System/Volumes/Data"

    /// Number of largest files the scan keeps.
    public static let resultLimit = 500

    /// Entries between two cancel checks. Reading 4096 warm directory entries
    /// is a few milliseconds, so a cancel lands well inside a second.
    public static let cancelCheckInterval = 4096

    /// Seconds between two progress events: 10 Hz, fast enough to look live
    /// and slow enough that the UI is not redrawn for nothing.
    public static let progressInterval: Double = 0.1

    /// `st_blocks` counts 512-byte blocks whatever the file system does.
    public static let blockSize: UInt64 = 512

    /// Roots whose first component says nothing on its own, so the breakdown
    /// takes two components: "/private/var" rather than "/private".
    public static let twoLevelRoots: Set<String> = [
        "private", "System", "Users", "Volumes", "usr", "opt", "var",
    ]
}

public enum ScanError: Error, Equatable, Sendable, CustomStringConvertible {
    case openFailed(String, Int32)
    case cacheFailed(String, String)

    public var description: String {
        switch self {
        case .openFailed(let path, let code):
            "cannot walk \(path) (errno \(code))"
        case .cacheFailed(let what, let reason):
            "\(what) failed: \(reason)"
        }
    }
}
