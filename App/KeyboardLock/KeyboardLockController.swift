import AppKit
import ApplicationServices
import Carbon
import Foundation
import Observation

/// What the lock is doing right now.
enum KeyboardLockState: Equatable {
    case idle
    case locked(until: Date)
    case failed(reason: String)

    var isLocked: Bool {
        if case .locked = self { return true }
        return false
    }
}

/// Why a lock ended. It only reaches the log, but the log is the record of a
/// feature that can trap a user, so every path names itself.
enum UnlockReason: String {
    case hold
    case chord
    case timeout
    case termination
    case sessionInactive
    case sleep
    case screenLocked
}

/// Locks the keyboard for cleaning and, above all, always unlocks it again.
///
/// Every path that can end a lock is here: the hold button, the Escape chord,
/// the hard timeout, app termination, sleep, the screen lock and fast user
/// switching. The last four matter because a locked keyboard at the login
/// window would leave the user unable to type their password.
@MainActor
@Observable
final class KeyboardLockController {
    private(set) var state: KeyboardLockState = .idle
    private(set) var permissions = LockPermissions()
    /// Kept after the state goes back to idle, so the tab can still show it.
    private(set) var lastFailure: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let overlay = LockOverlayController()
    @ObservationIgnored private var runner: EventTapRunner?
    @ObservationIgnored private var timeout: DispatchSourceTimer?
    @ObservationIgnored private let timeoutQueue = DispatchQueue(
        label: "com.serenearyal.mactools.lock.timeout"
    )
    /// Kept for the life of the app: the controller is owned by
    /// `AppServices.shared`, and an observer that outlives a lock is the
    /// point of them.
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let log = AppLog.lock

    init(settings: AppSettings) {
        self.settings = settings
        refreshPermissions()
        observeSessionEvents()
    }

    // MARK: - Permissions

    @discardableResult
    func refreshPermissions() -> LockPermissions {
        permissions = LockPermissions(
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess(),
            secureInputEnabled: IsSecureEventInputEnabled()
        )
        // The user went to System Settings, granted what was missing and came
        // back: the refusal is over. `lastFailure` stays, so the tab can still
        // say what happened, but the lock is offered again.
        if LockRecovery.clearsFailure(isFailed: isFailed, permissions: permissions) {
            state = .idle
        }
        return permissions
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Shows the system prompt. macOS only shows it once per app version, so
    /// the settings deep link stays next to the button.
    func requestAccessibility() {
        // The literal, not `kAXTrustedCheckOptionPrompt`: the constant is a
        // mutable global and Swift 6 refuses to read it from an actor.
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        refreshPermissions()
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        refreshPermissions()
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Locking

    /// `seconds` overrides the setting; the debug lock test uses it.
    func lock(seconds: Int? = nil) {
        guard !state.isLocked else { return }
        let permissions = refreshPermissions()

        if permissions.secureInputEnabled {
            fail(
                """
                Another app has Secure Keyboard Entry on, so no app can see the keyboard. \
                A password field or a terminal with Secure Keyboard Entry is the usual cause. \
                Close it, then try again.
                """
            )
            return
        }
        guard permissions.accessibility else {
            fail("MacTools needs Accessibility permission before it can hold the keyboard.")
            requestAccessibility()
            showOnboarding()
            return
        }
        guard permissions.inputMonitoring else {
            fail("MacTools needs Input Monitoring permission before it can hold the keyboard.")
            requestInputMonitoring()
            showOnboarding()
            return
        }

        // The setting is clamped on the way in and out; an override is
        // clamped here as well, so no caller can hold the keyboard longer
        // than the longest timeout the UI offers.
        let duration = TimeInterval(
            seconds.map { min(max($0, 1), LockTimeout.range.upperBound) }
                ?? settings.lockTimeoutSeconds
        )
        let runner = EventTapRunner { [weak self] in
            // The tap thread calls this. Everything below is main-actor work.
            Task { @MainActor in self?.unlock(reason: .chord) }
        }
        do {
            try runner.start()
        } catch {
            fail(
                error == .notPermitted
                    ? "macOS withdrew the permission. Grant it again below."
                    : "macOS refused the event tap. Try again, and check the permissions below."
            )
            return
        }

        self.runner = runner
        let started = Date()
        let until = started.addingTimeInterval(duration)
        state = .locked(until: until)
        lastFailure = nil
        overlay.show(startedAt: started, until: until) { [weak self] in
            self?.unlock(reason: .hold)
        }
        startTimeout(after: duration, runner: runner)
        log.notice("locked for \(Int(duration), privacy: .public) s")
    }

    func unlock(reason: UnlockReason) {
        guard state.isLocked else { return }
        log.notice("unlocked by \(reason.rawValue, privacy: .public)")
        release()
        state = .idle
    }

    /// The synchronous half of an unlock: safe to call from
    /// `applicationWillTerminate`, where no further main-actor turn happens.
    func releaseForTermination() {
        guard state.isLocked else { return }
        log.notice("unlocked by \(UnlockReason.termination.rawValue, privacy: .public)")
        release()
        state = .idle
    }

    private func release() {
        timeout?.cancel()
        timeout = nil
        runner?.stop()
        runner = nil
        overlay.hide()
    }

    private func fail(_ reason: String) {
        log.error("lock refused: \(reason, privacy: .public)")
        lastFailure = reason
        state = .failed(reason: reason)
    }

    private func showOnboarding() {
        AppServices.shared.windowController.show(tab: .keyboardLock)
    }

    // MARK: - The guarantees

    /// The hard timeout. It runs on a queue of its own and the first thing it
    /// does is stop the tap, which needs no main actor: a main thread that is
    /// stuck can therefore not keep the keyboard locked.
    private func startTimeout(after duration: TimeInterval, runner: EventTapRunner) {
        let timer = DispatchSource.makeTimerSource(queue: timeoutQueue)
        timer.schedule(deadline: .now() + duration)
        timer.setEventHandler { [weak self] in
            runner.stop()
            Task { @MainActor in self?.unlock(reason: .timeout) }
        }
        timeout = timer
        timer.resume()
    }

    /// Sleep, the screen lock and fast user switching all end with a login
    /// window that wants a password. A lock that survived them would lock the
    /// user out of their own Mac.
    private func observeSessionEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let pairs: [(NotificationCenter, Notification.Name, UnlockReason)] = [
            (workspace, NSWorkspace.willSleepNotification, .sleep),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionInactive),
            (distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked),
        ]
        observers = pairs.map { center, name, reason in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.unlock(reason: reason) }
            }
        }
    }

    // MARK: - Debug

    /// Window numbers of the overlay, for the capture path.
    var overlayWindowNumbers: [Int] { overlay.windowNumbers }

    /// Shows the overlay and nothing else: no tap, no permission, no risk.
    /// `--overlay-preview <seconds>` uses it to take a screenshot.
    func previewOverlay(seconds: Int) {
        let started = Date()
        let until = started.addingTimeInterval(TimeInterval(seconds))
        overlay.show(startedAt: started, until: until) { [weak self] in
            self?.overlay.hide()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.overlay.hide()
        }
    }
}
