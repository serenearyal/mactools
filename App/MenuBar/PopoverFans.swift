import FanControl
import SMCKit
import SwiftUI
import SysMetrics

/// The Fans section: the three thermal readouts, a card per fan with the
/// controls that used to need the window, and the two commands.
///
/// It is where "Thermals & Fans" went when the Dashboard gave its slot to the
/// battery. The Dashboard could show the fans but not command them - there was
/// room for two rows of text and two buttons - so the whole fan configuration
/// lives here now, one card per fan, and the Fans tab of the window is for the
/// curve editor and the sensor list.
///
/// Every group is a fixed box, `PopoverLayout.FansHeight`: the rpm changes
/// every two seconds, and no sample may cost a measurement of the panel.
struct PopoverFans: View {
    let services: AppServices
    let actions: MenuBarPopoverActions
    let open: (MainTab) -> Void

    private typealias Height = PopoverLayout.FansHeight

    private var store: MetricsStore { services.store }
    private var fans: FanStore { services.fans }
    private var helper: HelperController { services.helper }
    private var settings: AppSettings { services.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: Height.gap) {
            header
            cards
            notice
            buttons
        }
        .padding(.horizontal, PopoverLayout.padding)
        .padding(.vertical, PopoverLayout.sectionSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header

    /// The title beside the three readouts the Dashboard used to carry. One
    /// row: the section has four cards' worth of work to fit under it.
    private var header: some View {
        // On the baseline of the three values, not in the middle of the row:
        // the caption over each of them is a label, and the title is not.
        HStack(alignment: .lastTextBaseline, spacing: PopoverLayout.rowSpacing) {
            PopoverSectionTitle(title: "Fans", symbolName: "fan", tab: .fans, open: open)
            Spacer(minLength: PopoverLayout.rowSpacing)
            PopoverStat(
                caption: "CPU",
                value: temperature(store.hottestCPU),
                tint: store.hottestCPU.map { MetricColor.temperature($0.celsius) }
            )
            PopoverStat(
                caption: "GPU",
                value: temperature(store.hottest(in: .gpu)),
                tint: store.hottest(in: .gpu).map { MetricColor.temperature($0.celsius) }
            )
            PopoverStat(
                caption: "POWER",
                value: store.systemPower.map { Fmt.watts($0.watts) } ?? "--"
            )
        }
        .frame(height: Height.header)
    }

    private func temperature(_ reading: TemperatureReading?) -> String {
        reading.map { Fmt.temperature($0.celsius, unit: settings.temperatureUnit) } ?? "--"
    }

    // MARK: - The cards

    /// Two at most. A Mac with more fans has them all on the Fans tab, and the
    /// notice line under the cards says so.
    ///
    /// Centred rather than stacked at the top: a Mac with one fan gets its
    /// card in the middle of the space two would have filled, which reads as a
    /// layout and not as a card that lost its neighbour.
    @ViewBuilder
    private var cards: some View {
        Group {
            if cardModels.isEmpty {
                emptyState
            } else {
                VStack(spacing: PopoverLayout.rowSpacing) {
                    ForEach(cardModels.prefix(2)) { model in
                        FanCardView(
                            model: model,
                            store: store,
                            fans: fans,
                            settings: settings,
                            open: open
                        )
                    }
                }
            }
        }
        .frame(height: Height.cards, alignment: .center)
    }

    private var emptyState: some View {
        PopoverEmptyState(
            symbolName: fans.isAvailable ? "fan" : "fan.slash",
            text: fans.isAvailable
                ? "This Mac has no fan to control."
                : "Fan speeds and control need the privileged helper."
        )
    }

    /// The helper's fans when it is there, the plain SMC read when it is not.
    ///
    /// Without the helper the speeds are still true - the app reads them
    /// itself for the menu bar - so the cards are drawn with their controls
    /// disabled rather than replaced by an apology.
    private var cardModels: [FanCardModel] {
        if fans.isAvailable, !fans.fans.isEmpty {
            return fans.fans.map { FanCardModel(fan: $0, count: fans.fans.count) }
        }
        return store.fans.map { FanCardModel(reading: $0, count: store.fans.count) }
    }

    // MARK: - The one line under the cards

    /// The state of fan control, in the one place it can be read without
    /// hunting: the helper being the wrong build, a refused command, a fault,
    /// the thermal interlock, and otherwise the quiet summary.
    ///
    /// The row is always there. A refusal that arrives while the popover is
    /// open would otherwise push every card up by 30 pt.
    private var notice: some View {
        let state = currentNotice
        return HStack(spacing: PopoverLayout.rowSpacing) {
            Image(systemName: state.symbolName)
                .imageScale(.small)
                .foregroundStyle(state.tint)
            Text(state.text)
                .font(.caption)
                .foregroundStyle(state.isQuiet ? Color.secondary : state.tint)
                .lineLimit(2)
            Spacer(minLength: PopoverLayout.rowSpacing)
            if state.opensSettings {
                Button("Open Settings") { open(.settings) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
            }
            if state.isDismissable {
                Button { fans.clearCommandFailure() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, PopoverLayout.rowSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Height.notice)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(state.tint.opacity(state.isQuiet ? 0.06 : 0.12))
        }
    }

    private struct FanNotice {
        var text: String
        var symbolName: String
        var tint: Color = .secondary
        var isQuiet = false
        var opensSettings = false
        var isDismissable = false
    }

    private var currentNotice: FanNotice {
        if let mismatch = helper.mismatchMessage {
            return FanNotice(
                text: mismatch,
                symbolName: "arrow.triangle.2.circlepath",
                tint: .orange,
                opensSettings: true
            )
        }
        if let refusal = fans.lastCommandFailure {
            return FanNotice(
                text: refusal,
                symbolName: "exclamationmark.octagon.fill",
                tint: .red,
                isDismissable: true
            )
        }
        if let fault = fans.faults.first {
            return FanNotice(
                text: "Fan \(fault.fanIndex + 1): \(fault.reason)",
                symbolName: "exclamationmark.triangle.fill",
                tint: .red
            )
        }
        if fans.interlockEngaged {
            return FanNotice(
                text: interlockText,
                symbolName: "thermometer.sun.fill",
                tint: .red
            )
        }
        if !fans.isAvailable {
            return FanNotice(
                text: "Fan control needs the privileged helper.",
                symbolName: "lock.fill",
                tint: .secondary,
                isQuiet: true,
                opensSettings: true
            )
        }
        return FanNotice(
            text: summaryText,
            symbolName: "checkmark.seal",
            tint: .secondary,
            isQuiet: true
        )
    }

    /// Why every fan went back to Auto, and when it will be given back.
    private var interlockText: String {
        let hottest = fans.hottestDie.map {
            Fmt.temperature($0, unit: settings.temperatureUnit, digits: 1)
        }
        return "A die reached \(hottest ?? "100 °C"): every fan is on Auto until it is below "
            + Fmt.temperature(Fans.thermalReleaseCelsius, unit: settings.temperatureUnit)
            + "."
    }

    /// What the cards cannot say: how many fans there are in total, what they
    /// are set to together, and the die the helper watches.
    private var summaryText: String {
        let models = cardModels
        guard !models.isEmpty else { return "No fan on this Mac." }
        var parts = ["\(models.count) \(models.count == 1 ? "fan" : "fans")"]
        let modes = Set(fans.fans.map { FanRow.title(of: $0.mode) })
        if modes.count == 1, let mode = modes.first { parts.append(mode) }
        else if modes.count > 1 { parts.append("Mixed") }
        if let die = fans.hottestDie {
            parts.append("hottest die \(Fmt.temperature(die, unit: settings.temperatureUnit))")
        }
        if models.count > 2 {
            let rest = models.count - 2
            parts.append("\(rest) more on the Fans tab")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - The two commands

    private var buttons: some View {
        HStack(spacing: PopoverLayout.rowSpacing) {
            Button(action: actions.startAuto) {
                Text("All Auto").frame(maxWidth: .infinity)
            }
            .help("Give every fan back to the firmware")
            Button(action: actions.startFullBlast) {
                Text("Full Blast").frame(maxWidth: .infinity)
            }
            .help("Hold every fan at its maximum RPM")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(!fans.isAvailable || fans.fans.isEmpty)
        .frame(height: Height.buttons)
    }
}

// MARK: - One fan

/// A fan as the section draws it, from either source of truth.
///
/// The helper knows the mode the user asked for and the limits the governor
/// clamps to; without it the unprivileged SMC read still gives the speed and
/// the limits, and `fan` is nil, which is what disables every control.
struct FanCardModel: Identifiable {
    let index: Int
    let name: String
    let actualRPM: Double
    let minimumRPM: Double
    let maximumRPM: Double
    let targetRPM: Double
    let isForced: Bool
    /// Nil when this came from the SMC read, with no helper to command.
    let fan: FanStatus?

    var id: Int { index }

    var isControllable: Bool { fan != nil }

    /// What the firmware is doing with this fan, whoever asked for it. The
    /// same words the card in the window uses.
    var hardwareLine: String {
        isForced ? "forced, target \(Fmt.rpm(targetRPM))" : "firmware control"
    }

    /// Where the fan sits between its limits, 0 to 1.
    var loadFraction: Double {
        guard maximumRPM > minimumRPM else { return 0 }
        return ((actualRPM - minimumRPM) / (maximumRPM - minimumRPM)).clamped(to: 0...1)
    }

    init(fan: FanStatus, count: Int) {
        index = fan.index
        // The helper names its fans with `FanNaming` already; the count is
        // there so a snapshot from an older build still reads "Left fan".
        name = fan.name.isEmpty ? FanNaming.name(index: fan.index, of: count) : fan.name
        actualRPM = fan.actualRPM
        minimumRPM = fan.minimumRPM
        maximumRPM = fan.maximumRPM
        targetRPM = fan.targetRPM
        isForced = fan.hardwareMode == .forced
        self.fan = fan
    }

    init(reading: FanReading, count: Int) {
        index = reading.index
        name = FanNaming.name(index: reading.index, of: count)
        actualRPM = reading.actual
        minimumRPM = reading.minimum
        maximumRPM = reading.maximum
        targetRPM = reading.target
        isForced = reading.mode == .forced
        fan = nil
    }
}

/// The name and the speed, the gauge between the limits, the mode, and the
/// editor of that mode. Four fixed rows, so a fan that speeds up moves
/// nothing but its own digits.
private struct FanCardView: View {
    let model: FanCardModel
    let store: MetricsStore
    let fans: FanStore
    let settings: AppSettings
    let open: (MainTab) -> Void

    private typealias Height = PopoverLayout.FansHeight

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverLayout.rowSpacing) {
            head
            gauge
            segments
            editor
        }
        .padding(Height.cardPadding)
        .frame(height: Height.card)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.18))
        }
    }

    private var head: some View {
        HStack(alignment: .firstTextBaseline, spacing: PopoverLayout.rowSpacing) {
            Text(model.name)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: PopoverLayout.rowSpacing)
            Text(Int(model.actualRPM.rounded()).formatted())
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
            Text("rpm")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(height: Height.cardHead)
    }

    /// The scale at both ends and the bar between them: one glance says how
    /// much of this fan is in use. Pure SwiftUI shapes, so the capture path
    /// draws it like everything else that carries a number.
    private var gauge: some View {
        HStack(spacing: 6) {
            Text(Int(model.minimumRPM.rounded()).formatted())
            SegmentedBar(
                segments: [.init(id: "speed", value: model.loadFraction, style: barTint)],
                total: 1,
                height: 6
            )
            Text(Int(model.maximumRPM.rounded()).formatted())
        }
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(.tertiary)
        .frame(height: Height.cardGauge)
    }

    private var barTint: Color {
        model.isForced ? .accentColor : .secondary.opacity(0.6)
    }

    // MARK: - The mode

    private var segments: some View {
        FanModeSegments(selection: storedMode.kind, select: select)
            .frame(height: Height.cardSegments)
            .disabled(!model.isControllable)
            .opacity(model.isControllable ? 1 : 0.5)
    }

    private func select(_ kind: FanModeKind) {
        guard let fan = model.fan else { return }
        apply(FanModeDefaults.mode(of: kind, for: fan, store: store, current: storedMode))
    }

    @ViewBuilder
    private var editor: some View {
        Group {
            switch storedMode {
            case .auto:
                Text("The firmware decides, the way a Mac behaves out of the box.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .constant(let rpm):
                constantEditor(rpm: rpm)
            case .curve(let key, let start, let maxTemp):
                curveEditor(
                    curve: CurveSettings(sensorKey: key, startTemp: start, maxTemp: maxTemp)
                )
            }
        }
        .frame(height: Height.cardDetail, alignment: .center)
        .disabled(!model.isControllable)
    }

    /// The setpoint on a slider with the number beside it, and under both the
    /// read-back: a fan whose firmware refused the target says so here, on the
    /// line the eye is already on.
    private func constantEditor(rpm: Int) -> some View {
        VStack(alignment: .leading, spacing: PopoverLayout.rowSpacing) {
            HStack(spacing: PopoverLayout.rowSpacing) {
                Slider(value: constantBinding(rpm: rpm), in: rpmRange)
                    .controlSize(.small)
                Text(Fmt.rpm(Double(rpm)))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 76, alignment: .trailing)
            }
            .frame(height: Height.cardDetailRow)

            Text(model.hardwareLine)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(height: Height.cardDetailRow, alignment: .center)
        }
    }

    /// The sensor and the two ends of the ramp, the same three values the
    /// curve editor in the window writes. "Edit curve…" is for the picture of
    /// it: the plot needs more width than a menu bar panel has.
    private func curveEditor(curve: CurveSettings) -> some View {
        VStack(spacing: PopoverLayout.rowSpacing) {
            HStack(spacing: 6) {
                Text("Sensor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Sensor", selection: sensorBinding(curve)) {
                    ForEach(sensorChoices(curve), id: \.key) { choice in
                        Text(choice.title).tag(choice.key)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 150)
                Spacer(minLength: 0)
                // Not `.link`: that style draws as an empty box under
                // `ImageRenderer`, which is how the capture path sees this.
                Button { open(.fans) } label: {
                    Text("Edit curve…")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Open the Fans tab, where the ramp is drawn")
            }
            .frame(height: Height.cardDetailRow)

            HStack(spacing: PopoverLayout.rowSpacing) {
                temperatureStepper(
                    caption: "Start at",
                    celsius: curve.startTemp,
                    range: 20...max(21, curve.maxTemp - 1),
                    set: { apply(.curve(sensorKey: curve.sensorKey, startTemp: $0, maxTemp: curve.maxTemp)) }
                )
                temperatureStepper(
                    caption: "Max at",
                    celsius: curve.maxTemp,
                    range: min(curve.startTemp + 1, 104)...105,
                    set: { apply(.curve(sensorKey: curve.sensorKey, startTemp: curve.startTemp, maxTemp: $0)) }
                )
                Spacer(minLength: 0)
            }
            .frame(height: Height.cardDetailRow)
        }
    }

    private func temperatureStepper(
        caption: String,
        celsius: Double,
        range: ClosedRange<Double>,
        set: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Fmt.temperature(celsius, unit: settings.temperatureUnit))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
            Stepper(
                caption,
                value: Binding(
                    get: { celsius },
                    set: { set($0.rounded().clamped(to: range)) }
                ),
                in: range,
                step: 1
            )
            .labelsHidden()
            .controlSize(.small)
        }
    }

    // MARK: - Reading and writing the mode

    private var storedMode: FanMode {
        guard let fan = model.fan else {
            return model.isForced ? .constant(rpm: Int(model.actualRPM.rounded())) : .auto
        }
        return fans.storedMode(forFan: fan.index)
    }

    private var rpmRange: ClosedRange<Double> {
        model.minimumRPM...max(model.maximumRPM, model.minimumRPM + 1)
    }

    private func constantBinding(rpm: Int) -> Binding<Double> {
        Binding(
            get: { Double(rpm).clamped(to: rpmRange) },
            set: { value in
                // Steps of 50, the way the Fans tab writes it: finer than any
                // fan resolves, and it keeps a drag from sending a setpoint
                // for every pixel. `FanStore.setMode` debounces the rest.
                let stepped = (value / 50).rounded() * 50
                apply(.constant(rpm: Int(stepped.clamped(to: rpmRange).rounded())))
            }
        )
    }

    private func sensorBinding(_ curve: CurveSettings) -> Binding<String> {
        Binding(
            get: { curve.sensorKey },
            set: { apply(.curve(sensorKey: $0, startTemp: curve.startTemp, maxTemp: curve.maxTemp)) }
        )
    }

    /// The key first: the picker is the narrowest control of the card, and a
    /// title that truncates must still say which sensor the curve follows.
    private func sensorChoices(_ curve: CurveSettings) -> [(key: String, title: String)] {
        var choices = store.history.orderedSensors.map {
            (key: $0.key.stringValue, title: "\($0.key.stringValue) · \($0.label)")
        }
        if !choices.contains(where: { $0.key == curve.sensorKey }) {
            choices.insert((key: curve.sensorKey, title: curve.sensorKey), at: 0)
        }
        return choices
    }

    private func apply(_ mode: FanMode) {
        guard let fan = model.fan else { return }
        Task { await fans.setMode(mode, forFan: fan.index) }
    }
}

/// Auto | Constant | Sensor-based, drawn by hand.
///
/// Not `Picker(.segmented)`: that is an `NSSegmentedControl`, and
/// `ImageRenderer` draws an empty box for an AppKit-backed view, which is the
/// path every popover screenshot goes through. The geometry is the section
/// picker's, so the two segmented controls of the panel are one shape.
private struct FanModeSegments: View {
    let selection: FanModeKind
    let select: (FanModeKind) -> Void

