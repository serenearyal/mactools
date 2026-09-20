import Foundation

/// The XPC interface of the privileged helper.
///
/// `NSXPCConnection` needs an `@objc` protocol whose methods return nothing and
/// answer through a reply block. A failure travels as text in that block: a
/// reply block cannot throw, and an `NSError` over the wire would need a class
/// allowlist on both sides for no gain.
@objc public protocol VentHelperProtocol {
    /// `pong <version> uid=<euid>`: the cheapest proof that the connection is
    /// up, the signature passed and the helper runs as root.
    func ping(reply: @escaping @Sendable (String) -> Void)

    /// Marketing version and build of the running helper binary. The app
    /// compares it with its own to spot a stale legacy install.
    func helperVersion(reply: @escaping @Sendable (String) -> Void)

    /// The raw bytes of one SMC key, or nil with the reason.
    func readSMCKey(_ key: String, reply: @escaping @Sendable (Data?, String?) -> Void)

    /// `FanSnapshot` as JSON, or nil with the reason.
    ///
    /// JSON and not a payload class: `NSSecureCoding` would need a class, a
    /// hand-written coder and an allowlist on both sides to carry three
    /// numbers and an enum.
    func fanSnapshot(reply: @escaping @Sendable (Data?, String?) -> Void)

    /// Sets one fan to a `FanMode` encoded as JSON. The reply is the reason it
    /// did not happen, or nil.
    func setFanMode(fanIndex: Int, modeJSON: Data, reply: @escaping @Sendable (String?) -> Void)

    /// Every fan back to the firmware curve. The one call that must always
    /// work, so it reports a problem but never refuses to try.
    func restoreAllAuto(reply: @escaping @Sendable (String?) -> Void)

    /// `[ProcessInfoRow]` as JSON for the processes the calling user does not
    /// own, or nil with the reason.
    ///
    /// Those are the rows libproc refuses the app with EPERM, and they are the
    /// only ones worth sending: the client already has its own, and a full
    /// table would double a 580-row payload every three seconds.
    ///
    /// `excludingUID` is what the client believes its uid is. The helper
    /// filters by the uid of the XPC connection and never by this number; a
    /// mismatch is logged. The argument stays because a mismatch is worth
    /// seeing in the log of a machine where something is wrong.
    ///
    /// The helper keeps its own CPU baselines, so the first snapshot after the
    /// helper starts reports nil CPU for every row, exactly as the app's own
    /// first pass does.
    func processSnapshot(excludingUID: UInt32, reply: @escaping @Sendable (Data?, String?) -> Void)

    /// Sends SIGTERM or SIGKILL to a process the calling user cannot signal
    /// itself. The reply is the reason it did not happen, or nil.
    ///
    /// Only those two signals, never pid 0 or 1, and never the helper itself.
    /// Every call is logged, granted or refused.
    func signalProcess(pid: Int32, signal: Int32, reply: @escaping @Sendable (String?) -> Void)
}
