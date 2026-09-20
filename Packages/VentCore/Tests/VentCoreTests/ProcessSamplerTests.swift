import Foundation
import Testing

@testable import SysMetrics

@Suite("mach timebase conversion")
struct MachTimebaseTests {
    /// The ratio this machine reports. `ri_user_time` and `ri_system_time`
    /// are in these units, not in nanoseconds.
    private let m1 = MachTimebase(numerator: 125, denominator: 3)

    @Test("the M1 ratio turns mach units into nanoseconds")
    func m1Ratio() {
        #expect(m1.nanoseconds(fromAbsolute: 24) == 1_000)
        #expect(m1.nanoseconds(fromAbsolute: 24_000_000) == 1_000_000_000)
        // The busy-loop measurement: 24016897 units over one wall second.
        let nanoseconds = m1.nanoseconds(fromAbsolute: 24_016_897)
        #expect(abs(Double(nanoseconds) / 1e9 - 1.0007) < 0.001)
    }

    @Test("an Intel machine with a 1:1 ratio is the identity")
    func identity() {
        let intel = MachTimebase(numerator: 1, denominator: 1)
        #expect(intel.nanoseconds(fromAbsolute: 123_456_789) == 123_456_789)
    }

    @Test("a counter big enough to overflow a 64-bit multiply still converts")
    func noOverflow() {
        // About 96 CPU-days of mach units. value * 125 is still inside
        // UInt64 here, so the exact answer is checkable by hand.
        let value: UInt64 = 200_000_000_000_000
        #expect(m1.nanoseconds(fromAbsolute: value) == 8_333_333_333_333_333)
        // Near the top of UInt64 a 64-bit multiply traps; this must clamp.
        #expect(m1.nanoseconds(fromAbsolute: .max) == .max)
    }

    @Test("the conversion keeps sub-unit precision, it does not divide first")
    func precision() {
        // 1 mach unit is 41.66 ns; dividing before multiplying would give 0.
        #expect(m1.nanoseconds(fromAbsolute: 1) == 41)
        #expect(m1.nanoseconds(fromAbsolute: 2) == 83)
    }

    @Test("a broken timebase falls back to 1:1 instead of dividing by zero")
    func zeroGuard() {
        let broken = MachTimebase(numerator: 0, denominator: 0)
        #expect(broken.nanoseconds(fromAbsolute: 42) == 42)
    }

    @Test("the machine reports a usable timebase")
    func current() {
        #expect(MachTimebase.current.denominator > 0)
        #expect(MachTimebase.current.numerator > 0)
    }
}

@Suite("process CPU percent")
struct ProcessCPUMathTests {
    private func sample(cpu: UInt64, wall: UInt64, start: UInt64 = 111) -> ProcessCPUSample {
        ProcessCPUSample(cpuNanoseconds: cpu, wallNanoseconds: wall, startAbsoluteTime: start)
    }

