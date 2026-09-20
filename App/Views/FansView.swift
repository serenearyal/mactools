import Charts
import FanControl
import SMCKit
import SwiftUI

/// The Fans tab: the fan cards on the left, the live sensors on the right.
struct FansView: View {
    let store: MetricsStore
    let fans: FanStore
    let settings: AppSettings
    let helper: HelperController
    /// Where the "not installed" banner sends the user.
    let showSettings: () -> Void

    var body: some View {
        FansContent(
            store: store,
            fans: fans,
            settings: settings,
            helper: helper,
            showSettings: showSettings,
            scrolls: true
        )
        .task {
            await helper.refresh()
            fans.startPolling()
        }
        .onDisappear { fans.stopPolling() }
    }
}

/// The content without the tab's own lifetime, so the capture path can render
/// it outside a scroll view, which `ImageRenderer` cannot draw.
struct FansContent: View {
    let store: MetricsStore
    let fans: FanStore
    let settings: AppSettings
    let helper: HelperController
    let showSettings: () -> Void
    var scrolls = true

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                banner
                if scrolls {
                    ScrollView { cards.padding(Layout.cardSpacing) }
                } else {
                    cards.padding(Layout.cardSpacing)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()
            SensorColumn(store: store, settings: settings, scrolls: scrolls)
                .frame(width: 236)
        }
    }

    @ViewBuilder
    private var cards: some View {
        VStack(spacing: Layout.cardSpacing) {
            if fans.fans.isEmpty {
                Card(title: "Fans", symbolName: "fan", fills: false) {
                    Text(
                        fans.isAvailable
                            ? "The helper reports no fan on this Mac."
                            : "Fan speeds and control need the privileged helper."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    LocalFanSummary(snapshot: store.snapshot)
                }
            } else {
                ForEach(fans.fans) { fan in
                    FanCard(fan: fan, store: store, fans: fans, settings: settings)
                }
            }
        }
    }

    // MARK: - Banner

    @ViewBuilder
    private var banner: some View {
        VStack(spacing: 0) {
            if case .running = helper.state {
                EmptyView()
            } else {
                BannerRow(
                    symbolName: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: helperTitle,
                    detail: "Fan control needs the helper that runs as root.",
                    actionTitle: "Open Settings",
                    action: showSettings
                )
            }
            if fans.interlockEngaged {
                BannerRow(
                    symbolName: "thermometer.sun.fill",
                    tint: .red,
                    title: "Thermal interlock: every fan is on Auto",
                    detail: interlockDetail,
                    actionTitle: nil,
                    action: nil
                )
            }
            ForEach(fans.faults, id: \.fanIndex) { fault in
                BannerRow(
                    symbolName: "exclamationmark.octagon.fill",
                    tint: .red,
                    title: "Fan \(fault.fanIndex + 1)",
                    detail: fault.reason,
                    actionTitle: nil,
                    action: nil
                )
            }
            if let failure = fans.failure, !fans.isAvailable, case .running = helper.state {
                BannerRow(
                    symbolName: "exclamationmark.octagon.fill",
                    tint: .red,
                    title: "The helper did not answer",
                    detail: failure,
                    actionTitle: nil,
                    action: nil
                )
            }
            HStack(spacing: Layout.gutter) {
                Text(fans.fans.isEmpty ? "No fan" : "\(fans.fans.count) fans")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: Layout.gutter)
                if fans.isBusy {
                    ProgressView().controlSize(.small)
                }
                Button("All fans to Auto") {
                    Task { await fans.restoreAllAuto() }
                }
                .disabled(fans.fans.isEmpty || fans.isBusy)
                .help("Hands every fan back to the firmware")
            }
            .padding(.horizontal, Layout.cardPadding)
            .padding(.vertical, Layout.gutter * 1.5)
            Divider()
        }
    }

    private var helperTitle: String {
        switch helper.state {
        case .requiresApproval: "The helper is waiting for approval in System Settings"
        case .outdated: "The installed helper is older than this app"
        case .failed(let message): "The helper is not usable: \(message)"
        default: "The privileged helper is not installed"
        }
    }

    private var interlockDetail: String {
        let hottest = fans.hottestDie.map {
            Fmt.temperature($0, unit: settings.temperatureUnit, digits: 1)
        }
        return "A processor die reached \(hottest ?? "100 °C"). "
            + "The fans stay with the firmware until it is below "
            + Fmt.temperature(Fans.thermalReleaseCelsius, unit: settings.temperatureUnit)
            + "."
    }
}

