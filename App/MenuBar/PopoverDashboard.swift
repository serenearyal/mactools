import SMCKit
import SwiftUI
import SysMetrics

/// Everything the window shows, at a glance: CPU, memory, storage, the
/// battery, and the heaviest processes.
///
/// Every section title opens the matching tab. The numbers come straight from
/// the stores, which sample at the user's interval while this is on screen.
struct PopoverDashboard: View {
    let services: AppServices
    let open: (MainTab) -> Void

    private var store: MetricsStore { services.store }

    /// Each section takes the store and reads its own domain out of it, so a
    /// pass that only moved the CPU redraws the CPU section alone. Reading a
    /// whole snapshot here would make every section depend on every number.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section(height: PopoverLayout.DashboardHeight.cpu) {
                CPUSection(store: store, open: open)
            }
            Divider()
            section(height: PopoverLayout.DashboardHeight.memory) {
                MemorySection(store: store, open: open)
            }
            Divider()
            section(height: PopoverLayout.DashboardHeight.storage) {
                StorageSection(store: store, open: open)
            }
            Divider()
            section(height: PopoverLayout.DashboardHeight.battery) {
                PopoverBattery(store: store, settings: services.settings, open: open)
            }
            Divider()
            section(height: PopoverLayout.DashboardHeight.processes) {
                ProcessSection(processes: services.processes, reports: services.reports, open: open)
            }
        }
    }

    /// The padding every section shares, and the size none of them may change.
    ///
    /// Both axes are fixed, which is what stops one section's new number from
    /// costing a measurement of the section under it and of the panel around
    /// it. Each section stacks its own rows, so the spacing inside a section
    /// stays that section's business.
    private func section<Content: View>(
        height: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, PopoverLayout.padding)
            .padding(.vertical, PopoverLayout.sectionSpacing)
            .frame(width: PopoverLayout.width, height: height, alignment: .topLeading)
    }
}

// MARK: - CPU

private struct CPUSection: View {
    let store: MetricsStore
    let open: (MainTab) -> Void

    private var cpu: CPUSample? { store.cpu }

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
                // Both boxes are as wide as the widest value they can hold, so
                // a load going from 9 % to 10 % moves nothing beside it.
                HStack(spacing: PopoverLayout.rowSpacing) {
                    Text("user \(Fmt.percent(cpu?.total.user ?? 0, fractionDigits: 1))")
                        .frame(width: 66, alignment: .trailing)
                    Text("sys \(Fmt.percent(cpu?.total.system ?? 0, fractionDigits: 1))")
                        .frame(width: 60, alignment: .trailing)
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

/// One cluster: its letter, and a bar per core.
///
/// The bars are one `Canvas` rather than a stack of shapes. A ten-core Mac
/// draws ten bars and ten overlays here on every sample, and each one was a
/// view of its own to lay out and invalidate; the drawing is two rounded
/// rectangles a core, so it is cheaper to draw it than to describe it.
private struct CoreGroup: View {
    let tag: String
    let loads: [Double]
    let tint: Color

    private static let barWidth: CGFloat = 6
    private static let barSpacing: CGFloat = 3
    private static let barHeight: CGFloat = 22
    private static let cornerRadius: CGFloat = 1.5

    var body: some View {
        HStack(alignment: .bottom, spacing: CoreGroup.barSpacing) {
            Text(tag)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                draw(in: context, size: size)
            }
            .frame(width: width, height: CoreGroup.barHeight)
            .allowsHitTesting(false)
        }
    }

    private var width: CGFloat {
        guard !loads.isEmpty else { return 0 }
        return CGFloat(loads.count) * CoreGroup.barWidth
            + CGFloat(loads.count - 1) * CoreGroup.barSpacing
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        let track = Color(nsColor: .quaternaryLabelColor).opacity(0.5)
        for (index, load) in loads.enumerated() {
            let x = CGFloat(index) * (CoreGroup.barWidth + CoreGroup.barSpacing)
            context.fill(
                bar(x: x, height: size.height, in: size),
                with: .color(track)
            )
            let filled = max(1, size.height * load.clamped(to: 0...100) / 100)
            context.fill(bar(x: x, height: filled, in: size), with: .color(tint))
        }
    }

    /// One bar, grown from the bottom edge like the rectangle it replaces.
    private func bar(x: CGFloat, height: CGFloat, in size: CGSize) -> Path {
        Path(
            roundedRect: CGRect(
                x: x,
                y: size.height - height,
                width: CoreGroup.barWidth,
                height: height
            ),
            cornerRadius: CoreGroup.cornerRadius,
            style: .continuous
        )
    }
}

// MARK: - Memory

private struct MemorySection: View {
    let store: MetricsStore
    let open: (MainTab) -> Void

    private var memory: MemorySnapshot? { store.memory }

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
                    .frame(width: 146, alignment: .trailing)
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
                // Fixed boxes again: free and swap move all the time, and the
                // line they sit in must not breathe with them.
                Text(memory.map { "\(Fmt.memorySize($0.free)) free" } ?? "--")
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(memory.map { "\(Fmt.memorySize($0.swap.used)) swap" } ?? "--")
                    .monospacedDigit()
                    .frame(width: 82, alignment: .trailing)
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
    let store: MetricsStore
    let open: (MainTab) -> Void

    private var volume: VolumeInfo? { store.bootVolume }

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
                    .frame(width: 218, alignment: .trailing)
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
                    .frame(width: 96, alignment: .leading)
                Spacer(minLength: PopoverLayout.rowSpacing)
                Label(
                    Fmt.throughput(store.diskIO?.bytesReadPerSecond ?? 0),
                    systemImage: "arrow.down"
                )
                .monospacedDigit()
                .frame(width: 96, alignment: .trailing)
                Label(
                    Fmt.throughput(store.diskIO?.bytesWrittenPerSecond ?? 0),
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

// MARK: - Processes

private struct ProcessSection: View {
    let processes: ProcessStore
    let reports: ReportService
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
                // The confirmation sits in the row rather than under it, and
                // only where "Show All" already leaves room, so a copy changes
                // no height at all.
                if let confirmation = reports.confirmation {
                    Text(confirmation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                copyButton
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
            .animation(.easeInOut(duration: 0.2), value: reports.confirmation)

            HStack(alignment: .top, spacing: PopoverLayout.padding) {
                column(caption: "CPU", rows: cpuRows)
                column(caption: "MEMORY", rows: memoryRows)
            }
        }
    }

    /// The spinner keeps the same 18 pt box as the symbol: a copy taken with
    /// nothing sampled yet needs a second, and the header must not twitch.
    private var copyButton: some View {
        Button {
            reports.copyProcesses(samplesFirst: true)
        } label: {
            Group {
                if reports.isPreparing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "doc.on.clipboard")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(reports.isPreparing)
        .help("Copy processes for AI")
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