    @Test("one core fully busy for one second is 100 percent")
    func oneCore() throws {
        let percent = try #require(
            ProcessCPUMath.percent(
                previous: sample(cpu: 0, wall: 0),
                current: sample(cpu: 1_000_000_000, wall: 1_000_000_000)
            )
        )
        #expect(abs(percent - 100) < 1e-9)
    }

    @Test("four busy cores read 400 percent, Activity Monitor style")
    func fourCores() throws {
        let percent = try #require(
            ProcessCPUMath.percent(
                previous: sample(cpu: 0, wall: 0),
                current: sample(cpu: 4_000_000_000, wall: 1_000_000_000)
            )
        )
        #expect(abs(percent - 400) < 1e-9)
    }

    @Test("a converted mach-unit counter gives about 100 percent, not 2.4")
    func timebaseConversionFeedsThePercent() throws {
        let timebase = MachTimebase(numerator: 125, denominator: 3)
        // Numbers measured on this machine over one wall second of busy loop.
        let cpuUnits: UInt64 = 24_016_897
        let wallUnits: UInt64 = 24_045_346
        let percent = try #require(
            ProcessCPUMath.percent(
                previous: sample(cpu: 0, wall: 0),
                current: sample(
                    cpu: timebase.nanoseconds(fromAbsolute: cpuUnits),
                    wall: timebase.nanoseconds(fromAbsolute: wallUnits)
                )
            )
        )
        #expect(abs(percent - 99.88) < 0.1)

        // Reading the same counter as nanoseconds is the bug this guards.
        let unconverted = try #require(
            ProcessCPUMath.percent(
                previous: sample(cpu: 0, wall: 0),
                current: sample(cpu: cpuUnits, wall: timebase.nanoseconds(fromAbsolute: wallUnits))
            )
        )
        #expect(abs(unconverted - 2.4) < 0.1)
    }

    @Test("the first sample of a process has no percent")
    func noPrevious() {
        #expect(ProcessCPUMath.percent(previous: nil, current: sample(cpu: 5, wall: 10)) == nil)
    }

    @Test("a reused pid does not inherit the CPU time of the dead process")
    func pidReuse() {
        let previous = sample(cpu: 900_000_000, wall: 1_000_000_000, start: 111)
        let current = sample(cpu: 10_000_000, wall: 2_000_000_000, start: 222)
        #expect(ProcessCPUMath.percent(previous: previous, current: current) == nil)
        // Same start time: the percent is computed as usual.
        let same = sample(cpu: 1_400_000_000, wall: 2_000_000_000, start: 111)
        #expect(ProcessCPUMath.percent(previous: previous, current: same) == 50)
    }

    @Test("a non-advancing clock has no percent")
    func noInterval() {
        let previous = sample(cpu: 1, wall: 1_000)
        #expect(ProcessCPUMath.percent(previous: previous, current: sample(cpu: 2, wall: 1_000)) == nil)
        #expect(ProcessCPUMath.percent(previous: previous, current: sample(cpu: 2, wall: 500)) == nil)
    }

    @Test("a CPU counter that went backwards reads zero, not a negative")
    func backwardsCPU() {
        let previous = sample(cpu: 500_000_000, wall: 1_000_000_000)
        #expect(ProcessCPUMath.percent(previous: previous, current: sample(cpu: 0, wall: 2_000_000_000)) == 0)
    }
}

@Suite("process rows")
struct ProcessRowTests {
    private func row(
        pid: Int32,
        name: String = "proc",
        start: UInt64? = 1,
        cpu: Double? = nil,
        cpuNanoseconds: UInt64? = nil,
        memory: UInt64? = nil
    ) -> ProcessInfoRow {
        ProcessInfoRow(
            pid: pid,
            parentPID: 1,
            uid: 501,
            command: name,
            name: name,
            executablePath: "/usr/bin/\(name)",
            startAbsoluteTime: start,
            cpuPercent: cpu,
            cpuNanoseconds: cpuNanoseconds,
            memoryBytes: memory
        )
    }

    @Test("an app bundle name beats the executable name and the truncated comm")
    func displayName() {
        #expect(
            ProcessSampler.displayName(
                executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
                command: "Safari"
            ) == "Safari"
        )
        #expect(
            ProcessSampler.displayName(
                executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome Helper",
                command: "Google Chrome H"
            ) == "Google Chrome"
        )
        // The innermost bundle wins: that is the app that is running.
        #expect(
            ProcessSampler.displayName(
                executablePath: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator",
                command: "Simulator"
            ) == "Simulator"
        )
        #expect(
            ProcessSampler.displayName(
                executablePath: "/usr/libexec/logd",
                command: "logd"
            ) == "logd"
        )
        // comm is cut at 16 characters, so the path wins whenever there is one.
        #expect(
            ProcessSampler.displayName(
                executablePath: "/usr/libexec/containermanagerd",
                command: "containermanage"
            ) == "containermanagerd"
        )
        #expect(ProcessSampler.displayName(executablePath: nil, command: "kernel_task") == "kernel_task")
        #expect(ProcessSampler.displayName(executablePath: "", command: "kernel_task") == "kernel_task")
    }

    @Test("a row without counters is flagged as restricted")
    func restricted() {
        #expect(row(pid: 1).isRestricted)
        #expect(!row(pid: 1, memory: 1_024).isRestricted)
    }

    @Test("a row round-trips through Codable, because the helper sends it over XPC")
    func codable() throws {
        let original = row(pid: 42, name: "vent", cpu: 12.5, cpuNanoseconds: 99, memory: 1_048_576)
        let data = try JSONEncoder().encode([original])
        #expect(try JSONDecoder().decode([ProcessInfoRow].self, from: data) == [original])
    }

    @Test("the top lists keep the requested number of rows in order")
    func top() {
        let rows = [
            row(pid: 1, cpu: 3, memory: 30),
            row(pid: 2, cpu: nil, memory: nil),
            row(pid: 3, cpu: 90, memory: 10),
            row(pid: 4, cpu: 12, memory: 40),
        ]
        #expect(ProcessSampler.topByCPU(rows, count: 2).map(\.pid) == [3, 4])
        #expect(ProcessSampler.topByMemory(rows, count: 2).map(\.pid) == [4, 1])
        // A row with no readable counter sorts last, never into the top.
        #expect(ProcessSampler.topByCPU(rows, count: 3).map(\.pid) == [3, 4, 1])
        #expect(ProcessSampler.topByMemory(rows, count: 3).map(\.pid) == [4, 1, 3])
        #expect(ProcessSampler.topByCPU(rows, count: 0).isEmpty)
        #expect(ProcessSampler.topByCPU(rows, count: 99).count == 4)
    }
}

