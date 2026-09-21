import Charts
import SMCKit
import SwiftUI
import SysMetrics

struct OverviewView: View {
    let services: AppServices

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                // The setup card goes above the grid and pushes nothing out of
                // shape: the four cards keep their own height, and the tab
                // scrolls while the card is there. Dismissed, the layout is
                // the 2 x 2 grid that fits a 900 x 600 window exactly as it
                // did before.
                VStack(spacing: Layout.cardSpacing) {
                    if services.setup.isVisible {
                        SetupChecklistCard(checklist: services.setup)
                    }
                    OverviewCards(
                        store: services.store,
                        processes: services.processes,
                        settings: services.settings,
                        twoColumns: proxy.size.width >= Layout.twoColumnWidth,
                        open: { services.selectedTab = $0 }
                    )
                }
                .padding(Layout.cardSpacing)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear { services.setup.refresh() }
    }
}

/// The cards on their own, without the scroll view, so the capture path can
/// render them. A plain `Grid` rather than a lazy one: four cards, all of
/// them on screen.
struct OverviewCards: View {
    let store: MetricsStore
    let processes: ProcessStore
    let settings: AppSettings
    let twoColumns: Bool
    /// Where a card that is a summary of a tab sends the reader. The capture
    /// path renders the cards outside the window, where there is no tab to
    /// select, so it has somewhere to be nothing.
    var open: (MainTab) -> Void = { _ in }

    /// Every card takes the store, not a snapshot of it.
    ///
    /// A snapshot is one value: handing it down means this body reads every
    /// domain, so a pass that only moved the CPU invalidates the four cards and
    /// the grid around them. Reading `store.memory` inside the memory card is
    /// what keeps each card's redraw to its own numbers.
    @ViewBuilder
    var body: some View {
        if twoColumns {
            Grid(horizontalSpacing: Layout.cardSpacing, verticalSpacing: Layout.cardSpacing) {
                // Across the top, full width: the charge is the first thing a
                // laptop owner opens this window for, and the card is one row
                // tall. Below it the 2 x 2 grid is what it always was.
                GridRow(alignment: .top) {
                    BatteryCard(store: store, processes: processes, open: open)
                        .gridCellColumns(2)
                }
                GridRow(alignment: .top) {
                    CPUCard(store: store)
                    MemoryCard(store: store)
                }
                GridRow(alignment: .top) {
                    StorageCard(store: store)
                    ThermalsCard(store: store, settings: settings)
                }
            }
        } else {
            VStack(spacing: Layout.cardSpacing) {
                BatteryCard(store: store, processes: processes, open: open)
                CPUCard(store: store)
                MemoryCard(store: store)
                StorageCard(store: store)
                ThermalsCard(store: store, settings: settings)
            }
        }
    }
}

// MARK: - Battery

/// The charge, what it is doing, and the one app that is spending the most of
/// it. The whole card opens the Battery tab, where all of that has room.
private struct BatteryCard: View {
    let store: MetricsStore
    let processes: ProcessStore
    let open: (MainTab) -> Void

    @State private var hovering = false

    private var battery: BatteryReading? { store.battery }

