import AppKit
import Observation
import ServiceManagement

/// Whether macOS starts MacTools when the user logs in.
///
/// The three states that are not a plain yes or no all happen in practice, so
/// the UI names them instead of showing an unchecked box: a registration can
/// wait for approval under Login Items & Extensions, and a bundle that has
/// moved since it registered is `notFound`.
enum LaunchAtLoginStatus: Equatable, Sendable {
    case off
    case on
    /// Registered with launchd and waiting for the switch in System Settings.
    case requiresApproval
    case unknown

    /// What the toggle shows. A registration that waits for approval counts as
    /// on: the user asked for it, macOS has simply not carried it out yet.
    var isEnabled: Bool { self == .on || self == .requiresApproval }

    /// The mapping from Service Management, on its own so it can be tested
    /// without registering anything with launchd.
    static func of(_ status: SMAppService.Status) -> LaunchAtLoginStatus {
        switch status {
        // An app that has never registered itself as a login item reports
        // `notFound`, not `notRegistered`: checked on macOS 26.2 with the
        // bundle in /Applications. Both mean "macOS has no login item for
        // this app", which is the ordinary state and not a fault.
        case .notRegistered, .notFound: .off
        case .enabled: .on
        case .requiresApproval: .requiresApproval
        @unknown default: .unknown
        }
    }

    var title: String {
        switch self {
        case .off: "Off"
        case .on: "On"
        case .requiresApproval: "Needs approval in System Settings"
        case .unknown: "Unknown"
        }
    }

    /// The line under the toggle, or nil when the state speaks for itself.
    var detail: String? {
        switch self {
        case .off, .on: nil
        case .requiresApproval:
            "Turn MacTools on under Login Items & Extensions to finish."
        case .unknown:
            "Service Management reported a state this build does not know."
        }
    }
}

/// The login item, backed by `SMAppService.mainApp`.
///
/// Nothing is stored: the toggle reads the live status every time it appears
/// and every time the app becomes active, because the user can remove a login
/// item in System Settings and a cached boolean would then lie.
@MainActor
@Observable
final class LaunchAtLoginController {
    private(set) var status: LaunchAtLoginStatus = .unknown
    /// The last refusal from Service Management, for the row under the toggle.
    private(set) var failure: String?
    private(set) var isBusy = false

    /// `SMAppService.mainApp` is a value, not a handle: a fresh one reads the
    /// live status instead of a cached one.
    private var service: SMAppService { .mainApp }

    func refresh() {
        status = LaunchAtLoginStatus.of(service.status)
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        failure = nil
        do {
            if enabled {
                try service.register()
            } else {
                try await service.unregister()
            }
            AppLog.app.notice("launch at login \(enabled ? "registered" : "unregistered", privacy: .public)")
        } catch {
            failure = error.localizedDescription
            AppLog.app.error(
                """
                launch at login \(enabled ? "register" : "unregister", privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
