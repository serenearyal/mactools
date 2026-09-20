import SwiftUI

struct MainWindowView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        NavigationSplitView {
            // Not `MainTabSection.allCases` directly: on a Mac whose keyboard
            // has no backlight that item is not drawn at all, and a section
            // left with no items is not drawn either.
            List(selection: selection) {
                ForEach(services.sidebarSections, id: \.section) { group in
                    Section(group.section.title) {
                        ForEach(group.tabs) { tab in
                            Label(tab.title, systemImage: tab.symbolName)
                                .tag(tab)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 176, ideal: 192, max: 240)
        } detail: {
            // Above every tab, not on one of them: a bundle in the wrong place
            // breaks the helper, the keyboard lock and the storage scan alike.
            VStack(spacing: 0) {
                LaunchLocationBanner()
                TabDetailView(tab: services.selectedTab, services: services)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(services.selectedTab.title)
        }
        .frame(minWidth: 760, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    services.windowController.hide()
                } label: {
                    Label("Hide to Menu Bar", systemImage: "menubar.arrow.up.rectangle")
                }
                // An accessory app has no menu bar of its own, so Cmd-W would
                // do nothing at all without this.
                .keyboardShortcut("w", modifiers: .command)
                .help("Close the window. Vent keeps running in the menu bar.")
            }
        }
    }

    private var selection: Binding<MainTab?> {
        Binding(
            get: { services.selectedTab },
            set: { if let value = $0 { services.selectedTab = value } }
        )
    }

}

/// The right-hand side of the split view, as its own type so the capture
/// path can render one tab on its own.
struct TabDetailView: View {
    let tab: MainTab
    let services: AppServices

    @ViewBuilder
    var body: some View {
        switch tab {
        case .overview:
            OverviewView(services: services)
        case .fans:
            FansView(
                store: services.store,
                fans: services.fans,
                settings: services.settings,
                helper: services.helper,
                showSettings: { services.selectedTab = .settings }
            )
        case .sensors:
            SensorsView(store: services.store, settings: services.settings)
        case .processes:
            ProcessesView(
                store: services.processes,
                helper: services.helper,
                settings: services.settings,
                reports: services.reports,
                showSettings: { services.selectedTab = .settings }
            )
        case .storage:
            StorageView(
                store: services.store,
                storage: services.storage,
                settings: services.settings,
                reports: services.reports
            )
        case .keepAwake:
            KeepAwakeView(keepAwake: services.keepAwake)
        case .backlight:
            BacklightView(backlight: services.backlight)
        // R7 fills this one. It samples nothing until it does.
        case .windows:
            PlaceholderTabView(tab: tab)
        case .keyboardLock:
            KeyboardLockView(settings: services.settings, lock: services.keyboardLock)
        case .settings:
            SettingsTabView(
                settings: services.settings,
                store: services.store,
                helper: services.helper,
                setup: services.setup,
                showOverview: { services.selectedTab = .overview }
            )
        }
    }
}
