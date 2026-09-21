/// Directories the walk does not descend into.
///
/// The list is deliberately short. Index and revision stores are noise the
/// user cannot act on, `/private/var/folders` is per-boot caches, and
/// `/Volumes` holds other mounts (`FTS_XDEV` already stops there; the entry
/// keeps that true when the root is not the data volume).
///
/// Two things are on purpose absent. `/private/var/vm` stays in: the swap
/// files and the sleep image are legitimately large and the user may want to
/// see them. Trash directories stay in: a full Trash is exactly the kind of
/// space this tab is meant to find. iCloud and File Provider placeholders are
/// skipped by their `SF_DATALESS` flag in the walker, never by their path,
/// because the flag is the thing that actually says "downloading this would
/// cost a network round trip".
public struct SkipList: Sendable, Equatable {
    /// Matched against the directory name, at any depth.
    public var names: Set<String>
    /// Matched against the whole display path.
    public var paths: Set<String>

    public init(names: Set<String>, paths: Set<String>) {
        self.names = names
        self.paths = paths
    }

    public static let `default` = SkipList(
        names: [
            ".Spotlight-V100",
            ".fseventsd",
            ".DocumentRevisions-V100",
            ".TemporaryItems",
        ],
        paths: [
            "/private/var/folders",
            "/private/var/db/uuidtext",
            "/Volumes",
        ]
    )

    public static let none = SkipList(names: [], paths: [])

    public func skips(displayPath: String, name: String) -> Bool {
        names.contains(name) || paths.contains(displayPath)
    }
}
