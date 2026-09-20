import SwiftUI

/// A tab whose tool arrives in a later batch.
///
/// A titled empty state and nothing else. It observes no store and asks the
/// samplers for nothing, which is the point: the window on one of these tabs
/// costs what the closed app costs.
///
/// Not `ContentUnavailableView`: that draws an error, and none of this is an
/// error - the rest of the app works, this part is not built yet.
struct PlaceholderTabView: View {
    let tab: MainTab

    var body: some View {
        // A `ScrollView` around one short column, like every other tab: a
        // detail pane with no scroll view of its own leaves the sidebar
        // without its title bar inset, and the list slides under the traffic
        // lights. `containerRelativeFrame` keeps the column in the middle.
        ScrollView {
            VStack(spacing: Layout.gutter * 1.5) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(tab.title)
                    .font(.title2.weight(.semibold))
                Text(PlaceholderTabView.note(for: tab))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Layout.cardSpacing)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One sentence each, in the words of the thing that is coming.
    static func note(for tab: MainTab) -> String {
        switch tab {
        case .windows:
            "Window layouts arrive with the window manager."
        case .keepAwake:
            "Keeping this Mac awake arrives with the power tools."
        case .backlight:
            "Keyboard backlight control arrives with the brightness slider."
        default:
            "This part of Vent is not built yet."
        }
    }
}
