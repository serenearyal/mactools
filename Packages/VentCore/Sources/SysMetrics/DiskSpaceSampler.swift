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
}

/// Mounted volumes with their capacity.
///
/// On an APFS boot disk the only browsable volume is "/". Its capacity keys
/// report the whole container, so `total` is the disk the user bought and
/// `used` covers the System volume, the Data volume, the system snapshots and
/// the other container volumes together. That is the "384 GB of 494 GB" a
/// user expects, not the 12 GB of the read-only system volume alone.
public enum DiskSpaceSampler {
    static let resourceKeys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeIsInternalKey,
        .volumeIsRemovableKey,
        .volumeIsRootFileSystemKey,
    ]

    public static func sample() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: resourceKeys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap(info(for:)).sorted { lhs, rhs in
            if lhs.isBootVolume != rhs.isBootVolume { return lhs.isBootVolume }
            return lhs.mountPath < rhs.mountPath
        }
    }

    public static func info(for url: URL) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
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
