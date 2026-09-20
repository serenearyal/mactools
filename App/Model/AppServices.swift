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
    let storage = StorageStore()
    let helper = HelperController()
    let fans: FanStore
    let keyboardLock: KeyboardLockController
    let windowController = MainWindowController()
    /// Set by the app delegate once the status item exists.
    @ObservationIgnored var statusItemController: StatusItemController?

    private var tab: MainTab = .overview

    /// The sidebar selection. Setting it tells the store what to sample.
    var selectedTab: MainTab {
        get { tab }
        set {
            guard tab != newValue else { return }
            tab = newValue
            store.setActiveTab(newValue)
        }
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
        keyboardLock = KeyboardLockController(settings: settings)
        windowController.store = store
    }
}
