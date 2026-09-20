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
}
