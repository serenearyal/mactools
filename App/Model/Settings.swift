import FanControl
import Foundation
import Observation

/// One value the menu bar label can show.
enum MenuBarMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    case cpuUsage
    case memoryUsed
    case memoryPercent
    case diskUsedPercent
    case diskFree
    case cpuTemperature
    case sensorTemperature
    case fanSpeed
    case systemPower
    case diskIO

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpuUsage: "CPU usage"
        case .memoryUsed: "Memory used"
        case .memoryPercent: "Memory used, percent"
        case .diskUsedPercent: "Disk used, percent"
        case .diskFree: "Disk free"
        case .cpuTemperature: "Hottest CPU sensor"
        case .sensorTemperature: "Chosen sensor"
        case .fanSpeed: "Fastest fan"
        case .systemPower: "System power"
        case .diskIO: "Disk activity"
        }
    }

    var symbolName: String {
        switch self {
        case .cpuUsage: "cpu"
        case .memoryUsed, .memoryPercent: "memorychip"
        case .diskUsedPercent, .diskFree: "internaldrive"
        case .cpuTemperature, .sensorTemperature: "thermometer.medium"
        case .fanSpeed: "fan"
        case .systemPower: "bolt"
        case .diskIO: "arrow.up.arrow.down"
        }
    }

    /// The tiny caption above the value in the two-line label.
    var caption: String {
        switch self {
        case .cpuUsage: "CPU"
        case .memoryUsed, .memoryPercent: "MEM"
        case .diskUsedPercent, .diskFree: "SSD"
        case .cpuTemperature: "TEMP"
        case .sensorTemperature: "SENS"
        case .fanSpeed: "FAN"
        case .systemPower: "PWR"
        case .diskIO: "I/O"
        }
    }

    /// The widest string the value can take. The cell is sized from this, so
    /// the status item never changes width while the numbers change.
    var widestValue: String {
        switch self {
        case .cpuUsage, .memoryPercent, .diskUsedPercent: "100%"
        case .memoryUsed, .diskFree, .diskIO: "88.8G"
        case .cpuTemperature, .sensorTemperature: "188°"
        case .fanSpeed: "8888"
        case .systemPower: "88.8W"
        }
    }
}

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

    init() {}

    /// Every key is optional, so a settings file written by an older build
    /// keeps the choices it does hold instead of resetting all of them.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SettingsData()
        menuBarMetrics = try container.decodeIfPresent([MenuBarMetric].self, forKey: .menuBarMetrics)
            ?? fallback.menuBarMetrics
        labelStyle = try container.decodeIfPresent(MenuBarLabelStyle.self, forKey: .labelStyle)
            ?? fallback.labelStyle
        showMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon)
            ?? fallback.showMenuBarIcon
        refreshInterval = try container.decodeIfPresent(RefreshInterval.self, forKey: .refreshInterval)
            ?? fallback.refreshInterval
        temperatureUnit = try container.decodeIfPresent(TemperatureUnit.self, forKey: .temperatureUnit)
            ?? fallback.temperatureUnit
        sensorKey = try container.decodeIfPresent(String.self, forKey: .sensorKey) ?? fallback.sensorKey
        showUnlabelledSensors = try container.decodeIfPresent(Bool.self, forKey: .showUnlabelledSensors)
            ?? fallback.showUnlabelledSensors
        lockTimeoutSeconds = LockTimeout.clamp(
            try container.decodeIfPresent(Int.self, forKey: .lockTimeoutSeconds)
                ?? fallback.lockTimeoutSeconds
        )
        fanModes = try container.decodeIfPresent([String: FanMode].self, forKey: .fanModes)
            ?? fallback.fanModes
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
    static let defaultsKey = "settings.v1"

    private var data: SettingsData
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
