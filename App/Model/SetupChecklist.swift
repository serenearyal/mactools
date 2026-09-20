import AppKit
import Observation
import ScanKit

/// One row of the setup checklist.
struct SetupStep: Identifiable {
    /// What the row's button does. The checklist performs it, so the view
    /// stays a drawing of the state and nothing else.
    enum Action: Equatable {
        case installHelper
        case openLoginItems
        case grantInputPermissions
        case openFullDiskAccessSettings
        case enableLaunchAtLogin
    }

    let id: String
    let title: String
    /// One line: why Vent asks for this at all.
    let reason: String
    let isDone: Bool
    let actionTitle: String?
    let action: Action?
}

/// The first-run checklist: the four grants Vent needs, with their live state.
///
/// Every status comes from the source that already owns it - the helper
/// controller, the lock's permission probe, the Full Disk Access probe and
/// Service Management - so the card can never disagree with the tab that does
/// the same job. Nothing is cached beyond the current pass, because the user
/// grants these in System Settings, outside the app; `observeActivation()`
/// re-reads them every time Vent comes back to the front.
@MainActor
@Observable
final class SetupChecklist {
    let launchAtLogin = LaunchAtLoginController()
    private(set) var hasFullDiskAccess = true

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let helper: HelperController
    @ObservationIgnored private let lock: KeyboardLockController
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    /// `--setup-checklist show|hide`. A screenshot run flips the card without
    /// writing to what the user chose.
    @ObservationIgnored private var visibilityOverride: Bool?

    init(settings: AppSettings, helper: HelperController, lock: KeyboardLockController) {
        self.settings = settings
        self.helper = helper
        self.lock = lock
    }

    // MARK: - Visibility

    var isVisible: Bool { visibilityOverride ?? !settings.setupChecklistDismissed }

    func dismiss() {
        settings.setupChecklistDismissed = true
        AppLog.app.notice("setup checklist dismissed with \(self.remaining, privacy: .public) steps open")
    }

    /// The Settings tab brings the card back with this.
    func show() {
        settings.setupChecklistDismissed = false
        visibilityOverride = nil
    }

    func setVisibilityOverride(_ visible: Bool) {
        visibilityOverride = visible
    }

    // MARK: - The steps

    var steps: [SetupStep] {
        [helperStep, inputPermissionsStep, fullDiskAccessStep, launchAtLoginStep]
    }

    var remaining: Int { steps.count { !$0.isDone } }
    var isComplete: Bool { remaining == 0 }

    private var helperStep: SetupStep {
        let action: (String, SetupStep.Action)? = switch helper.state {
        case .running: nil
        case .requiresApproval: ("Open Login Items", .openLoginItems)
        case .outdated: ("Reinstall", .installHelper)
        default: ("Install", .installHelper)
        }
        // An installed helper of another build is not a missing helper: it
        // answers, and every call that matters fails. The row says so.
        let title = helper.needsReinstall
            ? "Privileged helper - update needed"
            : "Privileged helper"
        return SetupStep(
            id: "helper",
            title: title,
            reason: helper.mismatchMessage
                ?? "Fan control, and the CPU and memory of processes you do not own, need a daemon that runs as root.",
            isDone: helper.state.isRunning,
            actionTitle: action?.0,
            action: action?.1
        )
    }

    private var inputPermissionsStep: SetupStep {
        let permissions = lock.permissions
        let granted = permissions.accessibility && permissions.inputMonitoring
        let missing = [
            permissions.accessibility ? nil : "Accessibility",
            permissions.inputMonitoring ? nil : "Input Monitoring",
        ].compactMap { $0 }
        return SetupStep(
            id: "input",
            title: "Accessibility and Input Monitoring",
            reason: granted
                ? "The keyboard lock may hold every key."
                : "The keyboard lock needs \(missing.joined(separator: " and ")) before it can hold the keys.",
            isDone: granted,
            actionTitle: granted ? nil : "Grant",
            action: granted ? nil : .grantInputPermissions
        )
    }

    private var fullDiskAccessStep: SetupStep {
        SetupStep(
            id: "fullDiskAccess",
            title: "Full Disk Access",
            reason: hasFullDiskAccess
                ? "The storage scan can read every folder of the volume."
                : "Without it the storage scan skips the protected folders and counts them as unreadable.",
            isDone: hasFullDiskAccess,
            actionTitle: hasFullDiskAccess ? nil : "Open Settings",
            action: hasFullDiskAccess ? nil : .openFullDiskAccessSettings
        )
    }

    private var launchAtLoginStep: SetupStep {
        let status = launchAtLogin.status
        let action: (String, SetupStep.Action)? = switch status {
        case .on: nil
        case .requiresApproval: ("Open Login Items", .openLoginItems)
        default: ("Turn On", .enableLaunchAtLogin)
        }
        return SetupStep(
            id: "launchAtLogin",
            title: "Launch at login",
            reason: status == .on
                ? "Vent starts with the session."
                : "Vent only measures while it runs, so the menu bar stays empty until you open it by hand.",
            isDone: status == .on,
            actionTitle: action?.0,
            action: action?.1
        )
    }

    // MARK: - Doing something about a step

    func perform(_ action: SetupStep.Action) {
        switch action {
        case .installHelper:
            Task { await helper.install() }
        case .openLoginItems:
            helper.openLoginItemsSettings()
        case .grantInputPermissions:
            // The system prompt first, which is the shortest path the very
            // first time, then the tab that holds the deep links for every
            // time after that: macOS shows its prompt once per app version.
            if !lock.permissions.accessibility {
                lock.requestAccessibility()
            } else if !lock.permissions.inputMonitoring {
                lock.requestInputMonitoring()
            }
            AppServices.shared.windowController.show(tab: .keyboardLock)
        case .openFullDiskAccessSettings:
            guard let url = URL(string: FullDiskAccess.settingsURLString) else { return }
            NSWorkspace.shared.open(url)
        case .enableLaunchAtLogin:
            Task { await launchAtLogin.setEnabled(true) }
        }
    }

    // MARK: - Staying in step with System Settings

    func refresh() {
        hasFullDiskAccess = FullDiskAccess.isGranted()
        lock.refreshPermissions()
        launchAtLogin.refresh()
        Task { await helper.refresh() }
    }

    /// The user leaves to System Settings and comes back, so the moment Vent
    /// is active again is the moment every one of these can have changed.
    func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}
