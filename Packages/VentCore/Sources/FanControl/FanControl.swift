/// Namespace for the pure fan curve math, safety clamps and mode handling.
///
/// The real implementation arrives in a later batch.
public enum Fans {
    /// Any CPU or GPU sensor above this value forces the fans back to Auto.
    public static let thermalInterlockCelsius: Double = 100
}
