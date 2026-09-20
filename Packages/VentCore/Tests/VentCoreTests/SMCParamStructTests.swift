import Testing

import SMCKit

@Suite("SMCParamStruct matches the AppleSMC ABI")
struct SMCParamStructTests {
    @Test("the structure is 80 bytes")
    func size() {
        #expect(MemoryLayout<SMCParamStruct>.size == 80)
        #expect(MemoryLayout<SMCParamStruct>.stride == 80)
    }

    @Test("every field sits at the offset the driver expects")
    func offsets() {
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.key) == 0)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.vers) == 4)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.pLimitData) == 12)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.keyInfo) == 28)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.keyInfo.dataSize) == 28)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.keyInfo.dataType) == 32)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.keyInfo.dataAttributes) == 36)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.result) == 40)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.status) == 41)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.data8) == 42)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.data32) == 44)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.bytes) == 48)
    }

    @Test("the nested structures keep their own sizes")
    func nestedSizes() {
        #expect(MemoryLayout<SMCVersion>.size == 6)
        #expect(MemoryLayout<SMCPLimitData>.size == 16)
        #expect(MemoryLayout<SMCKeyInfoData>.size == 12)
        #expect(MemoryLayout<SMCBytes>.size == 32)
    }

    @Test("the payload round-trips through the byte field")
    func payloadRoundTrip() {
        var parameters = SMCParamStruct()
        parameters.setPayload([0xa6, 0x3e, 0x2a, 0x42])
        #expect(parameters.payload(4) == [0xa6, 0x3e, 0x2a, 0x42])
        #expect(parameters.payload(32).dropFirst(4).allSatisfy { $0 == 0 })

        parameters.setPayload([0x01])
        #expect(parameters.payload(4) == [0x01, 0, 0, 0])
    }
}
