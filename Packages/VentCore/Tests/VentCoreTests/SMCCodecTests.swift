import Testing

@testable import SMCKit

@Suite("SMC FourCC codes")
struct SMCFourCCTests {
    @Test("a code is the big-endian FourCC held as a native integer")
    func rawValue() {
        #expect(SMCFourCC(code: "TC0P")?.rawValue == 0x5443_3050)
        #expect(SMCFourCC(code: "#KEY")?.rawValue == 0x234B_4559)
        #expect(SMCFourCC(code: "flt ")?.rawValue == 0x666C_7420)
    }

    @Test("every four-character code round-trips")
    func roundTrip() {
        for text in ["TC0P", "#KEY", "flt ", "F0Ac", "Tp0b", "ui8 ", "PSTR"] {
            let code = SMCFourCC(code: text)
            #expect(code?.stringValue == text)
            #expect(code.map { SMCFourCC(rawValue: $0.rawValue) } == code)
        }
    }

    @Test("codes that are not four ASCII characters are rejected")
    func rejectsBadCodes() {
        #expect(SMCFourCC(code: "TC0") == nil)
        #expect(SMCFourCC(code: "TC0PP") == nil)
        #expect(SMCFourCC(code: "") == nil)
        #expect(SMCFourCC(code: "Tp0é") == nil)
    }

    @Test("non-printable bytes are shown as question marks")
    func printsUnprintableBytes() {
        #expect(SMCFourCC(rawValue: 0x0001_0203).stringValue == "????")
    }
}

@Suite("SMC payload codecs")
struct SMCDataTypeTests {
    @Test("the type code maps to the codec and back")
    func typeCodes() {
        for code in ["flt ", "fpe2", "sp78", "ui8 ", "ui16", "ui32", "si16", "flag"] {
            let fourCC = SMCFourCC(code: code)!
            #expect(SMCDataType(fourCC).code == fourCC)
        }
        #expect(SMCDataType("ch8*") == .other("ch8*"))
    }

    @Test("flt decodes the captured little-endian floats")
    func decodesFloat() {
        #expect(near(SMCDataType.float32.decode([0xa6, 0x3e, 0x2a, 0x42]), 42.56, tolerance: 0.005))
        #expect(SMCDataType.float32.decode([0x00, 0x00, 0x96, 0x44]) == .number(1200))
        #expect(SMCDataType.float32.decode([0x00, 0x98, 0xb4, 0x45]) == .number(5779))
    }

    @Test("the fixed-point codecs follow the big-endian SMC convention")
    func decodesFixedPoint() {
        #expect(SMCDataType.fpe2.decode([0x12, 0xc0]) == .number(1200))
        #expect(SMCDataType.sp78.decode([0x1e, 0x80]) == .number(30.5))
        #expect(SMCDataType.sp78.decode([0xff, 0x80]) == .number(-0.5))
    }

    @Test("the integer codecs are big-endian")
    func decodesIntegers() {
        #expect(SMCDataType.uint8.decode([0x2a]) == .number(42))
        #expect(SMCDataType.uint16.decode([0x04, 0xb0]) == .number(1200))
        #expect(SMCDataType.uint32.decode([0x00, 0x00, 0x07, 0xf6]) == .number(2038))
        #expect(SMCDataType.int16.decode([0xff, 0xfe]) == .number(-2))
        #expect(SMCDataType.flag.decode([0x01]) == .flag(true))
        #expect(SMCDataType.flag.decode([0x00]) == .flag(false))
    }

    @Test("an unknown type and a short payload stay raw")
    func keepsRawBytes() {
        #expect(SMCDataType("ch8*").decode([0x01, 0x02]) == .raw([0x01, 0x02]))
        #expect(SMCDataType.uint32.decode([0x01, 0x02]) == .raw([0x01, 0x02]))
    }

    @Test("every codec round-trips a value")
    func encodeDecodeSymmetry() {
        let cases: [(SMCDataType, SMCValue)] = [
            (.float32, .number(1200)),
            (.float32, .number(5779)),
            (.fpe2, .number(1200)),
            (.fpe2, .number(0.25)),
            (.sp78, .number(30.5)),
            (.sp78, .number(-0.5)),
            (.uint8, .number(42)),
            (.uint16, .number(1200)),
            (.uint32, .number(2038)),
            (.int16, .number(-2)),
            (.flag, .flag(true)),
            (.flag, .flag(false)),
        ]
        for (type, value) in cases {
            let bytes = type.encode(value)
            #expect(bytes?.count == type.byteCount, "\(type.code) encoded \(value)")
            #expect(bytes.map { type.decode($0) } == value, "\(type.code) round-trip of \(value)")
        }
    }

    @Test("a value outside the range of the codec is refused")
    func refusesOutOfRange() {
        #expect(SMCDataType.uint8.encode(.number(256)) == nil)
        #expect(SMCDataType.uint8.encode(.number(-1)) == nil)
        #expect(SMCDataType.fpe2.encode(.number(-1)) == nil)
        #expect(SMCDataType.int16.encode(.number(40000)) == nil)
        #expect(SMCDataType.sp78.encode(.number(200)) == nil)
        #expect(SMCDataType.float32.encode(.number(.infinity)) == nil)
        #expect(SMCDataType.uint16.encode(.raw([0x01])) == nil)
    }

