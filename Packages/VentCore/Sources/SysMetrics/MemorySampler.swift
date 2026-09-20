import Darwin

/// The `vm_statistics64` fields the memory view needs, in pages.
public struct VMPageCounts: Sendable, Equatable {
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var speculative: UInt64
    public var wired: UInt64
    public var purgeable: UInt64
    /// Anonymous pages, purgeable ones included.
    public var internalPages: UInt64
    /// File-backed pages.
    public var externalPages: UInt64
    /// Pages the compressor occupies, not the pages stored inside it.
    public var compressor: UInt64

    public init(
        free: UInt64 = 0,
        active: UInt64 = 0,
        inactive: UInt64 = 0,
        speculative: UInt64 = 0,
        wired: UInt64 = 0,
        purgeable: UInt64 = 0,
        internalPages: UInt64 = 0,
        externalPages: UInt64 = 0,
        compressor: UInt64 = 0
    ) {
        self.free = free
        self.active = active
        self.inactive = inactive
        self.speculative = speculative
        self.wired = wired
        self.purgeable = purgeable
        self.internalPages = internalPages
        self.externalPages = externalPages
        self.compressor = compressor
    }

    public init(_ statistics: vm_statistics64) {
        self.init(
            free: UInt64(statistics.free_count),
            active: UInt64(statistics.active_count),
            inactive: UInt64(statistics.inactive_count),
            speculative: UInt64(statistics.speculative_count),
            wired: UInt64(statistics.wire_count),
            purgeable: UInt64(statistics.purgeable_count),
            internalPages: UInt64(statistics.internal_page_count),
            externalPages: UInt64(statistics.external_page_count),
            compressor: UInt64(statistics.compressor_page_count)
        )
    }
}

public struct SwapUsage: Sendable, Equatable, Codable {
    public let total: UInt64
    public let used: UInt64

    public init(total: UInt64, used: UInt64) {
        self.total = total
        self.used = used
    }

    public static let none = SwapUsage(total: 0, used: 0)
}

/// `kern.memorystatus_vm_pressure_level`.
public enum MemoryPressureLevel: Int32, Sendable, Codable, CaseIterable {
    case normal = 1
    case warning = 2
    case critical = 4

    public var label: String {
        switch self {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        }
    }
}

public struct MemorySnapshot: Sendable, Equatable, Codable {
    public let total: UInt64
    /// Activity Monitor's "Memory Used": app + wired + compressed.
    public let used: UInt64
    public let app: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let cachedFiles: UInt64
    public let free: UInt64
    public let swap: SwapUsage
    public let pressure: MemoryPressureLevel?

    public init(
        total: UInt64,
        used: UInt64,
        app: UInt64,
        wired: UInt64,
        compressed: UInt64,
        cachedFiles: UInt64,
        free: UInt64,
        swap: SwapUsage,
        pressure: MemoryPressureLevel?
    ) {
        self.total = total
        self.used = used
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cachedFiles = cachedFiles
        self.free = free
        self.swap = swap
        self.pressure = pressure
    }

    /// Used share of the installed memory, 0...1.
    public var usedFraction: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }
}

/// The page arithmetic, free of system calls so a synthetic
/// `vm_statistics64` can drive it in a test.
public enum MemoryMath {
    public static func snapshot(
        pages: VMPageCounts,
        pageSize: UInt64,
        total: UInt64,
        swap: SwapUsage,
        pressure: MemoryPressureLevel?
    ) -> MemorySnapshot {
        // Activity Monitor's App Memory is the anonymous pages minus the
        // purgeable ones; the purgeable pages count as cached files instead.
        let appPages = pages.internalPages >= pages.purgeable
            ? pages.internalPages - pages.purgeable
            : 0
        let app = appPages * pageSize
        let wired = pages.wired * pageSize
        let compressed = pages.compressor * pageSize
        let cachedFiles = (pages.externalPages + pages.purgeable) * pageSize
        return MemorySnapshot(
            total: total,
            used: app + wired + compressed,
            app: app,
            wired: wired,
            compressed: compressed,
            cachedFiles: cachedFiles,
            free: pages.free * pageSize,
            swap: swap,
            pressure: pressure
        )
    }
}

public enum MemorySampler {
    /// The kernel page size is the unit of every `HOST_VM_INFO64` counter:
    /// 16384 bytes on Apple silicon, not the 4096 of the Intel machines.
    /// `vm_kernel_page_size` itself is a mutable global and not readable from
    /// Swift 6 concurrency-checked code, so this asks the host.
    public static var pageSize: UInt64 {
        var size: vm_size_t = 0
        guard host_page_size(mach_host_self(), &size) == KERN_SUCCESS, size > 0 else {
            return UInt64(getpagesize())
        }
        return UInt64(size)
    }

    public static func pageCounts() throws(MetricsError) -> VMPageCounts {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw MetricsError.hostCallFailed("host_statistics64(HOST_VM_INFO64)", status)
        }
        return VMPageCounts(statistics)
    }

    public static func swapUsage() -> SwapUsage {
        guard let usage = Sysctl.value("vm.swapusage", as: xsw_usage.self) else { return .none }
        return SwapUsage(total: usage.xsu_total, used: usage.xsu_used)
    }

    public static func pressureLevel() -> MemoryPressureLevel? {
        Sysctl.int32("kern.memorystatus_vm_pressure_level").flatMap(MemoryPressureLevel.init(rawValue:))
    }

    public static func sample() throws(MetricsError) -> MemorySnapshot {
        guard let total = Sysctl.uint64("hw.memsize") else {
            throw MetricsError.sysctlMissing("hw.memsize")
        }
        return MemoryMath.snapshot(
            pages: try pageCounts(),
            pageSize: pageSize,
            total: total,
            swap: swapUsage(),
            pressure: pressureLevel()
        )
    }
}
