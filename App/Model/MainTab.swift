import Foundation

/// Which part of the window is on screen. It decides what the sampler reads.
///
/// The order of the cases is the order of the sidebar, grouped by
/// `MainTabSection`.
enum MainTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case sensors
    case processes
    case storage
    case battery
    case fans
    case windows
    case keepAwake
    case keyboardLock
    case backlight
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .sensors: "Sensors"
        case .processes: "Processes"
        case .storage: "Storage"
        case .battery: "Battery"
        case .fans: "Fans"
        case .windows: "Windows"
        case .keepAwake: "Keep Awake"
        case .keyboardLock: "Keyboard Lock"
        case .backlight: "Keyboard Backlight"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .sensors: "thermometer.medium"
        case .processes: "list.bullet.rectangle"
        case .storage: "internaldrive"
        case .battery: "battery.75percent"
        case .fans: "fan"
        case .windows: "macwindow.on.rectangle"
        case .keepAwake: "cup.and.saucer"
        case .keyboardLock: "keyboard"
        case .backlight: "light.max"
        case .settings: "gearshape"
        }
    }

    /// `--tab <name>`. The raw names are camel case, so a run may write
    /// `keep-awake`, `keep_awake` or `keepawake` and mean the same tab.
    init?(argument: String) {
        let name = argument.lowercased().filter { $0 != "-" && $0 != "_" }
        guard let match = MainTab.allCases.first(where: { $0.rawValue.lowercased() == name })
        else { return nil }
        self = match
    }
}

/// The sidebar groups. Four headers, so eleven items read as four short lists
/// rather than one long one.
enum MainTabSection: String, CaseIterable, Identifiable, Sendable {
    case monitor
    case control
    case tools
    case app

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monitor: "Monitor"
        case .control: "Control"
        case .tools: "Tools"
        case .app: "App"
        }
    }

    var tabs: [MainTab] {
        switch self {
        case .monitor: [.overview, .sensors, .processes, .storage, .battery]
        case .control: [.fans, .windows, .keepAwake]
        case .tools: [.keyboardLock, .backlight]
        case .app: [.settings]
        }
    }

    /// Every tab belongs to exactly one section, and the sidebar order is the
    /// order of `MainTab.allCases`.
    static var orderedTabs: [MainTab] { allCases.flatMap(\.tabs) }
}
