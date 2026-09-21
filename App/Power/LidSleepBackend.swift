import AwakeKit
import Foundation

import HelperProtocol

/// What "Stay awake with the lid closed" needs from the privileged helper.
///
/// A protocol for the same reason the assertion has one: a test must be able
/// to drive every path of the controller without a daemon, and without a Mac
/// that cannot sleep for the length of the suite.
protocol LidSleepBackend: Sendable {
    /// The flag and who owns it.
    func report() async throws(HelperConnectionError) -> SleepDisabledReport
    /// Set or clear it. A refusal carries the reason, and the commonest one is
    /// a flag somebody else set with `pmset`.
    func set(_ disabled: Bool) async throws(HelperConnectionError)
}

/// The real one: XPC to the privileged helper, through the same version gate
/// every other privileged call uses.
///
/// An installed helper of another build answers `ping` and then drops the
/// connection on the first method it does not export. This feature is new, so
/// the helper that ships with the previous version of the app does not export
/// it at all, and the gate is what turns that into "Reinstall the helper"
/// instead of "The helper stopped while it was answering".
struct HelperLidSleepBackend: LidSleepBackend {
    private let connection = HelperConnection()

    func report() async throws(HelperConnectionError) -> SleepDisabledReport {
        try checkVersion()
        return try await connection.sleepDisabledState()
    }

    func set(_ disabled: Bool) async throws(HelperConnectionError) {
        try checkVersion()
        try await connection.setSleepDisabled(disabled)
    }

    private func checkVersion() throws(HelperConnectionError) {
        if let reason = HelperGate.shared.blockedReason { throw .refused(reason) }
    }
}
