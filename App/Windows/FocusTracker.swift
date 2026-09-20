import AppKit
import Foundation

/// Remembers which app the user was in before Vent took the front.
///
/// The popover is the reason this exists. Showing it activates Vent, so by the
/// time the Windows section draws, "the frontmost app" is Vent. The tracker
/// listens to every activation and keeps the last one that was neither Vent
/// nor a background agent, and the popover asks it who that was.
///
/// One notification per app switch, no polling and no timer: the cost of this
/// is zero while nothing changes.
@MainActor
final class FocusTracker {
    private(set) var lastAppPID: pid_t?
    private(set) var lastAppName: String?

    private var observers: [NSObjectProtocol] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init() {
        // Whoever is in front at launch counts, so the first popover after a
        // start has a target too.
        adopt(NSWorkspace.shared.frontmostApplication)

        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                MainActor.assumeIsolated { self?.adopt(app) }
            }
        )
        // An app that quits must not stay the target: its pid would be reused.
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
                MainActor.assumeIsolated { self?.forget(app) }
            }
        )
    }

    // No `deinit`: an observer token is not `Sendable`, and a nonisolated
    // deinit may not touch one under Swift 6. The tracker lives as long as the
    // app does.

    /// The window the user was last working in, captured through the
    /// accessibility API. Call it BEFORE anything activates Vent.
    func captureTarget() -> WindowTarget? {
        // The live frontmost app when it is not us: the most truthful answer,
        // and the one the Windows tab gets while the window has the front.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ownPID,
           front.activationPolicy == .regular,
           let target = WindowTarget.capture(pid: front.processIdentifier) {
            return target
        }
        guard let pid = lastAppPID else { return nil }
        return WindowTarget.capture(pid: pid)
    }

    private func adopt(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ownPID else { return }
        // `.regular` only: an agent that flashes to the front for a moment is
        // not what the user was working in.
        guard app.activationPolicy == .regular else { return }
        lastAppPID = app.processIdentifier
        lastAppName = app.localizedName
    }

    private func forget(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier == lastAppPID else { return }
        lastAppPID = nil
        lastAppName = nil
    }
}
