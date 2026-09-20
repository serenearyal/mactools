import Foundation
import XCTest

import FanControl
import HelperProtocol

/// A real XPC round trip against the real service object.
///
/// The installed daemon needs an admin approval that a test run cannot give,
/// so the test hosts `HelperService` on `NSXPCListener.anonymous()` and talks
/// to it through a real `NSXPCConnection`. That covers the interface, the
/// delegate, the reply blocks and the privilege gate; what it cannot cover is
/// launchd and the mach service name.
final class HelperXPCTests: XCTestCase {
    private var listener: NSXPCListener!
    private var delegate: HelperListenerDelegate!
    private var connection: NSXPCConnection!

    override func setUp() {
        super.setUp()
        delegate = HelperListenerDelegate(service: HelperService())
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
/// thing the daemon never does: `HelperService()` always demands root. That
/// is what lets a normal user run the whole XPC path, the JSON payloads and
/// the governor rules without a daemon and without a fan.
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
