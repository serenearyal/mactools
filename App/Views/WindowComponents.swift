import AppKit
import SwiftUI
import WindowKit

// The views the window manager is drawn with: the glyph of a target region,
// the command list the tab, the popover and the status menu share, the card
// that names the window in front, the gap slider and the conflict banner.

// MARK: - The miniature screen

/// The unit screen every glyph is drawn on.
///
/// The preview asks `WindowLayout` for the real frame on a 1600 x 1000 screen
/// and scales the answer, so a glyph cannot drift from what the click does: the
/// picture and the move come from one function. The gap is scaled with it, so
/// a caller that passes one sees the same inset the windows get.
enum WindowTilePreview {
    static let unit = ScreenFrame(
        id: 0,
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000)
    )
    /// Half the screen, centred: what `center` and `maximize height` need to
    /// have a window to work from.
    private static let sample = CGRect(x: 400, y: 250, width: 800, height: 500)

    /// The target region as a share of the tile, with y growing downwards the
    /// way SwiftUI draws.
    static func region(for action: WindowAction, gap: CGFloat, screenWidth: CGFloat) -> CGRect? {
        let scaled = gap <= 0 ? 0 : gap / max(screenWidth, 1) * unit.frame.width
        guard let frame = WindowLayout.target(
            action: action,
            on: unit,
            current: sample,
            gap: scaled
        ) else { return nil }
        return CGRect(
            x: frame.minX / unit.frame.width,
            y: (unit.frame.maxY - frame.maxY) / unit.frame.height,
            width: frame.width / unit.frame.width,
            height: frame.height / unit.frame.height
        )
    }
}

/// The little screen beside a command in the list: the same outline as a tile,
/// at menu size, with the target region filled in.
///
/// It comes from `WindowTilePreview` like the tiles do, so the picture and the
/// click can never say different things. Every edge is rounded to a whole
/// point, which is what keeps it crisp at 1x as well as at 2x, and the colours
/// are the label colour at two opacities, so it reads as a template glyph in
/// both appearances.
struct WindowRegionGlyph: View {
    let action: WindowAction
    var size = CGSize(width: 20, height: 14)
    var enabled = true

    /// The screen bezel: the region is drawn inside this inset.
    private static let inset: CGFloat = 2
    private var corner: CGFloat { 3 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
            content
        }
        .frame(width: size.width, height: size.height)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if let unit = WindowTilePreview.region(for: action, gap: 0, screenWidth: 1600) {
            let field = CGRect(
                x: WindowRegionGlyph.inset,
                y: WindowRegionGlyph.inset,
                width: size.width - WindowRegionGlyph.inset * 2,
                height: size.height - WindowRegionGlyph.inset * 2
            )
            let minX = (field.minX + unit.minX * field.width).rounded()
            let minY = (field.minY + unit.minY * field.height).rounded()
            let maxX = (field.minX + unit.maxX * field.width).rounded()
            let maxY = (field.minY + unit.maxY * field.height).rounded()
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.primary.opacity(0.55))
                .frame(width: max(maxX - minX, 2), height: max(maxY - minY, 2))
                .offset(x: minX, y: minY)
        } else {
            // Restore, larger, smaller and the two display moves are not a
            // region of the screen: the symbol says what they do instead.
            Image(systemName: action.symbolName)
                .font(.system(size: size.height * 0.58, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.55))
                .frame(width: size.width, height: size.height)
        }
    }
}

// MARK: - The header card

/// The window the grid will act on, or the reason there is none.
struct WindowTargetCard: View {
    let controller: WindowManagerController
    var compact = false

    var body: some View {
        Group {
            if !controller.accessibilityGranted {
                permissionRow
            } else if let target = controller.target, target.refusal == nil {
                windowRow(target)
            } else {
                refusalRow
            }
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
        }
    }

