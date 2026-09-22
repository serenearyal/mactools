import Darwin
import Foundation
import IOKit
import IOKit.storage
import Synchronization

/// The four cumulative counters every `IOBlockStorageDriver` publishes in its
/// "Statistics" dictionary.
public struct DiskIOCounters: Sendable, Equatable, Codable {
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    public var reads: UInt64
    public var writes: UInt64

    public init(bytesRead: UInt64 = 0, bytesWritten: UInt64 = 0, reads: UInt64 = 0, writes: UInt64 = 0) {
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.reads = reads
        self.writes = writes
    }

    public static let zero = DiskIOCounters()

    public static func + (lhs: DiskIOCounters, rhs: DiskIOCounters) -> DiskIOCounters {
        DiskIOCounters(
            bytesRead: lhs.bytesRead &+ rhs.bytesRead,
            bytesWritten: lhs.bytesWritten &+ rhs.bytesWritten,
            reads: lhs.reads &+ rhs.reads,
            writes: lhs.writes &+ rhs.writes
        )
    }
}

public struct DiskIORates: Sendable, Equatable, Codable {
    public let bytesReadPerSecond: Double
    public let bytesWrittenPerSecond: Double
    public let readsPerSecond: Double
    public let writesPerSecond: Double
    public let interval: Double

    public init(
        bytesReadPerSecond: Double,
        bytesWrittenPerSecond: Double,
        readsPerSecond: Double,
        writesPerSecond: Double,
        interval: Double
    ) {
        self.bytesReadPerSecond = bytesReadPerSecond
        self.bytesWrittenPerSecond = bytesWrittenPerSecond
        self.readsPerSecond = readsPerSecond
        self.writesPerSecond = writesPerSecond
        self.interval = interval
    }

    public static let zero = DiskIORates(
        bytesReadPerSecond: 0,
        bytesWrittenPerSecond: 0,
        readsPerSecond: 0,
        writesPerSecond: 0,
        interval: 0
    )
}

public struct DiskIOSample: Sendable, Equatable {
    public let total: DiskIOCounters
    /// Counters per BSD name, for example "disk0".
    public let devices: [String: DiskIOCounters]
    /// nil on the first sample, when there is nothing to subtract from.
    public let rates: DiskIORates?

    public init(total: DiskIOCounters, devices: [String: DiskIOCounters], rates: DiskIORates?) {
        self.total = total
        self.devices = devices
        self.rates = rates
    }
}

/// Counter arithmetic, free of IOKit so a test can drive it directly.
public enum DiskIOMath {
    /// A counter that went backwards means the driver was replaced or its
    /// statistics were reset; that interval contributes nothing rather than a
    /// negative or a huge wrapped rate.
    public static func delta(from previous: UInt64, to current: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    /// Throughput between two readings, or nil when the interval is not
    /// positive.
    public static func rates(
        from previous: DiskIOCounters,
        to current: DiskIOCounters,
        seconds: Double
    ) -> DiskIORates? {
        guard seconds > 0, seconds.isFinite else { return nil }
        let scale = 1 / seconds
        return DiskIORates(
            bytesReadPerSecond: Double(delta(from: previous.bytesRead, to: current.bytesRead)) * scale,
            bytesWrittenPerSecond: Double(delta(from: previous.bytesWritten, to: current.bytesWritten)) * scale,
            readsPerSecond: Double(delta(from: previous.reads, to: current.reads)) * scale,
            writesPerSecond: Double(delta(from: previous.writes, to: current.writes)) * scale,
            interval: seconds
        )
    }

    /// The traffic of one interval, device by device, added up.
    ///
    /// Per device and not on the sum: an ejected disk takes its counters out
    /// of the total, and a delta of the totals would then go backwards and hide
    /// the internal SSD's traffic for that interval. A device that is new has
    /// no baseline and contributes nothing; one that went backwards
    /// contributes nothing through `delta`.
    public static func traffic(
        from previous: [String: DiskIOCounters],
        to current: [String: DiskIOCounters]
    ) -> DiskIOCounters {
        current.reduce(DiskIOCounters.zero) { sum, device in
            guard let before = previous[device.key] else { return sum }
            let now = device.value
            return sum + DiskIOCounters(
                bytesRead: delta(from: before.bytesRead, to: now.bytesRead),
                bytesWritten: delta(from: before.bytesWritten, to: now.bytesWritten),
                reads: delta(from: before.reads, to: now.reads),
                writes: delta(from: before.writes, to: now.writes)
            )
        }
    }

    /// Throughput between two per-device readings, or nil when the interval
    /// is not positive.
    public static func rates(
        from previous: [String: DiskIOCounters],
        to current: [String: DiskIOCounters],
        seconds: Double
    ) -> DiskIORates? {
        rates(from: .zero, to: traffic(from: previous, to: current), seconds: seconds)
    }
}

/// Block-device throughput from the IORegistry. Readable without root.
///
/// Concurrency: a final class holding the previous reading and its timestamp
/// in a `Mutex`, like `SMCConnection`. The registry walk is a few
/// milliseconds, so a lock keeps the API synchronous.
public final class DiskIOSampler: Sendable {
    /// One baseline per BSD name, and a monotonic timestamp: a wall clock
    /// that NTP or the user moves would turn one interval into a spike.
    private struct Reading: Sendable {
        let devices: [String: DiskIOCounters]
        let timestamp: ContinuousClock.Instant
    }

