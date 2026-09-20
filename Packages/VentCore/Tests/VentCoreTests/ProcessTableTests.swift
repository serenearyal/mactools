import Foundation
import Synchronization
import Testing

@testable import SysMetrics

private func tableRow(
    pid: Int32,
    name: String = "proc",
    uid: uid_t = 501,
    user: String = "serene",
    path: String? = nil,
    cpu: Double? = nil,
    memory: UInt64? = nil
) -> ProcessTableRow {
    ProcessTableRow(
        info: ProcessInfoRow(
            pid: pid,
            parentPID: 1,
            uid: uid,
            command: name,
            name: name,
            executablePath: path ?? "/usr/bin/\(name)",
            startAbsoluteTime: 1,
            cpuPercent: cpu,
            cpuNanoseconds: cpu.map { UInt64($0) },
            memoryBytes: memory
        ),
        userName: user
    )
}

@Suite("process table filtering")
struct ProcessFilterTests {
    private let rows = [
        tableRow(pid: 10, name: "Vent", uid: 501, user: "serene"),
        tableRow(pid: 20, name: "kernel_task", uid: 0, user: "root"),
        tableRow(pid: 30, name: "mdworker", uid: 89, user: "_spotlight"),
    ]

    @Test("the scope splits the table by the uid of this user")
    func scope() {
        #expect(ProcessTable.filter(rows, scope: .all, currentUID: 501).map(\.pid) == [10, 20, 30])
        #expect(ProcessTable.filter(rows, scope: .mine, currentUID: 501).map(\.pid) == [10])
        #expect(ProcessTable.filter(rows, scope: .system, currentUID: 501).map(\.pid) == [20, 30])
        // Run as root, "mine" is the root rows and nothing else.
        #expect(ProcessTable.filter(rows, scope: .mine, currentUID: 0).map(\.pid) == [20])
    }

    @Test("the search looks at the name, the pid, the path and the user")
    func search() {
        let row = tableRow(
            pid: 1_234,
            name: "WindowServer",
            uid: 88,
            user: "_windowserver",
            path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
        )
        #expect(ProcessTable.matches(row, query: "window"))
        #expect(ProcessTable.matches(row, query: "SERVER"))
        #expect(ProcessTable.matches(row, query: "1234"))
        // A pid from a log is often remembered in part.
        #expect(ProcessTable.matches(row, query: "23"))
        #expect(ProcessTable.matches(row, query: "SkyLight"))
        #expect(ProcessTable.matches(row, query: "_windowserver"))
        #expect(!ProcessTable.matches(row, query: "safari"))
        // No query is not a filter, and neither is a space.
        #expect(ProcessTable.matches(row, query: ""))
        #expect(ProcessTable.matches(row, query: "   "))
    }

    @Test("the scope and the query both apply")
    func scopeAndQuery() {
        let filtered = ProcessTable.filter(rows, scope: .system, currentUID: 501, query: "kernel")
        #expect(filtered.map(\.pid) == [20])
        #expect(ProcessTable.filter(rows, scope: .mine, currentUID: 501, query: "kernel").isEmpty)
    }

    @Test("a row with no path is still searchable by name")
    func noPath() {
        let row = ProcessTableRow(
            info: ProcessInfoRow(
                pid: 0,
                parentPID: 0,
                uid: 0,
                command: "kernel_task",
                name: "kernel_task",
                executablePath: nil,
                startAbsoluteTime: nil,
                cpuPercent: nil,
                cpuNanoseconds: nil,
                memoryBytes: nil
            ),
            userName: "root"
        )
        #expect(ProcessTable.matches(row, query: "kernel"))
        #expect(!ProcessTable.matches(row, query: "/usr/bin"))
    }
}

@Suite("process table ordering")
struct ProcessOrderingTests {
    private let rows = [
        tableRow(pid: 3, name: "bravo", cpu: 12.5, memory: 300),
        tableRow(pid: 1, name: "alpha", cpu: nil, memory: nil),
        tableRow(pid: 2, name: "charlie", cpu: 0, memory: 100),
        tableRow(pid: 4, name: "delta", cpu: 99, memory: 200),
    ]

