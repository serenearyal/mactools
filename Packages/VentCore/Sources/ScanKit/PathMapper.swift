/// Paths between the volume the scan walks and the paths the user knows.
///
/// The data volume is mounted at `/System/Volumes/Data` and firmlinked into
/// `/`, so `fts` reports `/System/Volumes/Data/Users/x/a.pdf` for a file the
/// user calls `/Users/x/a.pdf`. Only the display form is stored and shown.
/// Mapping back is the identity: both forms reach the same inode on the same
/// device, so `stat`, `trashItem` and Finder all accept the short one.
/// `PathMapperTests` checks that on the running machine.
public enum PathMapper {
    public static let dataVolumePrefix = Scan.dataVolumePath

    /// Strips the data-volume prefix. Any other path passes through.
    public static func display(_ path: String) -> String {
        guard path.hasPrefix(dataVolumePrefix) else { return path }
        let rest = path.dropFirst(dataVolumePrefix.count)
        if rest.isEmpty { return "/" }
        // "/System/Volumes/DataFoo" is a different directory, not a prefix.
        guard rest.hasPrefix("/") else { return path }
        return String(rest)
    }

    /// The path to hand to a file operation. The display form already works.
    public static func fileSystem(_ displayPath: String) -> String { displayPath }

    public static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        let name = path[path.index(after: slash)...]
        return name.isEmpty ? path : String(name)
    }

    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return slash == path.startIndex ? "/" : String(path[path.startIndex..<slash])
    }

    /// The first `levels` components of an absolute path, "/" when there are
    /// none. "/Users/x/a.pdf" at two levels is "/Users/x".
    public static func prefix(of path: String, levels: Int) -> String {
        guard levels > 0, path.hasPrefix("/") else { return "/" }
        var index = path.index(after: path.startIndex)
        var taken = 0
        var end = path.endIndex
        while index < path.endIndex {
            if path[index] == "/" {
                taken += 1
                if taken == levels { end = index; break }
            }
            index = path.index(after: index)
        }
        let result = String(path[path.startIndex..<end])
        return result == "/" || result.isEmpty ? "/" : result
    }

    /// The bucket a file counts against in the root breakdown: one component
    /// of its directory, or two when the first one is a container everybody's
    /// files sit under.
    public static func rootBucket(of path: String) -> String {
        let directory = parent(of: path)
        guard directory.count > 1 else { return "/" }
        let first = prefix(of: directory, levels: 1)
        guard Scan.twoLevelRoots.contains(name(of: first)) else { return first }
        return prefix(of: directory, levels: 2)
    }

    /// The bucket a file counts against in the home breakdown: the folder
    /// directly under the home directory, or the home directory itself for a
    /// loose file. nil when the file is somewhere else.
    public static func homeBucket(of path: String, home: String) -> String? {
        guard path.hasPrefix(home + "/") else { return nil }
        let rest = path.dropFirst(home.count + 1)
        guard let slash = rest.firstIndex(of: "/") else { return home }
        return home + "/" + rest[rest.startIndex..<slash]
    }
}
