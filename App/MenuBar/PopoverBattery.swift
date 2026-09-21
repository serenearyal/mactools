import SwiftUI
import SysMetrics

/// The Battery section of the Dashboard: the charge, what the battery is
/// doing, the three numbers a laptop owner looks up, and the three apps that
/// are spending the charge right now.
///
/// It stands where Thermals and Fans used to be. Those moved to a section of
/// their own, where they have the room for the controls; the Dashboard is for
/// the numbers a glance is enough for, and on a laptop the charge is the first
/// of them.
///
/// Five fixed boxes, `PopoverLayout.DashboardHeight.battery*`: a Mac with no
/// battery, a battery that is calculating and a battery at 100 % all draw the
/// same height, so nothing in the panel moves between two samples. The header
/// opens the Battery tab, which is where the history, the cell temperature and
/// the whole energy list live.
struct PopoverBattery: View {
    let store: MetricsStore
    let processes: ProcessStore
    let open: (MainTab) -> Void

    private typealias Height = PopoverLayout.DashboardHeight

    /// Set once the section has been on screen long enough for a pass that
    /// reads the battery to have landed. See `phase`.
    @State private var settled = false

    /// The one read of the domain. `nil` is two different states, and only
    /// time tells them apart: a Mac with no battery at all, and a panel that
    /// opened before the first pass that asks for one came back. The store
    /// cannot say which - it holds the same nil either way - so the section
    /// says "reading" for as long as a pass may still be on its way, and
    /// "no battery" after that.
    private var phase: Phase {
        if let battery = store.battery { return .battery(battery) }
        return settled ? .absent : .waiting
    }

    /// How long a battery pass may take: the sampler reads it on the first
    /// pass after the popover asks for it, at the user's interval.
    private static let settleDelay: Duration = .seconds(3)

    private enum Phase {
        case battery(BatteryReading)
        case waiting
        case absent

        var reading: BatteryReading? {
            if case .battery(let reading) = self { return reading }
            return nil
        }

        var isAbsent: Bool {
            if case .absent = self { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverLayout.batteryRowSpacing) {
            titleRow
            levelBar
            stateRow
            statsRow
            energyRows
        }
        .task {
            try? await Task.sleep(for: PopoverBattery.settleDelay)
            settled = true
        }
    }

    // MARK: - The charge

    private var titleRow: some View {
        HStack(spacing: PopoverLayout.rowSpacing) {
            PopoverSectionTitle(
                title: "Battery",
                symbolName: "battery.100percent",
                tab: .battery,
                open: open
            )
            Spacer(minLength: PopoverLayout.rowSpacing)
            Text(percentText)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(phase.isAbsent ? .secondary : .primary)
                // The same 56 pt box as the CPU percentage above it, so the
                // two big numbers of the Dashboard sit on one right edge.
                .frame(width: 56, alignment: .trailing)
        }
        .frame(height: Height.batteryValue)
    }

    private var percentText: String {
        guard let reading = phase.reading else { return "--" }
        return "\(reading.percent.clamped(to: 0...100))%"
    }

    /// The same bar the memory and storage sections draw, so the three levels
    /// of the Dashboard are one shape at one height. The bolt sits inside the
    /// filled part while the charger is putting energy in.
    private var levelBar: some View {
        SegmentedBar(
            segments: [.init(id: "level", value: Double(fraction * 100), style: tint)],
            total: 100,
            height: Height.batteryBar
        )
        .overlay(alignment: .leading) {
            if phase.reading?.isCharging == true {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.leading, 3)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: Height.batteryBar)
    }

    private var fraction: Double {
        guard let reading = phase.reading else { return 0 }
        return Double(reading.percent.clamped(to: 0...100)) / 100
    }

    /// Green, amber, red. The thresholds are the ones macOS itself warns at,
    /// and the palette is the tab's, so the popover and the window say the
    /// same thing about the same charge.
    private var tint: Color {
        guard let reading = phase.reading else { return .secondary.opacity(0.4) }
        return BatteryText.tint(reading)
    }

    // MARK: - What it is doing

