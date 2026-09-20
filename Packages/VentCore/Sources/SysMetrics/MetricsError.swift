import Darwin

public enum MetricsError: Error, Equatable, Sendable, CustomStringConvertible {
    case hostCallFailed(String, kern_return_t)
    case sysctlMissing(String)
    case ioRegistryFailed(String, kern_return_t)
    case unavailable(String)

    public var description: String {
        switch self {
        case .hostCallFailed(let call, let status):
            "\(call) failed (kern_return 0x\(String(UInt32(bitPattern: status), radix: 16)))"
        case .sysctlMissing(let name):
            "the sysctl \(name) is not available"
        case .ioRegistryFailed(let call, let status):
            "\(call) failed (IOReturn 0x\(String(UInt32(bitPattern: status), radix: 16)))"
        case .unavailable(let what):
            "\(what) is not available on this machine"
        }
    }
}
