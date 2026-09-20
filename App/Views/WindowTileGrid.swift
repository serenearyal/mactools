import AppKit
import SwiftUI
import WindowKit

// MARK: - The miniature screen

/// The unit screen every tile is drawn on.
///
/// The preview asks `WindowLayout` for the real frame on a 1600 x 1000 screen
/// and scales the answer, so a tile cannot drift from what the click does: the
/// picture and the move come from one function. The gap is scaled with it, so
/// the slider moves the tiles apart on screen exactly as it moves the windows.
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

/// One tile: a rounded screen outline with the target region filled in.
struct WindowTile: View {
    let action: WindowAction
    let size: CGSize
    let gap: CGFloat
    let screenWidth: CGFloat
    var shortcut: String?
    var enabled = true
    let perform: (WindowAction) -> Void

    @State private var hovering = false

    private var corner: CGFloat { max(4, size.height / 10) }

    var body: some View {
        Button { perform(action) } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(hovering ? 1 : 0.55))
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        Color(nsColor: .separatorColor).opacity(hovering ? 0.9 : 0.6),
                        lineWidth: 1
                    )
                region
                    .padding(max(3, size.height / 14))
            }
            .frame(width: size.width, height: size.height)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 && enabled }
        .help(helpText)
        .accessibilityLabel(action.title)
    }

    @ViewBuilder
    private var region: some View {
        if let unit = WindowTilePreview.region(for: action, gap: gap, screenWidth: screenWidth) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: max(2, corner - 2), style: .continuous)
                    .fill(Color.accentColor.opacity(hovering ? 0.62 : 0.34))
                    .frame(
                        width: max(unit.width * proxy.size.width, 2),
                        height: max(unit.height * proxy.size.height, 2)
                    )
                    .offset(x: unit.minX * proxy.size.width, y: unit.minY * proxy.size.height)
            }
        }
    }

    private var helpText: String {
        guard let shortcut, !shortcut.isEmpty else { return action.title }
        return "\(action.title)  \(shortcut)"
    }
}

// MARK: - The grid

/// The shared window grid: one header, nine tiles, five thirds and the buttons
/// that are not a rectangle.
///
/// The popover and the Windows tab draw the same view at two widths. Every size
/// below comes from `columnWidth`, so the tiles stay screen shaped at both.
struct WindowTileGrid: View {
    let controller: WindowManagerController
    /// How wide the grid may be. The tiles are a third of it.
    let columnWidth: CGFloat
    var compact = false
    /// Closes the popover before the window moves. Nothing on the tab.
    var beforeAction: () -> Void = {}

    private var spacing: CGFloat { compact ? 8 : 10 }
    private var tileSize: CGSize {
        let width = ((columnWidth - spacing * 2) / 3).rounded(.down)
        return CGSize(width: width, height: (width / 1.75).rounded())
    }

    private var thirdSize: CGSize {
        let width = ((columnWidth - spacing * 4) / 5).rounded(.down)
        return CGSize(width: width, height: (width / 1.75).rounded())
    }

    private var gap: CGFloat { controller.gap }
    private var screenWidth: CGFloat {
        max(NSScreen.main?.frame.width ?? 1600, 1)
    }

    private static let rows: [[WindowAction]] = [
        [.topLeft, .topHalf, .topRight],
        [.leftHalf, .maximize, .rightHalf],
        [.bottomLeft, .bottomHalf, .bottomRight],
    ]
    private static let thirds: [WindowAction] = [
        .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            WindowTargetCard(controller: controller, compact: compact)
            if controller.accessibilityGranted {
                // One column for everything under the card: the tiles decide
                // its width, and the buttons and the gap line up with them
                // instead of running out to the edges of the panel.
                VStack(alignment: .leading, spacing: compact ? 10 : 14) {
                    grid
                    thirdsRow
                    buttons
                    GapSlider(controller: controller, compact: compact)
                }
                .frame(width: columnWidth)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var grid: some View {
        VStack(spacing: spacing) {
            ForEach(Array(WindowTileGrid.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row, id: \.self) { action in
                        tile(action, size: tileSize)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var thirdsRow: some View {
        HStack(spacing: spacing) {
            ForEach(WindowTileGrid.thirds, id: \.self) { action in
                tile(action, size: thirdSize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func tile(_ action: WindowAction, size: CGSize) -> some View {
        WindowTile(
            action: action,
            size: size,
            gap: gap,
            screenWidth: screenWidth,
            shortcut: controller.shortcutDisplay(for: action),
            enabled: controller.canAct,
            perform: perform
        )
    }

    private var buttons: some View {
        // A flowing row: four buttons always, two more when a second display is
        // plugged in. `ViewThatFits` would drop one; wrapping keeps them all.
        WrappingRow(spacing: compact ? 6 : 8) {
            actionButton(.almostMaximize)
            actionButton(.center)
            actionButton(.maximizeHeight)
            actionButton(.restore)
            if controller.screenCount > 1 {
                // The two arrows alone in the popover: with their titles the
                // row wraps onto a third line, and the section has a fixed
                // height. The tooltip and the grid above say what they do.
                actionButton(.previousDisplay, iconOnly: compact)
                actionButton(.nextDisplay, iconOnly: compact)
            }
        }
    }

    private func actionButton(_ action: WindowAction, iconOnly: Bool = false) -> some View {
        Button { perform(action) } label: {
            Group {
                if iconOnly {
                    Image(systemName: action.symbolName)
                } else {
                    Label(action.title, systemImage: action.symbolName)
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(compact ? .caption : .callout)
            .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(compact ? .small : .regular)
        .disabled(!controller.canAct)
        .help(helpText(action))
    }

    private func helpText(_ action: WindowAction) -> String {
        guard let shortcut = controller.shortcutDisplay(for: action) else { return action.title }
        return "\(action.title)  \(shortcut)"
    }

    private func perform(_ action: WindowAction) {
        beforeAction()
        controller.apply(action, reactivate: compact)
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
                        Button("Use Vent's alternate set") { controller.useAlternateSet() }
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

// MARK: - Key caps

/// "⌃⌥←" as three key caps, the way the system draws a shortcut.
struct KeyCapRow: View {
    let display: String
    var enabled = true

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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(enabled ? Color.primary : Color.secondary)
                    .frame(minWidth: 17, minHeight: 17)
                    .padding(.horizontal, 2)
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