    @Test("the payload capacity bounds an unknown type")
    func boundsRawEncoding() {
        #expect(SMCDataType("ch8*").encode(.raw([UInt8](repeating: 0, count: 32)))?.count == 32)
        #expect(SMCDataType("ch8*").encode(.raw([UInt8](repeating: 0, count: 33))) == nil)
    }

    @Test("values print in a readable form")
    func printsValues() {
        #expect("\(SMCValue.number(1200))" == "1200")
        #expect("\(SMCValue.number(42.56))" == "42.56")
        #expect("\(SMCValue.flag(true))" == "true")
        #expect("\(SMCValue.raw([0x0a, 0xff]))" == "0a ff")
    }

    private func near(_ value: SMCValue, _ expected: Double, tolerance: Double) -> Bool {
        guard let actual = value.doubleValue else { return false }
        return abs(actual - expected) <= tolerance
    }
}

@Suite("SMC error mapping")
struct SMCErrorTests {
    @Test("the documented result codes map to their meaning")
    func resultCodes() {
        #expect(SMCResultCode(rawValue: 0x80) == .commCollision)
        #expect(SMCResultCode(rawValue: 0x84) == .keyNotFound)
        #expect(SMCResultCode(rawValue: 0x89) == .badArgument)
        #expect(SMCResultCode(rawValue: 0x8a) == nil)
    }

    @Test("a result byte becomes a typed error")
    func resultToError() {
        #expect(SMCError.fromResult(0x84, key: "TC0P") == .keyNotFound("TC0P"))
        #expect(SMCError.fromResult(0x89, key: "TC0P") == .deviceError("TC0P", .badArgument))
        #expect(SMCError.fromResult(0x8a, key: "TC0P") == .unknownResult("TC0P", 0x8a))
    }

    @Test("kIOReturnNotPrivileged is told apart from other IOKit failures")
    func ioReturnToError() {
        #expect(SMCError.fromCall(SMCError.ioReturnNotPrivileged, key: "F0Md") == .notPrivileged("F0Md"))
        #expect(SMCError.fromCall(-536_870_206, key: "F0Md") == .callFailed("F0Md", -536_870_206))
        #expect(SMCError.ioReturnNotPrivileged == Int32(bitPattern: 0xe000_02c1))
    }

    @Test("every error explains itself")
    func descriptions() {
        #expect("\(SMCError.keyNotFound("TC0P"))" == "the SMC has no key TC0P")
        #expect("\(SMCError.notPrivileged("F0Md"))".contains("root"))
        #expect("\(SMCError.serviceNotFound)".contains("AppleSMC"))
    }
}

@Suite("sensor naming")
struct SensorNamingTests {
    @Test("the M1 Pro keys carry a label and a category")
    func knownKeys() {
        #expect(SensorNaming.descriptor(for: "Tp01").category == .cpuPerformance)
        #expect(SensorNaming.descriptor(for: "Tp09").category == .cpuEfficiency)
        #expect(SensorNaming.descriptor(for: "Tp0T").category == .cpuEfficiency)
        #expect(SensorNaming.descriptor(for: "Tg05").category == .gpu)
        #expect(SensorNaming.descriptor(for: "Tm02").category == .memory)
        #expect(SensorNaming.descriptor(for: "Ts0P").category == .enclosure)
        #expect(SensorNaming.descriptor(for: "TB0T").category == .battery)
        #expect(SensorNaming.descriptor(for: "TW0P").category == .wireless)
        #expect(SensorNaming.descriptor(for: "TaLP").category == .ambient)
        #expect(SensorNaming.descriptor(for: "TH0x").category == .ssd)
        #expect(SensorNaming.descriptor(for: "Tp0b").label == "CPU performance core 8")
    }

    @Test("an unknown key is labelled by its code")
    func unknownKey() {
        let descriptor = SensorNaming.descriptor(for: "Tzzz")
        #expect(descriptor.label == "Tzzz")
        #expect(descriptor.category == .other)
    }

    @Test("power keys have their own labels")
    func powerKeys() {
        #expect(SensorNaming.powerLabel(for: "PSTR") == "System total")
        #expect(SensorNaming.powerLabel(for: "PZZZ") == "PZZZ")
        #expect(SensorNaming.isKnownPowerKey("PSTR"))
        #expect(!SensorNaming.isKnownPowerKey("PZZZ"))
    }
}

@Suite("fan keys")
struct FanKeyTests {
    @Test("fan keys are built from the index and the suffix")
    func buildsKeys() {
        #expect(FanKeys.key(fan: 0, suffix: "Ac") == "F0Ac")
        #expect(FanKeys.key(fan: 1, suffix: "Md") == "F1Md")
        #expect(FanKeys.key(fan: 10, suffix: "Ac") == nil)
        #expect(FanKeys.key(fan: 0, suffix: "A") == nil)
    }
}
