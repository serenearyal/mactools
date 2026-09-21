import Darwin
import Foundation

public struct VolumeInfo: Sendable, Equatable, Codable, Identifiable {
    public let name: String
    public let mountPath: String
    public let total: UInt64
    /// `volumeAvailableCapacityForImportantUsage`: what the system would free
    /// up for a download the user asked for, purgeable space included. This
    /// is the number Finder shows.
    public let available: UInt64
    /// `volumeAvailableCapacity`: the raw free blocks, what `df` prints.
    public let availableRaw: UInt64
    public let used: UInt64
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isBootVolume: Bool
    /// `f_fstypename` from `statfs`, for example "apfs".
    public let fileSystemType: String
    /// `f_mntfromname`, for example "/dev/disk3s1s1".
    public let device: String

    public var id: String { mountPath }

    public init(
        name: String,
        mountPath: String,
        total: UInt64,
        available: UInt64,
        availableRaw: UInt64,
        used: UInt64,
        isInternal: Bool,
        isRemovable: Bool,
        isBootVolume: Bool,
        fileSystemType: String,
        device: String
    ) {
        self.name = name
        self.mountPath = mountPath
        self.total = total
        self.available = available
        self.availableRaw = availableRaw
        self.used = used
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isBootVolume = isBootVolume
        self.fileSystemType = fileSystemType
        self.device = device
    }

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    /// How much of `available` is purgeable: what the system would throw away
    /// for a download, over and above the free blocks `df` counts.
    public var purgeableBonus: Int64 {
        Int64(bitPattern: available) - Int64(bitPattern: availableRaw)
    }

    /// The same volume with the purgeable share added back.
    ///
    /// A pass that skipped the expensive key has the raw free space and
    /// nothing else; this puts the last purgeable estimate back on top of a
    /// fresh `statfs` number, so the free space still moves with every write
    /// while the slow part of it is only re-read now and then.
    public func addingPurgeableBonus(_ bonus: Int64) -> VolumeInfo {
        let sum = Int64(bitPattern: availableRaw) + bonus
        let capped = UInt64(max(0, min(sum, Int64(bitPattern: total))))
        return VolumeInfo(
            name: name,
            mountPath: mountPath,
            total: total,
            available: capped,
            availableRaw: availableRaw,
            used: total > capped ? total - capped : 0,
            isInternal: isInternal,
            isRemovable: isRemovable,
            isBootVolume: isBootVolume,
            fileSystemType: fileSystemType,
            device: device
        )
    }
}

/// Mounted volumes with their capacity.
///
/// On an APFS boot disk the only browsable volume is "/". Its capacity keys
/// report the whole container, so `total` is the disk the user bought and
/// `used` covers the System volume, the Data volume, the system snapshots and
/// the other container volumes together. That is the "384 GB of 494 GB" a
/// user expects, not the 12 GB of the read-only system volume alone.
public enum DiskSpaceSampler {
    /// The cheap keys. Every one of them comes out of the `statfs` the URL
    /// machinery has already done.
    static let resourceKeys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeIsInternalKey,
        .volumeIsRemovableKey,
        .volumeIsRootFileSystemKey,
    ]

    /// The expensive one.
    ///
    /// `volumeAvailableCapacityForImportantUsage` asks `cache_delete` how much
    /// it could free, and that answer costs a volume validation through IOKit
    /// per mount point - more than everything else one pass reads, together.
    /// It is the number Finder shows, so it stays; `includingPurgeableSpace`
    /// is how a caller that reads every few seconds leaves it out and puts the
    /// last value back with `addingPurgeableBonus`.
    static let purgeableKey: URLResourceKey = .volumeAvailableCapacityForImportantUsageKey

    public static func sample(includingPurgeableSpace: Bool = true) -> [VolumeInfo] {
        let keys = includingPurgeableSpace ? resourceKeys + [purgeableKey] : resourceKeys
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls
            .compactMap { info(for: $0, includingPurgeableSpace: includingPurgeableSpace) }
            .sorted { lhs, rhs in
                if lhs.isBootVolume != rhs.isBootVolume { return lhs.isBootVolume }
                return lhs.mountPath < rhs.mountPath
            }
    }

    public static func info(for url: URL, includingPurgeableSpace: Bool = true) -> VolumeInfo? {
        var keys = Set(resourceKeys)
        if includingPurgeableSpace { keys.insert(purgeableKey) }
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0
        else { return nil }

        let availableRaw = UInt64(max(0, values.volumeAvailableCapacity ?? 0))
        let important = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
        let available = important ?? availableRaw
        let capacity = UInt64(total)
        let mount = mountInfo(at: url.path)
        return VolumeInfo(
            name: values.volumeName ?? url.lastPathComponent,
            mountPath: mount?.path ?? url.path,
            total: capacity,
            available: available,
            availableRaw: availableRaw,
            used: capacity > available ? capacity - available : 0,
            isInternal: values.volumeIsInternal ?? false,
            isRemovable: values.volumeIsRemovable ?? false,
            isBootVolume: values.volumeIsRootFileSystem ?? (url.path == "/"),
            fileSystemType: mount?.type ?? "unknown",
            device: mount?.device ?? ""
        )
    }

    /// `statfs` fills fixed C char arrays; this turns the three the UI needs
    /// into Swift strings.
    private static func mountInfo(at path: String) -> (path: String, type: String, device: String)? {
        var buffer = statfs()
        guard statfs(path, &buffer) == 0 else { return nil }
        func text<T>(_ field: T, capacity: Int) -> String {
            withUnsafePointer(to: field) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
        }
        return (
            text(buffer.f_mntonname, capacity: Int(MAXPATHLEN)),
            text(buffer.f_fstypename, capacity: Int(MFSTYPENAMELEN)),
            text(buffer.f_mntfromname, capacity: Int(MAXPATHLEN))
        )
    }
}