    private func windowRow(_ target: WindowTarget) -> some View {
        HStack(spacing: 10) {
            icon(target)
            VStack(alignment: .leading, spacing: 2) {
                // Tail, not middle: the app name and the start of the title
                // are what identifies a window, and a middle ellipsis cuts a
                // long document name into two halves that say nothing.
                Text(target.label)
                    .font(compact ? .subheadline.weight(.medium) : .headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(target.sizeText)  ·  \(target.displayName)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func icon(_ target: WindowTarget) -> some View {
        if let image = target.icon {
            Image(nsImage: image)
                .resizable()
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: "macwindow")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
    }

    private var refusalRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "macwindow.badge.plus")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.target?.label ?? "No window")
                    .font(compact ? .subheadline.weight(.medium) : .headline)
                    .lineLimit(1)
                Text(controller.status ?? WindowRefusal.noWindow.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var permissionRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility permission")
                    .font(compact ? .subheadline.weight(.medium) : .headline)
                Text(WindowRefusal.accessibilityMissing.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Grant…") { controller.requestAccessibility() }
                .controlSize(compact ? .small : .regular)
        }
    }
}

// MARK: - The gap

struct GapSlider: View {
    let controller: WindowManagerController
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Text("Gap")
                .font(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
            GapTrack(
                value: Binding(
                    get: { controller.data.gap },
                    set: { controller.setGap($0) }
                ),
                range: Double(WindowLayout.gapRange.lowerBound)...Double(WindowLayout.gapRange.upperBound)
            )
            .frame(height: 20)
            Text("\(Int(controller.data.gap)) pt")
                .font(compact ? .caption : .callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .help("The space between two tiled windows and the screen edge.")
    }
}

/// A slider drawn by hand, in whole points.
///
/// Not `Slider`: that is an `NSSlider`, and `ImageRenderer` - the only way to
/// photograph the popover without a Screen Recording grant - draws a yellow
/// box for anything AppKit backs. The segmented control of the popover is hand
/// drawn for exactly the same reason.
struct GapTrack: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    private static let knob: CGFloat = 14
    private static let height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let travel = max(width - GapTrack.knob, 1)
            let fraction = (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 1)
            let x = travel * fraction
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.8))
                    .frame(height: GapTrack.height)
                // Up to the left edge of the knob, which covers the rest. A
                // fill that reached the centre would poke out of the knob at
                // zero, where the circle has no height left to hide it.
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(x, 0), height: GapTrack.height)
                Circle()
                    .fill(Color(nsColor: .controlColor))
                    .overlay {
                        Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .frame(width: GapTrack.knob, height: GapTrack.knob)
                    .offset(x: x)
            }
            .frame(height: proxy.size.height, alignment: .center)
            .contentShape(.rect)
            .gesture(
                // `minimumDistance: 0` so a click anywhere on the track jumps
                // there, the way an `NSSlider` with `continuous` does.
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let position = (gesture.location.x - GapTrack.knob / 2) / travel
                        let span = range.upperBound - range.lowerBound
                        let raw = range.lowerBound + min(max(position, 0), 1) * span
                        value = raw.rounded()
                    }
            )
        }
    }
}

// MARK: - The conflict banner

/// "Rectangle is running and owns these shortcuts."
struct WindowConflictBanner: View {
    let controller: WindowManagerController
    var compact = false

    var body: some View {
        if let conflict = controller.conflicts.first {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: compact ? 12 : 14))
                    Text("\(conflict.label) is running and owns these shortcuts.")
                        .font(compact ? .caption : .callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                WrappingRow(spacing: 6) {
                    if controller.choice != .alternate {
                        Button("Use MacTools' alternate set") { controller.useAlternateSet() }
                    }
                    Button("Quit \(conflict.name)") { controller.quit(conflict) }
                    if controller.choice != .off {
                        Button("Keep shortcuts off") { controller.turnShortcutsOff() }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(compact ? .caption : .callout)
            }
            .padding(compact ? 10 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                    }
            }
        }
    }
}

// MARK: - The command list

/// Rectangle's menu, as a view: every action in its group, with the glyph of
/// the region it fills, its name, and its chord on the right.
///
/// The Windows tab, the popover and the status item's Window submenu all draw
/// `controller.commandGroups`, so a row can only be added in one place.
struct WindowCommandListView: View {
    let controller: WindowManagerController
    var compact = false
    /// Two columns when the pane is wide enough: the whole list is then on
    /// screen at the default window size, the way the menu it copies is.
    var columns = 1
    /// Closes the popover before the window moves. Nothing on the tab.
    var beforeAction: () -> Void = {}

    /// Where the second column starts. The halves, the corners and the thirds
    /// go on the left; the whole-screen actions and the displays on the right.
    private static let splitGroup = 3

    var body: some View {
        if columns > 1 {
            HStack(alignment: .top, spacing: Layout.cardSpacing) {
                column(Array(0..<WindowCommandListView.splitGroup))
                column(Array(WindowCommandListView.splitGroup..<controller.commandGroups.count))
            }
        } else {
            column(Array(controller.commandGroups.indices))
        }
    }

