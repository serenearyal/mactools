import Foundation

/// Which part of the menu bar popover is on screen.
///
/// It decides what the popover samples, exactly like `MainTab` does for the
/// window, and the choice is remembered between launches.
enum PopoverSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case dashboard
    case windows
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .windows: "Windows"
        case .tools: "Tools"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .windows: "macwindow.on.rectangle"
        case .tools: "wrench.and.screwdriver"
        }
    }

    /// Cmd-1, Cmd-2, Cmd-3, in the order of the segmented control.
    var shortcutKey: Character {
        switch self {
        case .dashboard: "1"
        case .windows: "2"
        case .tools: "3"
        }
    }

    /// `--popover-section <name>`, case and separator tolerant.
    init?(argument: String) {
        let name = argument.lowercased().filter { $0 != "-" && $0 != "_" }
        guard let match = PopoverSection.allCases.first(where: { $0.rawValue.lowercased() == name })
        else { return nil }
        self = match
    }
}
