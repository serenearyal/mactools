import SwiftUI

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
    /// The cost is the room under the three Tools rows until R3, R4 and R7
    /// fill it. That is the right way round: the rows arrive into a layout
    /// that does not move, instead of the popover growing under the cursor.
    ///
    /// Measured against the Dashboard, the tallest section: it draws 506 pt at
    /// this width. The header, the control and the two hairlines add 92 pt, so
    /// the popover is 600 pt tall, inside the 620 pt limit.
    static let contentHeight: CGFloat = 508
    /// The header, the segmented control and the two hairlines between them.
    static let chromeHeight: CGFloat = 92
}

/// A small state badge in the popover header, "Awake 42m" and its like.
///
/// Nothing sets one yet. The slot it sits in has a fixed height, so the header
/// does not change when a later batch fills it.
struct PopoverBadge: Equatable, Sendable {
    let text: String
    let symbolName: String
    var tint: Color = .accentColor
}

struct PopoverBadgeView: View {
    let badge: PopoverBadge

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: badge.symbolName)
                .font(.system(size: 9, weight: .semibold))
            Text(badge.text)
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(badge.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous)
                .fill(badge.tint.opacity(0.12))
        }
    }
}

/// A section title that opens a tab. The whole label is the hit area, the
/// chevron says so without a hover, and the hover fills the area behind it.
struct PopoverSectionTitle: View {
    let title: String
    let symbolName: String
    let tab: MainTab
    let open: (MainTab) -> Void

    @State private var hovering = false

    var body: some View {
        Button { open(tab) } label: {
            HStack(spacing: 4) {
                Image(systemName: symbolName)
                    .imageScale(.small)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open the \(tab.title) tab")
        // The padding above is the hover area; this keeps the title on the
        // same x as the rest of the section.
        .padding(.leading, -5)
    }
}

/// One of the three header buttons.
struct PopoverIconButton: View {
    let symbolName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .imageScale(.medium)
                .foregroundStyle(.secondary)
                .frame(width: PopoverLayout.hitTarget, height: PopoverLayout.hitTarget)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.07 : 0))
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A caption over a value, both on fixed baselines so nothing moves when the
/// number changes width.
struct PopoverStat: View {
    let caption: String
    let value: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line under a row or a section: a refusal, a missing helper, a note.
struct PopoverHint: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row of the Tools section: a symbol, a title, an optional second line and
/// an optional control on the right.
///
/// Every tool is built from this one container, so a row a later batch adds
/// lands on the same baselines as the rows that are here today.
struct ToolRow<Trailing: View>: View {
    let title: String
    let symbolName: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: PopoverLayout.rowSpacing + 2) {
            Image(systemName: symbolName)
                .imageScale(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: PopoverLayout.rowSpacing)
            trailing
        }
        .padding(.horizontal, PopoverLayout.padding)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

extension ToolRow where Trailing == EmptyView {
    init(title: String, symbolName: String, detail: String? = nil) {
        self.init(title: title, symbolName: symbolName, detail: detail) { EmptyView() }
    }
}

/// The empty state of a section that a later batch fills: one symbol, one
/// line, centred in the height every section shares.
struct PopoverEmptyState: View {
    let symbolName: String
    let text: String

    var body: some View {
        VStack(spacing: PopoverLayout.sectionSpacing) {
            Image(systemName: symbolName)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, PopoverLayout.padding * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