    private func column(_ indices: [Int]) -> some View {
        let groups = controller.commandGroups
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(indices, id: \.self) { index in
                if index != indices.first {
                    Divider()
                        .padding(.vertical, compact ? 4 : 6)
                        .padding(.horizontal, 4)
                }
                ForEach(groups[index].rows) { row in
                    WindowCommandRowView(row: row, compact: compact, perform: perform)
                        .contextMenu { menu(for: row) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func menu(for row: WindowCommandRow) -> some View {
        // The shortcut set has no chord for these two, so there is nothing to
        // switch off. Rectangle leaves them open as well.
        if controller.choice != .off, !ShortcutSet.unbound.contains(row.action) {
            let enabled = controller.data.isEnabled(row.action)
            Button(enabled ? "Turn this shortcut off" : "Turn this shortcut on") {
                controller.setEnabled(!enabled, for: row.action)
            }
        }
    }

    private func perform(_ action: WindowAction) {
        beforeAction()
        controller.apply(action, reactivate: compact)
    }
}

/// One line of the command list. A whole-row button: a click runs the action
/// on the window that was in front.
struct WindowCommandRowView: View {
    let row: WindowCommandRow
    var compact = false
    let perform: (WindowAction) -> Void

    @State private var hovering = false

    private var height: CGFloat { compact ? 17 : 24 }
    private var glyph: CGSize {
        compact ? CGSize(width: 17, height: 12) : CGSize(width: 21, height: 15)
    }

    var body: some View {
        Button { perform(row.action) } label: {
            HStack(spacing: compact ? 7 : 10) {
                WindowRegionGlyph(action: row.action, size: glyph, enabled: row.isAvailable)
                Text(row.title)
                    .font(compact ? .caption : .callout)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut = row.shortcutDisplay {
                    KeyCapRow(display: shortcut, enabled: row.isAvailable, compact: compact)
                }
            }
            .padding(.horizontal, 5)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!row.isAvailable)
        .foregroundStyle(row.isAvailable ? Color.primary : Color.secondary)
        .opacity(row.isAvailable ? 1 : 0.55)
        .onHover { hovering = $0 && row.isAvailable }
        .help(help)
        .accessibilityLabel(row.title)
    }

    private var help: String {
        guard let shortcut = row.shortcutDisplay else { return row.title }
        return "\(row.title)  \(shortcut)"
    }
}

// MARK: - Key caps

/// "⌃⌥←" as three key caps, the way the system draws a shortcut.
struct KeyCapRow: View {
    let display: String
    var enabled = true
    /// The popover's size: the same caps one step smaller.
    var compact = false

    private static let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]

    /// The modifier symbols one by one, then whatever is left as one cap.
    private var caps: [String] {
        var caps: [String] = []
        var rest = Substring(display)
        while let first = rest.first, KeyCapRow.modifiers.contains(first) {
            caps.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { caps.append(String(rest)) }
        return caps
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: compact ? 9.5 : 11, weight: .medium))
                    .foregroundStyle(enabled ? Color.primary : Color.secondary)
                    // One width for every cap, so the chords of a whole list
                    // line up in a column instead of ragging to the right.
                    .frame(width: compact ? 14 : 17, height: compact ? 14 : 17)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(enabled ? 1 : 0.5))
                            .overlay {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                            }
                    }
            }
        }
        .opacity(enabled ? 1 : 0.6)
    }
}

// MARK: - A row that wraps

/// A horizontal row that starts a new line when it runs out of width.
///
/// `Layout` rather than a `LazyVGrid`: the buttons have different widths, and a
/// grid would give them all the widest one.
// `SwiftUI.Layout` in full: this app has an enum of its own called `Layout`.
struct WrappingRow: SwiftUI.Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = self.lines(subviews: subviews, width: width)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(lines.count - 1, 0))
        let widest = lines.map(\.width).max() ?? 0
        return CGSize(width: min(widest, width), height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: LayoutSubviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for line in lines(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.range {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var range: Range<Int>
        var width: CGFloat
        var height: CGFloat
    }

    private func lines(subviews: LayoutSubviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var start = 0
        var x: CGFloat = 0
        var height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = x == 0 ? size.width : x + spacing + size.width
            if next > width, index > start {
                lines.append(Line(range: start..<index, width: x, height: height))
                start = index
                x = size.width
                height = size.height
            } else {
                x = next
                height = max(height, size.height)
            }
        }
        if start < subviews.count {
            lines.append(Line(range: start..<subviews.count, width: x, height: height))
        }
        return lines
    }
}
