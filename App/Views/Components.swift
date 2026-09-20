import Charts
import SwiftUI

/// The 8-pt spacing grid the whole window follows.
enum Layout {
    static let gutter: CGFloat = 8
    static let cardPadding: CGFloat = 16
    static let cardSpacing: CGFloat = 16
    static let cardCorner: CGFloat = 12
    /// Two columns fit the 900 x 600 default window, whose detail pane is
    /// about 708 pt wide. Below that the cards stack.
    static let minimumCardWidth: CGFloat = 320
    static let twoColumnWidth = minimumCardWidth * 2 + cardSpacing * 3
}

/// A panel with a title line and a hairline border, the way the system
/// settings panes group content.
struct Card<Content: View>: View {
    let title: String
    let symbolName: String
    /// Cards in a grid row stretch so they end at the same line. A card in a
    /// stack hugs its content instead.
    var fills = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.gutter * 1.5) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer(minLength: 0)
            }
            content
        }
        .padding(Layout.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Layout.cardCorner, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: Layout.cardCorner, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
        }
    }
}

/// A caption over a value, with the value on a baseline that never moves.
struct StatBlock: View {
    let caption: String
    let value: String
    var tint: Color?
    var size: Font = .title3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(size.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
        }
    }
}

/// Label on the left, value on the right, aligned across a whole column.
struct StatRow: View {
    let label: String
    let value: String
    var tint: Color?

    var body: some View {
        HStack(spacing: Layout.gutter) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: Layout.gutter)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
        }
        .font(.callout)
    }
}

/// A bar cut into parts, used for memory and for disk space.
struct SegmentedBar: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let style: AnyShapeStyle

        init(id: String, value: Double, style: some ShapeStyle) {
            self.id = id
            self.value = value
            self.style = AnyShapeStyle(style)
        }
    }

    let segments: [Segment]
    let total: Double
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.style)
                        .frame(width: width(of: segment, in: proxy.size.width))
                }
                Rectangle()
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }

    private func width(of segment: Segment, in available: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let spacing = CGFloat(segments.count)
        return max(0, (available - spacing) * segment.value / total)
    }
}

/// A key with its colour, under a segmented bar.
struct LegendItem: View {
    let label: String
    let value: String
    let style: AnyShapeStyle

    init(label: String, value: String, style: some ShapeStyle) {
        self.label = label
        self.value = value
        self.style = AnyShapeStyle(style)
    }

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(style)
                .frame(width: 8, height: 8)
            // Explicit colours: a legend under a chart inherits the mark
            // style, and `.secondary` would tint the text with it.
            Text(label)
                .foregroundStyle(Color.secondary)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(Color.primary)
        }
        .font(.caption)
    }
}

/// A tiny line chart with no axes, for a table cell or a card corner.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = .accentColor
    var minimumRange: Double = 1

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Sample", index),
                    y: .value("Value", value)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .foregroundStyle(tint)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: domain)
        .chartPlotStyle { plot in plot.background(.clear) }
        .allowsHitTesting(false)
    }

    private var domain: ClosedRange<Double> {
        let lower = values.min() ?? 0
        let upper = values.max() ?? 1
        guard upper - lower >= minimumRange else {
            let centre = (upper + lower) / 2
            return (centre - minimumRange / 2)...(centre + minimumRange / 2)
        }
        return lower...upper
    }
}

/// The CPU history chart: filled area plus its line, 0 to 100 %.
struct HistoryAreaChart: View {
    let values: [Double]
    var upperBound: Double = 100
    var tint: Color = .accentColor

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                AreaMark(
                    x: .value("Sample", index),
                    y: .value("Value", value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    .linearGradient(
                        colors: [tint.opacity(0.35), tint.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Sample", index),
                    y: .value("Value", value)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .foregroundStyle(tint)
            }
        }
        .chartXScale(domain: 0...Double(max(values.count - 1, 1)))
        .chartYScale(domain: 0...upperBound)
        .chartXAxis(.hidden)
        .chartYAxis {
            // `Color.secondary`, not `.secondary`: inside a chart the
            // hierarchical style resolves against the mark colour and paints
            // the labels in the accent blue.
            AxisMarks(position: .leading, values: [0, upperBound / 2, upperBound]) {
                AxisGridLine()
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartLegend(.hidden)
    }
}
