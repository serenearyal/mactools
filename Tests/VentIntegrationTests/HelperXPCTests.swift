import Foundation
import XCTest

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
