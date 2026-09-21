import Foundation
import Observation

/// The objects the app is made of. One instance, reached from the SwiftUI
/// scene and from the AppKit side, so both see the same settings and the same
/// live numbers.
@MainActor
@Observable
final class AppServices {
    static let shared = AppServices()

    let settings: AppSettings
    let store: MetricsStore
    let processes = ProcessStore()
    let storage = StorageStore()
    let helper: HelperController
    let fans: FanStore
    let keyboardLock: KeyboardLockController
    /// R2, R3 and R4: Copy for AI, the sleep assertion and the keyboard light.
    let reports: ReportService
    let keepAwake: KeepAwakeController
    let backlight = KeyboardBacklightController()
    /// The window manager: the captured window, the tiles and the chords.
    let windows: WindowManagerController
    /// The first-run checklist and the login item behind it.
    let setup: SetupChecklist
    let windowController = MainWindowController()
    /// Set by the app delegate once the status item exists.
    @ObservationIgnored var statusItemController: StatusItemController?

    /// Observed: the sidebar reads it. The consumers next to it are not, so
    /// opening the popover does not invalidate the window's views.
    private var tab: MainTab = .overview
    /// Observed: the segmented control of the popover reads it.
    private var section: PopoverSection = .dashboard
    @ObservationIgnored private var consumers: SamplingConsumers = []
    @ObservationIgnored private var windowOccluded = false
    /// False under `--popover-section`: a capture run shows a section without
    /// rewriting the one the user chose.
    @ObservationIgnored private var persistsPopoverSection = true
    /// `--menu-bar-label on|off`. See `overrideLabelVisibility`.
    @ObservationIgnored private var labelOverride: Bool?
    /// `--power-rules off`. See `overridePowerRules`.
    @ObservationIgnored private var powerRules = true
    /// What the stores were last told, for the status file of a capture run.
    @ObservationIgnored private(set) var demand = SamplingDemand()

    /// The sidebar selection. Setting it tells the stores what to sample.
    var selectedTab: MainTab {
        get { tab }
        set {
            guard tab != newValue else { return }
            tab = newValue
            publishDemand()
        }
    }

    /// The popover's segmented control. It is remembered between launches, and
    /// it decides what an open popover samples.
    var popoverSection: PopoverSection {
        get { section }
        set {
            guard section != newValue else { return }
            section = newValue
            if persistsPopoverSection { settings.popoverSection = newValue }
            publishDemand()
        }
    }

    /// `--popover-section <name>`: the section a capture run wants, kept out
    /// of the settings file.
    func overridePopoverSection(_ section: PopoverSection) {
        persistsPopoverSection = false
        popoverSection = section
    }

    /// Who wants live numbers. The window and the popover each set their own
    /// flag; the stores see one value.
    ///
    /// A window that is covered by another window is still a consumer: it is
    /// one click away and it must not come back to a gap in its graphs. The
    /// occlusion only slows the cadence down.
    func setWindowVisible(_ visible: Bool, occluded: Bool = false) {
        let covered = visible && occluded
        guard windowOccluded != covered || consumers.contains(.window) != visible else { return }
        windowOccluded = covered
        setConsumer(.window, visible, force: true)
    }

    func setPopoverVisible(_ visible: Bool) {
        setConsumer(.popover, visible)
    }

    private func setConsumer(_ consumer: SamplingConsumers, _ active: Bool, force: Bool = false) {
        var updated = consumers
        if active { updated.insert(consumer) } else { updated.remove(consumer) }
        guard force || updated != consumers else { return }
        consumers = updated
        publishDemand()
    }

    /// The menu bar label is the one consumer that is always there, so what it
    /// draws decides whether an app with nothing on screen samples at all.
    ///
    /// Three ways it draws nothing: "Show in menu bar: icon only", an empty
    /// metric list, and a status item the menu bar has no room for - on a
    /// notched Mac the system parks the item off the edge of the screen, where
    /// every number it draws is for nobody.
    private var labelShowsMetrics: Bool {
        if let labelOverride { return labelOverride }
        guard settings.menuBarContent == .metrics, !settings.menuBarMetrics.isEmpty else {
            return false
        }
        return statusItemController?.isLabelOnScreen ?? true
    }

