import AwakeKit
import CoreGraphics
import FanControl
import Foundation
import Observation
import WindowKit

enum MenuBarLabelStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case twoLine
    case oneLine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .twoLine: "Compact, two lines"
        case .oneLine: "One line"
        }
    }
}

/// How much room the status item takes in the menu bar.
///
/// A notched Mac hides everything that does not fit behind the notch, without
/// a word, and a MacTools label with three metrics is wide. Icon only shrinks the
/// item to about 36 pt, against the 95 pt of two two-line metrics.
///
/// Both numbers are measured, not guessed: `--capture` writes the rendered
/// label width and the width of the status item itself, and the icon alone
/// renders 20 pt with 16 pt of padding from the system. The README quotes the
/// same two numbers.
enum MenuBarContent: String, CaseIterable, Codable, Identifiable, Sendable {
    case metrics
    case iconOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .metrics: "Metrics"
        case .iconOnly: "Icon only"
        }
    }
}

enum TemperatureUnit: String, CaseIterable, Codable, Identifiable, Sendable {
    case celsius
    case fahrenheit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .celsius: "Celsius"
        case .fahrenheit: "Fahrenheit"
        }
    }

    var suffix: String {
        switch self {
        case .celsius: "°C"
        case .fahrenheit: "°F"
        }
    }

    func convert(_ celsius: Double) -> Double {
        switch self {
        case .celsius: celsius
        case .fahrenheit: celsius * 9 / 5 + 32
        }
    }
}

enum RefreshInterval: Int, CaseIterable, Codable, Identifiable, Sendable {
    case oneSecond = 1
    case twoSeconds = 2
    case fiveSeconds = 5

    var id: Int { rawValue }
    var seconds: Double { Double(rawValue) }
    var title: String { "\(rawValue) s" }
}

/// Everything the user can change, in one Codable value.
struct SettingsData: Codable, Equatable, Sendable {
    var menuBarMetrics: [MenuBarMetric] = [.cpuUsage, .cpuTemperature]
    var labelStyle: MenuBarLabelStyle = .twoLine
    var showMenuBarIcon: Bool = true
    /// "Tint hot temperatures": amber at 70 C, orange at 80, red at 90. On by
    /// default - a temperature in the menu bar is there to be noticed.
    var tintsHotTemperatures: Bool = true
    /// "Spin the fan icon": the glyph turns with the fastest fan. On by
    /// default, and it costs nothing at all while the fans are at 0 rpm.
    var spinsFanIcon: Bool = true
    /// Metrics by default; icon only is the way out of a full menu bar.
    var menuBarContent: MenuBarContent = .metrics
    var refreshInterval: RefreshInterval = .twoSeconds
    var temperatureUnit: TemperatureUnit = .celsius
    /// FourCC of the sensor behind `MenuBarMetric.sensorTemperature`. The
    /// keys are case sensitive: "Tg05" is the first GPU die.
    var sensorKey: String = "Tg05"
    var showUnlabelledSensors: Bool = false
    /// The hard timeout of the keyboard lock, in seconds.
    var lockTimeoutSeconds: Int = LockTimeout.default
    /// What each fan should do, by fan index as a string. The helper forgets
    /// every mode as soon as the last client leaves, so this is the only
    /// memory the choice has.
    var fanModes: [String: FanMode] = [:]
    /// False until the user closes the setup card on the Overview. The
    /// Settings tab brings it back.
    var setupChecklistDismissed: Bool = false
    /// The popover section the user last looked at.
    var popoverSection: PopoverSection = .dashboard
    /// `.regular` instead of `.accessory`: a Dock icon, and the way back when
    /// the notch hides the status item.
    var showDockIcon: Bool = false
    /// True once the "MacTools keeps running here" tip has been shown. It appears
    /// the first time the window is closed and never again.
    var menuBarTipShown: Bool = false
    /// Copy for AI: whether the paste opens with the paragraph that tells the
    /// chat what to do with the table. On by default - the table alone is the
    /// unusual case, and it is one click away.
    var reportIncludesQuestion: Bool = true
    /// Keep Awake. The state itself is deliberately not here: MacTools never comes
    /// back holding this Mac awake after a relaunch.
    var keepAwakeDuration: KeepAwakeDuration = .indefinite
    var keepAwakeDisplay: Bool = false
    /// "Stay awake with the lid closed". Off until the user asks for it: it
    /// needs the privileged helper and it changes how the whole Mac behaves.
    var keepAwakeLidClose: Bool = false
    var keepAwakeBatteryGuard: Bool = true
    var keepAwakeBatteryThreshold: Int = 20
    /// The window manager: the shortcut set, the gap and its two switches.
    /// One nested value, so the settings file gains one key.
    var windows = WindowSettingsData()

    init() {}

