import AppKit
import AwakeKit
import SwiftUI

/// The Keep Awake tab: the switch and its options, an honest account of what
/// the assertion does and does not do, and the list of everything else on this
/// Mac that is holding it awake.
struct KeepAwakeView: View {
    let keepAwake: KeepAwakeController

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

                status
            } header: {
                Text("Keep Awake")
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
                    note("checkmark.circle", "Stops the idle sleep that follows a spell of no input.")
                    note(
                        "xmark.circle",
                        "Does not stop a sleep you ask for: the Apple menu, the power button "
                            + "and a closed lid on battery all still sleep this Mac."
                    )
                    note(
                        "xmark.circle",
                        "Does not stop the display dimming unless \"Keep the display on\" is on."
                    )
                    note("bolt.circle", "Releases itself when Vent quits, and when Vent is killed.")
                }
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("What it does")
            }

            if keepAwake.sleepDisabled == true {
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
            Image(systemName: keepAwake.isOn ? "circle.fill" : "circle")
                .font(.system(size: 8))
                .foregroundStyle(keepAwake.isOn ? Color.accentColor : Color.secondary)
                .frame(width: 20, alignment: .center)
            Text(keepAwake.detailText)
                .foregroundStyle(keepAwake.isOn ? .primary : .secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
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
                    + "with or without Keep Awake. Vent did not set this and cannot undo it: "
                    + "it needs root.",
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
