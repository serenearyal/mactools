import Darwin
import Foundation
import os

import HelperProtocol
import SMCKit

/// The one logger of the helper process.
///
/// `log stream --predicate 'subsystem == "com.serenearyal.vent"'` shows the app
/// and the helper together, which is what a fan bug needs.
enum HelperLog {
    static let logger = Logger(subsystem: HelperConstants.appBundleIdentifier, category: "helper")
}

/// Marketing version and build of this binary, read from the Info.plist
/// section linked into the executable.
enum HelperBuild {
    static let version: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short)+\(build)"
    }()
}

/// The object the helper exports over XPC.
///
/// Concurrency: XPC calls these methods on its own queues. Every stored
/// property is immutable, and `SMCConnection` locks around the driver call, so
/// the class needs no queue of its own. `@unchecked` because `NSObject` is not
/// `Sendable`.
final class HelperService: NSObject, VentHelperProtocol, @unchecked Sendable {
    /// One connection for the life of the process: opening the user client
    /// costs a mach round trip and the daemon may answer thousands of reads.
    private let smc: SMCConnection?
    private let smcError: String?
    private let log = HelperLog.logger

    override init() {
        do {
            smc = try SMCConnection()
            smcError = nil
        } catch {
            smc = nil
            smcError = error.description
            HelperLog.logger.error("cannot open the SMC: \(error.description, privacy: .public)")
        }
        super.init()
    }

    // MARK: - VentHelperProtocol

    func ping(reply: @escaping @Sendable (String) -> Void) {
        let euid = geteuid()
        log.debug("ping from a client, euid \(euid, privacy: .public)")
        reply("pong \(HelperBuild.version) uid=\(euid)")
    }

    func helperVersion(reply: @escaping @Sendable (String) -> Void) {
        reply(HelperBuild.version)
    }

    func readSMCKey(_ key: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
        if let failure = privilegeFailure() {
            reply(nil, failure)
            return
        }
        guard let code = SMCFourCC(code: key) else {
            reply(nil, "'\(key)' is not a four-character SMC key")
            return
        }
        guard let smc else {
            reply(nil, smcError ?? "the SMC is not reachable")
            return
        }
        do {
            let info = try smc.keyInfo(for: code)
            reply(Data(try smc.readBytes(code, info: info)), nil)
        } catch {
            log.error("read \(key, privacy: .public) failed: \(error.description, privacy: .public)")
            reply(nil, error.description)
        }
    }

    // MARK: - Privilege

    /// The reason a privileged call must be refused, or nil when it may run.
    ///
    /// Everything this helper exists for needs root. Without it the process is
    /// still useful: it answers `ping` and `helperVersion`, so the XPC path can
    /// be exercised from a test that is not root.
    private func privilegeFailure() -> String? {
        let euid = geteuid()
        guard euid != 0 else { return nil }
        return "the helper is not running as root (euid \(euid)); install it from the Settings tab"
    }
}