/// A `ScrollView` in the app, plain content in the capture path.
/// `ImageRenderer` draws nothing for an AppKit scroll view.
private struct ScrollViewIfNeeded<Content: View>: View {
    let scrolls: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if scrolls {
            ScrollView { content }
        } else {
            content
            Spacer(minLength: 0)
        }
    }
}

private struct BannerRow: View {
    let symbolName: String
    let tint: Color
    let title: String
    let detail: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.gutter) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Layout.gutter)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .padding(.horizontal, Layout.cardPadding)
        .padding(.vertical, Layout.gutter * 1.25)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
    }
}

/// What the app can show without the helper: the unprivileged SMC read that
/// already feeds the Overview and the menu bar.
private struct LocalFanSummary: View {
    let snapshot: MetricsSnapshot

    var body: some View {
        if !snapshot.fans.isEmpty {
            Divider()
            Text("Read directly, without the helper")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(snapshot.fans, id: \.index) { fan in
                StatRow(
                    label: FanNaming.name(index: fan.index, of: snapshot.fans.count),
                    value: Fmt.rpm(fan.actual)
                )
            }
        }
    }
}

// MARK: - One fan

private struct FanCard: View {
    let fan: FanStatus
    let store: MetricsStore
    let fans: FanStore
    let settings: AppSettings

    var body: some View {
        Card(title: fan.name, symbolName: "fan", fills: false) {
            speedRow
            SegmentedBar(
                segments: [.init(id: "speed", value: fan.loadFraction, style: barStyle)],
                total: 1,
                height: 8
            )
            HStack {
                Text(Fmt.rpm(fan.minimumRPM))
                Spacer(minLength: Layout.gutter)
                Text(Fmt.rpm(fan.maximumRPM))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)

            Divider()

            Picker("Control", selection: kindBinding) {
                ForEach(FanModeKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch storedMode.kind {
            case .auto:
                Text("The firmware decides, the way a Mac behaves out of the box.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .constant:
                ConstantEditor(fan: fan, fans: fans, rpm: storedConstantRPM)
            case .curve:
                CurveEditor(fan: fan, store: store, fans: fans, settings: settings, curve: storedCurve)
            }
        }
    }

    private var speedRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.gutter) {
            Text(Int(fan.actualRPM.rounded()).formatted())
                .font(.system(size: 28, weight: .semibold))
                .monospacedDigit()
            Text("rpm")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(storedMode.summary)
                    .font(.callout.weight(.medium))
                Text(hardwareLine)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hardwareLine: String {
        switch fan.hardwareMode {
        case .forced: "forced, target \(Fmt.rpm(fan.targetRPM))"
        case .auto: "firmware control"
        case .unknown: "mode unknown"
        }
    }

    private var barStyle: Color {
        fan.hardwareMode == .forced ? .accentColor : .secondary.opacity(0.6)
    }

    // MARK: - The mode being edited

    private var storedMode: FanMode { fans.storedMode(forFan: fan.index) }

    private var storedConstantRPM: Int {
        if case .constant(let rpm) = storedMode { return rpm }
        return Int(((fan.minimumRPM + fan.maximumRPM) / 2 / 50).rounded() * 50)
    }

    private var storedCurve: CurveSettings {
        if case .curve(let key, let start, let maxTemp) = storedMode {
            return CurveSettings(sensorKey: key, startTemp: start, maxTemp: maxTemp)
        }
        return CurveSettings(sensorKey: defaultSensorKey, startTemp: 45, maxTemp: 85)
    }

    private var defaultSensorKey: String {
        store.snapshot.hottestCPU?.key.stringValue
            ?? store.history.orderedSensors.first?.key.stringValue
            ?? "Tp01"
    }

    private var kindBinding: Binding<FanModeKind> {
        Binding(
            get: { storedMode.kind },
            set: { kind in
                let mode: FanMode = switch kind {
                case .auto: .auto
                case .constant: .constant(rpm: storedConstantRPM)
                case .curve:
                    .curve(
                        sensorKey: storedCurve.sensorKey,
                        startTemp: storedCurve.startTemp,
                        maxTemp: storedCurve.maxTemp
                    )
                }
                Task { await fans.setMode(mode, forFan: fan.index) }
            }
        )
    }
}

struct CurveSettings: Equatable {
    var sensorKey: String
    var startTemp: Double
    var maxTemp: Double
}

// MARK: - Constant

private struct ConstantEditor: View {
    let fan: FanStatus
    let fans: FanStore
    let rpm: Int

    /// Every control moves the setpoint in steps of 50.
    private static let step: Double = 50

    var body: some View {
        HStack(spacing: Layout.gutter * 1.5) {
            Slider(value: binding, in: fan.minimumRPM...max(fan.maximumRPM, fan.minimumRPM + 1))
            TextField(
                "rpm",
                value: binding,
                format: .number.precision(.fractionLength(0))
            )
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 72)
            Stepper("Speed", value: binding, in: fan.minimumRPM...fan.maximumRPM, step: ConstantEditor.step)
                .labelsHidden()
        }
    }

    private var binding: Binding<Double> {
        Binding(
            get: { Double(rpm) },
            set: { value in
                // Steps of 50: finer than any fan resolves, and it keeps the
                // slider from writing a new setpoint for every pixel.
                let stepped = (value / ConstantEditor.step).rounded() * ConstantEditor.step
                let clamped = min(max(stepped, fan.minimumRPM), fan.maximumRPM)
                Task { await fans.setMode(.constant(rpm: Int(clamped.rounded())), forFan: fan.index) }
            }
        )
    }
}

// MARK: - Curve

private struct CurveEditor: View {
    let fan: FanStatus
    let store: MetricsStore
    let fans: FanStore
    let settings: AppSettings
    let curve: CurveSettings

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Layout.gutter * 1.5, verticalSpacing: Layout.gutter) {
            GridRow {
                Text("Sensor")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.leading)
                Picker("Sensor", selection: sensorBinding) {
                    ForEach(sensorChoices, id: \.key) { choice in
                        Text(choice.title).tag(choice.key)
                    }
                }
                .labelsHidden()
            }
            GridRow {
                Text("Start")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                temperatureRow(
                    value: startBinding,
                    range: 20...(curve.maxTemp - 1),
                    caption: "fan at minimum below this"
                )
            }
            GridRow {
                Text("Full speed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                temperatureRow(
                    value: maxBinding,
                    range: (curve.startTemp + 1)...105,
                    caption: "fan at maximum above this"
                )
            }
        }

