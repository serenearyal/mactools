import Foundation

/// How long the Mac is kept awake.
///
/// The timeout is handed to `IOPMAssertionCreateWithProperties`, so the kernel
/// ends it even if the app dies first. There is no polling anywhere.
public enum KeepAwakeDuration: Sendable, Equatable, Hashable, Codable {
    case indefinite
    case minutes(Int)

    public static let presets: [KeepAwakeDuration] = [
        .indefinite,
        .minutes(30),
        .minutes(60),
        .minutes(120),
        .minutes(240),
    ]

    /// Nil means no timeout.
    public var seconds: Int? {
        switch self {
        case .indefinite: nil
        case .minutes(let minutes): max(0, minutes) * 60
        }
    }

    public var title: String {
        switch self {
        case .indefinite:
            "Indefinitely"
        case .minutes(let minutes) where minutes >= 60 && minutes % 60 == 0:
            minutes == 60 ? "1 hour" : "\(minutes / 60) hours"
        case .minutes(let minutes):
            minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
    }
}

/// The remaining time, as the header and the menu show it.
public enum Countdown {
    /// "42m", "1h 05m", "under 1m". Never a second count: a ticking second
    /// would redraw the menu bar sixty times a minute for nothing.
    public static func text(remainingSeconds: Int) -> String {
        guard remainingSeconds > 0 else { return "0m" }
        guard remainingSeconds >= 60 else { return "under 1m" }
        let hours = remainingSeconds / 3600
        let minutes = (remainingSeconds % 3600) / 60
        guard hours > 0 else { return "\(minutes)m" }
        return "\(hours)h \(minutes < 10 ? "0" : "")\(minutes)m"
    }
}
