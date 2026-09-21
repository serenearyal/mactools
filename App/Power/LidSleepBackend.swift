import AwakeKit
import Foundation

import HelperProtocol

/// What "Stay awake with the lid closed" needs from the privileged helper.
///
/// A protocol for the same reason the assertion has one: a test must be able
/// to drive every path of the controller without a daemon, and without a Mac
/// that cannot sleep for the length of the suite.
protocol LidSleepBackend: LidSleepPort {
    /// The flag and who owns it.
    func report() async throws(HelperConnectionError) -> SleepDisabledReport
    /// Set or clear it. A refusal carries the reason, and the commonest one is
    /// a flag somebody else set with `pmset`.
    func set(_ disabled: Bool) async throws(HelperConnectionError)
}

/// The two calls above, as the reconciler wants them: no typed errors and no
/// XPC in the signature, so the sequencing and the retries are testable
/// against a fake that never touches this Mac.
extension LidSleepBackend {
    func write(_ on: Bool) async -> String? {
        do {
            try await set(on)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func readBack() async -> LidSleepFacts? {
        guard let report = try? await report() else { return nil }
        return LidSleepFacts(flagSet: report.isSet, isOurs: report.setByVent)
    }
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
