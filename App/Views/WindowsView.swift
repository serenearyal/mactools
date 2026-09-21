import SwiftUI
import WindowKit

/// The Windows tab: the command list, and the settings that drive it.
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

    /// Above this the command list runs in two columns and the whole of it is
    /// on screen at the default window size; under it, at the 760 pt minimum,
    /// it is one column and the pane scrolls.
    static let twoColumnPaneWidth: CGFloat = 692

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= WindowsContent.twoColumnPaneWidth
            content(wide: wide)
        }
    }

    @ViewBuilder
    private func content(wide: Bool) -> some View {
        if scrolls {
            ScrollView { cards(wide: wide).padding(Layout.cardSpacing) }
        } else {
            VStack(spacing: 0) {
                cards(wide: wide).padding(Layout.cardSpacing)
                Spacer(minLength: 0)
            }
        }
    }

    /// The commands first: they are what the tab is for. The set, the gap and
    /// the two switches sit under them.
    private func cards(wide: Bool) -> some View {
        VStack(spacing: Layout.cardSpacing) {
            commandsCard(wide: wide)
            settingsCard(wide: wide)
        }
    }

    // MARK: - The commands

    private func commandsCard(wide: Bool) -> some View {
        Card(title: "Move the window in front", symbolName: "macwindow.on.rectangle", fills: false) {
            VStack(alignment: .leading, spacing: 10) {
                WindowTargetCard(controller: controller)
                if controller.accessibilityGranted {
                    WindowCommandListView(controller: controller, columns: wide ? 2 : 1)
                    if let status = controller.status, controller.target?.refusal == nil {
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
                        Text("Right-click a command to switch its shortcut off.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: - The settings under them

    private func settingsCard(wide: Bool) -> some View {
        Card(title: "Shortcuts", symbolName: "command", fills: false) {
            VStack(alignment: .leading, spacing: 12) {
                if controller.showsConflictBanner {
                    WindowConflictBanner(controller: controller)
                }
                HStack(alignment: .top, spacing: Layout.cardSpacing) {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Set", selection: choiceBinding) {
                            ForEach(WindowShortcutChoice.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 320)
                        Text(controller.choice.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if controller.choice != .off {
                            registrationLine
                        }
                    }
                    if wide {
                        GapSlider(controller: controller)
                            .frame(width: 240)
                    }
                }
                if !wide {
                    Divider()
                    GapSlider(controller: controller)
                }

                Divider()
                switches(wide: wide)

                if !controller.accessibilityGranted {
                    Divider()
                    accessibilityRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func switches(wide: Bool) -> some View {
        let layout = wide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: Layout.cardSpacing))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        layout {
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
                    Text("Go back to the app after a command")
                    Text("The popover takes the focus; this hands it straight back to the window that moved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What the system said about the chords, in one line: the answer to "the
    /// shortcuts do not work" without a log stream.
    private var registrationLine: some View {
        let states = controller.registrations.values
        let live = states.filter(\.isRegistered).count
        let failed = states.filter { if case .failed = $0 { true } else { false } }.count
        let taken = states.filter { $0 == .taken }.count
        let tint: Color = failed > 0
            ? .red
            : (taken > 0 || controller.sharesChordsWithAnotherManager ? .orange : .green)
        return HStack(spacing: 6) {
            // A dot rather than a word: the colour is read at a glance.
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(summary(live: live, taken: taken, failed: failed))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summary(live: Int, taken: Int, failed: Int) -> String {
        var text = "\(live) of \(live + taken + failed) shortcuts are live"
        if taken > 0 { text += ", \(taken) held by another app" }
        if failed > 0 { text += ", \(failed) refused by macOS" }
        if controller.sharesChordsWithAnotherManager {
            let name = controller.conflicts.first?.name ?? "another window manager"
            text += ". \(name) answers them too."
        }
        return text + "."
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
