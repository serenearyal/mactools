import SwiftUI

/// What the popover can ask the app to do. A struct of closures rather than a
/// reference to the controller: the view is rendered by the capture path too,
/// where none of these should fire.
struct MenuBarPopoverActions {
    var openTab: (MainTab) -> Void = { _ in }
    var selectSection: (PopoverSection) -> Void = { _ in }
    var lockKeyboard: () -> Void = {}
    /// Close the popover and leave the front to whoever had it. The Windows
    /// tiles use it: the window they move is behind the popover.
    var closePopover: () -> Void = {}
    var startAuto: () -> Void = {}
    var startFullBlast: () -> Void = {}
    var quit: () -> Void = {}
}

/// The dropdown behind the status item: a header, three sections and nothing
/// that moves when the user switches between them.
///
/// Dashboard is everything the window shows at a glance, Windows belongs to
/// the window manager, Tools holds the one-click actions. The section is
/// remembered, and it decides what the popover samples: Tools asks for the
/// fans alone, Windows for nothing at all.
struct MenuBarPopoverView: View {
    let services: AppServices
    var actions = MenuBarPopoverActions()
    /// The capture path renders one section without touching the app state.
    var forcedSection: PopoverSection?
    /// The header slot a later batch fills ("Awake 42m"). Empty today.
    var badge: PopoverBadge?

    private var section: PopoverSection { forcedSection ?? services.popoverSection }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            PopoverSectionPicker(selection: section, select: actions.selectSection)
            Divider()
            content
                .frame(
                    maxWidth: .infinity,
                    minHeight: PopoverLayout.contentHeight,
                    maxHeight: PopoverLayout.contentHeight,
                    alignment: .top
                )
                .clipped()
        }
        .frame(width: PopoverLayout.width, alignment: .leading)
        .frame(maxHeight: PopoverLayout.maximumHeight)
        .fixedSize(horizontal: false, vertical: true)
        // The popover takes the key window, and SwiftUI would draw a focus
        // ring around the first button of a panel nobody is tabbing through.
        .focusEffectDisabled()
        .background { shortcuts }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .dashboard:
            PopoverDashboard(services: services, actions: actions, open: open)
        case .windows:
            PopoverWindows(services: services, actions: actions, open: open)
        case .tools:
            PopoverTools(services: services, actions: actions, open: open)
        }
    }

    private func open(_ tab: MainTab) {
        actions.openTab(tab)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: PopoverLayout.rowSpacing) {
            Image(systemName: "fan.fill")
                .foregroundStyle(.tint)
                .imageScale(.medium)
            Text("Vent")
                .font(.headline)
            // The badge slot. It holds its height either way, so the header
            // never changes when a state appears in it.
            if let badge {
                PopoverBadgeView(badge: badge)
            }
            Spacer(minLength: PopoverLayout.rowSpacing)
            PopoverIconButton(symbolName: "macwindow", help: "Open Vent") {
                open(.overview)
            }
            PopoverIconButton(symbolName: "gearshape", help: "Settings") {
                open(.settings)
            }
            PopoverIconButton(symbolName: "power", help: "Quit Vent", action: actions.quit)
        }
        .frame(height: 44)
        .padding(.horizontal, PopoverLayout.padding)
    }

    /// Cmd-1, Cmd-2 and Cmd-3 switch sections. Zero-sized and clipped: the
    /// buttons are in the hierarchy so the shortcuts register, and they draw
    /// nothing and catch no click.
    private var shortcuts: some View {
        ZStack {
            ForEach(PopoverSection.allCases) { section in
                Button("Show \(section.title)") { actions.selectSection(section) }
                    .keyboardShortcut(KeyEquivalent(section.shortcutKey), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// The three sections, drawn by hand.
///
/// Not `Picker(.segmented)`: that is an `NSSegmentedControl`, and
/// `ImageRenderer` draws an empty box for an AppKit-backed view, which is the
/// path every popover screenshot goes through.
struct PopoverSectionPicker: View {
    let selection: PopoverSection
    let select: (PopoverSection) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PopoverSection.allCases) { section in
                segment(section)
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.28))
        }
        .padding(.horizontal, PopoverLayout.padding)
        .padding(.vertical, 6)
    }

    private func segment(_ section: PopoverSection) -> some View {
        let selected = section == selection
        return Button { select(section) } label: {
            HStack(spacing: 5) {
                Image(systemName: section.symbolName)
                    .imageScale(.small)
                Text(section.title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: PopoverLayout.hitTarget)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(selected ? 1 : 0))
                    .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 0.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(section.title) (Command-\(String(section.shortcutKey)))")
    }
}
