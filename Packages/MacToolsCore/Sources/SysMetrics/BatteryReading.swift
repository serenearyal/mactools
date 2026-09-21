import Foundation

/// One look at the battery: what the menu bar app draws, in one value.
///
/// Everything after `minutesRemaining` is optional because it comes from
/// `AppleSmartBattery`, and an external battery, a Mac in a virtual machine and
/// a desktop with a UPS answer only the first half.
public struct BatteryReading: Sendable, Equatable {
    /// 0...100, from the power source's current capacity against its maximum.
    public var percent: Int
    /// External power is connected, whether or not it is charging: a battery
    /// that sits at 80 % on the adapter is plugged in and not charging.
    public var isPluggedIn: Bool
    public var isCharging: Bool
    /// Full and on the adapter.
    public var isCharged: Bool
    /// To empty on battery, to full while charging. nil while the system is
    /// still calculating it, which is what it reports for the first minutes
    /// after a plug or an unplug.
    public var minutesRemaining: Int?
    public var cycleCount: Int?
    /// The raw maximum capacity against the design capacity.
    public var healthPercent: Int?
    public var temperatureCelsius: Double?
    /// Positive is into the battery, negative is out of it.
    public var watts: Double?
    /// The rating of the connected adapter, not what it is delivering.
    public var adapterWatts: Int?
    public var lowPowerMode: Bool

    public init(
        percent: Int,
        isPluggedIn: Bool,
        isCharging: Bool,
        isCharged: Bool = false,
        minutesRemaining: Int? = nil,
        cycleCount: Int? = nil,
        healthPercent: Int? = nil,
        temperatureCelsius: Double? = nil,
        watts: Double? = nil,
        adapterWatts: Int? = nil,
        lowPowerMode: Bool = false
    ) {
        self.percent = percent
        self.isPluggedIn = isPluggedIn
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.minutesRemaining = minutesRemaining
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
        self.temperatureCelsius = temperatureCelsius
        self.watts = watts
        self.adapterWatts = adapterWatts
        self.lowPowerMode = lowPowerMode
    }

    /// What one line of the popover says about the state, with no number in it.
    public var stateDescription: String {
        if isCharged { return "Charged" }
        if isCharging { return "Charging" }
        if isPluggedIn { return "Plugged in, not charging" }
        return "On battery"
    }
}

/// The dictionary half of the battery, kept apart from IOKit so it can be
/// tested with fixtures.
///
/// Every awkward case of the real answers lives here: a time that is still
/// being calculated, a desktop with no battery at all, a raw capacity above the
/// design capacity, and an amperage that arrives as an unsigned 32-bit number
/// with the sign bit set.
public enum BatteryParser {
    // The keys of `IOPSKeys.h`, spelled out so a fixture reads like the real
    // dictionary does in `ioreg`.
    static let typeKey = "Type"
    static let internalBatteryType = "InternalBattery"
    static let currentCapacityKey = "Current Capacity"
    static let maxCapacityKey = "Max Capacity"
    static let isChargingKey = "Is Charging"
    static let isChargedKey = "Is Charged"
    static let powerSourceStateKey = "Power Source State"
    static let acPowerValue = "AC Power"
    static let timeToEmptyKey = "Time to Empty"
    static let timeToFullKey = "Time to Full Charge"

    /// A time the system has not worked out yet. `-1` is what `IOPS` documents;
    /// `65535` is what the `AppleSmartBattery` registry entry says for the same
    /// state, and both reach this code.
    static func minutes(fromRawTime raw: Int) -> Int? {
        guard raw > 0, raw < 65535 else { return nil }
        return raw
    }

    /// `Amperage` is a signed milliamp count that several Macs publish as an
    /// unsigned 32-bit word, so a discharge of 1500 mA arrives as 4293467296.
    static func signedMilliamps(_ raw: Int64) -> Int64 {
        guard raw > Int64(Int32.max), raw <= Int64(UInt32.max) else { return raw }
        return raw - Int64(UInt32.max) - 1
    }

