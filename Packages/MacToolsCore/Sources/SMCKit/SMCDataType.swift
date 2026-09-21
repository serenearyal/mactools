import Foundation

/// A decoded SMC payload.
public enum SMCValue: Sendable, Equatable, CustomStringConvertible {
    case number(Double)
    case flag(Bool)
    case raw([UInt8])

    public var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .flag(let value): value ? 1 : 0
        case .raw: nil
        }
    }

    public var description: String {
        switch self {
        case .number(let value): SMCValue.format(value)
        case .flag(let value): value ? "true" : "false"
        case .raw(let bytes): bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
    }

    private static func format(_ value: Double) -> String {
        guard value.isFinite else { return "\(value)" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// The SMC payload encodings this project reads.
///
/// `flt ` is a little-endian IEEE float; every other numeric encoding is
/// big-endian, which is the SMC convention inherited from the PowerPC era.
public enum SMCDataType: Sendable, Hashable {
    case float32
    case fpe2
    case sp78
    case uint8
    case uint16
    case uint32
    case int16
    case flag
    case other(SMCFourCC)

    public init(_ code: SMCFourCC) {
        switch code {
        case "flt ": self = .float32
        case "fpe2": self = .fpe2
        case "sp78": self = .sp78
        case "ui8 ": self = .uint8
        case "ui16": self = .uint16
        case "ui32": self = .uint32
        case "si16": self = .int16
        case "flag": self = .flag
        default: self = .other(code)
        }
    }

    public var code: SMCFourCC {
        switch self {
        case .float32: "flt "
        case .fpe2: "fpe2"
        case .sp78: "sp78"
        case .uint8: "ui8 "
        case .uint16: "ui16"
        case .uint32: "ui32"
        case .int16: "si16"
        case .flag: "flag"
        case .other(let code): code
        }
    }

    /// The payload size the encoding needs, or nil when the encoding is unknown.
    public var byteCount: Int? {
        switch self {
        case .float32, .uint32: 4
        case .fpe2, .sp78, .uint16, .int16: 2
        case .uint8, .flag: 1
        case .other: nil
        }
    }

    /// Unknown encodings and wrong payload sizes come back as `.raw`.
    public func decode(_ bytes: [UInt8]) -> SMCValue {
        guard let byteCount, bytes.count >= byteCount else { return .raw(bytes) }
        switch self {
        case .float32:
            let pattern = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return .number(Double(Float(bitPattern: pattern)))
        case .fpe2:
            return .number(Double(bigEndianUInt16(bytes)) / 4)
        case .sp78:
            return .number(Double(Int16(bitPattern: bigEndianUInt16(bytes))) / 256)
        case .uint8:
            return .number(Double(bytes[0]))
        case .uint16:
            return .number(Double(bigEndianUInt16(bytes)))
        case .uint32:
            let value = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            return .number(Double(value))
        case .int16:
            return .number(Double(Int16(bitPattern: bigEndianUInt16(bytes))))
        case .flag:
            return .flag(bytes[0] != 0)
        case .other:
            return .raw(bytes)
        }
    }

    /// Returns nil when the value does not fit the encoding.
    public func encode(_ value: SMCValue) -> [UInt8]? {
        if case .other = self {
            guard case .raw(let bytes) = value, bytes.count <= SMCParamStruct.payloadCapacity else { return nil }
            return bytes
        }
        if case .raw(let bytes) = value {
            return bytes.count == byteCount ? bytes : nil
        }
        guard let number = value.doubleValue, number.isFinite else { return nil }
        switch self {
        case .float32:
            let pattern = Float(number).bitPattern
            return (0..<4).map { UInt8(truncatingIfNeeded: pattern >> (8 * UInt32($0))) }
        case .fpe2:
            let scaled = (number * 4).rounded()
            guard (0...Double(UInt16.max)).contains(scaled) else { return nil }
            return bigEndianBytes(UInt16(scaled))
        case .sp78:
            let scaled = (number * 256).rounded()
            guard (Double(Int16.min)...Double(Int16.max)).contains(scaled) else { return nil }
            return bigEndianBytes(UInt16(bitPattern: Int16(scaled)))
        case .uint8:
            let rounded = number.rounded()
            guard (0...Double(UInt8.max)).contains(rounded) else { return nil }
            return [UInt8(rounded)]
        case .uint16:
            let rounded = number.rounded()
            guard (0...Double(UInt16.max)).contains(rounded) else { return nil }
            return bigEndianBytes(UInt16(rounded))
        case .uint32:
            let rounded = number.rounded()
            guard (0...Double(UInt32.max)).contains(rounded) else { return nil }
            let raw = UInt32(rounded)
            return (0..<4).map { UInt8(truncatingIfNeeded: raw >> (8 * (3 - UInt32($0)))) }
        case .int16:
            let rounded = number.rounded()
            guard (Double(Int16.min)...Double(Int16.max)).contains(rounded) else { return nil }
            return bigEndianBytes(UInt16(bitPattern: Int16(rounded)))
        case .flag:
            return [number != 0 ? 1 : 0]
        case .other:
            return nil
        }
    }

    private func bigEndianUInt16(_ bytes: [UInt8]) -> UInt16 {
        UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private func bigEndianBytes(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }
}
