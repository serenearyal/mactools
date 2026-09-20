/// Keys of one fan. Fan keys are `F<index><suffix>`, so the index is a single
/// digit and the suffix is two characters.
public enum FanKeys {
    public static let count: SMCFourCC = "FNum"
    /// The key Intel machines need before a mode change is accepted.
    public static let forceTargets: SMCFourCC = "Ftst"

    public static func key(fan index: Int, suffix: String) -> SMCFourCC? {
        guard (0...9).contains(index), suffix.count == 2 else { return nil }
        return SMCFourCC(code: "F\(index)\(suffix)")
    }
}

public enum FanMode: String, Sendable {
    case auto
    case forced
    case unknown
}

/// What the SMC exposes for fan control on this machine.
public struct FanCapabilities: Sendable, Equatable {
    public let fanCount: Int
    /// "Md" on Apple silicon, "md" on some Intel machines.
    public let modeSuffix: String?
    public let hasForceTargets: Bool

    public init(fanCount: Int, modeSuffix: String?, hasForceTargets: Bool) {
        self.fanCount = fanCount
        self.modeSuffix = modeSuffix
        self.hasForceTargets = hasForceTargets
    }
}

public struct FanReading: Sendable, Equatable {
    public let index: Int
    public let actual: Double
    public let minimum: Double
    public let maximum: Double
    public let target: Double
    public let mode: FanMode

    public init(index: Int, actual: Double, minimum: Double, maximum: Double, target: Double, mode: FanMode) {
        self.index = index
        self.actual = actual
        self.minimum = minimum
        self.maximum = maximum
        self.target = target
        self.mode = mode
    }
}

public struct TemperatureReading: Sendable, Equatable {
    public let key: SMCFourCC
    public let label: String
    public let category: SensorCategory
    public let celsius: Double

    public init(key: SMCFourCC, label: String, category: SensorCategory, celsius: Double) {
        self.key = key
        self.label = label
        self.category = category
        self.celsius = celsius
    }
}

public struct PowerReading: Sendable, Equatable {
    public let key: SMCFourCC
    public let label: String
    public let watts: Double

    public init(key: SMCFourCC, label: String, watts: Double) {
        self.key = key
        self.label = label
        self.watts = watts
    }
}

extension SMCConnection {
    /// A sensor outside this range is a placeholder, not a reading.
    public static let plausibleTemperatureRange: ClosedRange<Double> = 1...125

    public func fanCapabilities() throws(SMCError) -> FanCapabilities {
        let count = Int(try readDouble(FanKeys.count) ?? 0)
        let modeSuffix = ["Md", "md"].first { suffix in
            guard let key = FanKeys.key(fan: 0, suffix: suffix) else { return false }
            return hasKey(key)
        }
        return FanCapabilities(
            fanCount: count,
            modeSuffix: modeSuffix,
            hasForceTargets: hasKey(FanKeys.forceTargets)
        )
    }

    public func readFans() throws(SMCError) -> [FanReading] {
        let capabilities = try fanCapabilities()
        var readings: [FanReading] = []
        for index in 0..<capabilities.fanCount {
            func value(_ suffix: String) -> Double? {
                guard let key = FanKeys.key(fan: index, suffix: suffix) else { return nil }
                return (try? readDouble(key)) ?? nil
            }
            let modeValue = capabilities.modeSuffix.flatMap { value($0) }
            readings.append(
                FanReading(
                    index: index,
                    actual: value("Ac") ?? 0,
                    minimum: value("Mn") ?? 0,
                    maximum: value("Mx") ?? 0,
                    target: value("Tg") ?? 0,
                    mode: modeValue.map { $0 == 0 ? .auto : .forced } ?? .unknown
                )
            )
        }
        return readings
    }

    /// Every key that can hold a temperature: "T" prefix, `flt ` encoding.
    public func temperatureKeys(in catalog: SMCKeyCatalog) -> [SMCFourCC] {
        catalog.entries(withKeyPrefix: "T", type: .float32).map(\.key)
    }

    /// The live sensors among `keys`: readable and inside the plausible range.
    /// Keys that disappear between the catalog and the read are dropped.
    public func readTemperatures(_ keys: [SMCFourCC]) -> [TemperatureReading] {
        keys.compactMap { key in
            guard let celsius = (try? readDouble(key)) ?? nil,
                  SMCConnection.plausibleTemperatureRange.contains(celsius)
            else { return nil }
            let descriptor = SensorNaming.descriptor(for: key)
            return TemperatureReading(
                key: key,
                label: descriptor.label,
                category: descriptor.category,
                celsius: celsius
            )
        }
    }

    /// Convenience for one-shot callers: enumerates the catalog first.
    public func readTemperatures() throws(SMCError) -> [TemperatureReading] {
        let catalog = try SMCKeyCatalog.load(from: self)
        return readTemperatures(temperatureKeys(in: catalog))
    }

    /// The labelled power keys of the machine. The SMC also publishes dozens of
    /// unnamed `P` rails, most of them zero or a fixed limit, so they are only
    /// included on request.
    public func readPower(in catalog: SMCKeyCatalog, includingUnlabelled: Bool = false) -> [PowerReading] {
        catalog.entries(withKeyPrefix: "P", type: .float32).compactMap { entry in
            guard includingUnlabelled || SensorNaming.isKnownPowerKey(entry.key) else { return nil }
            guard let watts = (try? readDouble(entry.key)) ?? nil, watts.isFinite else { return nil }
            return PowerReading(key: entry.key, label: SensorNaming.powerLabel(for: entry.key), watts: watts)
        }
    }

    public func readPower() throws(SMCError) -> [PowerReading] {
        readPower(in: try SMCKeyCatalog.load(from: self))
    }
}
