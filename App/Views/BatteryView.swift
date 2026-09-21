import AppKit
import SwiftUI
import SysMetrics

/// The Battery tab: what the charge is doing now, what the pack is worth, how
/// the charge has moved since MacTools started, and which apps are spending it.
///
/// The tab exists because the popover could only ever show a glance of the
/// battery, and the two questions a laptop owner really has - "how long have I
/// got" and "what is eating it" - need room the popover does not have.
struct BatteryView: View {
    let store: MetricsStore
    let processes: ProcessStore
    let settings: AppSettings

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                BatteryContent(
                    store: store,
                    processes: processes,
                    settings: settings,
                    // The same rule the Overview follows: two columns while the
                    // pane is wide enough for two readable cards, one below it.
                    twoColumns: proxy.size.width >= Layout.twoColumnWidth
                )
                .padding(Layout.cardSpacing)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// The cards without the tab's scroll view, so the capture path can render
/// them: `ImageRenderer` draws nothing for an AppKit scroll view.
struct BatteryContent: View {
    let store: MetricsStore
    let processes: ProcessStore
    let settings: AppSettings
    var twoColumns = true

    /// Set once a pass that reads the battery has had time to land. Until
    /// then a nil reading is "not read yet", not "no battery": the store holds
    /// the same nil for both, and only time tells them apart.
    @State private var settled = false

    private static let settleDelay: Duration = .seconds(3)

    private var reading: BatteryReading? { store.battery }
    private var isAbsent: Bool { store.battery == nil && settled }

    var body: some View {
        VStack(spacing: Layout.cardSpacing) {
            if isAbsent {
                NoBatteryCard()
            } else {
                BatteryHeroCard(
                    reading: reading,
                    points: Array(store.history.battery),
                    settings: settings,
                    // Five tiles across a wide pane, three across a narrow one:
                    // at the 760 pt minimum window five of them leave about
                    // 100 pt each, and "Service recommended" needs more.
                    tilesPerRow: twoColumns ? 5 : 3
                )
            }

            if twoColumns, !isAbsent {
                Grid(horizontalSpacing: Layout.cardSpacing, verticalSpacing: Layout.cardSpacing) {
                    GridRow(alignment: .top) {
                        ChargeHistoryCard(points: Array(store.history.battery))
                        EnergyCard(processes: processes)
                    }
                }
            } else if isAbsent {
                // A desktop has no charge to graph, and the energy list is
                // exactly as useful there as it is on a laptop.
                EnergyCard(processes: processes)
            } else {
                ChargeHistoryCard(points: Array(store.history.battery))
                EnergyCard(processes: processes)
            }
        }
        .task {
            try? await Task.sleep(for: BatteryContent.settleDelay)
            settled = true
        }
    }
}

// MARK: - The charge

private struct BatteryHeroCard: View {
    let reading: BatteryReading?
    let points: [BatteryPoint]
    let settings: AppSettings
    let tilesPerRow: Int

    var body: some View {
        Card(title: "Battery", symbolName: BatteryText.symbolName(reading), fills: false) {
            HStack(alignment: .firstTextBaseline, spacing: Layout.gutter * 2) {
                Text(percentText)
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
                Text(BatteryText.state(reading))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: Layout.gutter)
                if reading?.lowPowerMode == true {
                    Label("Low Power Mode", systemImage: "battery.50percent")
                        .font(.callout.weight(.medium))
                        .imageScale(.small)
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background { Capsule(style: .continuous).fill(Color.yellow.opacity(0.14)) }
                        .help("The system is trading speed for battery life")
                }
            }

            SegmentedBar(
                segments: [.init(id: "level", value: fraction * 100, style: BatteryText.tint(reading))],
                total: 100,
                height: 12
            )
            .overlay(alignment: .leading) {
                if reading?.isCharging == true {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.leading, 5)
                        .accessibilityHidden(true)
                }
            }

            Divider()

