import Foundation
import SMCKit

/// One fan as the helper sees it: what the firmware reports, plus the mode the
/// governor is holding for it.
public struct FanStatus: Codable, Hashable, Sendable, Identifiable {
    public let index: Int
    public let name: String
    public let actualRPM: Double
    public let minimumRPM: Double
    public let maximumRPM: Double
    public let targetRPM: Double
    /// What the `F%dMd` register says right now.
    public let hardwareMode: SMCFanMode
    /// What the user asked for.
    public let mode: FanMode
    /// The sensor of a curve, as the governor last read it.
    public let sensorCelsius: Double?

    public var id: Int { index }

    public init(
        index: Int,
        name: String,
        actualRPM: Double,
        minimumRPM: Double,
        maximumRPM: Double,
        targetRPM: Double,
        hardwareMode: SMCFanMode,
        mode: FanMode,
        sensorCelsius: Double? = nil
    ) {
        self.index = index
        self.name = name
        self.actualRPM = actualRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.targetRPM = targetRPM
        self.hardwareMode = hardwareMode
        self.mode = mode
        self.sensorCelsius = sensorCelsius
    }

    /// Where the fan sits between its limits, 0 to 1.
    public var loadFraction: Double {
        guard maximumRPM > minimumRPM else { return 0 }
        return min(max((actualRPM - minimumRPM) / (maximumRPM - minimumRPM), 0), 1)
    }
}

/// Everything the Fans tab and `mactoolsctl fan-status` need, in one reply.
public struct FanSnapshot: Codable, Hashable, Sendable {
    public let fans: [FanStatus]
    public let faults: [FanFault]
    public let interlockEngaged: Bool
    /// The die that decided the interlock state.
    public let hottestDieCelsius: Double?
    /// Set when the last read of the fans failed outright.
    public let readError: String?

    public init(
        fans: [FanStatus],
        faults: [FanFault] = [],
        interlockEngaged: Bool = false,
        hottestDieCelsius: Double? = nil,
        readError: String? = nil
    ) {
        self.fans = fans
        self.faults = faults
        self.interlockEngaged = interlockEngaged
        self.hottestDieCelsius = hottestDieCelsius
        self.readError = readError
    }

    public var isAllAuto: Bool {
        fans.allSatisfy { $0.mode.isAuto }
    }

    public func fault(forFan index: Int) -> String? {
        faults.first { $0.fanIndex == index }?.reason
    }

    // MARK: - Wire format

    public var jsonData: Data? {
        try? JSONEncoder().encode(self)
    }

    public init?(json: Data) {
        guard let decoded = try? JSONDecoder().decode(FanSnapshot.self, from: json) else { return nil }
        self = decoded
    }
}
