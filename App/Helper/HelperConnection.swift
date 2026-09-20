import FanControl
import Foundation

import HelperProtocol
import SysMetrics

enum HelperConnectionError: Error, LocalizedError, Equatable, Sendable {
    /// The connection failed: no daemon, a signature that does not match the
    /// requirement, or the helper died mid-call.
    case unavailable(String)
    /// The helper answered, and the answer is a refusal.
    case refused(String)
    /// No answer in time. Without this the UI would wait for ever on a mach
    /// service that launchd cannot start.
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .refused(let message): message
        case .timedOut: "The helper did not answer in time."
        }
    }
}

/// The client side of the XPC link to the privileged helper.
///
/// An actor, not a `@MainActor` class, so `ventctl` can use the same code as
/// the app. The connection is made on first use and thrown away on
/// invalidation, so a helper that is installed, killed or restarted while the
/// app runs needs no restart of the app: the next call reconnects.
actor HelperConnection {
    private var connection: NSXPCConnection?
    /// Counts the connections this actor has made, so a handler can tell
    /// whether it speaks for the current one.
    private var generation = 0
    private let requirement: String
    private let timeout: Duration

    init(
        requirement: String = HelperConstants.helperCodeSigningRequirement,
        timeout: Duration = .seconds(5)
    ) {
        self.requirement = requirement
        self.timeout = timeout
    }

    /// Drops the connection. The next call opens a new one.
    func disconnect() {
        guard let connection else { return }
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
        self.connection = nil
    }

    // MARK: - Calls

    func ping() async throws(HelperConnectionError) -> String {
        try await call { proxy, done in proxy.ping { done(.success($0)) } }
    }

    func helperVersion() async throws(HelperConnectionError) -> String {
        try await call { proxy, done in proxy.helperVersion { done(.success($0)) } }
    }

    func readSMCKey(_ key: String) async throws(HelperConnectionError) -> Data {
        try await call { proxy, done in
            proxy.readSMCKey(key) { data, error in
                if let data {
                    done(.success(data))
                } else {
                    done(.failure(.refused(error ?? "the helper returned no data and no reason")))
                }
            }
        }
    }

    // MARK: - Fans

    func fanSnapshot() async throws(HelperConnectionError) -> FanSnapshot {
        let data: Data = try await call { proxy, done in
            proxy.fanSnapshot { data, error in
                if let data {
                    done(.success(data))
                } else {
                    done(.failure(.refused(error ?? "the helper returned no fan state and no reason")))
                }
            }
        }
        guard let snapshot = FanSnapshot(json: data) else {
            throw .refused("the helper sent fan state this app cannot read")
        }
        return snapshot
    }

    func setFanMode(_ mode: FanMode, forFan index: Int) async throws(HelperConnectionError) {
        guard let json = mode.jsonData else {
            throw .refused("the fan mode could not be encoded")
        }
        try await callVoid { proxy, done in
            proxy.setFanMode(fanIndex: index, modeJSON: json) { done($0) }
        }
    }

    func restoreAllAuto() async throws(HelperConnectionError) {
        try await callVoid { proxy, done in
            proxy.restoreAllAuto { done($0) }
        }
    }

    // MARK: - Processes

    /// The rows of the processes this user does not own, with the counters
    /// libproc refuses an unprivileged pass. The helper filters by the uid of
    /// the connection; the argument only tells it what this side believes.
    func processSnapshot(excludingUID uid: uid_t = getuid()) async throws(HelperConnectionError) -> [ProcessInfoRow] {
        let data: Data = try await call { proxy, done in
            proxy.processSnapshot(excludingUID: UInt32(uid)) { data, error in
                if let data {
                    done(.success(data))
                } else {
                    done(.failure(.refused(error ?? "the helper returned no process list and no reason")))
                }
            }
        }
        guard let rows = try? JSONDecoder().decode([ProcessInfoRow].self, from: data) else {
            throw .refused("the helper sent a process list this app cannot read")
        }
        return rows
    }

    func signalProcess(pid: Int32, signal: ProcessSignal) async throws(HelperConnectionError) {
        try await callVoid { proxy, done in
            proxy.signalProcess(pid: pid, signal: signal.rawValue) { done($0) }
        }
    }

    // MARK: - Plumbing

    /// Runs one XPC call and returns the first of the reply, the connection
    /// error and the timeout. `NSXPCConnection` may call both the reply block
    /// and the error handler, so the result goes through a one-shot box.
    private func call<T: Sendable>(
        _ body: (any VentHelperProtocol, @escaping @Sendable (Result<T, HelperConnectionError>) -> Void) -> Void
    ) async throws(HelperConnectionError) -> T {
        let connection = activeConnection()
        let outcome: Result<T, HelperConnectionError> = await withCheckedContinuation { continuation in
            let box = OneShot(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                box.deliver(.failure(.unavailable(Self.message(for: error))))
            }
            guard let proxy = proxy as? any VentHelperProtocol else {
                box.deliver(.failure(.unavailable("the helper connection exports no usable proxy")))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) {
                box.deliver(.failure(.timedOut))
            }
            body(proxy, { box.deliver($0) })
        }
        switch outcome {
        case .success(let value):
            return value
        case .failure(let error):
            // A dead connection stays dead; make the next call build a new one.
            if case .unavailable = error { disconnect() }
            throw error
        }
    }

    /// The same, for the calls whose whole reply is "why not", where nil means
    /// it worked.
    private func callVoid(
        _ body: (any VentHelperProtocol, @escaping @Sendable (String?) -> Void) -> Void
    ) async throws(HelperConnectionError) {
        _ = try await call { (proxy, done: @escaping @Sendable (Result<Bool, HelperConnectionError>) -> Void) in
            body(proxy) { reason in
                done(reason.map { .failure(.refused($0)) } ?? .success(true))
            }
        }
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }
        generation += 1
        let connection = NSXPCConnection(
            machServiceName: HelperConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: VentHelperProtocol.self)
        // Refuse to talk to anything but our own signed helper. The string is
        // unit tested against SecRequirementCreateWithString, because a
        // malformed one raises an Objective-C exception right here.
        connection.setCodeSigningRequirement(requirement)
        // Explicitly @Sendable: XPC calls these from its own queue, and a
        // closure formed in an actor would otherwise be isolated to it. The
        // generation keeps a late handler from throwing away the connection
        // that replaced the one it belongs to.
        let mine = generation
        let onGone: @Sendable () -> Void = { [weak self] in
            Task { await self?.forget(generation: mine) }
        }
        connection.invalidationHandler = onGone
        connection.interruptionHandler = onGone
        connection.resume()
        self.connection = connection
        return connection
    }

    /// The helper went away by itself. Keep no handle to a dead connection.
    private func forget(generation gone: Int) {
        guard gone == generation else { return }
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection = nil
    }

    /// `NSXPCConnectionCodeSigningRequirementFailure`, which the Swift overlay
    /// does not name.
    private static let codeSigningFailure = 4102

    private static func message(for error: any Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return error.localizedDescription }
        return switch nsError.code {
        case CocoaError.Code.xpcConnectionInvalid.rawValue:
            "The helper is not installed, or launchd has no job for it."
        case CocoaError.Code.xpcConnectionInterrupted.rawValue:
            "The helper stopped while it was answering."
        case codeSigningFailure:
            "The installed helper does not match the expected signature."
        default:
            error.localizedDescription
        }
    }
}

/// Delivers the first result and ignores every later one, so a continuation is
/// never resumed twice.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<T, HelperConnectionError>, Never>?

    init(_ continuation: CheckedContinuation<Result<T, HelperConnectionError>, Never>) {
        self.continuation = continuation
    }

    func deliver(_ result: Result<T, HelperConnectionError>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}

extension Duration {
    /// Seconds as a `Double`, for the GCD deadline of the timeout.
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
