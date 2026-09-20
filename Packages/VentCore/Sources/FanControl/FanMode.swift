import Foundation

/// What the user asked one fan to do.
///
/// JSON is the wire format: the XPC layer would otherwise need an
/// `NSSecureCoding` class and an allowlist on both sides for three cases.
public enum FanMode: Codable, Hashable, Sendable {
    /// The firmware decides. `F%dMd = 0`, `F%dTg = 0`.
    case auto
    /// A fixed setpoint, clamped to the limits of the fan.
    case constant(rpm: Int)
    /// A linear ramp between two temperatures of one sensor.
    case curve(sensorKey: String, startTemp: Double, maxTemp: Double)

    public var isAuto: Bool {
        if case .auto = self { return true }
        return false
    }

    public var kind: FanModeKind {
        switch self {
        case .auto: .auto
        case .constant: .constant
        case .curve: .curve
        }
    }

    /// One line for a status list or a log.
    public var summary: String {
        switch self {
        case .auto:
            "Auto"
        case .constant(let rpm):
            "Constant \(rpm.formatted()) rpm"
        case .curve(let key, let start, let maxTemp):
            "Curve on \(key), \(Int(start.rounded()))-\(Int(maxTemp.rounded()))°C"
        }
    }

    // MARK: - Wire format

    public var jsonData: Data? {
        try? JSONEncoder().encode(self)
    }

    public init?(json: Data) {
        guard let decoded = try? JSONDecoder().decode(FanMode.self, from: json) else { return nil }
        self = decoded
    }
}

/// The three choices of the segmented control, without their payload.
public enum FanModeKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto
    case constant
    case curve

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .constant: "Constant"
        case .curve: "Sensor-based"
        }
    }
}

/// Why one fan is not doing what it was told.
public struct FanFault: Codable, Hashable, Sendable {
    public let fanIndex: Int
    public let reason: String

    public init(fanIndex: Int, reason: String) {
        self.fanIndex = fanIndex
        self.reason = reason
    }
}
