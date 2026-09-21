import Foundation

/// Numbers for a report.
///
/// The app's own formatters are locale aware, which is right on screen and
/// wrong here: a report is compared against a golden string and is read by a
/// chat model, so it must look the same on every Mac. Nothing in here asks
/// the locale.
public enum ReportFormat {
    public enum ByteStyle: Sendable {
        /// 1024, the way memory is counted.
        case memory
        /// 1000, the way a disk is sold and Finder shows it.
        case disk

        var base: Double {
            switch self {
            case .memory: 1024
            case .disk: 1000
            }
        }
    }

    static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// "512 B", "1.5 MB", "384 GB". One decimal below 100, none above: three
    /// significant digits are all a human reads here.
    public static func bytes(_ bytes: UInt64, style: ByteStyle) -> String {
        var value = Double(bytes)
        var unit = 0
        while value >= style.base, unit < units.count - 1 {
            value /= style.base
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        let digits = value < 100 ? 1 : 0
        return "\(decimal(value, digits: digits)) \(units[unit])"
    }

    /// "12.3". Per core, so it can pass 100.
    public static func cpu(_ percent: Double) -> String {
        guard percent.isFinite else { return "0.0" }
        return decimal(max(0, percent), digits: 1)
    }

    /// "2026-09-20" in the calendar the caller names, so a golden test is not
    /// a lottery on the time zone of the machine that runs it.
    public static func date(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return "\(pad(year, width: 4))-\(pad(month, width: 2))-\(pad(day, width: 2))"
    }

    /// "3d 4h 12m", dropping the units that are zero at the front.
    public static func uptime(seconds: Int) -> String {
        guard seconds >= 60 else { return "under 1m" }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Fixed decimals without a locale: `String(format:)` with no locale is
    /// the C behaviour, so the separator is always a point.
    static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    static func pad(_ value: Int, width: Int) -> String {
        let text = String(abs(value))
        let padding = max(0, width - text.count)
        return (value < 0 ? "-" : "") + String(repeating: "0", count: padding) + text
    }
}
