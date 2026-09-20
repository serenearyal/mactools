import Foundation
import Synchronization

/// Whether the installed helper is the one this app can talk to.
///
/// An installed helper of another version answers `ping` and then kills the
/// connection on the first method it does not export, which reaches the user as
/// "The helper stopped while it was answering". So the version mismatch is
/// checked once, by `HelperController`, and recorded here; the fan and the
/// process backends read it before every call and fail fast with the one
/// message that says what to do about it.
///
/// A shared value and not an injected dependency: the two backends live off the
/// main actor, they each own their own `HelperConnection`, and the answer is
/// one immutable string that changes only when the helper is installed again.
final class HelperGate: Sendable {
    static let shared = HelperGate()

    private let refusal = Mutex<String?>(nil)

    /// The reason not to call the helper, or nil when it is safe to call.
    var blockedReason: String? { refusal.withLock { $0 } }

    func block(installed: String, expected: String) {
        refusal.withLock { $0 = HelperGate.mismatchMessage(installed: installed, expected: expected) }
    }

    func allow() {
        refusal.withLock { $0 = nil }
    }

    /// The one wording for the banner, the popover, the Settings tab and every
    /// call that refuses to go out.
    static func mismatchMessage(installed: String, expected: String) -> String {
        "The installed helper is v \(installed), this app needs v \(expected) - press Reinstall in Settings"
    }
}
