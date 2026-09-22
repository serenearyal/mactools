import Darwin
import Synchronization

/// The four `CPU_STATE_*` tick counters of one processor. The kernel keeps
/// them as 32-bit counters that wrap.
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public static let zero = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
}

/// Shares of one sampling interval. Every field is 0...1 and the four add up
/// to 1.
public struct CPUUsage: Sendable, Equatable, Codable {
    public let user: Double
    public let system: Double
    public let idle: Double
    public let nice: Double

    public init(user: Double, system: Double, idle: Double, nice: Double) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public static let idleOnly = CPUUsage(user: 0, system: 0, idle: 1, nice: 0)

    /// Everything that is not idle, 0...1.
    public var busy: Double { min(1, max(0, user + system + nice)) }
    public var percent: Double { busy * 100 }
}

public struct CPUSample: Sendable, Equatable {
    public let total: CPUUsage
    public let cores: [CPUUsage]
    public let kinds: [CoreKind]

    public init(total: CPUUsage, cores: [CPUUsage], kinds: [CoreKind]) {
        self.total = total
        self.cores = cores
        self.kinds = kinds
    }

    public func kind(ofCore index: Int) -> CoreKind {
        kinds.indices.contains(index) ? kinds[index] : .performance
    }
}

/// The delta arithmetic, kept free of any system call so it can be tested with
/// synthetic tick sequences.
public enum CPUTickMath {
    /// Wrapping difference. The kernel counters are `UInt32` and wrap after
    /// about 497 days at 100 Hz, so `&-` is the right subtraction: it gives
    /// the elapsed ticks across the wrap.
    public static func delta(from previous: UInt32, to current: UInt32) -> UInt64 {
        UInt64(current &- previous)
    }

    /// Shares of the interval between two tick readings, or nil when no tick
    /// moved (the first sample, or an interval shorter than one tick).
    public static func usage(from previous: CPUTicks, to current: CPUTicks) -> CPUUsage? {
        let user = delta(from: previous.user, to: current.user)
        let system = delta(from: previous.system, to: current.system)
        let idle = delta(from: previous.idle, to: current.idle)
        let nice = delta(from: previous.nice, to: current.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        let scale = 1 / Double(total)
        return CPUUsage(
            user: Double(user) * scale,
            system: Double(system) * scale,
            idle: Double(idle) * scale,
            nice: Double(nice) * scale
        )
    }

    /// Per-core shares plus the machine total. The total is the sum of the
    /// deltas of every core, so a busy core weighs as much as an idle one.
    /// Returns nil when the two readings do not describe the same processor
    /// set or when no tick moved anywhere.
    public static func usage(from previous: [CPUTicks], to current: [CPUTicks]) -> (total: CPUUsage, cores: [CPUUsage])? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        var sums = (user: UInt64(0), system: UInt64(0), idle: UInt64(0), nice: UInt64(0))
        var cores: [CPUUsage] = []
        cores.reserveCapacity(current.count)
        for index in current.indices {
            sums.user += delta(from: previous[index].user, to: current[index].user)
            sums.system += delta(from: previous[index].system, to: current[index].system)
            sums.idle += delta(from: previous[index].idle, to: current[index].idle)
            sums.nice += delta(from: previous[index].nice, to: current[index].nice)
            cores.append(usage(from: previous[index], to: current[index]) ?? .idleOnly)
        }
        let grand = sums.user + sums.system + sums.idle + sums.nice
        guard grand > 0 else { return nil }
        let scale = 1 / Double(grand)
        let total = CPUUsage(
            user: Double(sums.user) * scale,
            system: Double(sums.system) * scale,
            idle: Double(sums.idle) * scale,
            nice: Double(sums.nice) * scale
        )
        return (total, cores)
    }

    /// The fewest ticks per core an interval has to span before its shares
    /// mean anything: 20, about 200 ms at the kernel's 100 Hz. A pass that
    /// lands milliseconds after the last one sees a tick or two per core, and
    /// one busy tick out of two is a 50 % or 100 % that never happened.
    public static let minimumTicksPerCore: UInt64 = 20

    /// True when the interval between two readings is long enough to report.
    /// Readings of different processor sets are "long enough": they cannot be
    /// compared at all, and the newer one has to become the baseline.
    public static func spansMinimumInterval(from previous: [CPUTicks], to current: [CPUTicks]) -> Bool {
        guard previous.count == current.count else { return true }
        var ticks = UInt64(0)
        for index in current.indices {
            ticks += delta(from: previous[index].user, to: current[index].user)
                + delta(from: previous[index].system, to: current[index].system)
                + delta(from: previous[index].idle, to: current[index].idle)
                + delta(from: previous[index].nice, to: current[index].nice)
        }
        return ticks >= UInt64(current.count) * minimumTicksPerCore
    }
}

/// Per-core CPU load from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`.
///
/// Concurrency: a final class that keeps the previous tick reading in a
/// `Mutex`. The mach call is a synchronous round trip of a few microseconds,
/// so a lock keeps the API synchronous and callable from any thread.
public final class CPUSampler: Sendable {
    public let topology: CoreTopology

    private let previous: Mutex<[CPUTicks]?>

    public init(topology: CoreTopology = .current()) {
        self.topology = topology
        previous = Mutex(nil)
    }

    /// Raw counters, one entry per logical processor.
    public static func readTicks() throws(MetricsError) -> [CPUTicks] {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let status = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &info,
            &infoCount
        )
        guard status == KERN_SUCCESS, let info else {
            throw MetricsError.hostCallFailed("host_processor_info", status)
        }
        // The kernel hands over a vm_allocate'd array; it leaks without this.
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        let states = Int(CPU_STATE_MAX)
        guard Int(infoCount) >= Int(processorCount) * states else {
            throw MetricsError.hostCallFailed("host_processor_info (short reply)", status)
        }
        return (0..<Int(processorCount)).map { core in
            let base = core * states
            return CPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    /// Usage since the previous call. The first call has nothing to compare
    /// against and returns nil after storing the baseline.
    ///
    /// A call too soon after the last one also returns nil, and keeps the old
    /// baseline, so the next call covers the whole interval instead of a few
    /// milliseconds of it. See `CPUTickMath.minimumTicksPerCore`.
    public func sample() throws(MetricsError) -> CPUSample? {
        let current = try CPUSampler.readTicks()
        return sample(ticks: current)
    }

    /// The baseline half of `sample()`, with the reading passed in, so a test
    /// can drive it with synthetic ticks.
    func sample(ticks current: [CPUTicks]) -> CPUSample? {
        let baseline = previous.withLock { stored -> [CPUTicks]? in
            guard let baseline = stored else {
                stored = current
                return nil
            }
            guard CPUTickMath.spansMinimumInterval(from: baseline, to: current) else { return nil }
            stored = current
            return baseline
        }
        guard let baseline, let usage = CPUTickMath.usage(from: baseline, to: current) else {
            return nil
        }
        return CPUSample(total: usage.total, cores: usage.cores, kinds: topology.kinds)
    }

    /// Forgets the baseline, so the next `sample()` returns nil again.
    public func reset() {
        previous.withLock { $0 = nil }
    }
}
