/// A four-character SMC key or data type code.
///
/// The AppleSMC user client reads the `key` and `dataType` fields as a native
/// u32 whose numeric value is the big-endian FourCC, so "TC0P" is 0x54433050
/// stored natively. Packing the four characters as big-endian bytes instead
/// makes every call fail with result 0x89 (bad argument).
public struct SMCFourCC: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Fails when `code` is not exactly four ASCII characters. The label keeps
    /// this initializer apart from the string-literal one, which traps.
    public init?(code: String) {
        let scalars = Array(code.unicodeScalars)
        guard scalars.count == 4 else { return nil }
        var value: UInt32 = 0
        for scalar in scalars {
            guard scalar.value <= 0x7f else { return nil }
            value = value << 8 | scalar.value
        }
        self.rawValue = value
    }

    public var stringValue: String {
        let bytes = [
            UInt8(truncatingIfNeeded: rawValue >> 24),
            UInt8(truncatingIfNeeded: rawValue >> 16),
            UInt8(truncatingIfNeeded: rawValue >> 8),
            UInt8(truncatingIfNeeded: rawValue),
        ]
        return String(bytes.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "?" })
    }

    public var description: String { stringValue }
}

extension SMCFourCC: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        guard let code = SMCFourCC(code: value) else {
            preconditionFailure("'\(value)' is not a four-character ASCII SMC code")
        }
        self = code
    }
}
