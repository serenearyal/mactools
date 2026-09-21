import Foundation
import Observation

import HelperProtocol

/// What the Settings tab shows about the privileged helper.
enum HelperState: Equatable, Sendable {
    case unknown
    case notInstalled
    /// No helper of this app, but the root daemon from before the rename is
    /// still installed. It answers nothing this app asks, and Install replaces
    /// it in one prompt.
    case supersededOnly
    /// Registered with launchd and waiting for the switch in System Settings.
    case requiresApproval
    case running(version: String, uid: UInt32)
    /// Answering, but older than the app that is talking to it. A legacy
    /// install keeps a copy of the binary, and that copy goes stale.
    case outdated(installed: String, expected: String)
    case failed(String)

    /// The one state in which everything that needs root works.
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Owns the helper: its state, the two installers and the XPC connection.
///
/// One button in the UI covers both install paths. Service Management first,
/// because it needs no password; if macOS refuses the daemon, the legacy
/// installer runs and asks for one. The user asked for a helper either way,
/// and a second button for "the other kind of install" would only ask them to
/// guess which one their certificate allows.
@MainActor
@Observable
final class HelperController {
    private(set) var state: HelperState = .unknown
    private(set) var isBusy = false
    /// Which installer put the current daemon there, once one did.
    private(set) var installedBy: HelperInstallerKind?

    @ObservationIgnored private let serviceManagement = SMAppServiceInstaller()
    @ObservationIgnored private let legacy = LegacyHelperInstaller()
    @ObservationIgnored private let connection = HelperConnection()
    @ObservationIgnored private let log = AppLog.helper

    var expectedVersion: String { HelperBundle.version }

    /// True when the helper is installed but not the one this app ships.
    var needsReinstall: Bool {
        if case .outdated = state { return true }
        return false
    }

    /// What every part of the UI says about an outdated helper, and nil while
    /// the helper is usable. The backends refuse their calls with the same
    /// line, so the banner, the popover and the error never disagree.
    var mismatchMessage: String? {
        guard case .outdated(let installed, let expected) = state else { return nil }
        return HelperGate.mismatchMessage(installed: installed, expected: expected)
    }

    // MARK: - Reading the state

    /// launchd first, then a ping. A job can be registered while the binary is
    /// missing or its signature is wrong, and only the ping sees that; the
    /// other way round, pinging a service launchd has never heard of would
    /// turn "not installed" into a connection error.
    func refresh() async {
        defer { publishGate() }
        let smStatus = serviceManagement.state()
        let legacyStatus = legacy.state()
        log.debug(
            """
            helper status: service management \(String(describing: smStatus), privacy: .public), \
            legacy \(String(describing: legacyStatus), privacy: .public)
            """
        )

        if smStatus == .enabled || legacyStatus == .enabled {
            installedBy = smStatus == .enabled ? .serviceManagement : .legacy
            state = await probe()
            return
        }
        if smStatus == .requiresApproval {
            state = .requiresApproval
            return
        }
        installedBy = nil
        state = switch (smStatus, legacyStatus) {
        case (_, .stale(let reason)), (.stale(let reason), _): .failed(reason)
        // Nothing of this app is installed. The daemon of the old name may
        // still be, and "not installed" would be a poor answer to that.
        default: legacy.hasSupersededInstall ? .supersededOnly : .notInstalled
        }
    }

    /// One round trip. It answers the only question that matters: does the
    /// helper run, as root, at the version this app expects?
    private func probe() async -> HelperState {
        do {
            let answer = try await connection.ping()
            log.info("helper says \(answer, privacy: .public)")
            guard let reply = PingReply(answer) else {
                return .failed("The helper answered something unexpected: \(answer)")
            }
            guard reply.uid == 0 else {
                return .failed("The helper is running as uid \(reply.uid), not root.")
            }
            guard reply.version == expectedVersion else {
                return .outdated(installed: reply.version, expected: expectedVersion)
            }
            return .running(version: reply.version, uid: reply.uid)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Tells the fan and the process backends whether this helper may be
    /// called at all. Every path that sets `state` ends here.
    private func publishGate() {
        if case .outdated(let installed, let expected) = state {
            log.error(
                """
                the installed helper is \(installed, privacy: .public), this app needs \
                \(expected, privacy: .public); refusing to call it
                """
            )
            HelperGate.shared.block(installed: installed, expected: expected)
        } else {
            HelperGate.shared.allow()
        }
    }

    // MARK: - Actions

    func install() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        defer { publishGate() }
        await connection.disconnect()

        do {
            try await serviceManagement.install()
            installedBy = .serviceManagement
        } catch {
            log.error("Service Management install failed: \(error.localizedDescription, privacy: .public)")
            do {
                try await legacy.install()
                installedBy = .legacy
            } catch HelperInstallError.cancelled {
                await refresh()
                return
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
        }
        // launchd registers the job before it can start it.
        try? await Task.sleep(for: .milliseconds(400))
        await refresh()
    }

    func uninstall() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        defer { publishGate() }
        await connection.disconnect()

        var failures: [String] = []
        if serviceManagement.state() != .notInstalled {
            do { try await serviceManagement.uninstall() } catch {
                failures.append(error.localizedDescription)
            }
        }
        // The old name's daemon goes with it: one script removes both
        // generations, so an uninstall leaves nothing of either behind.
        if legacy.state() != .notInstalled || legacy.hasSupersededInstall {
            do { try await legacy.uninstall() } catch HelperInstallError.cancelled {
                await refresh()
                return
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        installedBy = nil
        await refresh()
        if !failures.isEmpty, state != .notInstalled {
            state = .failed(failures.joined(separator: " "))
        }
    }

    func openLoginItemsSettings() {
        serviceManagement.openLoginItemsSettings()
    }
}

/// The `pong <version> uid=<euid>` line the helper answers with.
struct PingReply: Equatable {
    let version: String
    let uid: UInt32

    init?(_ text: String) {
        let parts = text.split(separator: " ")
        guard parts.count == 3, parts[0] == "pong", parts[2].hasPrefix("uid="),
              let uid = UInt32(parts[2].dropFirst("uid=".count))
        else { return nil }
        version = String(parts[1])
        self.uid = uid
    }
}
