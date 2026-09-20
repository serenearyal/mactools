import AppKit
import Foundation

/// A window manager that is running right now.
///
/// The shortcuts of this feature are the shortcuts of every other window
/// manager, and `RegisterEventHotKey` refuses a chord somebody else owns
/// without a word. A user who turns Vent's shortcuts on while Rectangle runs
/// would press ⌃⌥← and watch Rectangle answer; naming the app is the whole
/// difference between a bug report and a choice.
struct WindowManagerConflict: Identifiable, Equatable {
    let bundleIdentifier: String
    let name: String
    let version: String?
    let pid: pid_t

    var id: pid_t { pid }

    var label: String {
        guard let version, !version.isEmpty else { return name }
        return "\(name) \(version)"
    }

    /// The apps that own this kind of shortcut. Bundle identifiers, because a
    /// renamed app is still the same app.
    static let knownIdentifiers = [
        "com.knollsoft.Rectangle",
        "com.knollsoft.Hookshot",
        "com.crowdcafe.windowmagnet",
        "com.manytricks.Moom",
        "com.hegenberg.BetterSnapTool",
    ]

    @MainActor
    static func running() -> [WindowManagerConflict] {
        knownIdentifiers.flatMap { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier).map { app in
                WindowManagerConflict(
                    bundleIdentifier: identifier,
                    name: app.localizedName ?? identifier,
                    version: version(of: app),
                    pid: app.processIdentifier
                )
            }
        }
    }

    /// Asks the app to quit, the way Cmd-Q does. Never `forceTerminate`, and
    /// never without an explicit click: quitting somebody else's app behind
    /// their back is not something a menu bar tool may do.
    @MainActor
    @discardableResult
    func quit() -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        AppLog.windows.notice("asked \(self.name, privacy: .public) to quit")
        return app.terminate()
    }

    @MainActor
    private static func version(of app: NSRunningApplication) -> String? {
        guard let url = app.bundleURL, let bundle = Bundle(url: url) else { return nil }
        return bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
