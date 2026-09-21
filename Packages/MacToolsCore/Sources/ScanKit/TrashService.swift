import Foundation

public struct TrashOutcome: Sendable, Equatable {
    /// Original path to where the file now sits in the Trash.
    public let trashed: [String: URL]
    /// Original path to the reason it stayed.
    public let failed: [String: String]

    public init(trashed: [String: URL], failed: [String: String]) {
        self.trashed = trashed
        self.failed = failed
    }
}

/// Moving files to the Trash, and nothing else.
///
/// `FileManager.trashItem` is the only delete in the whole app: it is
/// reversible, it uses the `.Trashes` of the volume the file is on, and it
/// records the original location so "Put Back" works. `removeItem` is
/// deliberately absent from this file and from every caller of it - a scan
/// result that is one row out of date must never be able to erase data.
public enum TrashService {
    public static func trash(_ paths: [String]) -> TrashOutcome {
        var trashed: [String: URL] = [:]
        var failed: [String: String] = [:]
        for path in paths {
            let url = URL(filePath: PathMapper.fileSystem(path))
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                trashed[path] = resulting as URL? ?? url
            } catch {
                failed[path] = error.localizedDescription
            }
        }
        return TrashOutcome(trashed: trashed, failed: failed)
    }
}