@Suite("merge of the local and the privileged process pass")
struct ProcessMergeTests {
    private func row(
        pid: Int32,
        start: UInt64? = 1,
        cpu: Double? = nil,
        cpuNanoseconds: UInt64? = nil,
        memory: UInt64? = nil,
        name: String = "proc"
    ) -> ProcessInfoRow {
        ProcessInfoRow(
            pid: pid,
            parentPID: 1,
            uid: 0,
            command: name,
            name: name,
            executablePath: "/usr/libexec/\(name)",
            startAbsoluteTime: start,
            cpuPercent: cpu,
            cpuNanoseconds: cpuNanoseconds,
            memoryBytes: memory
        )
    }

    @Test("the privileged pass fills only the gaps the local pass left")
    func fillsGaps() {
        let local = [
            row(pid: 0, start: nil, name: "kernel_task"),
            row(pid: 1, start: nil, name: "launchd"),
            row(pid: 500, cpu: 4, cpuNanoseconds: 40, memory: 2_048, name: "Vent"),
        ]
        let privileged = [
            row(pid: 0, start: 7, cpu: 33, cpuNanoseconds: 330, memory: 1_000_000, name: "kernel_task"),
            row(pid: 1, start: 8, cpu: 0.2, cpuNanoseconds: 2, memory: 20_000, name: "launchd"),
            row(pid: 500, cpu: 99, cpuNanoseconds: 990, memory: 1, name: "Vent"),
        ]
        let merged = ProcessSampler.merge(local: local, privileged: privileged)

        #expect(merged.count == 3)
        #expect(merged[0].cpuPercent == 33)
        #expect(merged[0].memoryBytes == 1_000_000)
        #expect(merged[0].startAbsoluteTime == 7)
        #expect(merged[1].memoryBytes == 20_000)
        // The local numbers of a readable process are kept as they are.
        #expect(merged[2].cpuPercent == 4)
        #expect(merged[2].memoryBytes == 2_048)
    }

    @Test("a privileged row for a pid the local pass missed is appended")
    func appendsNewPIDs() {
        let merged = ProcessSampler.merge(
            local: [row(pid: 10)],
            privileged: [row(pid: 30, memory: 3), row(pid: 20, memory: 2)]
        )
        #expect(merged.map(\.pid) == [10, 20, 30])
    }

    @Test("a different start time under the same pid is a different process")
    func rejectsPIDReuse() {
        let merged = ProcessSampler.merge(
            local: [row(pid: 77, start: 1_000)],
            privileged: [row(pid: 77, start: 2_000, cpu: 50, memory: 9_999)]
        )
        #expect(merged.count == 1)
        #expect(merged[0].cpuPercent == nil)
        #expect(merged[0].memoryBytes == nil)
    }

    @Test("an empty privileged pass changes nothing")
    func noPrivilegedRows() {
        let local = [row(pid: 1), row(pid: 2, memory: 5)]
        #expect(ProcessSampler.merge(local: local, privileged: []) == local)
    }

    @Test("the merge is idempotent")
    func idempotent() {
        let local = [row(pid: 1), row(pid: 2, cpu: 1, memory: 5)]
        let privileged = [row(pid: 1, cpu: 7, cpuNanoseconds: 70, memory: 700)]
        let once = ProcessSampler.merge(local: local, privileged: privileged)
        #expect(ProcessSampler.merge(local: once, privileged: privileged) == once)
    }
}
