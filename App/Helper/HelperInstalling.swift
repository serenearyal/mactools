import Foundation

/// Where the LaunchDaemon came from.
enum HelperInstallerKind: String, Sendable {
    /// `SMAppService.daemon`, the modern path: no password, one approval in
    /// System Settings.
    case serviceManagement
    /// `/Library/LaunchDaemons` written under an admin prompt, for the case
    /// where Service Management refuses the certificate.
    case legacy

    var title: String {
        switch self {
        case .serviceManagement: "Login Items"
        case .legacy: "admin install"
        }
    }
}

/// What an installer reports about the daemon it owns.
enum HelperInstallState: Equatable, Sendable {
    /// No daemon registered and no files on disk.
    case notInstalled
    /// Registered, waiting for the user in System Settings > Login Items.
    case requiresApproval
    /// launchd has the job. It says nothing about the helper answering: only
    /// a ping proves that.
    case enabled
    /// The registration is gone but the plist is still on disk, which is what
    /// a moved or deleted app bundle looks like.
    case stale(String)
}

/// Facts about this app bundle that both installers need.
enum HelperBundle {
    /// The helper the build embedded next to the app executable.
    static var bundledHelperURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/MacToolsHelper")
    }

    /// Version string in the format the helper reports, so the two compare
    /// directly. Both targets carry the same MARKETING_VERSION and build.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short)+\(build)"
    }
}

/// One way to install the privileged helper.
///
/// Both paths sit behind this so the controller and the UI never branch on
/// which one is in use.
@MainActor
protocol HelperInstalling {
    var kind: HelperInstallerKind { get }
    func state() -> HelperInstallState
    func install() async throws
    func uninstall() async throws
}

enum HelperInstallError: Error, LocalizedError, Equatable {
    /// The user dismissed the admin prompt.
    case cancelled
    case helperMissing(String)
    case unsafePath(String)
    case commandFailed(String)
    case registration(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "The installation was cancelled."
        case .helperMissing(let path):
            "The helper is missing from the app bundle (\(path))."
        case .unsafePath(let path):
            "The app is in a path this installer cannot quote safely (\(path))."
        case .commandFailed(let message):
            message
        case .registration(let message):
            message
        }
    }
}