        CurvePlot(fan: fan, curve: curve, temperature: currentTemperature, settings: settings)
            .frame(height: 132)
    }

    private func temperatureRow(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        caption: String
    ) -> some View {
        HStack(spacing: Layout.gutter) {
            // No `step:`: a stepped slider draws a row of tick marks under the
            // track, and whole degrees come from the bindings instead.
            Slider(value: value, in: range.lowerBound < range.upperBound ? range : range.lowerBound...(range.lowerBound + 1))
            Text(Fmt.temperature(value.wrappedValue, unit: settings.temperatureUnit))
                .font(.callout)
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
        }
    }

    /// The live value of the chosen sensor: the fan's own reading from the
    /// helper first, the app's sampler as a fallback.
    private var currentTemperature: Double? {
        if let celsius = fan.sensorCelsius { return celsius }
        guard let key = SMCFourCC(code: curve.sensorKey) else { return nil }
        return store.snapshot.temperature(forKey: key)?.celsius
    }

    private var sensorChoices: [(key: String, title: String)] {
        var choices = store.history.orderedSensors.map {
            (key: $0.key.stringValue, title: "\($0.label) (\($0.key.stringValue))")
        }
        if !choices.contains(where: { $0.key == curve.sensorKey }) {
            choices.insert((key: curve.sensorKey, title: curve.sensorKey), at: 0)
        }
        return choices
    }

    private func apply(_ settings: CurveSettings) {
        Task {
            await fans.setMode(
                .curve(
                    sensorKey: settings.sensorKey,
                    startTemp: settings.startTemp,
                    maxTemp: settings.maxTemp
                ),
                forFan: fan.index
            )
        }
    }

    private var sensorBinding: Binding<String> {
        Binding(
            get: { curve.sensorKey },
            set: { apply(CurveSettings(sensorKey: $0, startTemp: curve.startTemp, maxTemp: curve.maxTemp)) }
        )
    }

    private var startBinding: Binding<Double> {
        Binding(
            get: { curve.startTemp },
            set: {
                apply(
                    CurveSettings(
                        sensorKey: curve.sensorKey,
                        startTemp: min($0.rounded(), curve.maxTemp - 1),
                        maxTemp: curve.maxTemp
                    )
                )
            }
        )
    }

    private var maxBinding: Binding<Double> {
        Binding(
            get: { curve.maxTemp },
            set: {
                apply(
                    CurveSettings(
                        sensorKey: curve.sensorKey,
                        startTemp: curve.startTemp,
                        maxTemp: max($0.rounded(), curve.startTemp + 1)
                    )
                )
            }
        )
    }
}

