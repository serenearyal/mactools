import Foundation

/// One value the menu bar label can show.
///
/// Its own file, away from `AppSettings`: the sampling plan is written in
/// terms of these cases, and the test bundle compiles the plan without the
/// observable settings object around it.
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
