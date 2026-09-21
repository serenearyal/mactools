/// Namespace for the Apple SMC access layer.
///
/// The layer is the 80-byte `SMCParamStruct`, `SMCFourCC`, the payload codecs
/// in `SMCDataType`, `SMCConnection`, `SMCKeyCatalog` and `SensorNaming`.
public enum SMC {
    /// Name of the IOKit service the SMC layer opens.
    public static let serviceName = "AppleSMC"
}
