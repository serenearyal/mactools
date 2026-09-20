import SwiftUI

/// The one-click actions, one `ToolRow` each.
///
/// Only what exists today has a row: the fans, the keyboard lock and the
/// storage scan. Keep Awake, the keyboard backlight and Copy for AI are not
/// drawn at all until they work; the container and the spacing are what the
/// later batches slot into.
struct PopoverTools: View {
    let services: AppServices
    let actions: MenuBarPopoverActions
    let open: (MainTab) -> Void

    private var fans: FanStore { services.fans }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fanRow
            Divider()
            lockRow
            Divider()
            storageRow
            // No hairline under the last row: the list ends, and the space
            // below it is where the rows of the later batches go.
            Spacer(minLength: 0)
        }
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