    /// Every key is optional, so a settings file written by an older build
    /// keeps the choices it does hold instead of resetting all of them.
    ///
    /// And every key is decoded on its own: one value this build does not
    /// know, a metric or a style a newer build added, costs that one key and
    /// nothing else. A throw here would make `load` fall back to the defaults,
    /// and the next write would put them over the fan curves and the
    /// shortcuts the file still held.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SettingsData()
        func value<T: Decodable>(_ key: CodingKeys, or fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        // A list keeps the entries it knows rather than dropping them all.
        menuBarMetrics = (try? container.decodeIfPresent([String].self, forKey: .menuBarMetrics))?
            .compactMap(MenuBarMetric.init(rawValue:))
            ?? fallback.menuBarMetrics
        labelStyle = value(.labelStyle, or: fallback.labelStyle)
        showMenuBarIcon = value(.showMenuBarIcon, or: fallback.showMenuBarIcon)
        tintsHotTemperatures = value(.tintsHotTemperatures, or: fallback.tintsHotTemperatures)
        spinsFanIcon = value(.spinsFanIcon, or: fallback.spinsFanIcon)
        menuBarContent = value(.menuBarContent, or: fallback.menuBarContent)
        refreshInterval = value(.refreshInterval, or: fallback.refreshInterval)
        temperatureUnit = value(.temperatureUnit, or: fallback.temperatureUnit)
        sensorKey = value(.sensorKey, or: fallback.sensorKey)
        showUnlabelledSensors = value(.showUnlabelledSensors, or: fallback.showUnlabelledSensors)
        lockTimeoutSeconds = LockTimeout.clamp(value(.lockTimeoutSeconds, or: fallback.lockTimeoutSeconds))
        // Per fan, for the same reason as the metrics: a mode this build
        // cannot read is that fan back on Auto, not every curve gone.
        fanModes = (try? container.decodeIfPresent([String: Lenient<FanMode>].self, forKey: .fanModes))?
            .compactMapValues(\.value)
            ?? fallback.fanModes
        setupChecklistDismissed = value(.setupChecklistDismissed, or: fallback.setupChecklistDismissed)
        popoverSection = value(.popoverSection, or: fallback.popoverSection)
        showDockIcon = value(.showDockIcon, or: fallback.showDockIcon)
        menuBarTipShown = value(.menuBarTipShown, or: fallback.menuBarTipShown)
        reportIncludesQuestion = value(.reportIncludesQuestion, or: fallback.reportIncludesQuestion)
        keepAwakeDuration = value(.keepAwakeDuration, or: fallback.keepAwakeDuration)
        keepAwakeDisplay = value(.keepAwakeDisplay, or: fallback.keepAwakeDisplay)
        keepAwakeLidClose = value(.keepAwakeLidClose, or: fallback.keepAwakeLidClose)
        keepAwakeBatteryGuard = value(.keepAwakeBatteryGuard, or: fallback.keepAwakeBatteryGuard)
        keepAwakeBatteryThreshold = value(.keepAwakeBatteryThreshold, or: fallback.keepAwakeBatteryThreshold)
            .clamped(to: KeepAwakeOptions.thresholdRange)
        windows = value(.windows, or: fallback.windows)
    }
}

/// One entry of a stored collection that decodes to nil instead of throwing,
/// so a single value this build does not know cannot take the rest with it.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// The persisted settings.
///
/// Storage is one JSON blob in `UserDefaults`: a single atomic write, no file
/// handling, and a missing or broken value falls back to the defaults. A
/// separate file in Application Support would buy nothing here.
@MainActor
@Observable
final class AppSettings {
    static let defaultsKey = SettingsMigration.settingsKey

