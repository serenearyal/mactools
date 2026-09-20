import SwiftUI

/// The Keyboard Lock tab: what the lock does, whether it may run, how long it
/// holds and the button that starts it.
struct KeyboardLockView: View {
    @Bindable var settings: AppSettings
    let lock: KeyboardLockController

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Layout.gutter) {
                    Text("Blocks every key so you can wipe the keyboard. The mouse and the trackpad keep working, and they are how you end the lock.")
                    Label(
                        "The power button and Touch ID stay live. macOS reserves them, and no app can take them.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)

                unlockPaths
            } header: {
                Text("Lock the keyboard for cleaning")
            }

            Section {
                Picker("Unlock automatically after", selection: $settings.lockTimeoutSeconds) {
                    ForEach(LockTimeout.choices, id: \.self) { seconds in
                        Text(LockTimeout.title(seconds)).tag(seconds)
                    }
                }

                Button {
                    lock.lock()
                } label: {
                    Label("Lock Keyboard", systemImage: "lock.laptopcomputer")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .controlSize(.extraLarge)
                .buttonStyle(.borderedProminent)
                .disabled(lock.state.isLocked)

                if case .failed(let reason) = lock.state {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let failure = lock.lastFailure {
                    Label("Last attempt: \(failure)", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Lock")
            } footer: {
                Text("The timeout always runs, even if the overlay never appears. It is the last way out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                permissionRow(
                    title: "Accessibility",
                    detail: "Lets Vent hold the keys.",
                    granted: lock.permissions.accessibility,
                    grant: { lock.requestAccessibility() },
                    settings: { lock.openAccessibilitySettings() }
                )
                permissionRow(
                    title: "Input Monitoring",
                    detail: "Lets Vent see the keys it holds.",
                    granted: lock.permissions.inputMonitoring,
                    grant: { lock.requestInputMonitoring() },
                    settings: { lock.openInputMonitoringSettings() }
                )
                if lock.permissions.secureInputEnabled {
                    Label(
                        "Secure Keyboard Entry is on in another app, so the lock cannot start. A password field or a terminal with Secure Keyboard Entry is the usual cause.",
                        systemImage: "exclamationmark.octagon.fill"
                    )
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("macOS asks for both once. After a grant, quit and open Vent again if the row stays red.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .onAppear { lock.refreshPermissions() }
    }

    private var unlockPaths: some View {
        VStack(alignment: .leading, spacing: 6) {
            unlockPath("hand.point.up.left.fill", "Hold the unlock button on screen for 1.5 s.")
            unlockPath("escape", "Press Esc three times inside 2 s.")
            // `hourglass`, not `timer`: next to `escape` at this size the two
            // round symbols read as the same thing.
            unlockPath("hourglass", "Wait for the timeout.")
        }
    }

    private func unlockPath(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.gutter) {
            // Fixed width: the symbols differ in width, and the three lines
            // have to start their text at the same x.
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            Text(text)
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        grant: @escaping () -> Void,
        settings: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.gutter) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Layout.gutter)
            if !granted {
                Button("Grant…", action: grant)
            }
            Button("Open Settings", action: settings)
        }
    }
}