    @Test("CPU descending is the default order of the tab")
    func cpuDescending() {
        #expect(ProcessTable.sorted(rows, by: .cpu, ascending: false).map(\.pid) == [4, 3, 2, 1])
    }

    @Test("a missing counter sorts last in both directions")
    func nilLast() {
        #expect(ProcessTable.sorted(rows, by: .cpu, ascending: true).map(\.pid) == [2, 3, 4, 1])
        #expect(ProcessTable.sorted(rows, by: .memory, ascending: true).map(\.pid) == [2, 4, 3, 1])
        #expect(ProcessTable.sorted(rows, by: .memory, ascending: false).map(\.pid) == [3, 4, 2, 1])
    }

    @Test("names sort the way the Finder sorts them")
    func names() {
        #expect(ProcessTable.sorted(rows, by: .name, ascending: true).map(\.pid) == [1, 3, 2, 4])
        #expect(ProcessTable.sorted(rows, by: .name, ascending: false).map(\.pid) == [4, 2, 3, 1])
    }

    @Test("the pid breaks every tie, so two refreshes draw the same table")
    func stableTies() {
        let same = [
            tableRow(pid: 9, name: "same", cpu: 5),
            tableRow(pid: 2, name: "same", cpu: 5),
            tableRow(pid: 7, name: "same", cpu: 5),
        ]
        #expect(ProcessTable.sorted(same, by: .name, ascending: true).map(\.pid) == [2, 7, 9])
        #expect(ProcessTable.sorted(same, by: .name, ascending: false).map(\.pid) == [2, 7, 9])
        #expect(ProcessTable.sorted(same, by: .cpu, ascending: false).map(\.pid) == [2, 7, 9])
        // The same rows in another order give the same table.
        #expect(ProcessTable.sorted(same.reversed(), by: .cpu, ascending: false).map(\.pid) == [2, 7, 9])
    }

    @Test("two rows with unreadable counters still order by pid")
    func bothNil() {
        let unknown = [tableRow(pid: 8), tableRow(pid: 5)]
        #expect(ProcessTable.sorted(unknown, by: .cpu, ascending: false).map(\.pid) == [5, 8])
        #expect(ProcessTable.sorted(unknown, by: .cpu, ascending: true).map(\.pid) == [5, 8])
    }

    @Test("the user column orders by name, then by uid")
    func users() {
        let accounts = [
            tableRow(pid: 1, uid: 0, user: "root"),
            tableRow(pid: 2, uid: 501, user: "serene"),
            tableRow(pid: 3, uid: 89, user: "daemon"),
            tableRow(pid: 4, uid: 88, user: "daemon"),
        ]
        #expect(ProcessTable.sorted(accounts, by: .user, ascending: true).map(\.pid) == [4, 3, 1, 2])
        // The whole key turns round, the uid inside it included; only the pid
        // that breaks the last tie always counts up.
        #expect(ProcessTable.sorted(accounts, by: .user, ascending: false).map(\.pid) == [2, 1, 3, 4])
    }

    @Test("the pid column sorts by number, not by text")
    func pids() {
        let many = [tableRow(pid: 100), tableRow(pid: 9), tableRow(pid: 1_000)]
        #expect(ProcessTable.sorted(many, by: .pid, ascending: true).map(\.pid) == [9, 100, 1_000])
        #expect(ProcessTable.sorted(many, by: .pid, ascending: false).map(\.pid) == [1_000, 100, 9])
    }

    /// The table headers sort through this comparator, so it has to agree with
    /// the pure function underneath it.
    @Test("the comparator the table uses follows the sort order")
    func comparator() {
        #expect(rows.sorted(using: ProcessComparator(key: .cpu, order: .reverse)).map(\.pid) == [4, 3, 2, 1])
        #expect(rows.sorted(using: ProcessComparator(key: .cpu, order: .forward)).map(\.pid) == [2, 3, 4, 1])
        #expect(rows.sorted(using: [ProcessComparator(key: .pid, order: .forward)]).map(\.pid) == [1, 2, 3, 4])
    }

