import Foundation

/// Which part of the menu bar popover is on screen.
///
/// It decides what the popover samples, exactly like `MainTab` does for the
/// window, and the choice is remembered between launches.
enum PopoverSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case dashboard
    case fans
    case windows
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .fans: "Fans"
        case .windows: "Windows"
        case .tools: "Tools"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .fans: "fan"
        case .windows: "macwindow.on.rectangle"
        case .tools: "wrench.and.screwdriver"
        }
    }

    /// Cmd-1 to Cmd-4, in the order of the segmented control.
    var shortcutKey: Character {
        switch self {
        case .dashboard: "1"
        case .fans: "2"
        case .windows: "3"
        case .tools: "4"
        }
    }

    /// `--popover-section <name>`, case and separator tolerant.
    init?(argument: String) {
        let name = argument.lowercased().filter { $0 != "-" && $0 != "_" }
        guard let match = PopoverSection.allCases.first(where: { $0.rawValue.lowercased() == name })
        else { return nil }
        self = match
    }

    /// A section the settings file names and this build does not have falls
    /// back to the Dashboard.
    ///
    /// Without this, one unknown string would throw out of `AppSettings`'
    /// decoder and take every other setting in the file with it: the sections
    /// are renamed between versions, and a downgrade is what produces the
    /// unknown name.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PopoverSection(rawValue: raw) ?? .dashboard
    }
}
