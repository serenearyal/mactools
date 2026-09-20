import SwiftUI
import WindowKit

/// The Windows section of the popover.
///
/// The window it acts on was captured before the popover opened: showing the
/// popover activates Vent, and from that instant nothing else is frontmost.
///
/// It draws no live number, so an open popover on this section costs exactly
/// what a closed one costs.
struct PopoverWindows: View {
    let services: AppServices
    var actions = MenuBarPopoverActions()
    let open: (MainTab) -> Void

    /// The grid is a little narrower than the section so the nine tiles keep a
    /// screen shape at 400 pt, and the whole section fits the fixed height
    /// without a scroll view.
    private static let gridWidth: CGFloat = 316

    private var controller: WindowManagerController { services.windows }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PopoverSectionTitle(
                title: "Windows",
                symbolName: "macwindow.on.rectangle",
                tab: .windows,
                open: open
            )
            if controller.showsConflictBanner {
                WindowConflictBanner(controller: controller, compact: true)
            }
            WindowTileGrid(
                controller: controller,
                columnWidth: PopoverWindows.gridWidth,
                compact: true,
                beforeAction: actions.closePopover
            )
            if let status = controller.status, controller.accessibilityGranted,
               controller.target?.refusal == nil {
                PopoverHint(text: status)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PopoverLayout.padding)
        .padding(.top, 12)
        .padding(.bottom, PopoverLayout.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
