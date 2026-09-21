import Foundation
import XCTest

import FanControl
import HelperProtocol
import SysMetrics

/// A real XPC round trip against the real service object.
///
/// The installed daemon needs an admin approval that a test run cannot give,
/// so the test hosts `HelperService` on `NSXPCListener.anonymous()` and talks
/// to it through a real `NSXPCConnection`. That covers the interface, the
/// delegate, the reply blocks and the privilege gate; what it cannot cover is
/// launchd and the mach service name.
///
/// `requiresRoot: true`, which is what the daemon demands, over fans that
/// exist only in this process. No test in this bundle can reach the SMC fans
/// of the machine: `HelperService.daemon()` is the only thing that builds
/// them, and it lives in a file the test target does not compile.
final class HelperXPCTests: XCTestCase {
    private var listener: NSXPCListener!
    private var delegate: HelperListenerDelegate!
    private var connection: NSXPCConnection!

    override func setUp() {
        super.setUp()
        let service = HelperService(
            fanHardware: InMemoryFanHardware.macBookPro(),
            requiresRoot: true
        )
        delegate = HelperListenerDelegate(service: service)
        listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()

        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: VentHelperProtocol.self)
        connection.resume()
    }

    override func tearDown() {
        connection.invalidate()
        listener.invalidate()
        connection = nil
        listener = nil
        delegate = nil
        super.tearDown()
    }

    private func proxy() throws -> any VentHelperProtocol {
        let raw = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("XPC connection error: \(error)")
        }
        return try XCTUnwrap(raw as? any VentHelperProtocol)
    }

    func testPingAnswersWithVersionAndUID() throws {
        let answered = expectation(description: "ping")
        let inbox = Inbox<String>()
        try proxy().ping {
            inbox.put($0)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)

        let reply = try XCTUnwrap(inbox.value)
        let parts = reply.split(separator: " ")
        XCTAssertEqual(parts.count, 3, reply)
        XCTAssertEqual(parts.first, "pong")
        XCTAssertEqual(parts.last, "uid=\(geteuid())")
        // The test bundle carries no helper version of its own, so only the
        // shape of the middle field is checked here.
        XCTAssertTrue(parts[1].contains("+"), reply)
    }

    func testHelperVersionIsReported() throws {
        let answered = expectation(description: "version")
        let inbox = Inbox<String>()
        try proxy().helperVersion {
            inbox.put($0)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        XCTAssertFalse(try XCTUnwrap(inbox.value).isEmpty)
    }

    /// The test process is not root, so every privileged call must come back
    /// with a reason and no data. This gate is what keeps a helper started by
    /// hand from looking as if it worked.
    func testReadSMCKeyIsRefusedWithoutRoot() throws {
        try XCTSkipIf(geteuid() == 0, "the privilege gate only refuses a non-root helper")
        let answered = expectation(description: "read")
        let inbox = Inbox<ReadReply>()
        try proxy().readSMCKey("F0Ac") { data, error in
            inbox.put(ReadReply(data: data, error: error))
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)

        let reply = try XCTUnwrap(inbox.value)
        XCTAssertNil(reply.data)
        XCTAssertEqual(reply.error?.contains("not running as root"), true, reply.error ?? "no message")
    }

    /// The system sleep setting is root-only like the rest: a helper started
    /// by hand must not look as if it worked.
    func testTheSleepSettingIsRefusedWithoutRoot() throws {
        try XCTSkipIf(geteuid() == 0, "the privilege gate only refuses a non-root helper")
        let answered = expectation(description: "set sleep")
        let inbox = Inbox<String?>()
        try proxy().setSleepDisabled(true) {
            inbox.put($0)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        XCTAssertEqual((inbox.value ?? nil)?.contains("not running as root"), true)
    }

    func testAnInvalidKeyIsRefusedPastTheGate() throws {
        try XCTSkipIf(geteuid() != 0, "an invalid key is only reached past the privilege gate")
        let answered = expectation(description: "read")
        let inbox = Inbox<ReadReply>()
        try proxy().readSMCKey("nope!") { data, error in
            inbox.put(ReadReply(data: data, error: error))
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)

        let reply = try XCTUnwrap(inbox.value)
        XCTAssertEqual(reply.error?.contains("four-character"), true, reply.error ?? "no message")
    }
}

/// The three fan methods over the same anonymous listener, with fans that
/// exist only in this process.
///
/// The service is built with `requiresRoot: false` here, which is the one
/// thing the daemon never does: `HelperService.daemon()` always demands root.
/// That is what lets a normal user run the whole XPC path, the JSON payloads
/// and the governor rules without a daemon and without a fan.
final class HelperFanXPCTests: XCTestCase {
    private var listener: NSXPCListener!
    private var delegate: HelperListenerDelegate!
    private var connection: NSXPCConnection!
    private var hardware: InMemoryFanHardware!

    override func setUp() {
        super.setUp()
        hardware = InMemoryFanHardware.macBookPro()
        let service = HelperService(fanHardware: hardware, requiresRoot: false)
        service.fans?.startWithAutoRestore()
        delegate = HelperListenerDelegate(service: service)
        listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()

        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: VentHelperProtocol.self)
        connection.resume()
    }

    override func tearDown() {
        connection.invalidate()
        listener.invalidate()
        connection = nil
        listener = nil
        delegate = nil
        hardware = nil
        super.tearDown()
    }

    private func proxy() throws -> any VentHelperProtocol {
        let raw = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("XPC connection error: \(error)")
        }
        return try XCTUnwrap(raw as? any VentHelperProtocol)
    }

    private func snapshot() throws -> FanSnapshot {
        let answered = expectation(description: "snapshot")
        let inbox = Inbox<ReadReply>()
        try proxy().fanSnapshot { data, error in
            inbox.put(ReadReply(data: data, error: error))
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        let reply = try XCTUnwrap(inbox.value)
        XCTAssertNil(reply.error)
        return try XCTUnwrap(FanSnapshot(json: try XCTUnwrap(reply.data)))
    }

    @discardableResult
    private func setMode(_ mode: FanMode, fan index: Int) throws -> String? {
        let answered = expectation(description: "set mode")
        let inbox = Inbox<String?>()
        try proxy().setFanMode(fanIndex: index, modeJSON: try XCTUnwrap(mode.jsonData)) {
            inbox.put($0)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        return inbox.value ?? nil
    }

    func testSnapshotDescribesBothFans() throws {
        let snapshot = try snapshot()
        XCTAssertEqual(snapshot.fans.map(\.name), ["Left fan", "Right fan"])
        XCTAssertEqual(snapshot.fans[0].minimumRPM, 1200)
        XCTAssertTrue(snapshot.isAllAuto)
        XCTAssertFalse(snapshot.interlockEngaged)
    }

    func testAConstantModeCrossesTheWireAndReachesTheFan() throws {
        XCTAssertNil(try setMode(.constant(rpm: 2500), fan: 0))
        XCTAssertEqual(hardware.fans[0].target, 2500)
        XCTAssertTrue(hardware.fans[0].manual)

        let snapshot = try snapshot()
        XCTAssertEqual(snapshot.fans[0].mode, .constant(rpm: 2500))
        XCTAssertEqual(snapshot.fans[0].hardwareMode, .forced)
        XCTAssertFalse(snapshot.isAllAuto)
    }

    func testAnOutOfRangeRequestIsClamped() throws {
        XCTAssertNil(try setMode(.constant(rpm: 99_999), fan: 1))
        XCTAssertEqual(hardware.fans[1].target, 6241)
    }

    func testRestoreAllAutoPutsEveryFanBack() throws {
        try setMode(.constant(rpm: 3000), fan: 0)
        try setMode(.curve(sensorKey: "Tp01", startTemp: 45, maxTemp: 85), fan: 1)

        let answered = expectation(description: "restore")
        let inbox = Inbox<String?>()
        try proxy().restoreAllAuto {
            inbox.put($0)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)

        XCTAssertNil(inbox.value ?? nil)
        XCTAssertTrue(hardware.fans.allSatisfy { !$0.manual && $0.target == 0 })
        XCTAssertTrue(try snapshot().isAllAuto)
    }

    func testAModeTheHelperCannotDecodeIsRefused() throws {
        let answered = expectation(description: "bad mode")
        let inbox = Inbox<String?>()
        try proxy().setFanMode(fanIndex: 0, modeJSON: Data("not json".utf8)) {
            inbox.put($0)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        XCTAssertEqual((inbox.value ?? nil)?.contains("could not be decoded"), true)
    }

    /// Restore guarantee 1, over a real connection: the last client to leave
    /// takes the fans with it. This is what makes `kill -9` of the app safe.
    func testTheLastClientLeavingRestoresAuto() throws {
        try setMode(.constant(rpm: 3200), fan: 0)
        XCTAssertTrue(hardware.fans[0].manual)

        connection.invalidate()

        let restored = expectation(description: "fans back on auto")
        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [hardware] timer in
            guard let hardware, hardware.fans.allSatisfy({ !$0.manual }) else { return }
            timer.invalidate()
            restored.fulfill()
        }
        wait(for: [restored], timeout: 5)
        poll.invalidate()

        // A new connection sees fans that are on Auto and hold no mode.
        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: VentHelperProtocol.self)
        connection.resume()
        XCTAssertTrue(try snapshot().isAllAuto)
    }
}

