import Darwin

/// The `result` byte the SMC puts in the reply.
public enum SMCResultCode: UInt8, Sendable, CustomStringConvertible {
    case success = 0x00
    case commCollision = 0x80
    case spuriousData = 0x81
    case badCommand = 0x82
    case badParameter = 0x83
    case keyNotFound = 0x84
    case keyNotReadable = 0x85
    case keyNotWritable = 0x86
    case keySizeMismatch = 0x87
    case framingError = 0x88
    case badArgument = 0x89

    public var description: String {
        switch self {
        case .success: "success"
        case .commCollision: "communication collision"
        case .spuriousData: "spurious data"
        case .badCommand: "bad command"
        case .badParameter: "bad parameter"
        case .keyNotFound: "key not found"
        case .keyNotReadable: "key not readable"
        case .keyNotWritable: "key not writable"
        case .keySizeMismatch: "key size mismatch"
        case .framingError: "framing error"
        case .badArgument: "bad argument"
        }
    }
}

public enum SMCError: Error, Equatable, Sendable, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case notPrivileged(SMCFourCC)
    case callFailed(SMCFourCC, kern_return_t)
    case keyNotFound(SMCFourCC)
    case deviceError(SMCFourCC, SMCResultCode)
    case unknownResult(SMCFourCC, UInt8)
    case unsupportedSize(SMCFourCC, UInt32)
    case encodingFailed(SMCFourCC, SMCDataType)

    /// kIOReturnNotPrivileged, the status a call gets without root. Some keys
    /// refuse even a key-info call to a normal user.
    public static let ioReturnNotPrivileged = kern_return_t(bitPattern: 0xe000_02c1)

    static func fromCall(_ status: kern_return_t, key: SMCFourCC) -> SMCError {
        status == SMCError.ioReturnNotPrivileged ? .notPrivileged(key) : .callFailed(key, status)
    }

    static func fromResult(_ result: UInt8, key: SMCFourCC) -> SMCError {
        guard let code = SMCResultCode(rawValue: result) else { return .unknownResult(key, result) }
        return code == .keyNotFound ? .keyNotFound(key) : .deviceError(key, code)
    }

    public var description: String {
        switch self {
        case .serviceNotFound:
            "the AppleSMC service is not available"
        case .openFailed(let status):
            "cannot open the SMC user client (IOReturn 0x\(hex(status)))"
        case .notPrivileged(let key):
            "not privileged for key \(key); this call needs root"
        case .callFailed(let key, let status):
            "the SMC call for key \(key) failed (IOReturn 0x\(hex(status)))"
        case .keyNotFound(let key):
            "the SMC has no key \(key)"
        case .deviceError(let key, let code):
            "the SMC rejected key \(key): \(code) (0x\(String(code.rawValue, radix: 16)))"
        case .unknownResult(let key, let result):
            "the SMC returned an unknown result 0x\(String(result, radix: 16)) for key \(key)"
        case .unsupportedSize(let key, let size):
            "key \(key) reports \(size) bytes, more than the 32-byte payload"
        case .encodingFailed(let key, let type):
            "the value does not fit the \(type.code) encoding of key \(key)"
        }
    }

    private func hex(_ status: kern_return_t) -> String {
        String(UInt32(bitPattern: status), radix: 16)
    }
}
