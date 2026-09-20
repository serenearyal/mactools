import AppKit
import SMCKit
import SwiftUI

/// One metric as it appears in the status item.
struct MenuBarCell: Equatable, Identifiable {
    let metric: MenuBarMetric
    let caption: String
    let value: String
    /// The widest string this cell can ever show. It sets the cell width.
    let widest: String

    var id: String { metric.rawValue }
}

/// Turns a snapshot into the strings the label shows.
@MainActor
enum MenuBarLabel {
    static let placeholder = "--"

    static func cells(snapshot: MetricsSnapshot, settings: AppSettings) -> [MenuBarCell] {
        // Icon only: no cell at all, and the label falls back to the bare
        // symbol. It is the whole mechanism behind the setting.
        guard settings.menuBarContent == .metrics else { return [] }
        return settings.menuBarMetrics.map { metric in
            MenuBarCell(
                metric: metric,
                caption: caption(for: metric, settings: settings),
                value: value(for: metric, snapshot: snapshot, settings: settings),
                widest: metric.widestValue
            )
        }
    }

    private static func caption(for metric: MenuBarMetric, settings: AppSettings) -> String {
        guard metric == .sensorTemperature, let key = SMCFourCC(code: settings.sensorKey) else {
            return metric.caption
        }
        let category = SensorNaming.descriptor(for: key).category
        guard category != .other else {
            return key.stringValue.trimmingCharacters(in: .whitespaces).uppercased()
        }
        return category.menuBarCaption
    }

    private static func value(
        for metric: MenuBarMetric,
        snapshot: MetricsSnapshot,
        settings: AppSettings
    ) -> String {
        switch metric {
        case .cpuUsage:
            guard let cpu = snapshot.cpu else { return placeholder }
            return Fmt.compactPercent(cpu.total.percent)
        case .memoryUsed:
            guard let memory = snapshot.memory else { return placeholder }
            return Fmt.compactBytes(Double(memory.used))
        case .memoryPercent:
            guard let memory = snapshot.memory else { return placeholder }
            return Fmt.compactPercent(memory.usedFraction * 100)
        case .diskUsedPercent:
            guard let volume = snapshot.bootVolume else { return placeholder }
            return Fmt.compactPercent(volume.usedFraction * 100)
        case .diskFree:
            guard let volume = snapshot.bootVolume else { return placeholder }
            return Fmt.compactBytes(Double(volume.available), base: 1000)
        case .cpuTemperature:
            guard let reading = snapshot.hottestCPU else { return placeholder }
            return Fmt.compactTemperature(reading.celsius, unit: settings.temperatureUnit)
        case .sensorTemperature:
            guard let key = SMCFourCC(code: settings.sensorKey),
                  let reading = snapshot.temperature(forKey: key)
            else { return placeholder }
            return Fmt.compactTemperature(reading.celsius, unit: settings.temperatureUnit)
        case .fanSpeed:
            guard let fan = snapshot.fastestFan else { return placeholder }
            return Fmt.compactRPM(fan.actual)
        case .systemPower:
            guard let power = snapshot.systemPower else { return placeholder }
            return Fmt.compactWatts(power.watts)
        case .diskIO:
            guard snapshot.diskIO != nil else { return placeholder }
            return Fmt.compactBytes(snapshot.diskThroughput, base: 1000)
        }
    }
}

extension SensorCategory {
    /// Four characters at most, to match the CPU / MEM / SSD captions.
    var menuBarCaption: String {
        switch self {
        case .cpuPerformance, .cpuEfficiency: "CPU"
        case .gpu: "GPU"
        case .memory: "MEM"
        case .enclosure: "ENCL"
        case .battery: "BATT"
        case .wireless: "WIFI"
        case .ambient: "AIR"
        case .ssd: "SSD"
        case .other: "SENS"
        }
    }
}

/// The font sizes and the geometry of the label, in one place, so the view
/// and the width measurement cannot drift apart.
enum MenuBarMetrics {
    static let height: CGFloat = 20
    static let iconSize: CGFloat = 10
    /// On its own the symbol carries the whole item, so it is drawn at the
    /// size the other icons of the menu bar use rather than the small size
    /// that sits next to a two-line cell.
    static let soloIconSize: CGFloat = 13
    /// The menu bar of a notched Mac is short, so every point counts.
    static let cellSpacing: CGFloat = 4
    static let iconSpacing: CGFloat = 3
    static let horizontalPadding: CGFloat = 1
    /// Slack on every cell, so a rounding difference between the AppKit
    /// measurement and the SwiftUI layout can never truncate a value.
    static let widthSlack: CGFloat = 1

