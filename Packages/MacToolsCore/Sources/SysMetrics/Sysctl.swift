import Darwin

/// Thin `sysctlbyname` wrapper. Every metric that is not a mach call reads a
/// named sysctl, so the pointer work lives in one place.
public enum Sysctl {
    public static func integer(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    public static func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    public static func int32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(nullTerminated: buffer)
    }

    /// Reads a fixed-layout C struct, for example `xsw_usage` from
    /// `vm.swapusage`. The kernel must return exactly `T`'s size.
    public static func value<T>(_ name: String, as type: T.Type = T.self) -> T? {
        var size = MemoryLayout<T>.size
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: size,
            alignment: MemoryLayout<T>.alignment
        )
        defer { storage.deallocate() }
        guard sysctlbyname(name, storage, &size, nil, 0) == 0, size == MemoryLayout<T>.size else {
            return nil
        }
        return storage.load(as: T.self)
    }
}

extension String {
    /// `String(cString:)` on a `[CChar]` is deprecated; this keeps its
    /// behaviour of stopping at the first NUL byte.
    init(nullTerminated buffer: [CChar]) {
        self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
