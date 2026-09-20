import Darwin
import Foundation
import Synchronization

/// `mach_timebase_info` as a value, so the conversion can be tested without
/// the ratio of the machine that runs the test.
public struct MachTimebase: Sendable, Equatable {
    public let numerator: UInt64
    public let denominator: UInt64

    public init(numerator: UInt64, denominator: UInt64) {
        self.numerator = max(1, numerator)
        self.denominator = max(1, denominator)
    }

    /// 125/3 on an M1 Pro, 1/1 on Intel.
    public static let current: MachTimebase = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else {
            return MachTimebase(numerator: 1, denominator: 1)
        }
        return MachTimebase(numerator: UInt64(info.numer), denominator: UInt64(info.denom))
    }()

    /// The multiply runs in 128 bits, because `value * numerator` overflows
    /// `UInt64` well before `mach_absolute_time` does, and rounding the
    /// division down first would lose precision on short intervals.
    public func nanoseconds(fromAbsolute value: UInt64) -> UInt64 {
        UInt64(clamping: UInt128(value) * UInt128(numerator) / UInt128(denominator))
    }
}

public struct ProcessInfoRow: Sendable, Codable, Equatable, Identifiable {
    public let pid: Int32
    public let parentPID: Int32
    public let uid: uid_t
    /// `pbsi_comm`, which the kernel truncates to 16 characters.
    public let command: String
    /// What the UI shows: the bundle name for an app, else the executable
    /// name, else `command`.
    public let name: String
    public let executablePath: String?
    /// `ri_proc_start_abstime`, the key that tells a reused pid apart. nil
    /// when `proc_pid_rusage` refused the process.
    public let startAbsoluteTime: UInt64?
    /// Activity Monitor style: 100 % is one core fully busy. nil on the first
    /// sample of a process and whenever the counters are not readable.
    public let cpuPercent: Double?
    /// User plus system time since the process started, in nanoseconds.
    public let cpuNanoseconds: UInt64?
    /// `ri_phys_footprint`, the number Activity Monitor calls Memory.
    public let memoryBytes: UInt64?

    public var id: Int32 { pid }
    /// True when `proc_pid_rusage` failed, usually with EPERM on a root-owned
    /// process. The privileged helper fills these in.
    public var isRestricted: Bool { memoryBytes == nil }

    public init(
        pid: Int32,
        parentPID: Int32,
        uid: uid_t,
        command: String,
        name: String,
        executablePath: String?,
        startAbsoluteTime: UInt64?,
        cpuPercent: Double?,
        cpuNanoseconds: UInt64?,
        memoryBytes: UInt64?
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.uid = uid
        self.command = command
        self.name = name
        self.executablePath = executablePath
        self.startAbsoluteTime = startAbsoluteTime
        self.cpuPercent = cpuPercent
        self.cpuNanoseconds = cpuNanoseconds
        self.memoryBytes = memoryBytes
    }

    public func with(cpuPercent: Double?, cpuNanoseconds: UInt64?, memoryBytes: UInt64?, startAbsoluteTime: UInt64?) -> ProcessInfoRow {
        ProcessInfoRow(
            pid: pid,
            parentPID: parentPID,
            uid: uid,
            command: command,
            name: name,
            executablePath: executablePath,
            startAbsoluteTime: startAbsoluteTime,
            cpuPercent: cpuPercent,
            cpuNanoseconds: cpuNanoseconds,
            memoryBytes: memoryBytes
        )
    }
}

/// One process at one instant, as far as the CPU arithmetic is concerned.
public struct ProcessCPUSample: Sendable, Equatable {
    public let cpuNanoseconds: UInt64
    public let wallNanoseconds: UInt64
    public let startAbsoluteTime: UInt64

    public init(cpuNanoseconds: UInt64, wallNanoseconds: UInt64, startAbsoluteTime: UInt64) {
        self.cpuNanoseconds = cpuNanoseconds
        self.wallNanoseconds = wallNanoseconds
        self.startAbsoluteTime = startAbsoluteTime
    }
}