    private var data: SettingsData
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Before the first read, and only ever once: the choices of the build
        // that was called Vent live in a domain of their own.
        SettingsMigration.runIfNeeded(into: defaults)
        data = AppSettings.load(from: defaults)
    }

    var menuBarMetrics: [MenuBarMetric] {
        get { data.menuBarMetrics }
        set { data.menuBarMetrics = newValue.uniqued(); persist() }
    }

    var labelStyle: MenuBarLabelStyle {
        get { data.labelStyle }
        set { data.labelStyle = newValue; persist() }
    }

    var showMenuBarIcon: Bool {
        get { data.showMenuBarIcon }
        set { data.showMenuBarIcon = newValue; persist() }
    }

    var menuBarContent: MenuBarContent {
        get { data.menuBarContent }
        set { data.menuBarContent = newValue; persist() }
    }

    var tintsHotTemperatures: Bool {
        get { data.tintsHotTemperatures }
        set { data.tintsHotTemperatures = newValue; persist() }
    }

    var spinsFanIcon: Bool {
        get { data.spinsFanIcon }
        set { data.spinsFanIcon = newValue; persist() }
    }

    var setupChecklistDismissed: Bool {
        get { data.setupChecklistDismissed }
        set { data.setupChecklistDismissed = newValue; persist() }
    }

    var popoverSection: PopoverSection {
        get { data.popoverSection }
        set { data.popoverSection = newValue; persist() }
    }

    var showDockIcon: Bool {
        get { data.showDockIcon }
        set { data.showDockIcon = newValue; persist() }
    }

    var menuBarTipShown: Bool {
        get { data.menuBarTipShown }
        set { data.menuBarTipShown = newValue; persist() }
    }

    var reportIncludesQuestion: Bool {
        get { data.reportIncludesQuestion }
        set { data.reportIncludesQuestion = newValue; persist() }
    }

    /// The four Keep Awake settings as the one value the controller works in.
    /// The threshold is clamped on the way out as well as in: a file written by
    /// hand must not put the stepper out of its own range.
    var keepAwakeOptions: KeepAwakeOptions {
        get {
            KeepAwakeOptions(
                duration: data.keepAwakeDuration,
                keepDisplayOn: data.keepAwakeDisplay,
                lidClose: data.keepAwakeLidClose,
                batteryGuardEnabled: data.keepAwakeBatteryGuard,
                batteryThreshold: data.keepAwakeBatteryThreshold
                    .clamped(to: KeepAwakeOptions.thresholdRange)
            )
        }
        set {
            data.keepAwakeDuration = newValue.duration
            data.keepAwakeDisplay = newValue.keepDisplayOn
            data.keepAwakeLidClose = newValue.lidClose
            data.keepAwakeBatteryGuard = newValue.batteryGuardEnabled
            data.keepAwakeBatteryThreshold = newValue.batteryThreshold
                .clamped(to: KeepAwakeOptions.thresholdRange)
            persist()
        }
    }

    /// The window manager's own settings. One accessor for the whole value:
    /// `settings.windows.gap = 12` reads it, changes it and writes it back.
    var windows: WindowSettingsData {
        get { data.windows }
        set {
            var clamped = newValue
            clamped.gap = Double(WindowLayout.clampGap(CGFloat(newValue.gap)))
            guard data.windows != clamped else { return }
            data.windows = clamped
            persist()
        }
    }

    var refreshInterval: RefreshInterval {
        get { data.refreshInterval }
        set { data.refreshInterval = newValue; persist() }
    }

    var temperatureUnit: TemperatureUnit {
        get { data.temperatureUnit }
        set { data.temperatureUnit = newValue; persist() }
    }

    var sensorKey: String {
        get { data.sensorKey }
        set { data.sensorKey = newValue; persist() }
    }

    var showUnlabelledSensors: Bool {
        get { data.showUnlabelledSensors }
        set { data.showUnlabelledSensors = newValue; persist() }
    }

    /// Clamped on the way in: a stored value out of range would hold the
    /// keyboard for longer than the UI ever offers.
    var lockTimeoutSeconds: Int {
        get { LockTimeout.clamp(data.lockTimeoutSeconds) }
        set { data.lockTimeoutSeconds = LockTimeout.clamp(newValue); persist() }
    }

    /// The mode the user last chose for one fan, Auto by default.
    func fanMode(forFan index: Int) -> FanMode {
        data.fanModes[String(index)] ?? .auto
    }

    /// Auto is stored as the absence of an entry, so the file stays empty for
    /// the ordinary case.
    func setFanMode(_ mode: FanMode, forFan index: Int) {
        guard fanMode(forFan: index) != mode else { return }
        if mode.isAuto {
            data.fanModes.removeValue(forKey: String(index))
        } else {
            data.fanModes[String(index)] = mode
        }
        persist()
    }

    /// The metrics that are off, in the fixed order of the enum.
    var availableMenuBarMetrics: [MenuBarMetric] {
        MenuBarMetric.allCases.filter { !data.menuBarMetrics.contains($0) }
    }

    func setMenuBarMetric(_ metric: MenuBarMetric, enabled: Bool) {
        if enabled {
            guard !data.menuBarMetrics.contains(metric) else { return }
            menuBarMetrics = data.menuBarMetrics + [metric]
        } else {
            menuBarMetrics = data.menuBarMetrics.filter { $0 != metric }
        }
    }

    func moveMenuBarMetrics(from source: IndexSet, to destination: Int) {
        var metrics = data.menuBarMetrics
        metrics.move(fromOffsets: source, toOffset: destination)
        menuBarMetrics = metrics
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: AppSettings.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> SettingsData {
        guard let stored = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(SettingsData.self, from: stored)
        else { return SettingsData() }
        return decoded
    }
}

extension Array where Element: Hashable {
    /// Keeps the first occurrence of every element, in order.
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
