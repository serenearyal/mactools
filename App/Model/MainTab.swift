import Foundation

/// Which part of the window is on screen. It decides what the sampler reads.
enum MainTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case fans
    case sensors
    case processes
    case storage
    case keyboardLock
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .fans: "Fans"
        case .sensors: "Sensors"
        case .processes: "Processes"
        case .storage: "Storage"
        case .keyboardLock: "Keyboard Lock"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .fans: "fan"
        case .sensors: "thermometer.medium"
        case .processes: "list.bullet.rectangle"
        case .storage: "internaldrive"
        case .keyboardLock: "keyboard"
        case .settings: "gearshape"
        }
    }
}
