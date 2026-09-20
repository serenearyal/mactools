import Darwin
import Foundation

/// The only two signals this app ever sends.
///
/// Quit gives the process its usual chance to save and exit; Force Quit does
/// not. Nothing else is offered, so nothing else has to be reasoned about.
public enum ProcessSignal: Int32, CaseIterable, Sendable {
    case terminate = 15
    case kill = 9

    public var title: String {
        switch self {
        case .terminate: "Quit"
        case .kill: "Force Quit"
        }
    }

    public var name: String {
        switch self {
        case .terminate: "SIGTERM"
        case .kill: "SIGKILL"
        }
    }
}

/// Who may be signalled, and with what.
///
/// Pure, and shared by the app and the privileged helper: the app signals the
/// processes of its own user directly, the helper signals the rest as root,
/// and both go through the same three rules.
public enum ProcessSignalPolicy {
    /// The reason this signal must not be sent, or nil when it may go out.
    public static func refusal(pid: Int32, signal: Int32, senderPID: Int32) -> String? {
        guard let allowed = ProcessSignal(rawValue: signal) else {
            let list = ProcessSignal.allCases
                .map { "\($0.name) (\($0.rawValue))" }
                .joined(separator: " and ")
            return "signal \(signal) is not allowed; only \(list) are"
        }
        // pid 0 is the kernel and pid 1 is launchd. Signalling either takes
        // the machine down, and a negative pid is a whole process group.
        guard pid > 1 else {
            return "pid \(pid) is the kernel or launchd, which must never be signalled"
        }
        guard pid != senderPID else {
            return "pid \(pid) is the process that would send the \(allowed.name)"
        }
        return nil
    }

    /// Sends the signal, or answers why it did not. `kill(2)`, so the reply is
    /// the errno text: "Operation not permitted" is the one the helper exists
    /// to avoid.
    public static func send(pid: Int32, signal: Int32, senderPID: Int32 = getpid()) -> String? {
        if let refusal = refusal(pid: pid, signal: signal, senderPID: senderPID) { return refusal }
        guard kill(pid, signal) != 0 else { return nil }
        return String(cString: strerror(errno))
    }
}