    private var stateRow: some View {
        HStack(spacing: PopoverLayout.rowSpacing) {
            Text(stateText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if phase.reading?.lowPowerMode == true {
                PopoverBadgeView(
                    badge: PopoverBadge(
                        text: "Low Power Mode",
                        symbolName: "battery.50percent",
                        tint: .yellow
                    )
                )
            }
            Spacer(minLength: 0)
        }
        .frame(height: Height.batteryState)
    }

    private var stateText: String {
        switch phase {
        case .waiting: return "Reading the battery…"
        case .absent: return "No battery. This Mac runs on mains power."
        case .battery(let reading): return BatteryText.state(reading)
        }
    }

    // MARK: - The numbers

    /// The three that move, on one line of caption-value pairs.
    ///
    /// They used to be three stacked boxes 34 pt tall, with the cell
    /// temperature and the adapter under them. One line of pairs says the same
    /// three things in 16 pt, and the 32 pt that buys is the energy list.
    private var statsRow: some View {
        HStack(spacing: PopoverLayout.padding) {
            pair(caption: powerCaption, value: powerText)
                .help("The power going into the battery, or coming out of it")
            pair(caption: "HEALTH", value: healthText)
                .help("What is left of the capacity this battery had when it was new")
            pair(caption: "CYCLES", value: cycleText)
                .help("Charge cycles since the battery was made")
            Spacer(minLength: PopoverLayout.rowSpacing)
            // The heading of the three rows under it, over the column they
            // are read in. Without it the list is three apps with watts
            // beside them, and the panel already has a list of processes.
            Text("ENERGY BY APP")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(height: Height.batteryStats)
    }

    private func pair(caption: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(caption)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .lineLimit(1)
    }

    /// "CHARGING" while the watts are going in, so the sign of the number
    /// beside it is spelled out rather than left to a plus.
    private var powerCaption: String {
        guard let reading = phase.reading, let watts = reading.watts, watts != 0 else {
            return "POWER"
        }
        return watts > 0 ? "CHARGING" : "DRAWING"
    }

    private var powerText: String {
        guard let reading = phase.reading, let watts = reading.watts else { return "--" }
        return BatteryText.signedWatts(watts)
    }

    private var healthText: String {
        guard let percent = phase.reading?.healthPercent else { return "--" }
        return "\(percent)%"
    }

    private var cycleText: String {
        guard let count = phase.reading?.cycleCount else { return "--" }
        return count.formatted()
    }

    // MARK: - What is spending it

    /// The three apps with the most energy behind them, in three 16 pt rows.
    ///
    /// The box is the same height whatever is in it: three rows, a line that
    /// says the measurement has not finished yet, or three placeholder rows on
    /// a Mac that has only just opened the panel.
    private var energyRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if apps.isEmpty {
                Text("Measuring which apps use the most energy…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(height: Height.batteryEnergyRow, alignment: .leading)
            } else {
                ForEach(apps) { app in
                    PopoverEnergyRow(app: app, open: open)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: Height.batteryEnergy, alignment: .topLeading)
    }

    private var apps: [AppEnergy] { Array(processes.topEnergyApps.prefix(3)) }
}

/// One app in the Dashboard's energy list: its icon, its name and its watts.
///
/// A click opens the Battery tab, where the same list has its share bars, its
/// process counts and the sentence that says what the measurement leaves out.
private struct PopoverEnergyRow: View {
    let app: AppEnergy
    let open: (MainTab) -> Void

    var body: some View {
        Button { open(.battery) } label: {
            HStack(spacing: 6) {
                Image(nsImage: BatteryText.icon(bundlePath: app.bundlePath))
                    .resizable()
                    .frame(width: 13, height: 13)
                Text(app.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(Fmt.appWatts(app.watts))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            .font(.caption)
            .frame(height: PopoverLayout.DashboardHeight.batteryEnergyRow)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(
            app.processCount > 1
                ? "\(app.name), \(app.processCount) processes. Open the Battery tab"
                : "\(app.name). Open the Battery tab"
        )
    }
}
