import FanControl
import SMCKit
import SwiftUI
import SysMetrics

/// Everything the window shows, at a glance: CPU, memory, storage, thermals
/// with the two fan commands, and the heaviest processes.
///
/// Every section title opens the matching tab. The numbers come straight from
/// the stores, which sample at the user's interval while this is on screen.
struct PopoverDashboard: View {
    let services: AppServices
    let actions: MenuBarPopoverActions
    let open: (MainTab) -> Void

    private var store: MetricsStore { services.store }
    private var snapshot: MetricsSnapshot { services.store.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section { CPUSection(store: store, open: open) }
            Divider()
            section { MemorySection(memory: snapshot.memory, open: open) }
            Divider()
            section { StorageSection(snapshot: snapshot, open: open) }
            Divider()
            section {
                ThermalSection(
                    snapshot: snapshot,
                    fans: services.fans,
                    helper: services.helper,
                    settings: services.settings,
                    actions: actions,
                    open: open
                )
            }
            Divider()
            section { ProcessSection(processes: services.processes, open: open) }
        }
    }

    /// The padding every section shares. Each section stacks its own rows, so
    /// the spacing inside a section stays that section's business.
    private func section<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, PopoverLayout.padding)
            .padding(.vertical, PopoverLayout.sectionSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - CPU

private struct CPUSection: View {
    let store: MetricsStore
    let open: (MainTab) -> Void

    private var cpu: CPUSample? { store.snapshot.cpu }

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverLayout.rowSpacing) {
            HStack(spacing: PopoverLayout.rowSpacing) {
                PopoverSectionTitle(title: "CPU", symbolName: "cpu", tab: .overview, open: open)
                Spacer(minLength: PopoverLayout.rowSpacing)
                Sparkline(values: Array(store.history.cpuTotal), minimumRange: 5)
                    .frame(width: 96, height: 18)
                Text(cpu.map { Fmt.compactPercent($0.total.percent) } ?? "--")
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }

            HStack(alignment: .bottom, spacing: PopoverLayout.sectionSpacing) {
                CoreGroup(tag: "E", loads: loads(of: .efficiency), tint: .accentColor.opacity(0.55))
                CoreGroup(tag: "P", loads: loads(of: .performance), tint: .accentColor)
                Spacer(minLength: PopoverLayout.rowSpacing)
                HStack(spacing: PopoverLayout.rowSpacing) {
                    Text("user \(Fmt.percent(cpu?.total.user ?? 0, fractionDigits: 1))")
                    Text("sys \(Fmt.percent(cpu?.total.system ?? 0, fractionDigits: 1))")
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
    }

    /// The loads of one cluster, or a bar per core of that cluster at zero
    /// before the first sample, so the row has its final height at once.
    private func loads(of kind: CoreKind) -> [Double] {
        guard let cpu else {
            let count = kind == .performance
                ? store.topology.performanceCount
                : store.topology.efficiencyCount
            return Array(repeating: 0, count: count)
        }
        return cpu.cores.indices
            .filter { cpu.kind(ofCore: $0) == kind }
            .map { cpu.cores[$0].percent }
    }
}

private struct CoreGroup: View {
    let tag: String
    let loads: [Double]
    let tint: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            Text(tag)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(Array(loads.enumerated()), id: \.offset) { _, load in
                CoreBar(percent: load, tint: tint)
            }
        }
    }
}

private struct CoreBar: View {
    let percent: Double
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
            .frame(width: 6, height: 22)
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(tint)
                    .frame(height: max(1, 22 * percent.clamped(to: 0...100) / 100))
            }
    }
}

// MARK: - Memory

