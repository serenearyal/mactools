import Darwin
import Foundation
import os

import FanControl
import HelperProtocol
import SMCKit

/// The one logger of the helper process.
///
/// `log stream --predicate 'subsystem == "com.serenearyal.vent"'` shows the app
/// and the helper together, which is what a fan bug needs.
enum HelperLog {
    static let logger = Logger(subsystem: HelperConstants.appBundleIdentifier, category: "helper")
    /// The fan governor logs under the category the app uses for it, so one
    /// stream shows both ends of a mode change.
    static let fans = Logger(subsystem: HelperConstants.appBundleIdentifier, category: "fans")
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
/// property is immutable, `SMCConnection` locks around the driver call and the
/// fan coordinator owns a serial queue of its own, so this class needs none.
/// `@unchecked` because `NSObject` is not `Sendable`.
final class HelperService: NSObject, VentHelperProtocol, @unchecked Sendable {
    /// One connection for the life of the process: opening the user client
    /// costs a mach round trip and the daemon may answer thousands of reads.
    private let smc: SMCConnection?
    private let smcError: String?
    private let log = HelperLog.logger

    /// nil when the SMC would not describe its fans. Every fan method then
    /// answers with `fanError`.
    let fans: FanCoordinator?
    private let fanError: String?
    /// False only for the XPC round-trip test, which runs as a normal user
    /// against a fake. The daemon always builds itself through `init()`.
    private let requiresRoot: Bool

    override convenience init() {
        self.init(fanHardware: nil, requiresRoot: true)
    }

    /// The designated initializer. `fanHardware` is nil in the daemon, where
    /// the fans come from the SMC connection this opens.
    init(fanHardware: (any FanHardware)?, requiresRoot: Bool) {
        self.requiresRoot = requiresRoot
        var connection: SMCConnection?
        do {
            connection = try SMCConnection()
            smcError = nil
        } catch {
            connection = nil
            smcError = error.description
            HelperLog.logger.error("cannot open the SMC: \(error.description, privacy: .public)")
        }
        smc = connection

        var hardware = fanHardware
        var failure: String?
        if hardware == nil {
            if let connection {
                do {
                    hardware = try SMCFanHardware(smc: connection)
                } catch {
                    failure = error.description
                }
            } else {
                failure = smcError
            }
        }
        fans = hardware.map { FanCoordinator(hardware: $0) }
        fanError = fans == nil ? (failure ?? "the fans are not reachable") : nil
        if let failure {
            HelperLog.logger.error("no fan control: \(failure, privacy: .public)")
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

    // MARK: - Fans

    func fanSnapshot(reply: @escaping @Sendable (Data?, String?) -> Void) {
        guard let fans, privilegeFailure() == nil else {
            reply(nil, privilegeFailure() ?? fanError)
            return
        }
        guard let data = fans.snapshot().jsonData else {
            reply(nil, "the fan snapshot could not be encoded")
            return
        }
        reply(data, nil)
    }

    func setFanMode(fanIndex: Int, modeJSON: Data, reply: @escaping @Sendable (String?) -> Void) {
        guard let fans, privilegeFailure() == nil else {
            reply(privilegeFailure() ?? fanError)
            return
        }
        guard let mode = FanMode(json: modeJSON) else {
            reply("the fan mode could not be decoded")
            return
        }
        reply(fans.setMode(mode, forFan: fanIndex))
    }

    /// Never refused for lack of root: the answer would be the same either
    /// way, and a client that is trying to make the fans safe deserves a
    /// plain reply.
    func restoreAllAuto(reply: @escaping @Sendable (String?) -> Void) {
        guard let fans else {
            reply(fanError)
            return
        }
        reply(fans.restoreAllAuto())
    }

    // MARK: - Privilege

    /// The reason a privileged call must be refused, or nil when it may run.
    ///
    /// Everything this helper exists for needs root. Without it the process is
    /// still useful: it answers `ping` and `helperVersion`, so the XPC path can
    /// be exercised from a test that is not root.
    private func privilegeFailure() -> String? {
        let euid = geteuid()
        guard !requiresRoot || euid == 0 else {
            return "the helper is not running as root (euid \(euid)); install it from the Settings tab"
        }
        return nil
    }
}
