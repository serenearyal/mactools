/// Namespace for the Apple SMC access layer.
///
/// The real implementation (ABI struct, FourCC, codecs, connection, key
/// catalog and sensor names) arrives in a later batch.
public enum SMC {
    /// Name of the IOKit service the SMC layer opens.
    public static let serviceName = "AppleSMC"
}
