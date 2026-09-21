import AppKit
import CoreGraphics
import Testing

/// The popover's sizes are constants, and a constant that is wrong is a panel
/// that clips its last section or leaves a hole above its bottom edge.
///
/// The panel, the section frame and each Dashboard section are fixed frames:
/// that is what stops SwiftUI measuring the whole 400 pt tree on every sample.
/// Nothing at runtime notices when the numbers stop adding up, so this does.
@Suite("Popover layout")
struct PopoverLayoutTests {
    @Test("The Dashboard sections and their hairlines fill the content height")
    func dashboardFillsTheContent() {
        let sections = PopoverLayout.DashboardHeight.all
        let hairlines = CGFloat(sections.count - 1)
        #expect(sections.reduce(0, +) + hairlines == PopoverLayout.contentHeight)
    }

    @Test("The panel is the content plus the chrome, and fits the limit")
    func panelFitsTheLimit() {
        #expect(
            PopoverLayout.panelHeight
                == PopoverLayout.contentHeight + PopoverLayout.chromeHeight
        )
        #expect(PopoverLayout.panelHeight <= PopoverLayout.maximumHeight)
    }

    @Test("The chrome is the header, the section picker and two hairlines")
    func chromeAddsUp() {
        let header: CGFloat = 44
        let picker = PopoverLayout.hitTarget + PopoverLayout.pickerPadding * 2 + 6 * 2
        #expect(header + picker + 2 == PopoverLayout.chromeHeight)
    }

    @Test("The Battery section is its five rows and the padding around them")
    func batteryHoldsItsRows() {
        let height = PopoverLayout.DashboardHeight.self
        let rows = height.batteryValue + height.batteryBar + height.batteryState
            + height.batteryStats + height.batteryDetail
        let spacing = PopoverLayout.rowSpacing * 4 + PopoverLayout.sectionSpacing * 2
        #expect(rows + spacing == height.battery)
    }

    @Test("The Fans section fills the same content height as the Dashboard")
    func fansFillTheContent() {
        let fans = PopoverLayout.FansHeight.self
        let groups = fans.header + fans.cards + fans.notice + fans.buttons
        let spacing = fans.gap * 3 + PopoverLayout.sectionSpacing * 2
        #expect(groups + spacing == PopoverLayout.contentHeight)
    }

    @Test("Two fan cards and the gap between them are the card region")
    func twoCardsFillTheRegion() {
        let fans = PopoverLayout.FansHeight.self
        #expect(fans.card * 2 + PopoverLayout.rowSpacing == fans.cards)
    }

    @Test("A fan card is its four rows and its own padding")
    func fanCardHoldsItsRows() {
        let fans = PopoverLayout.FansHeight.self
        let rows = fans.cardHead + fans.cardGauge + fans.cardSegments + fans.cardDetail
        let spacing = PopoverLayout.rowSpacing * 3 + fans.cardPadding * 2
        #expect(rows + spacing == fans.card)
        // The editor of a curve is two rows: the sensor with the link, and the
        // two ends of the ramp.
        #expect(fans.cardDetailRow * 2 + PopoverLayout.rowSpacing == fans.cardDetail)
    }

    @Test("Every section is taller than the padding it carries")
    func sectionsHoldTheirPadding() {
        for height in PopoverLayout.DashboardHeight.all {
            #expect(height > PopoverLayout.sectionSpacing * 2)
        }
    }

    /// Four tabs in 400 pt. The titles are drawn at the size the picker uses,
    /// with the weight of the selected one, and measured against the width one
    /// segment gets. A fifth section or a longer word truncates, and only a
    /// screenshot would otherwise say so.
    @Test("Every section title fits its segment with room for the icon")
    func sectionTitlesFitTheirSegment() {
        let width = PopoverLayout.segmentWidth(count: PopoverSection.allCases.count)
        // The symbol at `.imageScale(.small)` and the 5 pt beside it, plus a
        // little slack for the text's own bearing.
        let iconBudget: CGFloat = 22
        let font = NSFont.systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .semibold
        )
        for section in PopoverSection.allCases {
            let title = section.title as NSString
            let measured = title.size(withAttributes: [.font: font]).width
            #expect(
                measured + iconBudget <= width,
                "\(section.title) needs \(measured + iconBudget) pt of \(width)"
            )
        }
    }
}
