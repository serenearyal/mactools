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
    /// The first-run checklist and the login item behind it.
    let setup: SetupChecklist
    let windowController = MainWindowController()
    /// Set by the app delegate once the status item exists.
    @ObservationIgnored var statusItemController: StatusItemController?

    /// Observed: the sidebar reads it. The consumers next to it are not, so
    /// opening the popover does not invalidate the window's views.
    private var tab: MainTab = .overview
    @ObservationIgnored private var consumers: SamplingConsumers = []
    @ObservationIgnored private var windowOccluded = false

    /// The sidebar selection. Setting it tells the stores what to sample.
    var selectedTab: MainTab {
        get { tab }
        set {
            guard tab != newValue else { return }
            tab = newValue
            publishDemand()
        }
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

    private func publishDemand() {
        let demand = SamplingDemand(
            consumers: consumers,
            activeTab: tab,
            windowOccluded: windowOccluded
        )
        // Memory only, at `info` level: the line is how a sampling leak is
        // proved afterwards, and it is of no interest otherwise.
        AppLog.app.info("sampling demand: \(demand.summary, privacy: .public)")
        store.setDemand(demand)
        processes.setDemand(demand)
        fans.setDemand(demand)
    }

    private init() {
        let settings = AppSettings()
        self.settings = settings
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
        let helper = HelperController()
        self.helper = helper
        setup = SetupChecklist(settings: settings, helper: helper, lock: keyboardLock)
    }
}