/// The system sleep setting over the same anonymous listener, against a flag
/// that exists only in this process.
///
/// `InMemorySleepSwitch` is the whole point: the real setting is what
/// `sudo pmset disablesleep 1` writes, and a test that wrote it would leave
/// the machine running the suite unable to sleep. `HelperService.daemon()` is
/// the only thing that builds the real one, and it lives in a file this target
/// does not compile.
final class HelperSleepXPCTests: XCTestCase {
    private var listener: NSXPCListener!
    private var delegate: HelperListenerDelegate!
    private var connection: NSXPCConnection!
    private var power: InMemorySleepSwitch!
    private var marker: InMemorySleepDisabledMarker!

    private func start(flag: Bool = false, marked: Bool = false) {
        power = InMemorySleepSwitch(disabled: flag)
        marker = InMemorySleepDisabledMarker(marked: marked)
        let service = HelperService(
            fanHardware: InMemoryFanHardware.macBookPro(),
            sleep: SleepDisabledGovernor(power: power, marker: marker),
            requiresRoot: false
        )
        delegate = HelperListenerDelegate(service: service)
        listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()

        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: VentHelperProtocol.self)
        connection.resume()
    }

    override func tearDown() {
        connection?.invalidate()
        listener?.invalidate()
        connection = nil
        listener = nil
        delegate = nil
        power = nil
        marker = nil
        super.tearDown()
    }

    private func proxy() throws -> any VentHelperProtocol {
        let raw = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("XPC connection error: \(error)")
        }
        return try XCTUnwrap(raw as? any VentHelperProtocol)
    }

    private func report() throws -> SleepDisabledReport {
        let answered = expectation(description: "sleep state")
        let inbox = Inbox<ReadReply>()
        try proxy().sleepDisabledState { data, error in
            inbox.put(ReadReply(data: data, error: error))
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        let reply = try XCTUnwrap(inbox.value)
        XCTAssertNil(reply.error)
        return try JSONDecoder().decode(SleepDisabledReport.self, from: try XCTUnwrap(reply.data))
    }

    @discardableResult
    private func set(_ disabled: Bool) throws -> String? {
        let answered = expectation(description: "set sleep")
        let inbox = Inbox<String?>()
        try proxy().setSleepDisabled(disabled) {
            inbox.put($0)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        return inbox.value ?? nil
    }

    func testTheFlagCrossesTheWireAndComesBackOff() throws {
        start()
        XCTAssertEqual(try report(), SleepDisabledReport.clear)

        XCTAssertNil(try set(true))
        XCTAssertTrue(power.value)
        XCTAssertEqual(try report(), SleepDisabledReport(isSet: true, setByVent: true))
        XCTAssertEqual(try report().owner, .vent)

        XCTAssertNil(try set(false))
        XCTAssertFalse(power.value)
        XCTAssertFalse(marker.isMarked)
    }

    /// The user's own `pmset disablesleep 1`. Vent reports it and stops there.
    func testAFlagSomebodyElseSetIsRefusedOverTheWire() throws {
        start(flag: true)
        XCTAssertEqual(try report().owner, .somebodyElse)
        XCTAssertEqual(try set(true), SleepDisabledPolicy.foreignMessage)
        XCTAssertEqual(try set(false), SleepDisabledPolicy.foreignMessage)
        XCTAssertTrue(power.value, "the user's own setting is untouched")
        XCTAssertEqual(power.writes, 0)
    }

    /// Restore guarantee 1 for the sleep setting, over a real connection: this
    /// is what makes a `kill -9` of Vent safe, and it is the reason a Mac
    /// cannot be left unable to sleep by a crash.
    func testTheLastClientLeavingLetsThisMacSleepAgain() throws {
        start()
        XCTAssertNil(try set(true))
        XCTAssertTrue(power.value)

        connection.invalidate()

        let cleared = expectation(description: "the flag came off")
        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [power] timer in
            guard let power, !power.value else { return }
            timer.invalidate()
            cleared.fulfill()
        }
        wait(for: [cleared], timeout: 5)
        poll.invalidate()
        XCTAssertFalse(marker.isMarked)
    }

    /// A helper that has no business writing the setting says so instead of
    /// pretending it worked.
    func testAServiceWithoutSleepControlSaysSo() throws {
        power = InMemorySleepSwitch()
        marker = InMemorySleepDisabledMarker()
        let service = HelperService(fanHardware: InMemoryFanHardware.macBookPro(), requiresRoot: false)
        delegate = HelperListenerDelegate(service: service)
        listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: VentHelperProtocol.self)
        connection.resume()

        XCTAssertEqual(try set(true)?.contains("does not control the sleep setting"), true)
    }
}

