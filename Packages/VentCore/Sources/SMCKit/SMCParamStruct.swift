/// The 32-byte payload of an SMC call.
public typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

public struct SMCVersion: Sendable, Equatable {
    public var major: UInt8 = 0
    public var minor: UInt8 = 0
    public var build: UInt8 = 0
    public var reserved: UInt8 = 0
    public var release: UInt16 = 0

    public init() {}
}

public struct SMCPLimitData: Sendable, Equatable {
    public var version: UInt16 = 0
    public var length: UInt16 = 0
    public var cpuPLimit: UInt32 = 0
    public var gpuPLimit: UInt32 = 0
    public var memPLimit: UInt32 = 0

    public init() {}
}

public struct SMCKeyInfoData: Sendable, Equatable {
    public var dataSize: UInt32 = 0
    public var dataType: UInt32 = 0
    public var dataAttributes: UInt8 = 0
    // Swift packs a nested structure by its size, C by its stride, so the
    // three tail padding bytes of the C structure have to be spelled out.
    private var padding0: UInt8 = 0
    private var padding1: UInt8 = 0
    private var padding2: UInt8 = 0

    public init() {}
}

/// The 80-byte structure that selector 2 of the AppleSMC user client takes in
/// and gives back. The field order and the padding must match the driver
/// exactly; `SMCParamStructLayoutTests` pins every offset.
public struct SMCParamStruct: Sendable {
    public var key: UInt32 = 0
    public var vers = SMCVersion()
    public var pLimitData = SMCPLimitData()
    public var keyInfo = SMCKeyInfoData()
    public var result: UInt8 = 0
    public var status: UInt8 = 0
    public var data8: UInt8 = 0
    public var data32: UInt32 = 0
    public var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )

    public init() {}

    /// The first `count` payload bytes.
    public func payload(_ count: Int) -> [UInt8] {
        precondition((0...SMCParamStruct.payloadCapacity).contains(count))
        return withUnsafeBytes(of: bytes) { Array($0.prefix(count)) }
    }

    /// Copies `payload` into the front of the byte field and zeroes the rest.
    public mutating func setPayload(_ payload: [UInt8]) {
        precondition(payload.count <= SMCParamStruct.payloadCapacity)
        withUnsafeMutableBytes(of: &bytes) { buffer in
            buffer.copyBytes(from: payload)
            for offset in payload.count..<buffer.count { buffer[offset] = 0 }
        }
    }

    public static let payloadCapacity = 32
}
