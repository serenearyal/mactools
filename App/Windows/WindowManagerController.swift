import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation
import WindowKit

/// The window manager, as the UI sees it.
///
/// It owns the four parts and nothing else: who was in front (`FocusTracker`),
/// what may be written (`AXWindowMover`), which chords are live
/// (`HotKeyCenter`) and who else claims them (`WindowManagerConflict`). The
/// geometry lives in `WindowKit` and the AX calls in the mover.
@MainActor
@Observable
final class WindowManagerController {
    /// The window the popover and the tab act on. Captured before Vent takes
    /// the front, so it is the window the user was really working in.
    private(set) var target: WindowTarget?
    /// The last refusal or note, shown under the grid.
    private(set) var status: String?
    private(set) var conflicts: [WindowManagerConflict] = []
    private(set) var registrations: [WindowAction: HotKeyRegistration] = [:]
    private(set) var accessibilityGranted = AXIsProcessTrusted()
    /// Redrawn when a display is plugged in or the Dock moves.
    private(set) var screenCount = ScreenList.count

    @ObservationIgnored private let settings: AppSettings
    /// The Accessibility prompt and the deep link to System Settings. The lock
    /// asks for the same grant, so there is one implementation of both.
    @ObservationIgnored private let permissions: KeyboardLockController
    @ObservationIgnored let focus = FocusTracker()
    @ObservationIgnored let mover = AXWindowMover()
    @ObservationIgnored private let hotKeys = HotKeyCenter()
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var persistsShortcutChoice = true
    /// Observed, not ignored: `choice` is read by the picker, the banner and
    /// every row of the shortcut table, so a change to the override has to
    /// invalidate them the way a change to the setting does.
    private var choiceOverride: WindowShortcutChoice?
    @ObservationIgnored private let log = AppLog.windows

