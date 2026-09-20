import SwiftUI
import WindowKit

/// The Windows tab: the tile grid on the left, the shortcuts on the right.
///
/// It asks the samplers for nothing at all. Everything on it is read from the
/// accessibility API when the tab appears and after every click, so a window
/// left open on this tab costs what a closed app costs.
struct WindowsView: View {
    let controller: WindowManagerController
    let settings: AppSettings

    var body: some View {
        WindowsContent(controller: controller, settings: settings, scrolls: true)
            // The window the tab acts on is whatever was in front before Vent
            // took it, so it is read when the tab appears and never polled.
            .onAppear { controller.captureTarget() }
    }
}

/// The content without the tab's own lifetime, so the capture path can render
/// it outside a scroll view, which `ImageRenderer` cannot draw.
struct WindowsContent: View {
    let controller: WindowManagerController
    let settings: AppSettings
    var scrolls = true

    /// Under this the two columns stack. At 760 pt the detail pane is about
    /// 568 pt wide, which is not enough for a readable grid next to a table of
    /// shortcuts; above it, at the 900 pt default, both fit side by side.
    static let twoColumnPaneWidth: CGFloat = 692
    private static let shortcutColumn: CGFloat = 288
    private static let gridColumn: CGFloat = 380

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= WindowsContent.twoColumnPaneWidth
            content(wide: wide, paneWidth: proxy.size.width)
        }
    }

    @ViewBuilder
    private func content(wide: Bool, paneWidth: CGFloat) -> some View {
        if scrolls {
            ScrollView { columns(wide: wide, paneWidth: paneWidth).padding(Layout.cardSpacing) }
        } else {
            VStack(spacing: 0) {
                columns(wide: wide, paneWidth: paneWidth).padding(Layout.cardSpacing)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func columns(wide: Bool, paneWidth: CGFloat) -> some View {
        if wide {
            HStack(alignment: .top, spacing: Layout.cardSpacing) {
                gridCard(width: gridWidth(paneWidth: paneWidth))
                    .frame(width: gridWidth(paneWidth: paneWidth) + Layout.cardPadding * 2)
                shortcutsCard
            }
        } else {
            // One centred column. The same tile size as the wide layout: a
            // grid that took the whole pane would draw nine screens the size
            // of a playing card and push the shortcuts two screens down.
            let width = min(
                max(paneWidth - Layout.cardSpacing * 2 - Layout.cardPadding * 2, 240),
                WindowsContent.gridColumn
            )
            VStack(spacing: Layout.cardSpacing) {
                gridCard(width: width)
                shortcutsCard
            }
            .frame(maxWidth: width + Layout.cardPadding * 2)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func gridWidth(paneWidth: CGFloat) -> CGFloat {
        let free = paneWidth - Layout.cardSpacing * 3 - WindowsContent.shortcutColumn
            - Layout.cardPadding * 2
        return min(max(free, 300), WindowsContent.gridColumn)
    }

    private func gridCard(width: CGFloat) -> some View {
        Card(title: "Move the window in front", symbolName: "macwindow.on.rectangle", fills: false) {
            VStack(alignment: .leading, spacing: 14) {
                if controller.showsConflictBanner {
                    WindowConflictBanner(controller: controller)
                }
                WindowTileGrid(controller: controller, columnWidth: width)
                if let status = controller.status, controller.accessibilityGranted,
                   controller.target?.refusal == nil {
                    Label(status, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Layout.gutter) {
                    Button {
                        controller.captureTarget()
                    } label: {
                        Label("Use the window in front", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var shortcutsCard: some View {
        Card(title: "Shortcuts", symbolName: "command", fills: false) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Set", selection: choiceBinding) {
                    ForEach(WindowShortcutChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(controller.choice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                shortcutTable
                Divider()

                Toggle(isOn: workaroundBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Work around the enhanced interface offset")
                        Text("Some apps report their window in a space of their own. Vent switches the flag off while it writes, and never while VoiceOver runs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(isOn: reactivateBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Go back to the app after a tile click")
                        Text("The popover takes the focus; this hands it straight back to the window that moved.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !controller.accessibilityGranted {
                    Divider()
                    accessibilityRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: WindowsContent.shortcutColumn)
    }

    private var shortcutTable: some View {
        VStack(spacing: 0) {
            ForEach(WindowAction.allCases, id: \.self) { action in
                shortcutRow(action)
                if action != WindowAction.allCases.last {
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private func shortcutRow(_ action: WindowAction) -> some View {
        let enabled = settings.windows.isEnabled(action)
        let binding = controller.choice.set?.binding(for: action)
        return HStack(spacing: Layout.gutter) {
            RegistrationDot(
                state: controller.registrations[action],
                hasSet: controller.choice != .off,
                shared: controller.sharesChordsWithAnotherManager
            )
            Text(action.title)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: Layout.gutter)
            if let binding {
                KeyCapRow(display: binding.display, enabled: enabled && controller.choice != .off)
            } else {
                Text("-")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Toggle(
                "",
                isOn: Binding(
                    get: { enabled },
                    set: { controller.setEnabled($0, for: action) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(controller.choice == .off)
        }
        .padding(.vertical, 3)
        .help(helpText(action))
    }

    private func helpText(_ action: WindowAction) -> String {
        if controller.sharesChordsWithAnotherManager,
           controller.registrations[action] == .registered {
            let name = controller.conflicts.first?.name ?? "another window manager"
            return "\(action.title): \(name) is running, so both apps may answer this chord."
        }
        return switch controller.registrations[action] {
        case .registered: "\(action.title): this chord is live."
        case .taken: "\(action.title): another app already owns this chord."
        case .failed(let status): "\(action.title): macOS refused this chord (\(status))."
        case .off, .none: "\(action.title): no shortcut."
        }
    }

    private var accessibilityRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.gutter) {
            Image(systemName: "xmark.circle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility")
                Text("Lets Vent move the windows of other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Layout.gutter)
            Button("Grant…") { controller.requestAccessibility() }
            Button("Open Settings") { controller.openAccessibilitySettings() }
        }
        .controlSize(.small)
    }

    // MARK: - Bindings

    private var choiceBinding: Binding<WindowShortcutChoice> {
        Binding(
            get: { controller.choice },
            set: { controller.setChoice($0) }
        )
    }

    private var workaroundBinding: Binding<Bool> {
        Binding(
            get: { settings.windows.enhancedUserInterfaceWorkaround },
            set: { controller.setEnhancedUserInterfaceWorkaround($0) }
        )
    }

    private var reactivateBinding: Binding<Bool> {
        Binding(
            get: { settings.windows.reactivatesAfterTile },
            set: { controller.setReactivatesAfterTile($0) }
        )
    }
}

/// Registered, shared with another manager, taken, or off. A dot rather than a
/// word: the table has twenty-two rows, and the colour is read at a glance.
struct RegistrationDot: View {
    let state: HotKeyRegistration?
    let hasSet: Bool
    var shared = false

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: 7, height: 7)
    }

    private var colour: Color {
        guard hasSet else { return Color(nsColor: .quaternaryLabelColor) }
        if shared, state == .registered { return Color.orange }
        return switch state {
        case .registered: Color.green
        case .taken: Color.orange
        case .failed: Color.red
        case .off, .none: Color(nsColor: .quaternaryLabelColor)
        }
    }
}
