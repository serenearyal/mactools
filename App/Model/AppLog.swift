import os

import HelperProtocol

/// Every logger the app uses, in one place.
///
/// One subsystem, `com.serenearyal.mactools`, shared with the privileged helper,
/// so `log stream --predicate 'subsystem == "com.serenearyal.mactools"'` shows both
/// sides of a call. The categories are the features: `app` for the lifecycle,
/// `helper` for the daemon and its installers, `fans`, `lock`, `scan` and
/// `procs`.
///
/// Privacy is not a formality here. A file path or a process name says what
/// the user is working on, so both are logged `.private` and stay redacted
/// unless the user streams the log themselves. States, counters and error
/// messages are `.public`, because a redacted error is a bug report nobody can
/// read.
enum AppLog {
    /// Launch, termination and everything that belongs to no single feature.
    static let app = logger(category: "app")
    /// The privileged helper: its state, the installers and the XPC link.
    static let helper = logger(category: "helper")
    /// Fan modes, re-applied wishes and restores. The helper logs the other
    /// half of every line under the same category.
    static let fans = logger(category: "fans")
    static let lock = logger(category: "lock")
    /// The window manager: what was moved where, and which chord was taken.
    static let windows = logger(category: "windows")
    static let scan = logger(category: "scan")
    static let procs = logger(category: "procs")

    private static func logger(category: String) -> Logger {
        Logger(subsystem: HelperConstants.appBundleIdentifier, category: category)
    }
}
