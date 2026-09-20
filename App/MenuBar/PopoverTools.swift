import AwakeKit
import BacklightKit
import SwiftUI

/// The one-click actions, one `ToolRow` each.
///
/// The order is the order of how often a hand reaches for them, not the order
/// they were built in: Keep Awake and the keyboard light are the two a user
/// opens this panel for, the fans and the lock are occasional, and the two
/// copies are a deliberate act.
///
/// The keyboard backlight row is not drawn at all on a Mac whose keyboard does
/// not light up. A row that is only ever disabled is worse than no row.
struct PopoverTools: View {
    let services: AppServices
    let actions: MenuBarPopoverActions
    let open: (MainTab) -> Void

    private var fans: FanStore { services.fans }
    private var keepAwake: KeepAwakeController { services.keepAwake }
    private var backlight: KeyboardBacklightController { services.backlight }
    private var reports: ReportService { services.reports }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row { keepAwakeRow }
            Divider()
            if backlight.isAvailable {
                row { backlightRow }
                Divider()
            }
            row { fanRow }
            Divider()
            row { lockRow }
            Divider()
            row { copyRow }
            Divider()
            row { storageRow }
            // No hairline under the last row: the list ends there.
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // The Tools section is the one place that needs the cached scan result
        // before anything is clicked: "Largest files" has to know whether it
        // can offer anything at all.
        .onAppear { services.storage.loadCacheIfNeeded() }
    }

    /// The rows share what is left of the fixed popover height between them
    /// rather than stacking at the top and leaving 150 pt of nothing under the
    /// last one. It also means a Mac with no keyboard backlight gets five
    /// slightly taller rows instead of a bigger hole.
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Keep Awake

    private var keepAwakeRow: some View {
        ToolRow(
            title: "Keep Awake",
            symbolName: keepAwake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer",
            detail: keepAwake.detailText
        ) {
            HStack(spacing: PopoverLayout.rowSpacing) {
                Menu(keepAwake.options.duration.title) {
                    ForEach(KeepAwakeDuration.presets, id: \.self) { duration in
                        Button(duration.title) { keepAwake.setDuration(duration) }
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize()
                .help("How long to hold this Mac awake")

                Toggle("Keep Awake", isOn: awakeBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(keepAwake.isOn ? "Let this Mac sleep again" : "Hold this Mac awake")
            }
        }
    }

    private var awakeBinding: Binding<Bool> {
        Binding(get: { keepAwake.isOn }, set: { keepAwake.setOn($0) })
    }

    // MARK: - Keyboard backlight

    /// The one row with a control too wide for the trailing slot, so it is
    /// built from the same pieces as `ToolRow` rather than squeezed into it:
    /// the same 20 pt symbol column, the same padding, the same 44 pt floor.
    private var backlightRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: PopoverLayout.rowSpacing + 2) {
                Image(systemName: "light.max")
                    .imageScale(.medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .center)
                Text("Keyboard Backlight")
                Spacer(minLength: PopoverLayout.rowSpacing)
                Toggle("Auto", isOn: autoBinding)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Let the ambient light sensor set the level")
            }
            BacklightSlider(backlight: backlight)
                .padding(.leading, 28)
            backlightHint
        }
        .padding(.horizontal, PopoverLayout.padding)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var backlightHint: some View {
        if backlight.isAuto {
            HStack(spacing: PopoverLayout.rowSpacing) {
                PopoverHint(text: "Auto brightness may change this.")
                Button("Turn off Auto") { backlight.setAuto(false) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Stop the ambient light sensor from moving the level")
            }
            .padding(.leading, 28)
        } else if let note = backlight.reading.stateNote {
            PopoverHint(text: note)
                .padding(.leading, 28)
        }
    }

    private var autoBinding: Binding<Bool> {
        Binding(get: { backlight.isAuto }, set: { backlight.setAuto($0) })
    }

    // MARK: - Fans

    private var fanRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolRow(title: "Fans", symbolName: "fan", detail: fanDetail) {
                HStack(spacing: 6) {
                    Button("Auto", action: actions.startAuto)
                        .help("Give every fan back to the firmware")
                    Button("Full Blast", action: actions.startFullBlast)
                        .help("Hold every fan at its maximum RPM")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!fans.isAvailable)
            }
            fanHint
        }
    }

    /// The same order as the Dashboard: the helper is the wrong build, then
    /// the last command was refused, then there is no helper at all.
    @ViewBuilder
    private var fanHint: some View {
        if let mismatch = services.helper.mismatchMessage {
            hint {
                PopoverHint(text: mismatch, tint: .red)
                Button("Open Settings") { open(.settings) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else if let refusal = fans.lastCommandFailure {
            hint { PopoverHint(text: refusal, tint: .red) }
        } else if !fans.isAvailable {
            hint { PopoverHint(text: "Fan control needs the privileged helper.") }
        }
    }

    private func hint<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .padding(.horizontal, PopoverLayout.padding)
        // Under the row it belongs to, on the same baseline grid.
        .padding(.leading, 28)
        .padding(.bottom, PopoverLayout.sectionSpacing)
    }

    private var fanDetail: String {
        let rows = FanRow.rows(fans: fans, snapshot: services.store.snapshot)
        guard !rows.isEmpty else {
            return fans.isAvailable ? "No fan on this Mac" : "Not available"
        }
        let modes = Set(rows.map(\.mode))
        let mode = modes.count == 1 ? (modes.first ?? "Auto") : "Mixed"
        return ([mode] + rows.prefix(2).map(\.rpm)).joined(separator: " · ")
    }

    // MARK: - Keyboard lock

    private var lockRow: some View {
        ToolRow(
            title: "Keyboard Lock",
            symbolName: "keyboard",
            detail: "Swallows every key, for cleaning"
        ) {
            Button("Lock (\(LockTimeout.title(services.settings.lockTimeoutSeconds)))") {
                actions.lockKeyboard()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Lock for cleaning (\(LockTimeout.title(services.settings.lockTimeoutSeconds)))")
        }
    }

    // MARK: - Copy for AI

    /// The confirmation replaces the second line rather than joining it, so a
    /// copy moves nothing in the panel.
    private var copyRow: some View {
        ToolRow(
            title: "Copy for AI",
            symbolName: "doc.on.clipboard",
            detail: reports.confirmation ?? copyDetail
        ) {
            HStack(spacing: 6) {
                Button {
                    reports.copyProcesses(samplesFirst: true)
                } label: {
                    if reports.isPreparing {
                        // The same footprint as the word it replaces, so the
                        // two buttons do not shuffle while the sample runs.
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 70)
                    } else {
                        // 70 pt, measured: at 56 the label truncated to
                        // "Proces...".
                        Text("Processes").frame(width: 70)
                    }
                }
                .disabled(reports.isPreparing)
                .help("Copy the running processes as text for a chat model")

                // "Largest files" is what the button said first, and at this
                // width both labels truncated to "Proces..." and "Largest f...".
                // The row title and its second line carry the meaning.
                Button("Files") { reports.copyFiles() }
                    .disabled(!reports.canReportFiles)
                    .help(
                        reports.canReportFiles
                            ? "Copy the largest files as text for a chat model"
                            : "Scan first"
                    )
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .animation(.default, value: reports.isPreparing)
        }
    }

    private var copyDetail: String {
        reports.canReportFiles
            ? "Processes, or the largest files"
            : "Files needs a scan first"
    }

    // MARK: - Storage

    private var storageRow: some View {
        ToolRow(
            title: "Storage Scan",
            symbolName: "magnifyingglass",
            detail: "Find the largest files on this Mac"
        ) {
            Button("Scan Storage...") { open(.storage) }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Open the Storage tab to find the largest files")
        }
    }
}