    private let previous: Mutex<Reading?>

    public init() {
        previous = Mutex(nil)
    }

    /// Cumulative counters per BSD name, straight from the registry.
    public static func readCounters() throws(MetricsError) -> [String: DiskIOCounters] {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching(kIOBlockStorageDriverClass)
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard status == KERN_SUCCESS else {
            throw MetricsError.ioRegistryFailed("IOServiceGetMatchingServices(IOBlockStorageDriver)", status)
        }
        defer { IOObjectRelease(iterator) }

        var result: [String: DiskIOCounters] = [:]
        var index = 0
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            defer { index += 1 }
            guard let statistics = property(of: driver, kIOBlockStorageDriverStatisticsKey) as? [String: Any]
            else { continue }
            let counters = DiskIOCounters(
                bytesRead: number(statistics[kIOBlockStorageDriverStatisticsBytesReadKey]),
                bytesWritten: number(statistics[kIOBlockStorageDriverStatisticsBytesWrittenKey]),
                reads: number(statistics[kIOBlockStorageDriverStatisticsReadsKey]),
                writes: number(statistics[kIOBlockStorageDriverStatisticsWritesKey])
            )
            let name = bsdName(of: driver) ?? "driver\(index)"
            result[name] = (result[name] ?? .zero) + counters
        }
        return result
    }

    /// Counters plus the throughput since the previous call. The first call
    /// has no previous reading, so `rates` is nil.
    public func sample() throws(MetricsError) -> DiskIOSample {
        let devices = try DiskIOSampler.readCounters()
        let total = devices.values.reduce(DiskIOCounters.zero, +)
        let now = ContinuousClock.now
        let baseline = previous.withLock { stored -> Reading? in
            defer { stored = Reading(devices: devices, timestamp: now) }
            return stored
        }
        let rates = baseline.flatMap { baseline in
            let elapsed = baseline.timestamp.duration(to: now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            return DiskIOMath.rates(from: baseline.devices, to: devices, seconds: seconds)
        }
        return DiskIOSample(total: total, devices: devices, rates: rates)
    }

    public func reset() {
        previous.withLock { $0 = nil }
    }

    /// The BSD name lives on the IOMedia below the driver, not on the driver.
    private static func bsdName(of driver: io_registry_entry_t) -> String? {
        let name = IORegistryEntrySearchCFProperty(
            driver,
            kIOServicePlane,
            kIOBSDNameKey as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        )
        return name as? String
    }

    private static func property(of entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func number(_ value: Any?) -> UInt64 {
        (value as? NSNumber).map { UInt64(bitPattern: $0.int64Value) } ?? 0
    }
}
