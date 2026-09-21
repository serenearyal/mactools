import Foundation
import os

import HelperProtocol

/// Accepts XPC connections and exports the service on them.
///
/// The signature check is not here: `NSXPCListener` is told the client
/// requirement once in `main.swift`, and XPC validates the peer before this
/// delegate ever runs. A hand-rolled `SecCodeCheckValidity` on the audit token
/// would be the same check, later and with more ways to get it wrong. This
/// delegate wires up the interface and records who got in.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let service: HelperService
    private let log = HelperLog.logger

    init(service: HelperService) {
        self.service = service
        super.init()
    }

    /// Applies the client requirement to a listener. Kept next to the delegate
    /// so both halves of the trust decision are in one file.
    ///
    /// Not called for the anonymous listener of the round-trip test: that one
    /// has no mach service and no signed peer to demand anything of.
    static func applyClientRequirement(to listener: NSXPCListener) {
        listener.setConnectionCodeSigningRequirement(HelperConstants.clientCodeSigningRequirement)
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let pid = connection.processIdentifier
        let uid = connection.effectiveUserIdentifier
        connection.exportedInterface = NSXPCInterface(with: VentHelperProtocol.self)
        connection.exportedObject = service

        // Restore guarantee 1: the fans and the system sleep setting belong to
        // the clients, and the last one to leave takes the fans back to Auto
        // and lets this Mac sleep again. XPC can call both handlers for one
        // connection, and the registries ignore the second.
        let service = self.service
        let tokens = service.clientArrived()
        let gone: @Sendable () -> Void = { [log] in
            log.info("client pid \(pid, privacy: .public) gone")
            service.clientLeft(tokens)
        }
        connection.invalidationHandler = gone
        connection.interruptionHandler = gone

        connection.resume()
        log.info("client pid \(pid, privacy: .public) uid \(uid, privacy: .public) accepted")
        return true
    }
}