private struct MemorySection: View {
    let memory: MemorySnapshot?
    let open: (MainTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverLayout.rowSpacing) {
            HStack(spacing: PopoverLayout.rowSpacing) {
                PopoverSectionTitle(
                    title: "Memory",
                    symbolName: "memorychip",
                    tab: .overview,
                    open: open
                )
                Spacer(minLength: PopoverLayout.rowSpacing)
                Text(usage)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(MetricColor.pressure(memory?.pressure))
                    .help("\(pressure) memory pressure")
            }

            SegmentedBar(
                segments: [
                    .init(id: "app", value: Double(memory?.app ?? 0), style: Color.accentColor),
                    .init(id: "wired", value: Double(memory?.wired ?? 0), style: Color.accentColor.opacity(0.65)),
                    .init(id: "compressed", value: Double(memory?.compressed ?? 0), style: Color.accentColor.opacity(0.4)),
                    .init(id: "cached", value: Double(memory?.cachedFiles ?? 0), style: Color.secondary.opacity(0.35)),
                ],
                total: Double(memory?.total ?? 1),
                height: 7
            )

            HStack(spacing: PopoverLayout.rowSpacing) {
                Text("\(pressure) pressure")
                Spacer(minLength: PopoverLayout.rowSpacing)
                Text(memory.map { "\(Fmt.memorySize($0.free)) free" } ?? "--")
                    .monospacedDigit()
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(memory.map { "\(Fmt.memorySize($0.swap.used)) swap" } ?? "--")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var usage: String {
        guard let memory else { return "--" }
        return "\(Fmt.memorySize(memory.used)) of \(Fmt.memorySize(memory.total))"
    }

    private var pressure: String {
        memory?.pressure?.label.capitalized ?? "Normal"
    }
}

// MARK: - Storage

private struct StorageSection: View {
    let snapshot: MetricsSnapshot
    let open: (MainTab) -> Void

    private var volume: VolumeInfo? { snapshot.bootVolume }

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverLayout.rowSpacing) {
            HStack(spacing: PopoverLayout.rowSpacing) {
                PopoverSectionTitle(
                    title: "Storage",
                    symbolName: "internaldrive",
                    tab: .storage,
                    open: open
                )
                Spacer(minLength: PopoverLayout.rowSpacing)
                Text(usage)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }

            SegmentedBar(
                segments: [
                    .init(
                        id: "used",
                        value: Double(volume?.used ?? 0),
                        style: barStyle
                    )
                ],
                total: Double(volume?.total ?? 1),
                height: 7
            )

            HStack(spacing: PopoverLayout.rowSpacing) {
                Text(volume.map { "\(Fmt.storageSize($0.available)) free" } ?? "--")
                    .monospacedDigit()
                Spacer(minLength: PopoverLayout.rowSpacing)
                Label(
                    Fmt.throughput(snapshot.diskIO?.bytesReadPerSecond ?? 0),
                    systemImage: "arrow.down"
                )
                .monospacedDigit()
                .frame(width: 96, alignment: .trailing)
                Label(
                    Fmt.throughput(snapshot.diskIO?.bytesWrittenPerSecond ?? 0),
                    systemImage: "arrow.up"
                )
                .monospacedDigit()
                .frame(width: 96, alignment: .trailing)
            }
            .font(.caption)
            .imageScale(.small)
            .foregroundStyle(.secondary)
        }
    }

    private var usage: String {
        guard let volume else { return "--" }
        return "\(Fmt.storageSize(volume.used)) of \(Fmt.storageSize(volume.total)) used"
    }

    private var barStyle: Color {
        guard let volume, volume.usedFraction >= 0.9 else { return .accentColor }
        return MetricColor.usage(volume.usedFraction)
    }
}

// MARK: - Thermals and fans

private struct ThermalSection: View {
    let snapshot: MetricsSnapshot
    let fans: FanStore
    let helper: HelperController
    let settings: AppSettings
    let actions: MenuBarPopoverActions
    let open: (MainTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverLayout.rowSpacing) {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: PopoverLayout.rowSpacing) {
            PopoverSectionTitle(
                title: "Thermals & Fans",
                symbolName: "thermometer.medium",
                tab: .fans,
                open: open
            )
            Spacer(minLength: PopoverLayout.rowSpacing)
            if fans.interlockEngaged {
                Label("Interlock", systemImage: "thermometer.sun.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .help("A die above 100 °C: every fan is back on Auto")
            }
        }

        HStack(alignment: .top, spacing: PopoverLayout.rowSpacing) {
            PopoverStat(
                caption: "CPU",
                value: temperature(snapshot.hottestCPU),
                tint: snapshot.hottestCPU.map { MetricColor.temperature($0.celsius) }
            )
            PopoverStat(
                caption: "GPU",
                value: temperature(snapshot.hottest(in: .gpu)),
                tint: snapshot.hottest(in: .gpu).map { MetricColor.temperature($0.celsius) }
            )
            PopoverStat(
                caption: "POWER",
                value: snapshot.systemPower.map { Fmt.watts($0.watts) } ?? "--"
            )
        }

        // Two at most: the popover keeps one height, and a Mac with more fans
        // has them all on the Fans tab.
        ForEach(fanRows.prefix(2), id: \.index) { row in
            HStack(spacing: PopoverLayout.rowSpacing) {
                Text(row.name)
                    .foregroundStyle(.secondary)
                Text(row.mode)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: PopoverLayout.rowSpacing)
                Text(row.rpm)
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
            }
            .font(.caption)
        }

