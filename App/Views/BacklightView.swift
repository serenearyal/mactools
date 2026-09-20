import BacklightKit
import SwiftUI

/// The Keyboard Backlight tab: the same control as the popover, larger, with
/// what the ambient sensor is doing to it right now.
///
/// The tab is only reachable on a Mac whose built-in keyboard lights up; the
/// sidebar drops the item entirely otherwise, so there is no dead state here.
struct BacklightView: View {
    let backlight: KeyboardBacklightController

    var body: some View {
        Form {
            Section {
                BacklightSlider(backlight: backlight, large: true)

                HStack(spacing: Layout.gutter) {
                    Toggle("Auto brightness", isOn: autoBinding)
                        .toggleStyle(.switch)
                        .help("Let the ambient light sensor set the level")
                    Spacer(minLength: Layout.gutter)
                }

                if let note = backlight.reading.stateNote {
                    Label(note, systemImage: "sun.max")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Brightness")
            } footer: {
                Text(
                    backlight.isAuto
                        ? "Auto brightness is on, so the ambient light sensor may move this "
                            + "again a moment after you set it."
                        : "The slider writes the same 16 steps the F5 and F6 keys walk."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                VStack(alignment: .leading, spacing: Layout.gutter) {
                    note(
                        "keyboard",
                        "F5 and F6 keep working. They move the same value in sixteenths, and "
                            + "the slider follows them within a second."
                    )
                    note(
                        "sun.max",
                        "In a bright room the system switches the backlight off by itself. "
                            + "The slider still writes; the light comes back when the room dims."
                    )
                    note(
                        "moon.zzz",
                        "After a spell of no typing the system dims the keyboard. The next key "
                            + "press brings it back."
                    )
                    note(
                        "lock.open",
                        "Vent changes the Auto setting only when you switch it here. Nothing "
                            + "else in the app touches it."
                    )
                }
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("What to expect")
            }
        }
        .formStyle(.grouped)
        .onAppear { backlight.refresh() }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.gutter) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            Text(text)
        }
    }

    private var autoBinding: Binding<Bool> {
        Binding(get: { backlight.isAuto }, set: { backlight.setAuto($0) })
    }
}

/// The slider itself: a dim symbol, the track, a bright symbol and the percent.
///
/// Shared by the tab and the popover row so the two never drift apart. The
/// percent has a fixed width, so a move from 9 % to 100 % does not shuffle the
/// row it sits in.
///
/// The two symbols are the slider's own value labels rather than views beside
/// it. A bare `Slider` inside a `Form` is given the control half of the row and
/// leaves the label half empty, which put 190 pt of nothing between the dim
/// symbol and the track; the value labels travel with the control instead.
struct BacklightSlider: View {
    let backlight: KeyboardBacklightController
    var large = false

    var body: some View {
        HStack(spacing: Layout.gutter) {
            Slider(
                value: Binding(
                    get: { backlight.level },
                    set: { backlight.slide(to: $0) }
                ),
                in: 0...1
            ) {
                Text("Keyboard backlight")
            } minimumValueLabel: {
                Image(systemName: "light.min")
                    .imageScale(large ? .medium : .small)
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "light.max")
                    .imageScale(large ? .medium : .small)
                    .foregroundStyle(.secondary)
            } onEditingChanged: { editing in
                // The snap happens once, on the release: snapping during the
                // drag would make the handle stick to the rungs.
                if !editing { backlight.commit() }
            }
            .labelsHidden()
            .controlSize(large ? .regular : .small)
            .help("Keyboard backlight brightness")

            Text(backlight.percentText)
                .font(large ? .callout : .caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                // Fixed: "6%" and "100%" must not move the slider's right edge.
                .frame(width: large ? 44 : 36, alignment: .trailing)
        }
    }
}
