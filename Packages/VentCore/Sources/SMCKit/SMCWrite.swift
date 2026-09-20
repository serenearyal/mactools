/// The SMC write path, kept apart from every read so that a read-only build
/// stays obviously read-only. Nothing calls it yet: the fan governor in the
/// privileged helper is the only planned caller, and a write without root
/// comes back as `SMCError.notPrivileged`.
extension SMCConnection {
    public func writeBytes(_ payload: [UInt8], to key: SMCFourCC, info: SMCKeyInfo) throws(SMCError) {
        guard info.dataSize <= UInt32(SMCParamStruct.payloadCapacity), payload.count == Int(info.dataSize) else {
            throw SMCError.unsupportedSize(key, info.dataSize)
        }
        var input = SMCParamStruct()
        input.key = key.rawValue
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMCConnection.writeCommand()
        input.setPayload(payload)
        _ = try call(input, key: key)
    }

    public func write(_ value: SMCValue, to key: SMCFourCC) throws(SMCError) {
        let info = try keyInfo(for: key)
        guard let payload = info.type.encode(value) else {
            throw SMCError.encodingFailed(key, info.type)
        }
        try writeBytes(payload, to: key, info: info)
    }
}
