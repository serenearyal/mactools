import SMCKit
import SwiftUI

struct SensorsView: View {
    let store: MetricsStore
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if groups.isEmpty {
                ContentUnavailableView(
                    "No sensor is answering",
                    systemImage: "thermometer.medium.slash",
                    description: Text("The SMC did not return a plausible temperature.")
                )
            } else {
                table
            }
            Divider()
            powerRails
        }
    }

    private var header: some View {
        HStack(spacing: Layout.gutter) {
            Text("\(store.history.sensors.count) sensors")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: Layout.gutter)
            Toggle("Show unlabelled sensors", isOn: $settings.showUnlabelledSensors)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout)
        }
        .padding(.horizontal, Layout.cardPadding)
        .padding(.vertical, Layout.gutter * 1.5)
    }

    /// Every ideal width adds up to the 560 pt the detail pane has in the
    /// 760 pt minimum window. A `Table` lays its columns out at their ideal
    /// and clips what does not fit rather than shrinking to the minimum, so
    /// the sum of the ideals is what decides whether the last column is on
    /// screen at all.
    private var table: some View {
        Table(of: SensorTrace.self) {
            TableColumn("Sensor") { trace in
                Text(trace.label)
                    .lineLimit(1)
            }
            .width(min: 150, ideal: 210)

            TableColumn("Key") { trace in
                Text(trace.key.stringValue)
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            .width(44)

            TableColumn("Now") { trace in
                Text(Fmt.temperature(trace.current, unit: settings.temperatureUnit, digits: 1))
                    .monospacedDigit()
                    .foregroundStyle(MetricColor.temperature(trace.current))
            }
            .width(64)

            TableColumn("Min") { trace in
                Text(Fmt.temperature(trace.minimum, unit: settings.temperatureUnit, digits: 1))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(64)

            TableColumn("Max") { trace in
                Text(Fmt.temperature(trace.maximum, unit: settings.temperatureUnit, digits: 1))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(64)

            TableColumn("History") { trace in
                Sparkline(values: Array(trace.values), minimumRange: 2)
                    .frame(height: 18)
                    // The last column takes whatever is left, and the trace
                    // ran into the right edge of the window. Every other
                    // column keeps its distance; so does this one now.
                    .padding(.trailing, Layout.gutter)
            }
            .width(min: 50, ideal: 60)
        } rows: {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.traces) { trace in
                        TableRow(trace)
                    }
                }
            }
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
    }

    private var powerRails: some View {
        VStack(alignment: .leading, spacing: Layout.gutter) {
            Text("Power rails")
                .font(.headline)
            if store.snapshot.power.isEmpty {
                Text("No power rail is answering.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: Layout.cardPadding * 2) {
                    ForEach(store.snapshot.power, id: \.key) { rail in
                        StatBlock(caption: rail.label, value: Fmt.watts(rail.watts), size: .callout)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Layout.cardPadding)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var groups: [SensorGroup] {
        let traces = store.history.orderedSensors
        var order: [SensorCategory] = []
        var buckets: [SensorCategory: [SensorTrace]] = [:]
        for trace in traces {
            if buckets[trace.category] == nil { order.append(trace.category) }
            buckets[trace.category, default: []].append(trace)
        }
        return order.map { SensorGroup(category: $0, traces: buckets[$0] ?? []) }
    }
}

private struct SensorGroup: Identifiable {
    let category: SensorCategory
    let traces: [SensorTrace]

    var id: String { category.rawValue }
    var title: String { category.label }
}
