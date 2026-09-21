import AppKit
import AwakeKit
import SwiftUI

/// The Keep Awake tab: the switch and its options, an honest account of what
/// the assertion does and does not do, and the list of everything else on this
/// Mac that is holding it awake.
struct KeepAwakeView: View {
    let keepAwake: KeepAwakeController
    /// The way to the Install button, for a helper too old to know what the
    /// lid option is. Defaulted, so the one call site stays a one-liner.
    var openSettings: () -> Void = { AppServices.shared.selectedTab = .settings }

    var body: some View {
        Form {
            Section {
                Toggle("Keep this Mac awake", isOn: onBinding)
                    .toggleStyle(.switch)
                    .help("Hold a sleep assertion while this is on")

                Picker("For", selection: durationBinding) {
                    ForEach(durations, id: \.self) { duration in
                        Text(duration.title).tag(duration)
                    }
                }
                .help("How long the assertion lasts before it releases itself")

                // Directly under the main switch: it is the option people come
                // to this tab for, and under "Options" it was below the fold.
                lidToggle

                status
            } header: {
                Text("Sleep")
            } footer: {
                Text(
                    "Vent starts every launch with this off. There is no \"turn on at launch\" "
                        + "option on purpose: a Mac that silently never sleeps because of a "
                        + "setting made weeks ago is a flat battery waiting to happen."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Keep the display on", isOn: displayBinding)
                    .help("Also hold a display-sleep assertion, so the screen stays lit")
                Toggle("Use the battery guard", isOn: guardBinding)
                    .help("Release the assertion when the charge falls to the threshold")
                Stepper(
                    "Turn off below \(keepAwake.options.batteryThreshold) % on battery",
                    value: thresholdBinding,
                    in: KeepAwakeOptions.thresholdRange
                )
                .disabled(!keepAwake.options.batteryGuardEnabled)
                .monospacedDigit()
                .help("Between 5 % and 50 %")
            } header: {
                Text("Options")
            } footer: {
                Text(
                    "The guard also releases the assertion when this Mac reaches a critical "
                        + "thermal state, whatever these settings say."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                VStack(alignment: .leading, spacing: Layout.gutter) {
                    // Truthful in both modes: what the second line promises
                    // changes with the lid hold, so it is derived from what is
                    // actually held rather than written twice.
                    ForEach(summaryLines) { line in
                        note(line.stops ? "checkmark.circle" : "xmark.circle", line.text)
                    }
                    note(
                        "bolt.circle",
                        keepAwake.blocking.lidSleepIsOurs
                            ? "Both come off when Vent quits, when Vent is killed, when the timer ends "
                                + "and when the battery guard or a hot Mac says so."
                            : "Releases itself when Vent quits, and when Vent is killed."
                    )
                }
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("What it does")
            }

            if keepAwake.lidSetBySomebodyElse {
                Section {
                    sleepDisabledRow
                } header: {
                    Text("This Mac cannot sleep at all")
                }
            }

            Section {
                if keepAwake.assertions.isEmpty {
                    Text("Nothing is holding this Mac awake.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(keepAwake.assertions) { entry in
                        assertionRow(entry)
                    }
                }
            } header: {
                Text("What is keeping this Mac awake")
            } footer: {
                Text("Read from the power manager every five seconds, and only while this tab is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { keepAwake.setListVisible(true) }
        .onDisappear { keepAwake.setListVisible(false) }
    }

    // MARK: - The lid

    /// The one option that needs root. It is drawn as a switch plus a caption,
    /// and under it whatever stands between the user and the thing working:
    /// an old helper, no helper at all, or a flag `pmset` already holds.
    @ViewBuilder
    private var lidToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Stay awake with the lid closed", isOn: lidBinding)
                .help("Hold the system-wide sleep setting, the one \"pmset disablesleep 1\" writes")
            Text(LidSleepPolicy.thermalCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            lidHint
        }
    }

    @ViewBuilder
    private var lidHint: some View {
        if keepAwake.lidClearPending {
            // Ahead of everything else under this switch: Vent wants the flag
            // off, this Mac still will not sleep with the lid shut, and the
            // user is the one carrying it about.
            Label(
                KeepAwakeController.clearRetryText
                    + ". This Mac still does not sleep with the lid closed. "
                    + "Vent keeps asking the helper; "
                    + "\"\(PowerAssertions.enableSleepCommand)\" ends it at once.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        } else if keepAwake.lidNeedsReinstall {
            HStack(spacing: Layout.gutter) {
                Label("Reinstall the helper to use this", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Open Settings", action: openSettings)
                    .controlSize(.small)
            }
        } else if let failure = keepAwake.lidFailure {
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if keepAwake.options.lidClose, keepAwake.blocking.lidSleepIsOurs {
            Label("On: this Mac stays awake with the lid closed", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var summaryLines: [AwakeBlocking.Line] {
        AwakeBlocking.summary(
            lidHeld: keepAwake.blocking.lidSleepBlocked,
            displayHeld: keepAwake.blocking.displaySleepHeld
        )
    }

    // MARK: - Pieces

    /// The five presets, plus whatever is set if it is not one of them.
    ///
    /// A `Picker` whose selection matches no tag draws an empty box, which is
    /// what `--keep-awake-test` did with its one minute duration. A settings
    /// file written by hand can do the same.
    private var durations: [KeepAwakeDuration] {
        let current = keepAwake.options.duration
        guard !KeepAwakeDuration.presets.contains(current) else {
            return KeepAwakeDuration.presets
        }
        return KeepAwakeDuration.presets + [current]
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: Layout.gutter) {
            // The same light as under the fan in the menu bar.
            AwakeLEDDot(led: keepAwake.blocking.led)
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                Text(keepAwake.detailText)
                    .foregroundStyle(keepAwake.isOn ? .primary : .secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                AwakeLEDLegend(current: keepAwake.blocking.led)
            }
            Spacer(minLength: Layout.gutter)
        }
        .font(.callout)
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.gutter) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            Text(text)
        }
    }

    private func assertionRow(_ entry: AssertionEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.gutter) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.processName)
                        .lineLimit(1)
                    // `String(_:)`, not interpolation: SwiftUI groups an
                    // interpolated integer, and "pid 64,722" is not a pid.
                    Text("pid " + String(entry.pid))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Text(entry.name.isEmpty ? entry.plainType : "\(entry.plainType) · \(entry.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Layout.gutter)
        }
        .help(entry.type)
    }

    /// The one case Vent can only report: somebody ran `pmset disablesleep 1`
    /// as root, and this Mac will not sleep whatever any app asks for.
    private var sleepDisabledRow: some View {
        VStack(alignment: .leading, spacing: Layout.gutter) {
            Label(
                "Somebody ran \"pmset disablesleep 1\" on this Mac. It never sleeps by itself, "
                    + "with or without Keep Awake. Vent did not set this one, so Vent will not "
                    + "undo it: a setting the user made by hand is theirs to reverse.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Layout.gutter) {
                Text(PowerAssertions.enableSleepCommand)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                            }
                    }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        PowerAssertions.enableSleepCommand,
                        forType: .string
                    )
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .help("Copy the command that lets this Mac sleep again")
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Bindings

    private var onBinding: Binding<Bool> {
        Binding(get: { keepAwake.isOn }, set: { keepAwake.setOn($0) })
    }

    private var durationBinding: Binding<KeepAwakeDuration> {
        Binding(get: { keepAwake.options.duration }, set: { keepAwake.setDuration($0) })
    }

    private var displayBinding: Binding<Bool> {
        Binding(get: { keepAwake.options.keepDisplayOn }, set: { keepAwake.setKeepDisplayOn($0) })
    }

    private var lidBinding: Binding<Bool> {
        Binding(get: { keepAwake.options.lidClose }, set: { keepAwake.setLidClose($0) })
    }

    private var guardBinding: Binding<Bool> {
        Binding(
            get: { keepAwake.options.batteryGuardEnabled },
            set: { keepAwake.setBatteryGuardEnabled($0) }
        )
    }

    private var thresholdBinding: Binding<Int> {
        Binding(
            get: { keepAwake.options.batteryThreshold },
            set: { keepAwake.setBatteryThreshold($0) }
        )
    }
}