    init(settings: AppSettings, permissions: KeyboardLockController) {
        self.settings = settings
        self.permissions = permissions
        hotKeys.onAction = { [weak self] action in
            self?.applyFromHotKey(action)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenCount = ScreenList.count
                self?.mover.resetCycle()
            }
        }
    }

    // No `deinit`: an observer token is not `Sendable`, and a nonisolated
    // deinit may not touch one under Swift 6. The controller lives as long as
    // the app does, and the notification centre drops the token with it.

    // MARK: - Settings

    var choice: WindowShortcutChoice {
        choiceOverride ?? settings.windows.shortcutChoice
    }

    var gap: CGFloat {
        CGFloat(settings.windows.gap)
    }

    var data: WindowSettingsData { settings.windows }

    /// The user picked a set: in the tab, in the popover or on the banner.
    /// It writes the marker as well as the choice, so an "Off" chosen here is
    /// never migrated back to Rectangle's layout at the next launch.
    func setChoice(_ choice: WindowShortcutChoice) {
        choiceOverride = nil
        if persistsShortcutChoice {
            var data = settings.windows
            data.shortcutChoice = choice
            data.shortcutChoiceIsUserChoice = true
            settings.windows = data
        } else {
            choiceOverride = choice
        }
        applyShortcuts()
    }

    /// `--shortcut-set <off|rectangle|alternate>`: one run on another set,
    /// with the settings file left exactly as the user wrote it.
    func overrideChoice(_ choice: WindowShortcutChoice) {
        persistsShortcutChoice = false
        choiceOverride = choice
        applyShortcuts()
    }

    func setEnabled(_ enabled: Bool, for action: WindowAction) {
        var data = settings.windows
        data.setEnabled(enabled, for: action)
        settings.windows = data
        applyShortcuts()
    }

    func setGap(_ gap: Double) {
        settings.windows.gap = Double(WindowLayout.clampGap(CGFloat(gap)))
    }

    func setEnhancedUserInterfaceWorkaround(_ enabled: Bool) {
        settings.windows.enhancedUserInterfaceWorkaround = enabled
    }

    func setReactivatesAfterTile(_ enabled: Bool) {
        settings.windows.reactivatesAfterTile = enabled
    }

    // MARK: - Lifecycle

    /// Called once at launch. It claims the chords of the chosen set and looks
    /// for the apps that own the same ones.
    func start() {
        refreshConflicts()
        applyShortcuts()
    }

    /// Every chord goes back to the system. The app delegate calls this on the
    /// way out, so a quit never leaves a shortcut claimed.
    func stop() {
        hotKeys.unregisterAll()
        registrations = [:]
    }

    /// Claims the chords of the chosen set and writes down what the system
    /// said about each one.
    ///
    /// The log line is the one thing a user can hand over when a shortcut does
    /// nothing: it names the set, how many chords are live and the OSStatus of
    /// every chord that was refused.
    func applyShortcuts() {
        guard let set = choice.set else {
            hotKeys.unregisterAll()
            registrations = [:]
            log.notice("shortcuts: off, 0 registered")
            return
        }
        registrations = hotKeys.register(set.bindings, disabled: settings.windows.disabled)
        let registered = registrations.values.filter(\.isRegistered).count
        let taken = registrations.values.filter { $0 == .taken }.count
        let failures = registrations
            .compactMap { action, state -> String? in
                guard case .failed(let status) = state else { return nil }
                return "\(action.rawValue) \(status)"
            }
            .sorted()
        log.notice(
            """
            shortcuts: set \(set.id, privacy: .public), \
            \(registered, privacy: .public) registered, \
            \(taken, privacy: .public) taken, \
            \(failures.count, privacy: .public) failed\
            \(failures.isEmpty ? "" : " [" + failures.joined(separator: ", ") + "]", privacy: .public)
            """
        )
    }

    func refreshConflicts() {
        conflicts = WindowManagerConflict.running()
    }

    @discardableResult
    func refreshAccessibility() -> Bool {
        accessibilityGranted = AXIsProcessTrusted()
        return accessibilityGranted
    }

    func requestAccessibility() {
        permissions.requestAccessibility()
        refreshAccessibility()
    }

    func openAccessibilitySettings() {
        permissions.openAccessibilitySettings()
    }

    /// The conflict banner's third button: stop claiming anything.
    func turnShortcutsOff() {
        setChoice(.off)
    }

    /// The conflict banner's first button.
    func useAlternateSet() {
        setChoice(.alternate)
    }

    func quit(_ conflict: WindowManagerConflict) {
        conflict.quit()
        // The app takes a moment to go; the chords are free after that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.refreshConflicts()
            self?.applyShortcuts()
        }
    }

    // MARK: - The target window

    /// Reads the window the user was last working in.
    ///
    /// The popover calls this BEFORE it shows itself: `NSApp.activate()` makes
    /// Vent the frontmost app, and from that instant there is no other focused
    /// window to find.
    @discardableResult
    func captureTarget() -> WindowTarget? {
        refreshAccessibility()
        refreshConflicts()
        screenCount = ScreenList.count
        guard accessibilityGranted else {
            target = nil
            status = WindowRefusal.accessibilityMissing.message
            return nil
        }
        let captured = focus.captureTarget()
        target = captured
        status = captured?.refusal?.message ?? (captured == nil ? WindowRefusal.noWindow.message : nil)
        return captured
    }

    /// The current window without a fresh capture, for a view that redraws.
    func refreshTarget() {
        guard let target else {
            captureTarget()
            return
        }
        self.target = target.refreshed() ?? target
    }

    // MARK: - What the views ask

    /// A tile may be clicked: there is a window, and it is one we may move.
    var canAct: Bool {
        accessibilityGranted && target != nil && target?.refusal == nil
    }

    /// The chord of one action, for a tooltip and for the table. Nil when the
    /// shortcuts are off or this action is switched off.
    func shortcutDisplay(for action: WindowAction) -> String? {
        guard let set = choice.set, settings.windows.isEnabled(action) else { return nil }
        return set.binding(for: action)?.display
    }

    /// The command list: every action, grouped, with its chord and whether it
    /// can run on the window in front right now.
    ///
    /// The Windows tab, the popover and the status item's Window submenu all
    /// draw this one value, so the three cannot drift apart.
    var commandGroups: [WindowCommandGroup] {
        WindowCommandList.groups(
            set: choice.set,
            disabled: settings.windows.disabled,
            canAct: canAct,
            screenCount: screenCount
        )
    }

    /// The banner appears while another manager runs and Vent is not already
    /// out of its way. On the alternate set with every chord registered there
    /// is no conflict left to report.
    var showsConflictBanner: Bool {
        guard !conflicts.isEmpty else { return false }
        return choice != .alternate || registrations.values.contains(.taken)
    }

    /// Vent uses Rectangle's own layout while Rectangle is running.
    ///
    /// Measured on macOS 26: `RegisterEventHotKey` answers
    /// `eventHotKeyExistsErr` only for a chord the SAME process already holds.
    /// Two apps may claim one chord and both are told "registered", and both
    /// then answer the key. So a green dot would be a promise this cannot
    /// keep, and these bindings are marked as shared instead.
    var sharesChordsWithAnotherManager: Bool {
        choice == .rectangle && !conflicts.isEmpty
    }

    // MARK: - Acting

    /// A click in the popover or on the tab.
    ///
    /// `reactivate` brings the moved window's app back to the front, which is
    /// what the user wants after they picked a tile from a panel that took the
    /// focus away from it.
    @discardableResult
    func apply(_ action: WindowAction, reactivate: Bool = false) -> WindowMoveResult {
        guard let target else {
            status = WindowRefusal.noWindow.message
            return .refused(.noWindow)
        }
        let result = mover.apply(
            action,
            to: target,
            gap: gap,
            enhancedUserInterfaceWorkaround: settings.windows.enhancedUserInterfaceWorkaround
        )
        status = result.message
        self.target = target.refreshed() ?? target
        if case .moved = result, reactivate, settings.windows.reactivatesAfterTile {
            NSRunningApplication(processIdentifier: target.pid)?.activate()
        }
        return result
    }

    /// A chord. It acts on whatever is in front at this instant, never on the
    /// window the popover remembered: a shortcut is pressed while the user is
    /// in the window they mean.
    private func applyFromHotKey(_ action: WindowAction) {
        lastHotKeyAction = action
        // The self test drives this path against its own probe window. When
        // the hook is installed the frontmost window is never read at all: a
        // test may not move a window of the user's, not even by accident.
        let candidate = hotKeyTarget.map { $0() } ?? WindowTarget.captureFrontmost()
        guard let live = candidate else {
            log.notice("hot key \(action.rawValue, privacy: .public): no window in front")
            return
        }
        let result = mover.apply(
            action,
            to: live,
            gap: gap,
            enhancedUserInterfaceWorkaround: settings.windows.enhancedUserInterfaceWorkaround
        )
        if let message = result.message {
            log.notice("hot key \(action.rawValue, privacy: .public) refused: \(message, privacy: .public)")
        }
    }

    // MARK: - Debug

    /// The window every chord acts on, for the self test alone.
    ///
    /// Nothing in the app sets it. `WindowSelfTest` installs it so that the
    /// Carbon path can be driven against the probe window instead of whatever
    /// the user has in front.
    @ObservationIgnored var hotKeyTarget: (() -> WindowTarget?)?
    /// The action of the last chord that reached `applyFromHotKey`, whether it
    /// moved anything or not. The self test reads it to prove the Carbon
    /// handler dispatched.
    @ObservationIgnored private(set) var lastHotKeyAction: WindowAction?

    /// Sends the Carbon hot key event of one action into the handler
    /// `RegisterEventHotKey` feeds, exactly as a real press does. The self
    /// test is the only caller; it returns nil when the action is not claimed.
    @discardableResult
    func dispatchHotKeyForSelfTest(_ action: WindowAction) -> OSStatus? {
        lastHotKeyAction = nil
        return hotKeys.sendRegisteredHotKey(for: action)
    }

    /// Every binding of the chosen set with what the system said about it. The
    /// capture status file prints this, so a run can prove the conflict without
    /// pressing a key.
    var registrationReport: [String] {
        guard let set = choice.set else { return ["shortcut set: off"] }
        return ["shortcut set: \(set.id)"] + set.bindings.map { binding in
            let state = registrations[binding.action] ?? .off
            return "  \(binding.action.rawValue) \(binding.display): \(state.summary)"
        }
    }
}