/// The ramp, with the sensor where it is now and the speed that follows.
private struct CurvePlot: View {
    /// Both axes count whole degrees and whole rpm. Named because the
    /// shorthand is ambiguous inside an `AxisValueLabel`.
    static let wholeNumber = FloatingPointFormatStyle<Double>.number
        .precision(.fractionLength(0))

    let fan: FanStatus
    let curve: CurveSettings
    let temperature: Double?
    let settings: AppSettings

    var body: some View {
        Chart {
            ForEach(points, id: \.temp) { point in
                LineMark(
                    x: .value("Temperature", point.temp),
                    y: .value("Speed", point.rpm)
                )
                .lineStyle(StrokeStyle(lineWidth: 2))
                .foregroundStyle(Color.accentColor)
            }
            if let temperature {
                RuleMark(x: .value("Now", clampedTemperature(temperature)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Color.secondary)
                if let rpm = resultingRPM {
                    PointMark(
                        x: .value("Now", clampedTemperature(temperature)),
                        y: .value("Speed", rpm)
                    )
                    .symbolSize(70)
                    .foregroundStyle(MetricColor.temperature(temperature))
                    .annotation(position: .topLeading, spacing: 4) {
                        Text("\(Fmt.temperature(temperature, unit: settings.temperatureUnit)) · \(Fmt.rpm(rpm))")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: fan.minimumRPM...max(fan.maximumRPM, fan.minimumRPM + 1))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) {
                AxisGridLine()
                AxisValueLabel(format: CurvePlot.wholeNumber)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [fan.minimumRPM, fan.maximumRPM]) {
                AxisGridLine()
                AxisValueLabel(format: CurvePlot.wholeNumber)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartLegend(.hidden)
    }

    private var domain: ClosedRange<Double> {
        let lower = min(curve.startTemp - 10, temperature.map { $0 - 5 } ?? curve.startTemp - 10)
        let upper = max(curve.maxTemp + 10, temperature.map { $0 + 5 } ?? curve.maxTemp + 10)
        return lower...upper
    }

    private func clampedTemperature(_ value: Double) -> Double {
        min(max(value, domain.lowerBound), domain.upperBound)
    }

    private var resultingRPM: Double? {
        guard let temperature else { return nil }
        return FanCurve.targetRPM(
            temp: temperature,
            min: fan.minimumRPM,
            max: fan.maximumRPM,
            start: curve.startTemp,
            maxTemp: curve.maxTemp
        )
    }

    /// The ramp drawn as the governor would compute it, so the picture cannot
    /// drift away from the code that moves the fan.
    private var points: [(temp: Double, rpm: Double)] {
        stride(from: domain.lowerBound, through: domain.upperBound, by: 0.5).compactMap { temp in
            FanCurve.targetRPM(
                temp: temp,
                min: fan.minimumRPM,
                max: fan.maximumRPM,
                start: curve.startTemp,
                maxTemp: curve.maxTemp
            )
            .map { (temp: temp, rpm: $0) }
        }
    }
}

// MARK: - Sensors on the right

private struct SensorColumn: View {
    let store: MetricsStore
    let settings: AppSettings
    var scrolls = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Temperature sensors")
                .font(.headline)
                .padding(.horizontal, Layout.cardPadding)
                .padding(.vertical, Layout.gutter * 1.5)
            Divider()
            ScrollViewIfNeeded(scrolls: scrolls) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.history.orderedSensors) { trace in
                        HStack(spacing: Layout.gutter) {
                            Text(trace.label)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: Layout.gutter)
                            Text(Fmt.temperature(trace.current, unit: settings.temperatureUnit))
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(MetricColor.temperature(trace.current))
                        }
                    }
                    if store.history.orderedSensors.isEmpty {
                        Text("No sensor is answering.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Layout.cardPadding)
                .padding(.vertical, Layout.gutter * 1.5)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
