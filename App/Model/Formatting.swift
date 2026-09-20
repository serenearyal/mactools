import Foundation
import SwiftUI
import SysMetrics

/// Number formatting for the whole app.
///
/// Two families: `compact*` for the menu bar, where a fixed character count
/// keeps the label from jittering, and the long forms for the window.
enum Fmt {
    // MARK: - Menu bar, fixed width

    /// "42%", "100%".
    static func compactPercent(_ percent: Double) -> String {
        "\(Int(percent.rounded().clamped(to: 0...999)))%"
    }

    /// At most five characters: "999M", "12.4G", "0".
    static func compactBytes(_ bytes: Double, base: Double = 1024) -> String {
        let units = ["", "K", "M", "G", "T", "P"]
        var value = max(0, bytes)
        var unit = 0
        while value >= base, unit < units.count - 1 {
            value /= base
            unit += 1
        }
        if unit == 0 { return "\(Int(value.rounded()))" }
        let digits = value < 10 ? 1 : 0
        return "\(value.formatted(.number.precision(.fractionLength(digits))))\(units[unit])"
    }

    /// "56°", "133°".
    static func compactTemperature(_ celsius: Double, unit: TemperatureUnit) -> String {
        "\(Int(unit.convert(celsius).rounded()))°"
    }

    static func compactRPM(_ rpm: Double) -> String {
        "\(Int(rpm.rounded()))"
    }

    static func compactWatts(_ watts: Double) -> String {
        let digits = watts < 10 ? 1 : 0
        return "\(watts.formatted(.number.precision(.fractionLength(digits))))W"
    }

    // MARK: - Window

    /// "384 GB", decimal units, the way storage is sold and Finder shows it.
    /// Fixed precision, so "384 GB of 494 GB" does not mix decimal counts.
    static func storageSize(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        guard gigabytes >= 1 else {
            return bytes.formatted(.byteCount(style: .file, allowedUnits: .all, spellsOutZero: false))
        }
        guard gigabytes < 1000 else {
            let terabytes = gigabytes / 1000
            return "\(terabytes.formatted(.number.precision(.fractionLength(2)))) TB"
        }
        let digits = gigabytes < 100 ? 1 : 0
        return "\(gigabytes.formatted(.number.precision(.fractionLength(digits)))) GB"
    }

    /// "12.4 GB", binary units, the way memory is counted.
    static func memorySize(_ bytes: UInt64) -> String {
        bytes.formatted(.byteCount(style: .memory, allowedUnits: .all, spellsOutZero: false))
    }

    /// "12.4 MB/s". Never "bytes", so an idle disk reads "0 kB/s" and the
    /// line does not change shape at every sample.
    static func throughput(_ bytesPerSecond: Double) -> String {
        let value = UInt64(max(0, bytesPerSecond).rounded())
        guard value >= 1000 else { return "0 kB/s" }
        let units: ByteCountFormatStyle.Units = [.kb, .mb, .gb, .tb]
        return "\(value.formatted(.byteCount(style: .file, allowedUnits: units, spellsOutZero: false)))/s"
    }

    /// "12.3" for the process table: Activity Monitor counts one busy core as
    /// 100, and one decimal is what tells an idle process from a sleeping one.
    static func processCPU(_ percent: Double) -> String {
        percent.formatted(.number.precision(.fractionLength(1)))
    }

    static func percent(_ fraction: Double, fractionDigits: Int = 0) -> String {
        fraction.formatted(.percent.precision(.fractionLength(fractionDigits)))
    }

    static func temperature(_ celsius: Double, unit: TemperatureUnit, digits: Int = 0) -> String {
        let value = unit.convert(celsius)
        return "\(value.formatted(.number.precision(.fractionLength(digits))))\(unit.suffix)"
    }

    static func rpm(_ rpm: Double) -> String {
        "\(Int(rpm.rounded()).formatted()) rpm"
    }

    static func watts(_ watts: Double) -> String {
        "\(watts.formatted(.number.precision(.fractionLength(1)))) W"
    }
}

/// Green / yellow / red thresholds. These are the only colours the app picks
/// itself; everything else is a system colour.
enum MetricColor {
    static func temperature(_ celsius: Double) -> Color {
        switch celsius {
        case ..<70: .green
        case ..<90: .yellow
        default: .red
        }
    }

    static func pressure(_ level: MemoryPressureLevel?) -> Color {
        switch level {
        case .warning: .yellow
        case .critical: .red
        default: .green
        }
    }

    static func usage(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.7: .green
        case ..<0.9: .yellow
        default: .red
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