    /// `--menu-bar-label on|off`, for `scripts/measure_idle.sh` alone.
    ///
    /// The measurement needs both states on purpose, and neither of them can
    /// be arranged from outside: whether the menu bar has room for one more
    /// item depends on what else is in it at that second.
    func overrideLabelVisibility(_ shows: Bool) {
        labelOverride = shows
        publishDemand()
    }

    /// The status item moved, or the screens changed: the label may have gone
    /// behind the notch, or come back.
    func refreshDemand() {
        publishDemand()
    }

    /// The settings that decide what the label draws, and the power readings
    /// that decide how often anything is sampled. Both are push only.
    func startObservingEnvironment() {
        trackLabelSettings()
        trackPowerConditions()
        publishDemand()
    }

    private func trackLabelSettings() {
        withObservationTracking {
            _ = settings.menuBarContent
            _ = settings.menuBarMetrics
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                trackLabelSettings()
                publishDemand()
            }
        }
    }

    /// One subscription for the whole app: `KeepAwakeController` owns the
    /// `IOPSNotificationCreateRunLoopSource` and the two notifications, and the
    /// cadence rules read the value it publishes.
    private func trackPowerConditions() {
        let status = withObservationTracking {
            keepAwake.power
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                trackPowerConditions()
            }
        }
        store.setPowerConditions(
            powerRules
                ? PowerConditions(
                    onBattery: status.onBattery,
                    lowPowerMode: status.lowPowerMode,
                    thermalState: status.thermal
                )
                : PowerConditions()
        )
    }

    /// `--power-rules off`, for `scripts/measure_idle.sh` alone: the cadence
    /// this Mac would use on wall power, out of Low Power Mode and cool.
    ///
    /// Without it a measurement taken on a laptop in Low Power Mode would
    /// claim a budget that only holds in Low Power Mode.
    func overridePowerRules(_ enabled: Bool) {
        powerRules = enabled
        trackPowerConditions()
    }

    private func publishDemand() {
        let demand = SamplingDemand(
            consumers: consumers,
            activeTab: tab,
            popoverSection: section,
            windowOccluded: windowOccluded,
            menuBarShowsMetrics: labelShowsMetrics
        )
        guard demand != self.demand else { return }
        self.demand = demand
        // Memory only, at `info` level: the line is how a sampling leak is
        // proved afterwards, and it is of no interest otherwise.
        AppLog.app.info("sampling demand: \(demand.summary, privacy: .public)")
        store.setDemand(demand)
        processes.setDemand(demand)
        fans.setDemand(demand)
        backlight.setDemand(demand)
    }

    private init() {
        let settings = AppSettings()
        self.settings = settings
        section = settings.popoverSection
        store = MetricsStore(settings: settings)
        // The fake fans keep their modes to themselves: a screenshot run must
        // not rewrite what the user's real fans do.
        let fake = DebugFanBackend.isRequested
        fans = FanStore(
            settings: settings,
            backend: fake ? DebugFanBackend() : HelperFanBackend(),
            persistsModes: !fake
        )
        let keyboardLock = KeyboardLockController(settings: settings)
        self.keyboardLock = keyboardLock
        // The lock owns the Accessibility prompt, and the window manager needs
        // the same grant, so it borrows that one implementation.
        windows = WindowManagerController(settings: settings, permissions: keyboardLock)
        let helper = HelperController()
        self.helper = helper
        setup = SetupChecklist(settings: settings, helper: helper, lock: keyboardLock)
        keepAwake = KeepAwakeController(settings: settings)
        reports = ReportService(
            settings: settings,
            processes: processes,
            storage: storage,
            store: store
        )
    }

    /// The sidebar, minus what this Mac cannot do.
    ///
    /// Only the backlight can vanish today: on a Mac whose keyboard does not
    /// light up, the row, the sidebar item and the tab are not drawn at all
    /// rather than drawn dead.
    var sidebarSections: [(section: MainTabSection, tabs: [MainTab])] {
        MainTabSection.allCases.compactMap { section in
            let tabs = section.tabs.filter { tab in
                tab != .backlight || backlight.isAvailable
            }
            return tabs.isEmpty ? nil : (section, tabs)
        }
    }
}
