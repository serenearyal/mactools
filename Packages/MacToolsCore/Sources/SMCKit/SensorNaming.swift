public enum SensorCategory: String, Sendable, CaseIterable {
    case cpuPerformance
    case cpuEfficiency
    case gpu
    case memory
    case enclosure
    case battery
    case wireless
    case ambient
    case ssd
    case other

    public var label: String {
        switch self {
        case .cpuPerformance: "CPU performance"
        case .cpuEfficiency: "CPU efficiency"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .enclosure: "Enclosure"
        case .battery: "Battery"
        case .wireless: "Wireless"
        case .ambient: "Ambient"
        case .ssd: "SSD"
        case .other: "Other"
        }
    }

    public var isProcessor: Bool {
        self == .cpuPerformance || self == .cpuEfficiency || self == .gpu
    }
}

public struct SensorDescriptor: Sendable, Equatable {
    public let key: SMCFourCC
    public let label: String
    public let category: SensorCategory

    public init(key: SMCFourCC, label: String, category: SensorCategory) {
        self.key = key
        self.label = label
        self.category = category
    }
}

/// Human labels for the SMC keys of Apple silicon laptops.
///
/// The core numbering follows the sensor table of exelban/stats, which is the
/// most widely checked public mapping. Keys that are not in the table keep
/// their FourCC as the label.
public enum SensorNaming {
    public static func descriptor(for key: SMCFourCC) -> SensorDescriptor {
        guard let entry = temperatureTable[key] else {
            return SensorDescriptor(key: key, label: key.stringValue, category: .other)
        }
        return SensorDescriptor(key: key, label: entry.label, category: entry.category)
    }

    public static func powerLabel(for key: SMCFourCC) -> String {
        powerTable[key] ?? key.stringValue
    }

    /// True for the keys a power view should show by default.
    public static func isKnownPowerKey(_ key: SMCFourCC) -> Bool {
        powerTable[key] != nil
    }

    /// The labelled temperature keys, in key order. A caller that must not pay
    /// for the 0.8 s catalog enumeration reads these directly and drops the
    /// ones the machine does not answer.
    public static func knownTemperatureKeys(
        in categories: Set<SensorCategory>? = nil
    ) -> [SMCFourCC] {
        temperatureTable
            .filter { categories?.contains($0.value.category) ?? true }
            .keys
            .sorted { $0.stringValue < $1.stringValue }
    }

    /// The labelled power keys, in key order.
    public static var knownPowerKeys: [SMCFourCC] {
        powerTable.keys.sorted { $0.stringValue < $1.stringValue }
    }

    private static let temperatureTable: [SMCFourCC: (label: String, category: SensorCategory)] = [
        // M1 generation performance cores.
        "Tp01": ("CPU performance core 1", .cpuPerformance),
        "Tp05": ("CPU performance core 2", .cpuPerformance),
        "Tp0D": ("CPU performance core 3", .cpuPerformance),
        "Tp0H": ("CPU performance core 4", .cpuPerformance),
        "Tp0L": ("CPU performance core 5", .cpuPerformance),
        "Tp0P": ("CPU performance core 6", .cpuPerformance),
        "Tp0X": ("CPU performance core 7", .cpuPerformance),
        "Tp0b": ("CPU performance core 8", .cpuPerformance),
        // M1 generation efficiency cores.
        "Tp09": ("CPU efficiency core 1", .cpuEfficiency),
        "Tp0T": ("CPU efficiency core 2", .cpuEfficiency),

        "Tg05": ("GPU 1", .gpu),
        "Tg0D": ("GPU 2", .gpu),
        "Tg0L": ("GPU 3", .gpu),
        "Tg0T": ("GPU 4", .gpu),

        "Tm02": ("Memory 1", .memory),
        "Tm06": ("Memory 2", .memory),
        "Tm08": ("Memory 3", .memory),
        "Tm09": ("Memory 4", .memory),
        "Tm0P": ("Mainboard", .enclosure),

        "Ts0P": ("Enclosure 1 (palm rest)", .enclosure),
        "Ts1P": ("Enclosure 2 (palm rest)", .enclosure),
        "Ts0S": ("Enclosure 3", .enclosure),

        "TB0T": ("Battery", .battery),
        "TB1T": ("Battery 1", .battery),
        "TB2T": ("Battery 2", .battery),

        "TW0P": ("Wireless module", .wireless),

        "TaLP": ("Airflow left", .ambient),
        "TaRF": ("Airflow right", .ambient),
        "TA0P": ("Ambient 1", .ambient),
        "TA1P": ("Ambient 2", .ambient),

        "TH0x": ("SSD NAND", .ssd),
        "TH0a": ("SSD NAND 1", .ssd),
        "TH0b": ("SSD NAND 2", .ssd),
        "TH0c": ("SSD NAND 3", .ssd),
        "Th0H": ("Heatpipe", .other),
    ]

    private static let powerTable: [SMCFourCC: String] = [
        "PSTR": "System total",
        "PDTR": "DC in",
        "PMTR": "Memory total",
        "PPBR": "Battery",
        "PDBR": "Display backlight",
    ]
}
