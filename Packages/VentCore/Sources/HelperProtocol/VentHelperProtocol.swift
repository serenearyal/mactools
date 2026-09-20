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
}
