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
        let picker = PopoverLayout.hitTarget + 3 * 2 + 6 * 2
        #expect(header + picker + 2 == PopoverLayout.chromeHeight)
    }

    @Test("The fan slot holds two fan rows, so no fan state resizes a section")
    func fanSlotHoldsTwoRows() {
        // Two caption rows of 13 pt with one row spacing between them.
        let twoFanRows = 13 * 2 + PopoverLayout.rowSpacing
        #expect(PopoverLayout.DashboardHeight.fanSlot == twoFanRows)
    }

    @Test("Every section is taller than the padding it carries")
    func sectionsHoldTheirPadding() {
        for height in PopoverLayout.DashboardHeight.all {
            #expect(height > PopoverLayout.sectionSpacing * 2)
        }
    }
}
