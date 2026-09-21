import CoreGraphics

/// The sizes the popover follows. 400 pt wide, never taller than 620 pt, and
/// everything inside it on the 8-pt grid.
enum PopoverLayout {
    static let width: CGFloat = 400
    static let maximumHeight: CGFloat = 620
    static let padding: CGFloat = 16
    static let rowSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 12
    /// Every clickable thing is at least this tall.
    static let hitTarget: CGFloat = 28
    /// The height the three sections share.
    ///
    /// A fixed height rather than an animated resize: an `NSPopover` that
    /// changes size re-lays out and re-anchors under the status item, so the
    /// panel jumps on every switch, and the three sections differ by hundreds
    /// of points today. With one height the header, the segmented control and
    /// all four edges stay exactly where they are, whichever section is on
    /// screen, and a screenshot of one section is comparable with the next.
    ///
    /// It is the Dashboard, the tallest of the three, that sets it: its five
    /// sections and the four hairlines between them are exactly this tall.
    /// The Windows and Tools sections spread their rows over the same height.
    /// The header, the tab control and the two hairlines add 92 pt, so the
    /// popover is 600 pt tall, inside the 620 pt limit.
    static let contentHeight: CGFloat = 508
    /// The header, the segmented control and the two hairlines between them.
    static let chromeHeight: CGFloat = 92
    /// The whole panel. A constant, and every frame inside it is one too: see
    /// `DashboardHeight`.
    static let panelHeight: CGFloat = contentHeight + chromeHeight

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
        static let thermals: CGFloat = 154
        static let processes: CGFloat = 116
        static let all: [CGFloat] = [cpu, memory, storage, thermals, processes]
        /// The slot inside the Thermals section that holds either the fan rows
        /// or the one state line that stands in for them. Two fan rows are the
        /// tallest thing it can hold - two caption lines and the row spacing
        /// between them - and a two-line hint with a small button beside it is
        /// shorter, so no fan state makes the section grow.
        static let fanSlot: CGFloat = 34
    }
}