            StatTileRow(tiles: tiles, perRow: tilesPerRow)
        }
    }

    private var percentText: String {
        guard let reading else { return "--" }
        return "\(reading.percent.clamped(to: 0...100))%"
    }

    private var fraction: Double {
        guard let reading else { return 0 }
        return Double(reading.percent.clamped(to: 0...100)) / 100
    }

    /// The numbers a laptop owner looks up once a week, in the order they are
    /// asked for: what it is drawing, what the pack is worth, how much of its
    /// life it has spent, how warm it is, and how long it has been on this side
    /// of the plug.
    private var tiles: [StatTileModel] {
        var tiles = [
            StatTileModel(
                id: "power",
                caption: "Power now",
                value: reading?.watts.map(BatteryText.signedWatts) ?? "--",
                detail: powerDetail
            ),
            StatTileModel(
                id: "health",
                caption: "Health",
                value: reading?.healthPercent.map { "\($0)%" } ?? "--",
                detail: healthDetail,
                tint: healthTint
            ),
            StatTileModel(
                id: "cycles",
                caption: "Cycles",
                value: reading?.cycleCount?.formatted() ?? "--",
                detail: "charge cycles"
            ),
            StatTileModel(
                id: "temperature",
                caption: "Temperature",
                value: reading?.temperatureCelsius
                    .map { Fmt.temperature($0, unit: settings.temperatureUnit) } ?? "--",
                detail: "the cells"
            ),
        ]
        if let since = sinceTile { tiles.append(since) }
        return tiles
    }

    private var powerDetail: String? {
        guard let reading else { return nil }
        guard reading.isPluggedIn else { return "out of the battery" }
        guard let adapter = reading.adapterWatts else { return "on the adapter" }
        return "of \(adapter) W adapter"
    }

    private var healthDetail: String? {
        guard let percent = reading?.healthPercent else { return nil }
        // Apple's own threshold: below 80 % of the design capacity the battery
        // is a service part, and saying so is the whole point of the number.
        return percent < 80 ? "Service recommended" : "Normal"
    }

    private var healthTint: Color? {
        guard let percent = reading?.healthPercent, percent < 80 else { return nil }
        return .orange
    }

    /// How long ago the plug went in or came out - but only when the history
    /// watched it happen. A run that reaches the first point it has is a run
    /// that started before MacTools did, and its length is the uptime of the
    /// app rather than an answer to the question.
    private var sinceTile: StatTileModel? {
        guard let reading, let last = points.last else { return nil }
        var index = points.count - 1
        while index > 0, points[index - 1].isCharging == last.isCharging { index -= 1 }
        guard index > 0 else { return nil }
        let elapsed = Date.now.timeIntervalSince(points[index].date)
        guard elapsed >= 60 else { return nil }
        let value = BatteryText.duration(Int(elapsed / 60))
        if reading.isCharging {
            return StatTileModel(id: "since", caption: "Since plugged in", value: value, detail: "charging")
        }
        // Plugged in and not charging: the run began when the charge stopped,
        // which is not when the plug went in, so there is nothing honest to
        // say and the tile stays away.
        guard !reading.isPluggedIn else { return nil }
        return StatTileModel(id: "since", caption: "Since unplugged", value: value, detail: "on battery")
    }
}