    static let twoLineCaptionSize: CGFloat = 7
    static let twoLineCaptionTracking: CGFloat = 0.2
    static let twoLineValueSize: CGFloat = 10
    static let oneLineCaptionSize: CGFloat = 8.5
    static let oneLineValueSize: CGFloat = 10.5
    static let oneLineGap: CGFloat = 2

    static func captionFont(_ style: MenuBarLabelStyle) -> NSFont {
        NSFont.systemFont(
            ofSize: style == .twoLine ? twoLineCaptionSize : oneLineCaptionSize,
            weight: .semibold
        )
    }

    static func valueFont(_ style: MenuBarLabelStyle) -> NSFont {
        NSFont.monospacedDigitSystemFont(
            ofSize: style == .twoLine ? twoLineValueSize : oneLineValueSize,
            weight: .medium
        )
    }

    /// The fixed width of one cell: the widest value it can ever hold, and
    /// the caption only when that is wider still. Monospaced digits make
    /// every value of the same shape exactly as wide, so the item never
    /// jitters, and nothing is reserved beyond that.
    static func width(of cell: MenuBarCell, style: MenuBarLabelStyle) -> CGFloat {
        let caption = measure(cell.caption, font: captionFont(style), tracking: tracking(style))
        let widest = measure(cell.widest, font: valueFont(style), tracking: 0)
        switch style {
        case .twoLine:
            return (max(caption, widest) + widthSlack).rounded(.up)
        case .oneLine:
            return (caption + oneLineGap + widest + widthSlack).rounded(.up)
        }
    }

    static func tracking(_ style: MenuBarLabelStyle) -> CGFloat {
        style == .twoLine ? twoLineCaptionTracking : 0
    }

    private static func measure(_ text: String, font: NSFont, tracking: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: tracking]
        return (text as NSString).size(withAttributes: attributes).width
    }
}

/// The status item label. Rendered by `ImageRenderer` into a template image,
/// so the system paints it in the right colour in light and dark mode.
struct MenuBarLabelView: View {
    let cells: [MenuBarCell]
    let style: MenuBarLabelStyle
    var showIcon: Bool = true
    /// Keep Awake is holding an assertion.
    ///
    /// The filled variant of the same symbol, not a second glyph and not a
    /// badge: `fan` and `fan.fill` have the same advance width, so the item
    /// does not change size, and at 10 pt in the menu bar a solid shape next
    /// to a hollow one is the only difference that reads at all. A dot or a
    /// cup badge turns to mud at 1x.
    var awake: Bool = false

    var body: some View {
        HStack(spacing: MenuBarMetrics.iconSpacing) {
            if showIcon || cells.isEmpty {
                Image(systemName: awake ? "fan.fill" : "fan")
                    .font(.system(
                        size: cells.isEmpty ? MenuBarMetrics.soloIconSize : MenuBarMetrics.iconSize,
                        weight: .medium
                    ))
            }
            if !cells.isEmpty {
                HStack(spacing: MenuBarMetrics.cellSpacing) {
                    ForEach(cells) { cell in
                        cellView(cell)
                    }
                }
            }
        }
        .padding(.horizontal, MenuBarMetrics.horizontalPadding)
        .frame(height: MenuBarMetrics.height)
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private func cellView(_ cell: MenuBarCell) -> some View {
        let width = MenuBarMetrics.width(of: cell, style: style)
        switch style {
        case .twoLine:
            VStack(spacing: 0) {
                Text(cell.caption)
                    .font(.system(size: MenuBarMetrics.twoLineCaptionSize, weight: .semibold))
                    .tracking(MenuBarMetrics.twoLineCaptionTracking)
                    .opacity(0.75)
                Text(cell.value)
                    .font(.system(size: MenuBarMetrics.twoLineValueSize, weight: .medium))
                    .monospacedDigit()
            }
            .fixedSize()
            .frame(width: width)
        case .oneLine:
            HStack(spacing: MenuBarMetrics.oneLineGap) {
                Text(cell.caption)
                    .font(.system(size: MenuBarMetrics.oneLineCaptionSize, weight: .semibold))
                    .opacity(0.75)
                Text(cell.value)
                    .font(.system(size: MenuBarMetrics.oneLineValueSize, weight: .medium))
                    .monospacedDigit()
            }
            .fixedSize()
            .frame(width: width, alignment: .leading)
        }
    }
}
