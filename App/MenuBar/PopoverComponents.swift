import SwiftUI

/// A small state badge: "Awake 42m" in the header, "Low Power Mode" beside the
/// battery. Every slot that holds one has a fixed height, so a state that
/// appears between two samples moves nothing around it.
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