/// What a Mac with no battery sees. Calm, one line, no dashes where numbers
/// would be: nothing is missing here, there is simply no battery.
private struct NoBatteryCard: View {
    var body: some View {
        Card(title: "Battery", symbolName: "powerplug", fills: false) {
            HStack(spacing: Layout.gutter * 1.5) {
                Image(systemName: "powerplug")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This Mac has no battery")
                        .font(.title3.weight(.medium))
                    Text("It runs on mains power. The energy list below still says which apps are working hardest.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Charge history

private struct ChargeHistoryCard: View {
    let points: [BatteryPoint]

    var body: some View {
        Card(title: "Charge history", symbolName: "chart.xyaxis.line") {
            if points.count < 2 {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                    // The chart takes whatever height the card has, so the
                    // card beside it decides the row and neither of them
                    // leaves a hole above its bottom edge.
                    .frame(minHeight: 160, maxHeight: .infinity)
                    .overlay {
                        Text("History starts when MacTools starts")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
            } else {
                ChargeHistoryChart(points: points)
                    .frame(minHeight: 160, maxHeight: .infinity)
                HStack(spacing: Layout.gutter) {
                    Text(BatteryText.span(points))
                    Spacer(minLength: Layout.gutter)
                    // Only while there is a band to explain: a key for a
                    // colour that is nowhere on the chart is noise.
                    if points.contains(where: \.isCharging) {
                        LegendItem(label: "Charging", value: "", style: Color.green.opacity(0.35))
                    }
                    Text("now")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// The charge over time, as one `Canvas` and three paths.
///
/// Not a `Chart`: one mark per point is one view per point to lay out, and a
/// day of history is 2 880 of them. The sparkline of the window was moved off
/// Swift Charts for exactly this reason, and this line is the same line.
struct ChargeHistoryChart: View {
    let points: [BatteryPoint]

    /// Room on the left for "100", and half a line width top and bottom so a
    /// full battery is not clipped in half.
    private static let gutter: CGFloat = 26
    private static let inset: CGFloat = 4

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            draw(in: context, size: size)
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Battery charge over time")
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        guard points.count > 1, size.width > ChargeHistoryChart.gutter + 8, size.height > 16 else {
            return
        }
        let plot = CGRect(
            x: ChargeHistoryChart.gutter,
            y: ChargeHistoryChart.inset,
            width: size.width - ChargeHistoryChart.gutter,
            height: size.height - ChargeHistoryChart.inset * 2
        )
        let first = points[0].date
        let span = max(points[points.count - 1].date.timeIntervalSince(first), 60)
        func x(_ date: Date) -> CGFloat {
            plot.minX + plot.width * CGFloat(date.timeIntervalSince(first) / span)
        }
        func y(_ percent: Int) -> CGFloat {
            plot.maxY - plot.height * CGFloat(percent.clamped(to: 0...100)) / 100
        }

        drawChargingBands(in: context, plot: plot, x: x)
        drawGrid(in: context, plot: plot, y: y)

        var line = Path()
        for (index, point) in points.enumerated() {
            let at = CGPoint(x: x(point.date), y: y(point.percent))
            if index == 0 { line.move(to: at) } else { line.addLine(to: at) }
        }
        var area = line
        area.addLine(to: CGPoint(x: x(points[points.count - 1].date), y: plot.maxY))
        area.addLine(to: CGPoint(x: x(first), y: plot.maxY))
        area.closeSubpath()
        context.fill(
            area,
            with: .linearGradient(
                Gradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)]),
                startPoint: CGPoint(x: plot.minX, y: plot.minY),
                endPoint: CGPoint(x: plot.minX, y: plot.maxY)
            )
        )
        context.stroke(
            line,
            with: .color(.accentColor),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        )
    }

    /// 0, 50 and 100, with the labels outside the plot on the left.
    private func drawGrid(in context: GraphicsContext, plot: CGRect, y: (Int) -> CGFloat) {
        for percent in [0, 50, 100] {
            let line = y(percent)
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: line))
            path.addLine(to: CGPoint(x: plot.maxX, y: line))
            context.stroke(
                path,
                with: .color(Color(nsColor: .quaternaryLabelColor).opacity(0.7)),
                lineWidth: 1
            )
            context.draw(
                Text("\(percent)").font(.caption2).foregroundStyle(Color.secondary),
                at: CGPoint(x: plot.minX - 6, y: line),
                anchor: .trailing
            )
        }
    }

    /// Every stretch the charger was putting energy in, as a band behind the
    /// line: the shape of a day is "it fell, then it was plugged in", and the
    /// band is what says which is which without a second chart.
    private func drawChargingBands(
        in context: GraphicsContext,
        plot: CGRect,
        x: (Date) -> CGFloat
    ) {
        var index = 0
        while index < points.count {
            guard points[index].isCharging else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < points.count, points[end + 1].isCharging { end += 1 }
            let start = x(points[index].date)
            // A run that reaches the last point runs to the right edge; any
            // other ends where the next point already was not charging.
            let stop = end + 1 < points.count ? x(points[end + 1].date) : plot.maxX
            context.fill(
                Path(CGRect(x: start, y: plot.minY, width: max(2, stop - start), height: plot.height)),
                with: .color(.green.opacity(0.16))
            )
            index = end + 1
        }
    }
}

// MARK: - Using the most energy

private struct EnergyCard: View {
    let processes: ProcessStore

    /// Six fills the card at the 900 x 600 default window without scrolling.
    /// The store keeps ten; the tail of a list like this is noise.
    private static let rows = 6

    private var apps: [AppEnergy] { Array(processes.topEnergyApps.prefix(EnergyCard.rows)) }

    var body: some View {
        Card(title: "Using the most energy", symbolName: "bolt") {
            if apps.isEmpty {
                HStack {
                    Text("Measuring…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(height: 64)
            } else {
                VStack(spacing: Layout.gutter) {
                    ForEach(apps) { EnergyRow(app: $0) }
                }
            }
            Spacer(minLength: Layout.gutter)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The honest small print: this is the CPU energy of the processes of an
    /// app and nothing else. A bright display and a busy radio are most of a
    /// laptop's draw, and neither is counted here.
    private var caption: String {
        "Mean over \(BatteryText.window(seconds: processes.energyWindowSeconds)). "
            + "CPU energy only: the display and radios are not counted."
    }
}

private struct EnergyRow: View {
    let app: AppEnergy

    var body: some View {
        HStack(spacing: Layout.gutter) {
            Image(nsImage: BatteryText.icon(bundlePath: app.bundlePath))
                .resizable()
                .frame(width: 18, height: 18)
            Text(app.name)
                .lineLimit(1)
                .truncationMode(.tail)
            if app.processCount > 1 {
                Text(app.processCount.formatted())
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background { Capsule(style: .continuous).fill(Color.secondary.opacity(0.14)) }
                    .help("\(app.processCount) processes")
            }
            Spacer(minLength: Layout.gutter)
            SegmentedBar(
                segments: [.init(id: app.id, value: app.share.clamped(to: 0...1), style: Color.accentColor)],
                total: 1,
                height: 5
            )
            .frame(width: 72)
            Text(Fmt.appWatts(app.watts))
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
        .font(.callout)
        .help("\(app.name): \(Fmt.percent(app.share, fractionDigits: 0)) of the energy of all processes")
    }
}

// MARK: - The words

/// The sentences and the symbols the battery has, in one place: the popover
/// section and the tab say the same thing about the same reading.
enum BatteryText {
    /// "On battery - 2 h 5 min left", "Charging - 40 min to full".
    static func state(_ reading: BatteryReading?) -> String {
        guard let reading else { return "Reading the battery…" }
        // "Fully charged" rather than `stateDescription`'s "Charged": there is
        // room here to tell the reader it is done rather than to label it.
        if reading.isCharged || (reading.isPluggedIn && reading.percent >= 100) {
            return "Fully charged"
        }
        guard let minutes = reading.minutesRemaining else {
            // A battery that is neither charging nor emptying has no time to
            // report, and "calculating" about it would be a lie.
            guard reading.isCharging || !reading.isPluggedIn else { return reading.stateDescription }
            return "\(reading.stateDescription) - calculating…"
        }
        let clause = reading.isCharging
            ? "\(duration(minutes)) to full"
            : "\(duration(minutes)) left"
        return "\(reading.stateDescription) - \(clause)"
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

    /// "+46 W" into the battery, "-11.4 W" out of it. One decimal under 10 W,
    /// none above: a laptop on battery draws single digits, and a charger at
    /// 96 W does not need a tenth.
    static func signedWatts(_ watts: Double) -> String {
        let magnitude = abs(watts)
        let digits = magnitude < 10 ? 1 : 0
        let sign = watts > 0 ? "+" : (watts < 0 ? "-" : "")
        return "\(sign)\(magnitude.formatted(.number.precision(.fractionLength(digits)))) W"
    }

    /// The symbol that matches the charge, so the card title carries the level
    /// the way the menu bar does.
    static func symbolName(_ reading: BatteryReading?) -> String {
        guard let reading else { return "battery.75percent" }
        if reading.isCharging { return "battery.100percent.bolt" }
        switch reading.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Green, amber, red, at the thresholds macOS itself warns at.
    static func tint(_ reading: BatteryReading?) -> Color {
        guard let reading else { return .secondary.opacity(0.4) }
        if reading.isPluggedIn, !reading.isCharging, reading.percent > 20 { return .green }
        switch reading.percent {
        case ..<11: return .red
        case ..<21: return .yellow
        default: return .green
        }
    }

    /// "the last 3 min", "the last 45 s". The window is the energy sampler's,
    /// and it is short until the app has been running for a while.
    static func window(seconds: Double) -> String {
        guard seconds >= 90 else { return "the last \(Int(seconds.rounded())) s" }
        return "the last \(duration(Int((seconds / 60).rounded())))"
    }

    /// How much of the day the chart covers: "the last 2 h 10 min".
    static func span(_ points: [BatteryPoint]) -> String {
        guard let first = points.first, let last = points.last else { return "" }
        let minutes = Int(last.date.timeIntervalSince(first.date) / 60)
        return minutes < 1 ? "the last minute" : "the last \(duration(minutes))"
    }

    /// The icon of an app, out of the cache the process table fills.
    ///
    /// `pid: -1` on purpose: there is no one process behind an app that runs
    /// twelve of them, so the lookup goes straight to the bundle, and the
    /// cache is keyed by that path.
    @MainActor
    static func icon(bundlePath: String?) -> NSImage {
        ProcessIconCache.shared.icon(pid: -1, path: bundlePath)
    }
}