/// The two process methods over the same anonymous listener.
///
/// `requiresRoot: false` again, so the whole path runs as a normal user: the
/// snapshot then carries the rows of the other users with empty counters,
/// which is exactly the shape the app merges. What only a real daemon can
/// show is the counters themselves.
final class HelperProcessXPCTests: XCTestCase {
    private var listener: NSXPCListener!
    private var delegate: HelperListenerDelegate!
    private var connection: NSXPCConnection!
    private var children: [Process] = []

    override func setUp() {
        super.setUp()
        let service = HelperService(fanHardware: InMemoryFanHardware.macBookPro(), requiresRoot: false)
        delegate = HelperListenerDelegate(service: service)
        listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()

        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: VentHelperProtocol.self)
        connection.resume()
    }

    override func tearDown() {
        for child in children where child.isRunning { child.terminate() }
        children = []
        connection.invalidate()
        listener.invalidate()
        connection = nil
        listener = nil
        delegate = nil
        super.tearDown()
    }

    private func proxy() throws -> any VentHelperProtocol {
        let raw = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("XPC connection error: \(error)")
        }
        return try XCTUnwrap(raw as? any VentHelperProtocol)
    }

    private func snapshot(excludingUID uid: UInt32 = geteuid()) throws -> [ProcessInfoRow] {
        let answered = expectation(description: "process snapshot")
        let inbox = Inbox<ReadReply>()
        try proxy().processSnapshot(excludingUID: uid) { data, error in
            inbox.put(ReadReply(data: data, error: error))
            answered.fulfill()
        }
        wait(for: [answered], timeout: 10)
        let reply = try XCTUnwrap(inbox.value)
        XCTAssertNil(reply.error)
        return try JSONDecoder().decode([ProcessInfoRow].self, from: try XCTUnwrap(reply.data))
    }

    private func signal(pid: Int32, signal number: Int32) throws -> String? {
        let answered = expectation(description: "signal")
        let inbox = Inbox<String?>()
        try proxy().signalProcess(pid: pid, signal: number) {
            inbox.put($0)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        return inbox.value ?? nil
    }

    /// Starts a child this test owns, so nothing else on the machine is ever
    /// the target of a signal here.
    private func startChild() throws -> Int32 {
        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["600"]
        try child.run()
        children.append(child)
        return child.processIdentifier
    }

    func testTheSnapshotHasRowsAndNoneOfThemBelongToTheCaller() throws {
        let rows = try snapshot()
        XCTAssertFalse(rows.isEmpty)
        XCTAssertFalse(rows.contains { $0.uid == geteuid() }, "the caller's own rows are the client's job")
        // The rows the app cannot read are the point of the call: root owns
        // most of them on any running Mac.
        XCTAssertTrue(rows.contains { $0.uid == 0 })
        XCTAssertTrue(rows.allSatisfy { $0.pid >= 0 })
    }

    /// The uid the client claims is only a hint; the connection decides. A
    /// client that asked for root to be excluded still gets no row of its own.
    func testTheClaimedUIDDoesNotChangeWhatIsExcluded() throws {
        let rows = try snapshot(excludingUID: 0)
        XCTAssertFalse(rows.contains { $0.uid == geteuid() })
        XCTAssertTrue(rows.contains { $0.uid == 0 })
    }

    /// The documented first-call behaviour, and the reason the helper keeps a
    /// sampler of its own: a CPU percent is a delta between two calls.
    func testTheFirstSnapshotHasNoCPUPercentAndTheNextOneDoes() throws {
        let first = try snapshot()
        XCTAssertTrue(first.allSatisfy { $0.cpuPercent == nil }, "a first sample has nothing to compare against")

        Thread.sleep(forTimeInterval: 0.5)
        let starts = Dictionary(first.map { ($0.pid, $0.startAbsoluteTime) }, uniquingKeysWith: { first, _ in first })
        let second = try snapshot()
        XCTAssertFalse(second.isEmpty)
        // Only the rows that were there the first time and gave up their
        // counters: a process that started in between has no baseline either.
        let comparable = second.filter { $0.cpuNanoseconds != nil && starts[$0.pid] == $0.startAbsoluteTime }
        XCTAssertTrue(comparable.allSatisfy { $0.cpuPercent != nil })
    }

    func testLaunchdIsNeverSignalled() throws {
        let refusal = try XCTUnwrap(try signal(pid: 1, signal: SIGTERM))
        XCTAssertTrue(refusal.contains("launchd"), refusal)
        // EPERM, not ESRCH: launchd is there, and a test that is not root may
        // not signal it. Either answer means the process still exists.
        XCTAssertTrue(kill(1, 0) == 0 || errno == EPERM, "launchd is still there")
    }

    func testTheHelperDoesNotKillItself() throws {
        let refusal = try XCTUnwrap(try signal(pid: getpid(), signal: SIGKILL))
        XCTAssertTrue(refusal.contains("\(getpid())"), refusal)
    }

    func testASignalOutsideTheAllowListIsRefused() throws {
        let pid = try startChild()
        for number: Int32 in [SIGSTOP, SIGHUP, SIGINT, 0] {
            let refusal = try XCTUnwrap(try signal(pid: pid, signal: number), "signal \(number)")
            XCTAssertTrue(refusal.contains("not allowed"), refusal)
        }
        XCTAssertEqual(kill(pid, 0), 0, "the child is untouched")
    }

    func testAChildOfTheTestIsTerminated() throws {
        let pid = try startChild()
        XCTAssertNil(try signal(pid: pid, signal: SIGTERM))

        let gone = expectation(description: "the child ended")
        let child = try XCTUnwrap(children.first { $0.processIdentifier == pid })
        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            guard !child.isRunning else { return }
            timer.invalidate()
            gone.fulfill()
        }
        wait(for: [gone], timeout: 5)
        poll.invalidate()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
    }
}

private struct ReadReply: Sendable {
    let data: Data?
    let error: String?
}

/// The reply lands on an XPC queue and is read on the test thread, so it goes
/// through a lock.
private final class Inbox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    func put(_ value: T) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: T? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
