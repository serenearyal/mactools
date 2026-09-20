import Foundation

import FanControl
import HelperProtocol
import SysMetrics

/// The helper side of the CLI.
///
/// `ventctl` is signed with the same identity as the app and its bundle
/// identifier is in the helper's client requirement, so it reaches the same
/// mach service the app does. It is the fastest way to tell an installation
/// problem from an app problem.
enum HelperCommands {
    static func ping() throws {
        let answer = try blocking { try await connection.ping() }
        print(answer)
        print("client: \(HelperConstants.ventctlBundleIdentifier)")
        print("service: \(HelperConstants.machServiceName)")
    }

    static func read(key: String) throws {
        let data = try blocking { try await connection.readSMCKey(key) }
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("\(key)  \(data.count) bytes  \(hex.isEmpty ? "-" : hex)")
    }

    // MARK: - Processes, for MetricsCommands

    /// The rows of the processes this user does not own, as the helper sees
    /// them with root privileges.
    static func processSnapshot() throws -> [ProcessInfoRow] {
        try blocking { try await connection.processSnapshot() }
    }

    // MARK: - Fans, for FanCommands

    static func fanSnapshot() throws -> FanSnapshot {
        try blocking { try await connection.fanSnapshot() }
    }

    static func setFanMode(_ mode: FanMode, forFan index: Int) throws {
        try blocking { try await connection.setFanMode(mode, forFan: index) }
    }

    static func restoreAllAuto() throws {
        try blocking { try await connection.restoreAllAuto() }
    }

    private static let connection = HelperConnection()

    /// `ventctl` is a synchronous tool: every command runs to the end and
    /// exits. One task and one semaphore is the whole bridge it needs.
    private static func blocking<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                box.value = .success(try await body())
            } catch {
                box.value = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.value {
        case .success(let value):
            return value
        case .failure(let error):
            throw CLIError((error as? any LocalizedError)?.errorDescription ?? "\(error)")
        case nil:
            throw CLIError("the helper call finished without a result")
        }
    }
}

/// Written by the task, read after the semaphore, so no two threads touch it
/// at the same time.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    var value: Result<T, any Error>?
}
