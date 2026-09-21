/// Why a window was not moved. Every refusal has a sentence for the user:
/// a shortcut that silently does nothing is the worst outcome here.
public enum WindowRefusal: String, Sendable, Equatable, Hashable, CaseIterable, Codable, Error {
    case fullScreen
    case minimized
    case notStandardWindow
    case notMovable
    case noWindow
    case isMacTools
    case accessibilityMissing

    public var message: String {
        switch self {
        case .fullScreen:
            "This window is in full screen. Leave full screen first."
        case .minimized:
            "This window is in the Dock. Open it first."
        case .notStandardWindow:
            "This is not a standard window, so it cannot be tiled."
        case .notMovable:
            "This app does not let its window be moved or resized."
        case .noWindow:
            "No window is in front."
        case .isMacTools:
            "MacTools does not move its own window."
        case .accessibilityMissing:
            "MacTools needs Accessibility permission to move windows."
        }
    }
}
