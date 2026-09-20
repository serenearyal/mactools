/// Namespace for CPU, memory, disk space, disk I/O and process metrics.
///
/// Every sampler here is read-only and needs no privilege. The process table
/// is the exception: `proc_pid_rusage` refuses root-owned processes, so those
/// rows arrive without CPU and memory and the helper fills them in with
/// `ProcessSampler.merge(local:privileged:)`.
public enum Metrics {
    /// Default sampling interval, in seconds.
    public static let defaultSampleInterval: Double = 1

    /// Default history length of a graph: 5 minutes at the default interval.
    public static let defaultHistoryLength: Int = 300
}