public enum ProcessCPUMath {
    /// CPU time over wall time, in percent, Activity Monitor style: one fully
    /// busy core is 100 %, so a machine with eight cores tops out at 800 %.
    ///
    /// Returns nil when there is nothing to compare against: no previous
    /// sample, a different start time under the same pid (the pid was reused
    /// for another process), or a non-positive interval.
    public static func percent(previous: ProcessCPUSample?, current: ProcessCPUSample) -> Double? {
        guard let previous else { return nil }
        guard previous.startAbsoluteTime == current.startAbsoluteTime else { return nil }
        guard current.wallNanoseconds > previous.wallNanoseconds else { return nil }
        let wall = current.wallNanoseconds - previous.wallNanoseconds
        // A counter that went backwards means the reading is not comparable;
        // report no CPU rather than a negative one.
        let cpu = current.cpuNanoseconds > previous.cpuNanoseconds
            ? current.cpuNanoseconds - previous.cpuNanoseconds
            : 0
        return Double(cpu) / Double(wall) * 100
    }
}

/// The process table from libproc.
///
/// Concurrency: a final class that keeps the previous CPU reading per pid in
/// a `Mutex`. The libproc calls are synchronous, one per process, a few
/// milliseconds for the whole table.
public final class ProcessSampler: Sendable {
    private let timebase: MachTimebase
    private let previous: Mutex<[Int32: ProcessCPUSample]>

    public init(timebase: MachTimebase = .current) {
        self.timebase = timebase
        previous = Mutex([:])
    }

    /// Every process the kernel lists. Rows whose counters are refused keep
    /// their identity with nil CPU and nil memory.
    public func sample() throws(MetricsError) -> [ProcessInfoRow] {
        let pids = try ProcessSampler.allPIDs()
        let wall = timebase.nanoseconds(fromAbsolute: mach_absolute_time())

        var rows: [ProcessInfoRow] = []
        rows.reserveCapacity(pids.count)
        var live: [Int32: ProcessCPUSample] = [:]
        live.reserveCapacity(pids.count)

        previous.withLock { history in
            for pid in pids {
                guard let identity = ProcessSampler.identity(of: pid) else { continue }
                let path = ProcessSampler.executablePath(of: pid)
                let name = ProcessSampler.displayName(executablePath: path, command: identity.command)

                guard let usage = ProcessSampler.resourceUsage(of: pid) else {
                    rows.append(
                        ProcessInfoRow(
                            pid: pid,
                            parentPID: identity.parentPID,
                            uid: identity.uid,
                            command: identity.command,
                            name: name,
                            executablePath: path,
                            startAbsoluteTime: nil,
                            cpuPercent: nil,
                            cpuNanoseconds: nil,
                            memoryBytes: nil
                        )
                    )
                    continue
                }

                let cpu = timebase.nanoseconds(
                    fromAbsolute: usage.ri_user_time &+ usage.ri_system_time
                )
                let current = ProcessCPUSample(
                    cpuNanoseconds: cpu,
                    wallNanoseconds: wall,
                    startAbsoluteTime: usage.ri_proc_start_abstime
                )
                live[pid] = current
                rows.append(
                    ProcessInfoRow(
                        pid: pid,
                        parentPID: identity.parentPID,
                        uid: identity.uid,
                        command: identity.command,
                        name: name,
                        executablePath: path,
                        startAbsoluteTime: usage.ri_proc_start_abstime,
                        cpuPercent: ProcessCPUMath.percent(previous: history[pid], current: current),
                        cpuNanoseconds: cpu,
                        memoryBytes: usage.ri_phys_footprint
                    )
                )
            }
            // Replacing the whole map evicts every pid that is gone.
            history = live
        }
        return rows
    }

    public func topByCPU(_ count: Int) throws(MetricsError) -> [ProcessInfoRow] {
        ProcessSampler.topByCPU(try sample(), count: count)
    }

    public func topByMemory(_ count: Int) throws(MetricsError) -> [ProcessInfoRow] {
        ProcessSampler.topByMemory(try sample(), count: count)
    }

    public func reset() {
        previous.withLock { $0 = [:] }
    }

    /// A row with no readable CPU sorts below a row that reports 0 %, so the
    /// unknowns do not push real load out of the list.
    public static func topByCPU(_ rows: [ProcessInfoRow], count: Int) -> [ProcessInfoRow] {
        top(rows, count: count) { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }
    }

