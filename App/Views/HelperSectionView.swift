import SwiftUI

/// The privileged helper, at the top of the Settings tab.
///
/// Compact on purpose: one status line and three buttons. Fan control, the
/// full process list and everything else that needs root is unavailable until
/// this line is green, so it is the first thing in the tab.
struct HelperSectionView: View {
    let helper: HelperController

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: Layout.gutter) {
                Image(systemName: appearance.symbolName)
                    .foregroundStyle(appearance.tint)
                    .frame(width: 20, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appearance.title)
                    if let detail = appearance.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Layout.gutter)
                if helper.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: Layout.gutter) {
                Button(installTitle) {
                    Task { await helper.install() }
                }
                .disabled(helper.isBusy)
                Button("Uninstall") {
                    Task { await helper.uninstall() }
                }
                .disabled(helper.isBusy || helper.state == .notInstalled)
                Spacer(minLength: Layout.gutter)
                Button("Open Login Items Settings") {
                    helper.openLoginItemsSettings()
                }
            }
        } header: {
            Text("Privileged helper")
        } footer: {
            Text("Fan control and the full process list need a helper that runs as root. Installing it registers a launch daemon, which macOS asks you to approve once.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await helper.refresh() }
    }

    private var installTitle: String {
        switch helper.state {
        case .outdated: "Reinstall"
        case .running: "Reinstall"
        default: "Install"
        }
    }

    private var appearance: (symbolName: String, tint: Color, title: String, detail: String?) {
        switch helper.state {
        case .unknown:
            ("hourglass", .secondary, "Checking…", nil)
        case .notInstalled:
            ("xmark.circle", .secondary, "Not installed", nil)
        case .supersededOnly:
            (
                "exclamationmark.triangle.fill", .orange,
                "A helper from the old name (Vent) is installed.",
                "Install replaces it."
            )
        case .requiresApproval:
            (
                "exclamationmark.triangle.fill", .orange,
                "Needs approval in System Settings",
                "Turn MacTools on under Login Items & Extensions, then come back."
            )
        case .running(let version, let uid):
            (
                "checkmark.circle.fill", .green,
                "Running v\(version) as root",
                "uid \(uid), installed with \(helper.installedBy?.title ?? "an unknown installer")."
            )
        case .outdated(let installed, let expected):
            (
                "arrow.triangle.2.circlepath", .orange,
                "Running v\(installed), the app is v\(expected)",
                "Reinstall so the helper matches this build."
            )
        case .failed(let message):
            ("exclamationmark.octagon.fill", .red, "Error", message)
        }
    }
}
