import Foundation

/// The last scan of a volume, as JSON under Application Support.
///
/// A cold scan of the data volume is minutes, so the window must be able to
/// show the previous result the moment it opens. The file is keyed by volume
/// UUID, so an external disk keeps its own, and written atomically, so a
/// crash mid-write cannot leave half a file behind.
public struct ScanCache: Sendable {
    /// Bumped when `ScanResult` changes shape. A file from another version is
    /// ignored rather than migrated: it costs one rescan.
    public static let version = 1

    public let directory: URL

    public init(directory: URL = ScanCache.defaultDirectory()) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(filePath: NSHomeDirectory() + "/Library/Application Support")
        return base.appending(path: "Vent", directoryHint: .isDirectory)
    }

    /// The volume UUID of the file system `path` sits on, or a flattened form
    /// of the path when the volume has no UUID (a RAM disk, a test folder).
    public static func volumeIdentifier(for path: String) -> String {
        let url = URL(filePath: path, directoryHint: .isDirectory)
        if let uuid = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString {
            return uuid
        }
        let flattened = path.map { $0 == "/" ? "-" : $0 }
        return String(flattened).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public func url(volume: String) -> URL {
        directory.appending(path: "scan-\(volume).json")
    }

    /// nil when nothing is cached for this volume or the file is from another
    /// version. A damaged file throws, so the UI can say so.
    public func load(volume: String) throws(ScanError) -> ScanResult? {
        let url = url(volume: volume)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let file = try ScanCache.decoder.decode(File.self, from: data)
            return file.version == ScanCache.version ? file.result : nil
        } catch {
            throw ScanError.cacheFailed("reading \(url.lastPathComponent)", "\(error)")
        }
    }

    @discardableResult
    public func save(_ result: ScanResult, volume: String) throws(ScanError) -> URL {
        let url = url(volume: volume)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let data = try ScanCache.encoder.encode(
                File(version: ScanCache.version, result: result)
            )
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw ScanError.cacheFailed("writing \(url.lastPathComponent)", "\(error)")
        }
    }

    public func remove(volume: String) {
        try? FileManager.default.removeItem(at: url(volume: volume))
    }

    private struct File: Codable {
        let version: Int
        let result: ScanResult
    }

    /// The default strategy, which writes the interval since the reference
    /// date - the number `Date` actually holds. ISO 8601 would drop the
    /// fraction of a second of an `st_mtimespec`, and seconds-since-1970
    /// would lose the last bits to the epoch offset, so neither round-trips.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
