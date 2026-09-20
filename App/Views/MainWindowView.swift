import SwiftUI

struct MainWindowView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(MainTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbolName)
                        .tag(tab)
                }
            }
            .navigationSplitViewColumnWidth(min: 176, ideal: 192, max: 240)
        } detail: {
            TabDetailView(tab: services.selectedTab, services: services)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(services.selectedTab.title)
        }
        .frame(minWidth: 760, minHeight: 480)
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
            OverviewView(store: services.store, settings: services.settings)
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
            PlaceholderTabView(
                tab: .processes,
                description: "The sortable process table with CPU and memory arrives in a later batch."
            )
        case .storage:
            StorageView(store: services.store, storage: services.storage)
        case .keyboardLock:
            KeyboardLockView(settings: services.settings, lock: services.keyboardLock)
        case .settings:
            SettingsTabView(
                settings: services.settings,
                store: services.store,
                helper: services.helper
            )
        }
    }
}

struct PlaceholderTabView: View {
    let tab: MainTab
    let description: String

    var body: some View {
        ContentUnavailableView {
            Label(tab.title, systemImage: tab.symbolName)
        } description: {
            Text(description)
        }
    }
}
