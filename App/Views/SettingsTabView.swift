import SMCKit
import SwiftUI

struct SettingsTabView: View {
    @Bindable var settings: AppSettings
    let store: MetricsStore

    var body: some View {
        Form {
            Section {
                metricList
                if !settings.availableMenuBarMetrics.isEmpty {
                    Menu {
                        ForEach(settings.availableMenuBarMetrics) { metric in
                            Button {
                                settings.setMenuBarMetric(metric, enabled: true)
                            } label: {
                                Label(metric.title, systemImage: metric.symbolName)
                            }
                        }
                    } label: {
                        Label("Add metric", systemImage: "plus")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                }
            } header: {
                Text("Menu bar metrics")
            } footer: {
                Text("Drag to reorder. The label keeps a fixed width for every metric, so the numbers never shift.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Label style", selection: $settings.labelStyle) {
                    ForEach(MenuBarLabelStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Toggle("Show icon", isOn: $settings.showMenuBarIcon)
                    .help("Hides the fan symbol to save room in a crowded menu bar")
                Picker("Temperature unit", selection: $settings.temperatureUnit) {
                    ForEach(TemperatureUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
            }

            Section("Sampling") {
                Picker("Refresh interval", selection: $settings.refreshInterval) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                .pickerStyle(.segmented)
                if settings.menuBarMetrics.contains(.sensorTemperature) {
                    Picker("Menu bar sensor", selection: $settings.sensorKey) {
                        ForEach(sensorChoices, id: \.key) { choice in
                            Text(choice.title).tag(choice.key)
                        }
                    }
                }
                Text("The window samples at this interval. With the window closed the app only reads what the menu bar shows, and it stops while the Mac sleeps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var metricList: some View {
        List {
            ForEach(settings.menuBarMetrics) { metric in
                HStack(spacing: Layout.gutter) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                        .imageScale(.small)
                    // Fixed width: the symbols differ in width, and without
                    // it every row would start its title at another x.
                    Image(systemName: metric.symbolName)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .center)
                    Text(metric.title)
                    Spacer(minLength: Layout.gutter)
                    Text(metric.caption)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button {
                        settings.setMenuBarMetric(metric, enabled: false)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from the menu bar")
                }
                .padding(.vertical, 1)
                // Every separator starts at the same x, at the row edge.
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            }
            .onMove { source, destination in
                settings.moveMenuBarMetrics(from: source, to: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: CGFloat(max(settings.menuBarMetrics.count, 1)) * 26 + 8)
    }

    private var sensorChoices: [(key: String, title: String)] {
        var choices = store.history.orderedSensors.map { trace in
            (key: trace.key.stringValue, title: "\(trace.label) (\(trace.key.stringValue))")
        }
        if !choices.contains(where: { $0.key == settings.sensorKey }) {
            choices.insert((key: settings.sensorKey, title: settings.sensorKey), at: 0)
        }
        return choices
    }
}
