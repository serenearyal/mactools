import SwiftUI
import WindowKit

/// The Windows section of the popover: the command list, at menu size.
///
/// The window it acts on was captured before the popover opened: showing the
/// popover activates Vent, and from that instant nothing else is frontmost.
///
/// The list replaces the tile grid that used to be here. The two together do
/// not fit the height the three sections share, and the list is the thing the
/// user reads a shortcut off - which is what the section is for. No scroll
/// view: every row fits, and an `NSScrollView` in here would also be invisible
/// to the capture path, which draws the popover with `ImageRenderer`.
///
/// It draws no live number, so an open popover on this section costs exactly
/// what a closed one costs.
struct PopoverWindows: View {
    let services: AppServices
    var actions = MenuBarPopoverActions()
    let open: (MainTab) -> Void

    private var controller: WindowManagerController { services.windows }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PopoverSectionTitle(
                title: "Windows",
                symbolName: "macwindow.on.rectangle",
                tab: .windows,
                open: open
            )
            targetLine
            if controller.accessibilityGranted {
                WindowCommandListView(
                    controller: controller,
                    compact: true,
                    beforeAction: actions.closePopover
                )
            } else {
                PopoverHint(text: WindowRefusal.accessibilityMissing.message, tint: .orange)
                Button("Grant Accessibility…") { controller.requestAccessibility() }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PopoverLayout.padding)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One line, not the tab's card: the height this section shares with the
    /// Dashboard leaves room for the list and nothing more.
    @ViewBuilder
    private var targetLine: some View {
        if controller.accessibilityGranted {
            HStack(spacing: 6) {
                if let conflict = controller.conflicts.first, controller.showsConflictBanner {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text("\(conflict.name) owns these shortcuts")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(controller.target?.label ?? controller.status ?? WindowRefusal.noWindow.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 14)
        }
    }
}
