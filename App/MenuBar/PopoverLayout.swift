import CoreGraphics

/// The sizes the popover follows. 400 pt wide, never taller than 620 pt, and
/// everything inside it on the 8-pt grid.
enum PopoverLayout {
    static let width: CGFloat = 400
    static let maximumHeight: CGFloat = 620
    static let padding: CGFloat = 16
    static let rowSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 12
    /// Inside the Battery section only. Six rather than eight: the section
    /// carries six boxes now that the energy list is in it, and the two points
    /// a gap gives back are two points the list can have.
    static let batteryRowSpacing: CGFloat = 6
    /// The vertical padding of the Top Processes section, which is the one
    /// section that gives its padding up. See `DashboardHeight.battery`.
    static let processesPadding: CGFloat = 8
    /// Every clickable thing is at least this tall.
    static let hitTarget: CGFloat = 28
    /// The inset of the segmented control around its segments, and the gap
    /// between two of them. `PopoverSectionPicker` draws with these, and
    /// `PopoverLayoutTests` measures the titles against the width they leave.
    static let pickerPadding: CGFloat = 3
    static let segmentSpacing: CGFloat = 2

    /// The height the four sections share.
    ///
    /// A fixed height rather than an animated resize: an `NSPopover` that
    /// changes size re-lays out and re-anchors under the status item, so the
    /// panel jumps on every switch, and the four sections differ by hundreds
    /// of points today. With one height the header, the segmented control and
    /// all four edges stay exactly where they are, whichever section is on
    /// screen, and a screenshot of one section is comparable with the next.
    ///
    /// It is the Dashboard, the tallest of the four, that sets it: its five
    /// sections and the four hairlines between them are exactly this tall.
    /// Fans, Windows and Tools spread their rows over the same height.
    /// The header, the tab control and the two hairlines add 92 pt, so the
    /// popover is 600 pt tall, inside the 620 pt limit.
    ///
    /// The number has not moved since the Dashboard was built, and it may not:
    /// the Windows section fills it to the last row, and 42 pt less clipped
    /// "Next Display" off the bottom of the list.
    static let contentHeight: CGFloat = 508
    /// The header, the segmented control and the two hairlines between them.
    static let chromeHeight: CGFloat = 92
    /// The whole panel. A constant, and every frame inside it is one too: see
    /// `DashboardHeight`.
    static let panelHeight: CGFloat = contentHeight + chromeHeight

    /// The width one segment of the section picker gets, with the padding of
    /// the panel, the inset of the control and the gaps taken off.
    static func segmentWidth(count: Int) -> CGFloat {
        let gaps = segmentSpacing * CGFloat(max(0, count - 1))
        let inner = width - padding * 2 - pickerPadding * 2 - gaps
        return inner / CGFloat(count)
    }

    /// The height of each Dashboard section, in the order they are drawn.
    ///
    /// They are constants for the sake of the CPU cost, not the looks. While
    /// the panel sized itself to its content, every sample made SwiftUI
    /// measure the whole tree again - `RootGeometry` down through every stack
    /// of every section - and that pass alone was 1.4 % of a core with the
    /// Dashboard open, twice what the numbers themselves cost. A fixed height
    /// on the panel and on each section ends the measure at the frame: a CPU
    /// sample redraws the CPU section and asks its siblings nothing.
    ///
    /// The numbers are what the sections drew when they sized themselves, so
    /// the panel looks the same to the point. They add up to `contentHeight`
    /// with the four hairlines between them, and `PopoverLayoutTests` fails if
    /// an edit breaks that sum.
    enum DashboardHeight {
        static let cpu: CGFloat = 74
        static let memory: CGFloat = 80
        static let storage: CGFloat = 80
        static let battery: CGFloat = 162
        static let processes: CGFloat = 108
        static let all: [CGFloat] = [cpu, memory, storage, battery, processes]

        /// The five rows of the Battery section. Every one of them is a fixed
        /// box: the percentage, the level bar, the line that says what the
        /// battery is doing, the three numbers on one line, and the three apps
        /// that are spending the charge. A Mac with no battery fills the same
        /// five boxes, so the section is the same height on every machine.
        ///
        /// The section grew by 8 pt for the energy list, and the 8 pt came out
        /// of the vertical padding of Top Processes under it: that section
        /// keeps all three of its rows and every point of its content, and the
        /// panel is the same 600 pt it has always been. The quiet "Cells at
        /// 30 C" line went instead - the cell temperature is on the Battery
        /// tab now, beside the health and the cycles.
        static let batteryValue: CGFloat = 22
        static let batteryBar: CGFloat = 8
        static let batteryState: CGFloat = 20
        static let batteryStats: CGFloat = 16
        static let batteryEnergyRow: CGFloat = 16
        static let batteryEnergy: CGFloat = batteryEnergyRow * 3
    }

    /// The Fans section, which spends the same `contentHeight` on one row of
    /// readouts, up to two fan cards, one notice and the two commands.
    ///
    /// Every group is a fixed box for the same reason the Dashboard's are: the
    /// rpm of a fan changes every two seconds, and no sample may cost a
    /// measurement of the panel around it.
    enum FansHeight {
        /// The title beside the CPU, GPU and power readouts.
        static let header: CGFloat = 34
        /// Between the four groups.
        static let gap: CGFloat = 14
        /// The cards share this, whether there are two of them or one.
        static let cards: CGFloat = 342
        static let card: CGFloat = 167
        static let cardPadding: CGFloat = 12
        /// Inside a card, one `rowSpacing` apart: the name with the live rpm,
        /// the min-max gauge, the mode control and the editor of that mode.
        static let cardHead: CGFloat = 24
        static let cardGauge: CGFloat = 15
        static let cardSegments: CGFloat = 26
        static let cardDetail: CGFloat = 54
        /// One row of the editor: a slider, a picker or a pair of steppers.
        static let cardDetailRow: CGFloat = 23
        /// The helper state, a refused command or the quiet summary. Always
        /// there, so a refusal that arrives mid-sample resizes nothing.
        static let notice: CGFloat = 34
        static let buttons: CGFloat = 32
    }
}
