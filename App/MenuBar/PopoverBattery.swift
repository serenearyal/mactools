import SwiftUI
import SysMetrics

/// The Battery section of the Dashboard: the charge, what the battery is
/// doing, and the four numbers a laptop owner looks up once a week.
///
/// It stands where Thermals and Fans used to be. Those moved to a section of
/// their own, where they have the room for the controls; the Dashboard is for
/// the numbers a glance is enough for, and on a laptop the charge is the first
/// of them.
///
/// Five fixed boxes, `PopoverLayout.DashboardHeight.battery*`: a Mac with no
/// battery, a battery that is calculating and a battery at 100 % all draw the
/// same height, so nothing in the panel moves between two samples.
struct PopoverBattery: View {
    let store: MetricsStore
    let settings: AppSettings
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
        VStack(alignment: .leading, spacing: PopoverLayout.rowSpacing) {
            titleRow
            levelBar
            stateRow
            statsRow
            detailRow
        }
        .task {
            try? await Task.sleep(for: PopoverBattery.settleDelay)
            settled = true
        }
    }

    // MARK: - The charge

    /// The title opens the Overview: there is no Battery tab, and the window
    /// shows the same reading there.
    private var titleRow: some View {
        HStack(spacing: PopoverLayout.rowSpacing) {
            PopoverSectionTitle(
                title: "Battery",
                symbolName: "battery.100percent",
                tab: .overview,
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
    /// and the palette is `MetricColor`'s so the Dashboard speaks one language
    /// from the CPU down to the battery.
    private var tint: Color {
        guard let reading = phase.reading else { return .secondary.opacity(0.4) }
        if reading.isPluggedIn, !reading.isCharging, reading.percent > 20 { return .green }
        switch reading.percent {
        case ..<11: return .red
        case ..<21: return .yellow
        default: return .green
        }
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
        case .waiting:
            return "Reading the battery…"
        case .absent:
            return "No battery. This Mac runs on mains power."
        case .battery(let reading):
            // `stateDescription` is the word for the state, and this is the
            // one place that adds the time to it. "Fully charged" rather than
            // its "Charged": the popover has the room, and the reader who
            // looks here wants to be told it is done, not labelled.
            if reading.isCharged || (reading.isPluggedIn && reading.percent >= 100) {
                return "Fully charged"
            }
            guard let minutes = reading.minutesRemaining else {
                // A battery that is neither charging nor emptying has no time
                // to report, and saying "calculating" about it would be a lie.
                guard reading.isCharging || !reading.isPluggedIn else {
                    return reading.stateDescription
                }
                return "\(reading.stateDescription) - calculating…"
            }
            let clause = reading.isCharging
                ? "\(PopoverBattery.duration(minutes)) to full"
                : "\(PopoverBattery.duration(minutes)) left"
            return "\(reading.stateDescription) - \(clause)"
        }
    }

    /// "38 min", "5 h 12 min", "5 h". Hours first, because the difference
    /// between four hours and five is what the reader is after.
    static func duration(_ minutes: Int) -> String {
        let total = max(0, minutes)
        guard total >= 60 else { return "\(total) min" }
        let hours = total / 60
        let rest = total % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    // MARK: - The numbers

    /// The three that move, in the same caption-over-value boxes the Fans
    /// section gives the dies. Each box is a third of the width whatever is in
    /// it, so a watt going from 9.8 to 10 moves nothing beside it.
    private var statsRow: some View {
        HStack(alignment: .top, spacing: PopoverLayout.rowSpacing) {
            PopoverStat(caption: powerCaption, value: powerText)
                .help("The power going into the battery, or coming out of it")
            PopoverStat(caption: "HEALTH", value: healthText)
                .help("What is left of the capacity this battery had when it was new")
            PopoverStat(caption: "CYCLES", value: cycleText)
                .help("Charge cycles since the battery was made")
        }
        .frame(height: Height.batteryStats)
    }

    /// The two that barely move, quiet under the three that do.
    private var detailRow: some View {
        HStack(spacing: PopoverLayout.rowSpacing) {
            Text(temperatureText)
            Spacer(minLength: PopoverLayout.rowSpacing)
            Text(adapterText)
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .frame(height: Height.batteryDetail)
    }

    /// "CHARGING" while the watts are going in, so the sign of the number
    /// below is spelled out rather than left to a plus.
    private var powerCaption: String {
        guard let reading = phase.reading, let watts = reading.watts, watts != 0 else {
            return "POWER"
        }
        return watts > 0 ? "CHARGING" : "DRAWING"
    }

    private var powerText: String {
        guard let reading = phase.reading, let watts = reading.watts else { return "--" }
        return PopoverBattery.signedWatts(watts)
    }

    /// Only while there is one to name: on battery the line above has already
    /// said so, and "No adapter" under it would be a second way to say
    /// nothing.
    private var adapterText: String {
        guard let reading = phase.reading, reading.isPluggedIn else { return "" }
        guard let adapter = reading.adapterWatts else { return "On the adapter" }
        return "\(adapter) W adapter"
    }

    /// "+46 W" into the battery, "-11.4 W" out of it. One decimal under 10 W,
    /// none above: a laptop on battery draws single digits, and a charger at
    /// 96 W does not need a tenth.
    static func signedWatts(_ watts: Double) -> String {
        let magnitude = abs(watts)
        let digits = magnitude < 10 ? 1 : 0
        let sign = watts > 0 ? "+" : (watts < 0 ? "-" : "")
        return "\(sign)\(magnitude.formatted(.number.precision(.fractionLength(digits)))) W"
    }

    private var healthText: String {
        guard let percent = phase.reading?.healthPercent else { return "--" }
        return "\(percent)%"
    }

    private var cycleText: String {
        guard let count = phase.reading?.cycleCount else { return "--" }
        return count.formatted()
    }

    private var temperatureText: String {
        guard let celsius = phase.reading?.temperatureCelsius else { return "" }
        return "Cells at \(Fmt.temperature(celsius, unit: settings.temperatureUnit))"
    }
}