    @Test("the totals add up what the rows report and ignore what they do not")
    func totals() {
        #expect(ProcessTable.totalCPUPercent(rows) == 111.5)
        #expect(ProcessTable.restrictedCount(rows) == 1)
    }
}

@Suite("signal allow-list")
struct ProcessSignalPolicyTests {
    @Test("SIGTERM and SIGKILL to an ordinary process are allowed")
    func allowed() {
        #expect(ProcessSignalPolicy.refusal(pid: 4_242, signal: 15, senderPID: 99) == nil)
        #expect(ProcessSignalPolicy.refusal(pid: 4_242, signal: 9, senderPID: 99) == nil)
    }

    @Test("every other signal is refused")
    func allowList() {
        for signal: Int32 in [0, 1, 2, 3, 6, 10, 17, 19, 30, -9, 64] {
            let refusal = ProcessSignalPolicy.refusal(pid: 4_242, signal: signal, senderPID: 99)
            #expect(refusal?.contains("not allowed") == true, "signal \(signal)")
        }
    }

    @Test("the kernel, launchd and a process group are never signalled")
    func lowPIDs() {
        for pid: Int32 in [1, 0, -1, -4_242] {
            #expect(ProcessSignalPolicy.refusal(pid: pid, signal: 15, senderPID: 99) != nil, "pid \(pid)")
        }
        #expect(ProcessSignalPolicy.refusal(pid: 2, signal: 15, senderPID: 99) == nil)
    }

    @Test("the sender never signals itself")
    func itself() {
        #expect(ProcessSignalPolicy.refusal(pid: 99, signal: 9, senderPID: 99) != nil)
        #expect(ProcessSignalPolicy.refusal(pid: 99, signal: 15, senderPID: 99) != nil)
    }

    /// The refusal comes before the `kill(2)`, so a forbidden call never
    /// reaches the kernel.
    @Test("a refused send does not signal anything")
    func sendRefuses() {
        #expect(ProcessSignalPolicy.send(pid: 1, signal: 15, senderPID: 99)?.contains("launchd") == true)
        #expect(ProcessSignalPolicy.send(pid: 4_242, signal: 2, senderPID: 99)?.contains("not allowed") == true)
    }

    @Test("signal 0 is not a probe this app is allowed to make")
    func noProbe() {
        #expect(ProcessSignalPolicy.refusal(pid: 4_242, signal: 0, senderPID: 99) != nil)
    }
}

@Suite("uid to user name")
struct UserNameCacheTests {
    @Test("a uid is looked up one time")
    func caches() {
        let calls = Mutex(0)
        let cache = UserNameCache { uid in
            calls.withLock { $0 += 1 }
            return uid == 501 ? "serene" : nil
        }
        #expect(cache.name(for: 501) == "serene")
        #expect(cache.name(for: 501) == "serene")
        #expect(cache.name(for: 501) == "serene")
        #expect(calls.withLock { $0 } == 1)
        #expect(cache.count == 1)
    }

    @Test("a uid with no account shows the number, and that answer is kept too")
    func unknownUID() {
        let calls = Mutex(0)
        let cache = UserNameCache { _ in
            calls.withLock { $0 += 1 }
            return nil
        }
        #expect(cache.name(for: 4_294_967_294) == "4294967294")
        #expect(cache.name(for: 4_294_967_294) == "4294967294")
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("this machine knows the name of the user running the test")
    func passwordDatabase() {
        #expect(UserNameCache.passwordDatabase(getuid()) != nil)
        #expect(UserNameCache.passwordDatabase(0) == "root")
        #expect(UserNameCache.shared.name(for: 0) == "root")
    }
}