    public static func topByMemory(_ rows: [ProcessInfoRow], count: Int) -> [ProcessInfoRow] {
        top(rows, count: count) { ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) }
    }

    static func top(
        _ rows: [ProcessInfoRow],
        count: Int,
        by areInOrder: (ProcessInfoRow, ProcessInfoRow) -> Bool
    ) -> [ProcessInfoRow] {
        guard count > 0 else { return [] }
        return Array(rows.sorted(by: areInOrder).prefix(count))
    }

    /// Fills the gaps of the unprivileged pass with the rows the root helper
    /// returned. Pure, so B6 can test the merge without XPC.
    ///
    /// The local pass sees every pid, so it sets the shape of the result; a
    /// privileged row only contributes the numbers the local pass could not
    /// read. A privileged row for a pid that is not in the local list is
    /// appended, because the process started between the two passes.
    public static func merge(local: [ProcessInfoRow], privileged: [ProcessInfoRow]) -> [ProcessInfoRow] {
        guard !privileged.isEmpty else { return local }
        var byPID = Dictionary(privileged.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        let merged = local.map { row -> ProcessInfoRow in
            guard let other = byPID.removeValue(forKey: row.pid) else { return row }
            // A different start time under the same pid is a different
            // process, so the privileged numbers do not belong to this row.
            if let mine = row.startAbsoluteTime,
               let theirs = other.startAbsoluteTime,
               mine != theirs {
                return row
            }
            guard row.memoryBytes == nil || row.cpuPercent == nil else { return row }
            return row.with(
                cpuPercent: row.cpuPercent ?? other.cpuPercent,
                cpuNanoseconds: row.cpuNanoseconds ?? other.cpuNanoseconds,
                memoryBytes: row.memoryBytes ?? other.memoryBytes,
                startAbsoluteTime: row.startAbsoluteTime ?? other.startAbsoluteTime
            )
        }
        return merged + byPID.values.sorted { $0.pid < $1.pid }
    }

    /// The bundle name for an executable inside a `.app`, else the file name
    /// of the executable. `comm` is the last resort because the kernel cuts
    /// it at 16 characters.
    public static func displayName(executablePath: String?, command: String) -> String {
        guard let executablePath, !executablePath.isEmpty else { return command }
        let components = executablePath.split(separator: "/", omittingEmptySubsequences: true)
        if let bundle = components.last(where: { $0.hasSuffix(".app") }) {
            return String(bundle.dropLast(4))
        }
        return components.last.map(String.init) ?? command
    }

    // MARK: - libproc

    /// Every pid the kernel lists, kernel_task (pid 0) included.
    ///
    /// `proc_listallpids` takes a buffer size in bytes but returns a pid
    /// count (unlike `proc_listpids`, which returns bytes). Pid 0 and pid 1
    /// sit at the end of the list, so a wrong length drops them silently.
    static func allPIDs() throws(MetricsError) -> [Int32] {
        var capacity = max(Int(proc_listallpids(nil, 0)), 256) * 2
        for _ in 0..<4 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let count = buffer.withUnsafeMutableBufferPointer { pointer in
                Int(proc_listallpids(pointer.baseAddress, Int32(pointer.count * MemoryLayout<pid_t>.size)))
            }
            guard count > 0 else { throw MetricsError.unavailable("proc_listallpids") }
            if count < capacity { return Array(buffer.prefix(count)) }
            capacity *= 2
        }
        throw MetricsError.unavailable("proc_listallpids")
    }

    /// `PROC_PIDT_SHORTBSDINFO` is the one flavour that answers for every
    /// process without root.
    static func identity(of pid: pid_t) -> (parentPID: pid_t, uid: uid_t, command: String)? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        let command = withUnsafePointer(to: info.pbsi_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                String(cString: $0)
            }
        }
        return (pid_t(bitPattern: info.pbsi_ppid), info.pbsi_uid, command)
    }

    static func executablePath(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE, which Swift does not import from
        // <sys/proc_info.h>.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(nullTerminated: buffer)
    }

    /// nil when the call is refused, which is EPERM for root-owned processes.
    static func resourceUsage(of pid: pid_t) -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        return status == 0 ? usage : nil
    }
}