    var body: some View {
        HStack(spacing: PopoverLayout.segmentSpacing) {
            ForEach(FanModeKind.allCases) { kind in
                segment(kind)
            }
        }
        .padding(PopoverLayout.pickerPadding)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.28))
        }
    }

    private func segment(_ kind: FanModeKind) -> some View {
        let selected = kind == selection
        return Button { select(kind) } label: {
            Text(kind.title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: PopoverLayout.FansHeight.cardSegments - PopoverLayout.pickerPadding * 2)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(selected ? 1 : 0))
                        .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 0.5)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The modes a fan gets the first time

/// What "Constant" and "Sensor-based" mean before the user has moved anything.
///
/// One place, so the popover and the Fans tab of the window start a fan from
/// the same setpoint and the same ramp.
enum FanModeDefaults {
    /// Half way between the limits, on a 50 rpm step.
    static func constantRPM(for fan: FanStatus) -> Int {
        Int(((fan.minimumRPM + fan.maximumRPM) / 2 / 50).rounded() * 50)
    }

    /// The hottest CPU die the app can see, and the ramp the governor was
    /// written against.
    @MainActor
    static func curve(for store: MetricsStore) -> CurveSettings {
        CurveSettings(sensorKey: sensorKey(for: store), startTemp: 45, maxTemp: 85)
    }