        HStack(spacing: PopoverLayout.rowSpacing) {
            Button(action: actions.startAuto) {
                Text("Auto").frame(maxWidth: .infinity)
            }
            .help("Give every fan back to the firmware")
            Button(action: actions.startFullBlast) {
                Text("Full Blast").frame(maxWidth: .infinity)
            }
            .help("Hold every fan at its maximum RPM")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(!fans.isAvailable)

        // One line under the buttons, in this order: the helper is the wrong
        // build, then the last command was refused, then no helper at all. A
        // refused command is invisible anywhere else in the popover.
        if let mismatch = helper.mismatchMessage {
            PopoverHint(text: mismatch, tint: .red)
            Button("Open Settings") { open(.settings) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else if let refusal = fans.lastCommandFailure {
            PopoverHint(text: refusal, tint: .red)
        } else if !fans.isAvailable {
            PopoverHint(text: "Fan control needs the privileged helper.")
        }
    }

    private func temperature(_ reading: TemperatureReading?) -> String {
        reading.map { Fmt.temperature($0.celsius, unit: settings.temperatureUnit) } ?? "--"
    }

    /// The helper knows the mode the user asked for; without it the SMC read
    /// still gives the speed, and the mode is what the firmware reports.
    private var fanRows: [FanRow] {
        FanRow.rows(fans: fans, snapshot: snapshot)
    }
}

/// One fan, named the way both sources of truth allow.
struct FanRow {
    let index: Int
    let name: String
    let rpm: String
    let mode: String

    static func title(of mode: FanMode) -> String {
        switch mode {
        case .auto: "Auto"
        case .constant: "Constant"
        case .curve: "Curve"
        }
    }

    @MainActor
    static func rows(fans: FanStore, snapshot: MetricsSnapshot) -> [FanRow] {
        if fans.isAvailable, !fans.fans.isEmpty {
            return fans.fans.map { fan in
                FanRow(
                    index: fan.index,
                    name: "Fan \(fan.index + 1)",
                    rpm: Fmt.rpm(fan.actualRPM),
                    mode: title(of: fan.mode)
                )
            }
        }
        return snapshot.fans.map { fan in
            FanRow(
                index: fan.index,
                name: "Fan \(fan.index + 1)",
                rpm: Fmt.rpm(fan.actual),
                mode: fan.mode == .forced ? "Constant" : "Auto"
            )
        }
    }
}

// MARK: - Processes

private struct ProcessSection: View {
    let processes: ProcessStore
    let open: (MainTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverLayout.rowSpacing) {
            HStack(spacing: PopoverLayout.rowSpacing) {
                PopoverSectionTitle(
                    title: "Top Processes",
                    symbolName: "list.bullet.rectangle",
                    tab: .processes,
                    open: open
                )
                Spacer(minLength: PopoverLayout.rowSpacing)
                // Not `.link`: that style draws as an empty box under
                // `ImageRenderer`, which is how the capture path sees this.
                Button { open(.processes) } label: {
                    Text("Show All")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .top, spacing: PopoverLayout.padding) {
                column(caption: "CPU", rows: cpuRows)
                column(caption: "MEMORY", rows: memoryRows)
            }
        }
    }

    private func column(caption: String, rows: [ProcessLine]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(rows) { row in
                Button { open(.processes) } label: {
                    HStack(spacing: 4) {
                        Text(row.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(row.value)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                    .font(.caption)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Three rows either way: placeholders keep the popover the same height
    /// from the first paint, before the first libproc pass lands.
    private var cpuRows: [ProcessLine] {
        ProcessLine.padded(
            processes.topByCPU.prefix(3).map {
                ProcessLine(
                    id: $0.pid,
                    name: $0.name,
                    value: $0.cpuPercent.map { "\(Fmt.processCPU($0))%" } ?? "--"
                )
            }
        )
    }

    private var memoryRows: [ProcessLine] {
        ProcessLine.padded(
            processes.topByMemory.prefix(3).map {
                ProcessLine(
                    id: $0.pid,
                    name: $0.name,
                    value: $0.memoryBytes.map { Fmt.memorySize($0) } ?? "--"
                )
            }
        )
    }
}

private struct ProcessLine: Identifiable {
    let id: Int32
    let name: String
    let value: String

    static func padded(_ rows: [ProcessLine]) -> [ProcessLine] {
        guard rows.count < 3 else { return rows }
        return rows + (rows.count..<3).map {
            ProcessLine(id: Int32(-1 - $0), name: "--", value: "--")
        }
    }
}
