/// Every key the SMC publishes, with its size, encoding and attributes.
///
/// Enumeration is `#KEY` for the count plus one index lookup and one key-info
/// call per key: about 2000 keys in well under a second on an M1 Pro. A few
/// keys refuse the key-info call to a normal user, so `info` is optional and
/// the key still appears in the catalog.
public struct SMCKeyCatalog: Sendable {
    public struct Entry: Sendable, Equatable {
        public let key: SMCFourCC
        public let info: SMCKeyInfo?

        public init(key: SMCFourCC, info: SMCKeyInfo?) {
            self.key = key
            self.info = info
        }
    }

    public let entries: [Entry]
    /// The count the SMC reports in `#KEY`, before any key is described.
    public let reportedCount: Int

    private let index: [SMCFourCC: SMCKeyInfo]

    public init(entries: [Entry], reportedCount: Int) {
        self.entries = entries
        self.reportedCount = reportedCount
        index = Dictionary(
            entries.compactMap { entry in entry.info.map { (entry.key, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public static func load(from connection: SMCConnection) throws(SMCError) -> SMCKeyCatalog {
        let count = try connection.keyCount()
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for position in 0..<count {
            let key = try connection.key(at: position)
            entries.append(Entry(key: key, info: try? connection.keyInfo(for: key)))
        }
        return SMCKeyCatalog(entries: entries, reportedCount: count)
    }

    public var count: Int { entries.count }

    /// The keys whose key-info call failed, in catalog order.
    public var undescribedKeys: [SMCFourCC] {
        entries.filter { $0.info == nil }.map(\.key)
    }

    public func info(for key: SMCFourCC) -> SMCKeyInfo? { index[key] }

    public func contains(_ key: SMCFourCC) -> Bool { index[key] != nil }

    public func entries(withKeyPrefix prefix: String, type: SMCDataType? = nil) -> [Entry] {
        entries.filter { entry in
            guard let info = entry.info, entry.key.stringValue.hasPrefix(prefix) else { return false }
            return type == nil || info.type == type
        }
    }
}