    /// One reading from the three dictionaries the sampler copies.
    ///
    /// nil when there is no internal battery: a desktop Mac answers with power
    /// sources that are not batteries, or with none at all.
    public static func reading(
        powerSource: [String: Any],
        smartBattery: [String: Any] = [:],
        adapter: [String: Any] = [:],
        lowPowerMode: Bool = false
    ) -> BatteryReading? {
        guard let percent = percent(powerSource: powerSource) else { return nil }

        let isPluggedIn = string(powerSource[powerSourceStateKey]) == acPowerValue
        let isCharging = bool(powerSource[isChargingKey]) ?? false
        let isCharged = (bool(powerSource[isChargedKey]) ?? false) && isPluggedIn
        let rawTime = isCharging
            ? integer(powerSource[timeToFullKey])
            : integer(powerSource[timeToEmptyKey])

        return BatteryReading(
            percent: percent,
            isPluggedIn: isPluggedIn,
            isCharging: isCharging,
            isCharged: isCharged,
            minutesRemaining: isCharged ? nil : rawTime.flatMap { minutes(fromRawTime: Int($0)) },
            cycleCount: integer(smartBattery["CycleCount"]).map { Int($0) },
            healthPercent: health(smartBattery: smartBattery),
            temperatureCelsius: temperature(smartBattery: smartBattery),
            watts: watts(smartBattery: smartBattery),
            adapterWatts: integer(adapter["Watts"]).map { Int($0) },
            lowPowerMode: lowPowerMode
        )
    }

    /// 0...100. A power source whose maximum is missing or zero is not a
    /// battery this app can draw.
    private static func percent(powerSource: [String: Any]) -> Int? {
        if let type = string(powerSource[typeKey]), type != internalBatteryType { return nil }
        guard let current = integer(powerSource[currentCapacityKey]),
              let maximum = integer(powerSource[maxCapacityKey]),
              maximum > 0
        else { return nil }
        let ratio = Double(current) / Double(maximum) * 100
        return Swift.min(100, Swift.max(0, Int(ratio.rounded())))
    }

    /// The maximum capacity against the design capacity, clamped to 100: a new
    /// battery often reports 101 % or 102 %, and "102 % health" reads like a
    /// bug rather than like good news.
    ///
    /// `NominalChargeCapacity` first, because it is the number macOS itself
    /// shows: this machine reports 5043 of 6075 there and 4893 in
    /// `AppleRawMaxCapacity`, which is 83 % against 81 %, and 83 % is what
    /// System Settings and `system_profiler SPPowerDataType` say. The raw
    /// capacity is the fallback for the Macs that publish no nominal one.
    private static func health(smartBattery: [String: Any]) -> Int? {
        guard let maximum = integer(smartBattery["NominalChargeCapacity"])
                ?? integer(smartBattery["AppleRawMaxCapacity"]),
              let design = integer(smartBattery["DesignCapacity"]),
              design > 0, maximum > 0
        else { return nil }
        let ratio = Double(maximum) / Double(design) * 100
        return Swift.min(100, Swift.max(0, Int(ratio.rounded())))
    }

    /// Hundredths of a degree Celsius. Anything outside a range a battery can
    /// survive is a key that means something else on this machine.
    private static func temperature(smartBattery: [String: Any]) -> Double? {
        guard let raw = integer(smartBattery["Temperature"]) else { return nil }
        let celsius = Double(raw) / 100
        guard celsius > -20, celsius < 100 else { return nil }
        return celsius
    }

    /// Milliamps times millivolts is microwatts. Positive is into the battery,
    /// which is the sign `Amperage` already uses.
    private static func watts(smartBattery: [String: Any]) -> Double? {
        guard let rawAmperage = integer(smartBattery["Amperage"]),
              let millivolts = integer(smartBattery["Voltage"]),
              millivolts > 0
        else { return nil }
        let milliamps = signedMilliamps(rawAmperage)
        return Double(milliamps) * Double(millivolts) / 1_000_000
    }

    // MARK: - Reading a CoreFoundation dictionary

    private static func integer(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber: number.int64Value
        case let number as Int: Int64(number)
        default: nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: number.boolValue
        case let flag as Bool: flag
        default: nil
        }
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }
}
