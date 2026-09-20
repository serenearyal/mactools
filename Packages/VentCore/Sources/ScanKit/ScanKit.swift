/// Namespace for the largest-files scan: bounded heap, walker, coordinator, cache.
///
/// The real implementation arrives in a later batch.
public enum Scan {
    /// Volume the whole-disk scan walks.
    public static let dataVolumePath = "/System/Volumes/Data"

    /// Number of largest files the scan keeps.
    public static let resultLimit = 500
}
