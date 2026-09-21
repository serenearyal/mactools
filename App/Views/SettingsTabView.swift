import SMCKit
import SwiftUI

struct SettingsTabView: View {
    @Bindable var settings: AppSettings
    let store: MetricsStore
    let helper: HelperController
    let setup: SetupChecklist
    /// Where "Show setup checklist" sends the user, since the card lives on
    /// the Overview.
    let showOverview: () -> Void

    var body: some View {
        Form {
            HelperSectionView(helper: helper)

            Section {
                launchAtLoginRow
                // Never disabled, even while the card is on screen: the button
                // is also how a user finds the checklist again, and landing
                // on the Overview is the right answer either way.
                Button("Show setup checklist") {
                    setup.show()
                    showOverview()
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("MacTools only measures while it runs. The checklist on the Overview tracks the four permissions it asks for.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

            Section {
                Picker("Show in menu bar", selection: $settings.menuBarContent) {
                    ForEach(MenuBarContent.allCases) { content in
                        Text(content.title).tag(content)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Label style", selection: $settings.labelStyle) {
                    ForEach(MenuBarLabelStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .disabled(isIconOnly)
                Toggle("Show icon", isOn: $settings.showMenuBarIcon)
                    .help("Hides the fan symbol to save room in a crowded menu bar")
                    .disabled(isIconOnly)
                Picker("Temperature unit", selection: $settings.temperatureUnit) {
                    ForEach(TemperatureUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                Toggle("Show Dock icon", isOn: $settings.showDockIcon)
                    .help("Also show MacTools in the Dock and in the app switcher")
                Text("With the Dock icon on, clicking it opens the window. It is the way back when a full menu bar hides the status item behind the notch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Appearance")
            } footer: {
                Text(isIconOnly
                    ? "Icon only shrinks the item to about 36 pt, against the 95 pt of two two-line metrics. On a notched Mac that is often the difference between an item you can see and one the system hides."
                    : "The window keeps showing every metric; this is only what the menu bar has room for.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Tint hot temperatures", isOn: $settings.tintsHotTemperatures)
                    .help("Amber at 70 °C, orange at 80 °C, red at 90 °C, whatever unit the label shows")
                Toggle("Spin the fan icon", isOn: $settings.spinsFanIcon)
                    .help("The symbol turns with the fastest fan, and stands still while the fans do")
                    .disabled(!settings.showMenuBarIcon && !isIconOnly)
            } header: {
                Text("Menu bar")
            } footer: {
                Text("Only the temperature itself changes colour, and only the value, not the caption. The fan turns from one revolution in three seconds at its slowest to one in half a second at full speed; it stands still at 0 rpm, in Low Power Mode and with Reduce Motion on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        // The user can remove the login item in System Settings while MacTools is
        // running, so the toggle reads the live status instead of a boolean of
        // its own, here and on every activation.
        .onAppear { setup.launchAtLogin.refresh() }
    }

    private var isIconOnly: Bool { settings.menuBarContent == .iconOnly }

    @ViewBuilder
    private var launchAtLoginRow: some View {
        let login = setup.launchAtLogin
        Toggle("Launch at login", isOn: Binding(
            get: { login.status.isEnabled },
            set: { wanted in Task { await login.setEnabled(wanted) } }
        ))
        .disabled(login.isBusy)

        if let detail = login.status.detail {
            HStack(alignment: .firstTextBaseline, spacing: Layout.gutter) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 20, alignment: .center)
                Text(detail)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Layout.gutter)
                Button("Open Login Items Settings") { login.openLoginItemsSettings() }
            }
        }
        if let failure = login.failure {
            Label(failure, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The chosen metrics, in order, draggable.
    ///
    /// A `VStack` and not a `List`: a list inside a `Form` has no height of its
    /// own, and the hard-coded `count * 26 + 8` it used to be given clipped
    /// every row the moment a font or a control grew. This is as tall as its
    /// rows are, whatever they contain, and the reordering is a drag from one
    /// row onto another instead of a list's own move gesture.
    private var metricList: some View {
        VStack(spacing: 0) {
            ForEach(Array(settings.menuBarMetrics.enumerated()), id: \.element) { index, metric in
                if index > 0 { Divider() }
                metricRow(metric)
                    .draggable(metric.rawValue)
                    .dropDestination(for: String.self) { items, _ in
                        move(items, before: index)
                    }
            }
            if settings.menuBarMetrics.isEmpty {
                HStack {
                    Text("The label shows the fan symbol alone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func metricRow(_ metric: MenuBarMetric) -> some View {
        HStack(spacing: Layout.gutter) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .imageScale(.small)
            // Fixed width: the symbols differ in width, and without it every
            // row would start its title at another x.
            Image(systemName: metric.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            Text(metric.title)
                .lineLimit(1)
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
        .padding(.vertical, 5)
        // The whole row is the drag handle and the drop target, not just the
        // text inside it.
        .contentShape(.rect)
    }

    /// Drops the dragged metric in front of the row it was let go over.
    private func move(_ items: [String], before index: Int) {
        guard let raw = items.first,
              let dragged = MenuBarMetric(rawValue: raw),
              let from = settings.menuBarMetrics.firstIndex(of: dragged),
              from != index
        else { return }
        // `move(fromOffsets:toOffset:)` counts the destination in the array as
        // it is before the move, so a drag downwards lands one place short.
        settings.moveMenuBarMetrics(
            from: IndexSet(integer: from),
            to: from < index ? index + 1 : index
        )
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