    @MainActor
    static func sensorKey(for store: MetricsStore) -> String {
        store.hottestCPU?.key.stringValue
            ?? store.history.orderedSensors.first?.key.stringValue
            ?? "Tp01"
    }

    /// The mode one segment stands for, keeping whatever the user already
    /// chose for it: switching to Auto and back must not forget the setpoint.
    @MainActor
    static func mode(
        of kind: FanModeKind,
        for fan: FanStatus,
        store: MetricsStore,
        current: FanMode
    ) -> FanMode {
        switch kind {
        case .auto:
            return .auto
        case .constant:
            if case .constant = current { return current }
            return .constant(rpm: constantRPM(for: fan))
        case .curve:
            if case .curve = current { return current }
            let curve = FanModeDefaults.curve(for: store)
            return .curve(
                sensorKey: curve.sensorKey,
                startTemp: curve.startTemp,
                maxTemp: curve.maxTemp
            )
        }
    }
}

// MARK: - A fan named the way both sources of truth allow

/// One fan, for the places that show a line rather than a card: the Tools
/// section's summary, and the Fans section's own notice.
struct FanRow {
    let index: Int
    let name: String
    let rpm: String
    let mode: String

    static func title(of mode: FanMode) -> String {
        switch mode {
        case .auto: "Auto"
        case .constant: "Constant"
        case .curve: "Sensor-based"
        }
    }

    @MainActor
    static func rows(fans: FanStore, smcFans: [FanReading]) -> [FanRow] {
        if fans.isAvailable, !fans.fans.isEmpty {
            return fans.fans.map { fan in
                FanRow(
                    index: fan.index,
                    name: FanNaming.name(index: fan.index, of: fans.fans.count),
                    rpm: Fmt.rpm(fan.actualRPM),
                    mode: title(of: fan.mode)
                )
            }
        }
        return smcFans.map { fan in
            FanRow(
                index: fan.index,
                name: FanNaming.name(index: fan.index, of: smcFans.count),
                rpm: Fmt.rpm(fan.actual),
                mode: fan.mode == .forced ? "Constant" : "Auto"
            )
        }
    }
}