    var body: some View {
        Button { open(.battery) } label: {
            // Not `.link` and not a bordered button: a link style draws as an
            // empty box under `ImageRenderer`, which is how the capture path
            // sees this card.
            card.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open the Battery tab")
    }

    private var card: some View {
        Card(title: "Battery", symbolName: BatteryText.symbolName(battery), fills: false) {
            HStack(alignment: .firstTextBaseline, spacing: Layout.gutter * 2) {
                Text(battery.map { "\($0.percent.clamped(to: 0...100))%" } ?? "--")
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text(BatteryText.state(battery))
                        .font(.callout)
                        .lineLimit(1)
                    Text(energyLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Layout.gutter)
                if battery?.lowPowerMode == true {
                    Label("Low Power Mode", systemImage: "battery.50percent")
                        .font(.caption.weight(.medium))
                        .imageScale(.small)
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background { Capsule(style: .continuous).fill(Color.yellow.opacity(0.14)) }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(hovering ? Color.secondary : Color(nsColor: .tertiaryLabelColor))
            }

            SegmentedBar(
                segments: [
                    .init(
                        id: "level",
                        value: Double(battery?.percent.clamped(to: 0...100) ?? 0),
                        style: BatteryText.tint(battery)
                    )
                ],
                total: 100
            )
        }
    }

    /// "Arc is using the most: 4.2 W", or what the list can honestly say
    /// before it has two samples to compare.
    private var energyLine: String {
        guard let top = processes.topEnergyApps.first else {
            return "Measuring which apps use the most energy…"
        }
        // "MacTools is using the most: 0.0 W" is a true sentence that says
        // nothing. Under a tenth of a watt the machine is idle, and that is
        // the thing worth saying.
        guard top.watts >= 0.05 else { return "No app is using much energy" }
        return "\(top.name) is using the most: \(Fmt.appWatts(top.watts))"
    }
}

// MARK: - CPU

private struct CPUCard: View {
    let store: MetricsStore

    private var total: Double { store.cpu?.total.percent ?? 0 }

    var body: some View {
        Card(title: "CPU", symbolName: "cpu") {
            HStack(alignment: .firstTextBaseline, spacing: Layout.gutter) {
                Text(store.cpu == nil ? "--" : Fmt.compactPercent(total))
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text("user \(Fmt.percent(store.cpu?.total.user ?? 0, fractionDigits: 1))")
                    Text("system \(Fmt.percent(store.cpu?.total.system ?? 0, fractionDigits: 1))")
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(store.topology.performanceCount)P + \(store.topology.efficiencyCount)E")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // These two heights decide whether all four cards fit in the
            // 900 x 600 default window without scrolling.
            HistoryAreaChart(values: Array(store.history.cpuTotal))
                .frame(height: 76)

            VStack(alignment: .leading, spacing: 4) {
                Text("Per core")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                coreChart
                    .frame(height: 66)
            }
        }
    }

    private var cores: [CoreLoad] {
        guard let cpu = store.cpu else { return [] }
        var efficiency = 0
        var performance = 0
        return cpu.cores.enumerated().map { index, usage in
            let kind = cpu.kind(ofCore: index)
            let number: Int
            if kind == .performance {
                performance += 1
                number = performance
            } else {
                efficiency += 1
                number = efficiency
            }
            return CoreLoad(index: index, kind: kind, label: "\(kind.tag)\(number)", percent: usage.percent)
        }
    }

    @ViewBuilder
    private var coreChart: some View {
        let loads = cores
        if loads.isEmpty {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                .overlay {
                    Text("Sampling…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
        } else {
            Chart(loads) { core in
                BarMark(
                    x: .value("Core", core.label),
                    y: .value("Load", core.percent),
                    width: .fixed(14)
                )
                .cornerRadius(3)
                .foregroundStyle(by: .value("Kind", core.kind == .performance ? "Performance" : "Efficiency"))
            }
            .chartForegroundStyleScale([
                "Efficiency": Color.accentColor.opacity(0.55),
                "Performance": Color.accentColor,
            ])
            .chartYScale(domain: 0...100)
            .chartYAxis {
                // Two marks only: the bars are 66 pt tall and three labels
                // would collide.
                AxisMarks(position: .leading, values: [0, 100]) {
                    AxisGridLine()
                    AxisValueLabel().font(.caption2).foregroundStyle(Color.secondary)
                }
            }
            .chartXAxis {
                AxisMarks { AxisValueLabel().font(.caption2).foregroundStyle(Color.secondary) }
            }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 4) {
                HStack(spacing: Layout.gutter * 1.5) {
                    LegendItem(label: "Efficiency", value: "", style: Color.accentColor.opacity(0.55))
                    LegendItem(label: "Performance", value: "", style: Color.accentColor)
                }
            }
        }
    }
}

private struct CoreLoad: Identifiable {
    let index: Int
    let kind: CoreKind
    let label: String
    let percent: Double

    var id: Int { index }
}

// MARK: - Memory

private struct MemoryCard: View {
    let store: MetricsStore

    var body: some View {
        Card(title: "Memory", symbolName: "memorychip") {
            if let memory = store.memory {
                HStack(alignment: .firstTextBaseline, spacing: Layout.gutter) {
                    Text("\(Fmt.memorySize(memory.used)) of \(Fmt.memorySize(memory.total))")
                        .font(.title3.weight(.medium))
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Label(
                        memory.pressure?.label.capitalized ?? "Unknown",
                        systemImage: "circle.fill"
                    )
                    .font(.caption)
                    .imageScale(.small)
                    .foregroundStyle(MetricColor.pressure(memory.pressure))
                }

                SegmentedBar(
                    segments: [
                        .init(id: "app", value: Double(memory.app), style: Color.accentColor),
                        .init(id: "wired", value: Double(memory.wired), style: Color.accentColor.opacity(0.65)),
                        .init(id: "compressed", value: Double(memory.compressed), style: Color.accentColor.opacity(0.4)),
                        .init(id: "cached", value: Double(memory.cachedFiles), style: Color.secondary.opacity(0.35)),
                    ],
                    total: Double(memory.total)
                )

                Grid(alignment: .leading, horizontalSpacing: Layout.gutter * 1.5, verticalSpacing: 6) {
                    GridRow {
                        LegendItem(label: "App", value: Fmt.memorySize(memory.app), style: Color.accentColor)
                        LegendItem(label: "Wired", value: Fmt.memorySize(memory.wired), style: Color.accentColor.opacity(0.65))
                    }
                    GridRow {
                        LegendItem(label: "Compressed", value: Fmt.memorySize(memory.compressed), style: Color.accentColor.opacity(0.4))
                        LegendItem(label: "Cached files", value: Fmt.memorySize(memory.cachedFiles), style: Color.secondary.opacity(0.35))
                    }
                }

                Divider()

                StatRow(label: "Swap used", value: "\(Fmt.memorySize(memory.swap.used)) of \(Fmt.memorySize(memory.swap.total))")
                StatRow(label: "Free", value: Fmt.memorySize(memory.free))

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent history")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Sparkline(values: Array(store.history.memoryUsed), minimumRange: 5)
                        .frame(height: 24)
                }
            } else {
                CardPlaceholder()
            }
        }
    }
}

// MARK: - Storage

private struct StorageCard: View {
    let store: MetricsStore

    var body: some View {
        Card(title: "Storage", symbolName: "internaldrive") {
            if let volume = store.bootVolume {
                Text("\(Fmt.storageSize(volume.used)) of \(Fmt.storageSize(volume.total)) used")
                    .font(.title3.weight(.medium))
                    .monospacedDigit()

                SegmentedBar(
                    segments: [
                        .init(id: "used", value: Double(volume.used), style: usedStyle(volume.usedFraction))
                    ],
                    total: Double(volume.total)
                )

                HStack {
                    Text(volume.name)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Layout.gutter)
                    Text("\(Fmt.storageSize(volume.available)) free")
                        .monospacedDigit()
                }
                .font(.callout)

                Divider()

                HStack(alignment: .top, spacing: Layout.cardPadding) {
                    VStack(alignment: .leading, spacing: 6) {
                        StatBlock(
                            caption: "Read",
                            value: Fmt.throughput(store.diskIO?.bytesReadPerSecond ?? 0),
                            size: .callout
                        )
                        Sparkline(values: Array(store.history.diskRead), minimumRange: 1_000_000)
                            .frame(height: 20)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        StatBlock(
                            caption: "Write",
                            value: Fmt.throughput(store.diskIO?.bytesWrittenPerSecond ?? 0),
                            size: .callout
                        )
                        Sparkline(values: Array(store.history.diskWrite), tint: .accentColor.opacity(0.6), minimumRange: 1_000_000)
                            .frame(height: 20)
                    }
                }
            } else {
                CardPlaceholder()
            }
        }
    }

    private func usedStyle(_ fraction: Double) -> Color {
        fraction >= 0.9 ? MetricColor.usage(fraction) : .accentColor
    }
}

// MARK: - Thermals

private struct ThermalsCard: View {
    let store: MetricsStore
    let settings: AppSettings

    var body: some View {
        Card(title: "Thermals", symbolName: "thermometer.medium") {
            if store.temperatures.isEmpty && store.fans.isEmpty {
                CardPlaceholder()
            } else {
                Grid(alignment: .leading, horizontalSpacing: Layout.cardPadding, verticalSpacing: Layout.gutter * 1.5) {
                    GridRow {
                        temperatureBlock("CPU", reading: store.hottestCPU)
                            .gridColumnAlignment(.leading)
                        temperatureBlock("GPU", reading: store.hottest(in: .gpu))
                            .gridColumnAlignment(.leading)
                    }
                    GridRow {
                        temperatureBlock("SSD", reading: store.hottest(in: .ssd))
                        temperatureBlock("Battery", reading: store.hottest(in: .battery))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                HStack(alignment: .top, spacing: Layout.cardPadding) {
                    StatBlock(
                        caption: "System power",
                        value: store.systemPower.map { Fmt.watts($0.watts) } ?? "--",
                        size: .callout
                    )
                    Spacer(minLength: 0)
                    ForEach(store.fans, id: \.index) { fan in
                        StatBlock(
                            caption: "Fan \(fan.index + 1)",
                            value: Fmt.rpm(fan.actual),
                            size: .callout
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func temperatureBlock(_ caption: String, reading: TemperatureReading?) -> some View {
        StatBlock(
            caption: caption,
            value: reading.map { Fmt.temperature($0.celsius, unit: settings.temperatureUnit) } ?? "--",
            tint: reading.map { MetricColor.temperature($0.celsius) },
            size: .title3
        )
    }
}

private struct CardPlaceholder: View {
    var body: some View {
        HStack {
            Text("Sampling…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(height: 64)
    }
}
