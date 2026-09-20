import IOKit
import Synchronization

/// What the SMC reports about one key.
public struct SMCKeyInfo: Sendable, Equatable {
    public let dataSize: UInt32
    public let dataType: SMCFourCC
    public let attributes: UInt8

    public init(dataSize: UInt32, dataType: SMCFourCC, attributes: UInt8) {
        self.dataSize = dataSize
        self.dataType = dataType
        self.attributes = attributes
    }

    public var type: SMCDataType { SMCDataType(dataType) }
}

/// One key with its description and its raw payload.
public struct SMCReading: Sendable, Equatable {
    public let key: SMCFourCC
    public let info: SMCKeyInfo
    public let bytes: [UInt8]

    public init(key: SMCFourCC, info: SMCKeyInfo, bytes: [UInt8]) {
        self.key = key
        self.info = info
        self.bytes = bytes
    }

    public var value: SMCValue { info.type.decode(bytes) }
}

/// An open connection to the AppleSMC user client.
///
/// Concurrency: a final class holding the `io_connect_t` in a `Mutex`. The
/// driver call is one synchronous round trip of a few hundred microseconds, so
/// a lock is simpler and cheaper than an actor and keeps the whole API
/// synchronous for callers on any thread.
public final class SMCConnection: Sendable {
    /// The selector of the single user-client method the SMC exposes.
    private static let structMethodSelector: UInt32 = 2

    private enum Command: UInt8 {
        case readBytes = 5
        case writeBytes = 6
        case readIndex = 8
        case readKeyInfo = 9
    }

    /// The key that holds the number of keys the SMC publishes.
    public static let keyCountKey: SMCFourCC = "#KEY"

    private let port: Mutex<io_connect_t>

    public init() throws(SMCError) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(SMC.serviceName))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        let status = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard status == kIOReturnSuccess else { throw SMCError.openFailed(status) }
        port = Mutex(connection)
    }

    deinit {
        port.withLock { connection in
            if connection != 0 { IOServiceClose(connection) }
        }
    }

    public func keyInfo(for key: SMCFourCC) throws(SMCError) -> SMCKeyInfo {
        var input = SMCParamStruct()
        input.key = key.rawValue
        input.data8 = Command.readKeyInfo.rawValue
        let output = try call(input, key: key)
        return SMCKeyInfo(
            dataSize: output.keyInfo.dataSize,
            dataType: SMCFourCC(rawValue: output.keyInfo.dataType),
            attributes: output.keyInfo.dataAttributes
        )
    }

    public func readBytes(_ key: SMCFourCC, info: SMCKeyInfo) throws(SMCError) -> [UInt8] {
        guard info.dataSize <= UInt32(SMCParamStruct.payloadCapacity) else {
            throw SMCError.unsupportedSize(key, info.dataSize)
        }
        var input = SMCParamStruct()
        input.key = key.rawValue
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Command.readBytes.rawValue
        let output = try call(input, key: key)
        return output.payload(Int(info.dataSize))
    }

    public func read(_ key: SMCFourCC) throws(SMCError) -> SMCReading {
        let info = try keyInfo(for: key)
        return SMCReading(key: key, info: info, bytes: try readBytes(key, info: info))
    }

    /// The decoded value, or nil when the key holds an encoding this layer
    /// does not understand.
    public func readDouble(_ key: SMCFourCC) throws(SMCError) -> Double? {
        try read(key).value.doubleValue
    }

    /// True when the key exists, false when the SMC reports "key not found".
    public func hasKey(_ key: SMCFourCC) -> Bool {
        (try? keyInfo(for: key)) != nil
    }

    public func keyCount() throws(SMCError) -> Int {
        let value = try readDouble(SMCConnection.keyCountKey) ?? 0
        return Int(value)
    }

    public func key(at index: Int) throws(SMCError) -> SMCFourCC {
        var input = SMCParamStruct()
        input.data8 = Command.readIndex.rawValue
        input.data32 = UInt32(index)
        let output = try call(input, key: SMCConnection.keyCountKey)
        return SMCFourCC(rawValue: output.key)
    }

    /// The one place that talks to the driver. The write path calls it too.
    func call(_ input: SMCParamStruct, key: SMCFourCC) throws(SMCError) -> SMCParamStruct {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let inputSize = MemoryLayout<SMCParamStruct>.stride

        let status = port.withLock { connection in
            IOConnectCallStructMethod(
                connection,
                SMCConnection.structMethodSelector,
                &input,
                inputSize,
                &output,
                &outputSize
            )
        }
        guard status == kIOReturnSuccess else { throw SMCError.fromCall(status, key: key) }
        guard output.result == 0 else { throw SMCError.fromResult(output.result, key: key) }
        return output
    }

    static func writeCommand() -> UInt8 { Command.writeBytes.rawValue }
}
