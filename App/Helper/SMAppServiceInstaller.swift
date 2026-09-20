import Foundation
import ServiceManagement

import HelperProtocol

/// Registers `Contents/Library/LaunchDaemons/com.serenearyal.vent.helper.plist`
/// with launchd through Service Management.
///
/// This path asks for no password. macOS registers the daemon disabled and the
/// user turns it on in System Settings > Login Items, which is why
/// `requiresApproval` is a normal outcome and not an error.
@MainActor
final class SMAppServiceInstaller: HelperInstalling {
    let kind = HelperInstallerKind.serviceManagement

    /// `SMAppService.daemon` is a value, not a handle: a fresh one every time
    /// reads the live status instead of a cached one.
    private var service: SMAppService {
        SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    }

    /// launchd rejects a register that lands on the same job in the same
    /// moment as its unregister, with "Operation not permitted".
    private static let reregisterGap = Duration.milliseconds(700)

    func state() -> HelperInstallState {
        switch service.status {
        // A daemon this app has never registered reports `notFound`, not
        // `notRegistered`: checked on macOS 26.2 with the plist present in
        // Contents/Library/LaunchDaemons. Both mean "nothing to talk to".
        case .notRegistered, .notFound:
            .notInstalled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        @unknown default:
            .stale("unknown Service Management status")
        }
    }

    func install() async throws {
        let service = service
        // A re-register is the only way to point launchd at a new binary after
        // the app has been rebuilt or moved.
        if service.status != .notRegistered {
            try? await service.unregister()
            try? await Task.sleep(for: Self.reregisterGap)
        }
        do {
            try service.register()
        } catch {
            throw HelperInstallError.registration(
                "Service Management refused the daemon: \(error.localizedDescription)"
            )
        }
        if service.status == .requiresApproval {
            openLoginItemsSettings()
        }
    }

    func uninstall() async throws {
        do {
            try await service.unregister()
        } catch {
            // Unregistering a job launchd never had is a success, not a
            // failure the user has to read.
            guard service.status != .notRegistered else { return }
            throw HelperInstallError.registration(
                "Service Management could not remove the daemon: \(error.localizedDescription)"
            )
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
