import Foundation
import Testing

@testable import SysMetrics

/// The dictionary half of the battery, with the answers a real Mac gives.
///
/// The fixtures are the `IOPS` descriptions and the `AppleSmartBattery`
/// properties as `ioreg` prints them, so a Mac that disagrees with this suite
/// disagrees about a key, not about the arithmetic.
@Suite("Battery parsing")
struct BatteryParserTests {
    /// A MacBook Pro on battery at 71 %, two and a half hours left.
    private let discharging: [String: Any] = [
        "Type": "InternalBattery",
        "Current Capacity": 71,
        "Max Capacity": 100,
        "Is Charging": false,
        "Is Charged": false,
        "Power Source State": "Battery Power",
        "Time to Empty": 152,
        "Time to Full Charge": -1,
    ]

    /// The same Mac a minute after the adapter went in.
    private let charging: [String: Any] = [
        "Type": "InternalBattery",
        "Current Capacity": 71,
        "Max Capacity": 100,
        "Is Charging": true,
        "Is Charged": false,
        "Power Source State": "AC Power",
        "Time to Empty": -1,
        "Time to Full Charge": 64,
    ]

    /// Full, on the adapter, nothing left to count down.
    private let charged: [String: Any] = [
        "Type": "InternalBattery",
        "Current Capacity": 100,
        "Max Capacity": 100,
        "Is Charging": false,
        "Is Charged": true,
        "Power Source State": "AC Power",
        "Time to Empty": 0,
        "Time to Full Charge": 0,
    ]

    /// `AppleSmartBattery` on a machine with 142 cycles and a healthy cell,
    /// discharging at about 1.5 A from 12.4 V.
    private let smartBattery: [String: Any] = [
        "CycleCount": 142,
        "AppleRawMaxCapacity": 7_542,
        "DesignCapacity": 8_694,
        "Temperature": 3_112,
        "Amperage": -1_512,
        "Voltage": 12_408,
    ]

    private let adapter: [String: Any] = ["Watts": 96, "Name": "96W USB-C Power Adapter"]

    // MARK: - The four states

    @Test("On battery: the time counts down to empty and the watts flow out")
    func dischargingReading() throws {
        let reading = try #require(
            BatteryParser.reading(
                powerSource: discharging,
                smartBattery: smartBattery,
                lowPowerMode: true
            )
        )
        #expect(reading.percent == 71)
        #expect(!reading.isPluggedIn)
        #expect(!reading.isCharging)
        #expect(!reading.isCharged)
        #expect(reading.minutesRemaining == 152)
        #expect(reading.cycleCount == 142)
        #expect(reading.temperatureCelsius == 31.12)
        #expect(reading.lowPowerMode)
        // Out of the battery is negative: 1.512 A at 12.408 V.
        let watts = try #require(reading.watts)
        #expect(watts < 0)
        #expect(abs(watts + 18.76) < 0.01)
        // No adapter dictionary, so no rating to show.
        #expect(reading.adapterWatts == nil)
        #expect(reading.stateDescription == "On battery")
    }

    @Test("Charging: the time counts up to full and the adapter rating is there")
    func chargingReading() throws {
        let reading = try #require(
            BatteryParser.reading(
                powerSource: charging,
                smartBattery: smartBattery,
                adapter: adapter
            )
        )
        #expect(reading.isPluggedIn)
        #expect(reading.isCharging)
        #expect(!reading.isCharged)
        // "Time to Empty" is -1 while charging, and this reading must not
        // reach for it.
        #expect(reading.minutesRemaining == 64)
        #expect(reading.adapterWatts == 96)
        #expect(reading.stateDescription == "Charging")
    }

    @Test("Full on the adapter: charged, and no countdown at all")
    func chargedReading() throws {
        let reading = try #require(
            BatteryParser.reading(powerSource: charged, adapter: adapter)
        )
        #expect(reading.percent == 100)
        #expect(reading.isPluggedIn)
        #expect(reading.isCharged)
        #expect(!reading.isCharging)
        #expect(reading.minutesRemaining == nil)
        #expect(reading.stateDescription == "Charged")
    }

    @Test("Plugged in and holding: not charging, and not charged either")
    func pluggedInNotCharging() throws {
        var held = charged
        held["Is Charged"] = false
        held["Current Capacity"] = 80
        let reading = try #require(BatteryParser.reading(powerSource: held))
        #expect(reading.isPluggedIn)
        #expect(!reading.isCharging)
        #expect(!reading.isCharged)
        #expect(reading.stateDescription == "Plugged in, not charging")
    }

    @Test("Charged is only ever true on the adapter")
    func chargedNeedsTheAdapter() throws {
        var unplugged = charged
        unplugged["Power Source State"] = "Battery Power"
        let reading = try #require(BatteryParser.reading(powerSource: unplugged))
        #expect(!reading.isCharged)
        #expect(reading.stateDescription == "On battery")
    }

    // MARK: - A time that is not a time

    @Test("A time the system is still working out is no time at all")
    func calculatingTime() throws {
        for raw in [-1, 0, 65_535] {
            var source = discharging
            source["Time to Empty"] = raw
            let reading = try #require(BatteryParser.reading(powerSource: source))
            #expect(reading.minutesRemaining == nil, "\(raw) is not a countdown")
        }
        #expect(BatteryParser.minutes(fromRawTime: 152) == 152)
        #expect(BatteryParser.minutes(fromRawTime: 65_534) == 65_534)
        #expect(BatteryParser.minutes(fromRawTime: -1) == nil)
    }

    @Test("A missing time key reads as calculating, not as zero")
    func missingTimeKey() throws {
        var source = discharging
        source.removeValue(forKey: "Time to Empty")
        let reading = try #require(BatteryParser.reading(powerSource: source))
        #expect(reading.minutesRemaining == nil)
    }

    // MARK: - No battery, and half a battery

    @Test("A Mac with no battery reads as no battery")
    func desktopMac() {
        #expect(BatteryParser.reading(powerSource: [:]) == nil)
        // A UPS is a power source and it is not this Mac's battery.
        #expect(
            BatteryParser.reading(
                powerSource: ["Type": "UPS", "Current Capacity": 90, "Max Capacity": 100]
            ) == nil
        )
        // A description with no capacity in it is nothing anybody can draw.
        #expect(BatteryParser.reading(powerSource: ["Type": "InternalBattery"]) == nil)
        #expect(
            BatteryParser.reading(
                powerSource: ["Type": "InternalBattery", "Current Capacity": 50, "Max Capacity": 0]
            ) == nil
        )
    }

    @Test("Without the registry entry, the first half of the reading still stands")
    func noSmartBattery() throws {
        let reading = try #require(BatteryParser.reading(powerSource: discharging))
        #expect(reading.percent == 71)
        #expect(reading.cycleCount == nil)
        #expect(reading.healthPercent == nil)
        #expect(reading.temperatureCelsius == nil)
        #expect(reading.watts == nil)
        #expect(!reading.lowPowerMode)
    }

    @Test("A registry entry missing one key loses that field and no other")
    func partialSmartBattery() throws {
        var partial = smartBattery
        partial.removeValue(forKey: "Voltage")
        partial.removeValue(forKey: "DesignCapacity")
        let reading = try #require(
            BatteryParser.reading(powerSource: discharging, smartBattery: partial)
        )
        #expect(reading.cycleCount == 142)
        #expect(reading.temperatureCelsius == 31.12)
        #expect(reading.watts == nil)
        #expect(reading.healthPercent == nil)
    }

    // MARK: - The arithmetic

    @Test("Percent is the capacity against the maximum, rounded and clamped")
    func percentArithmetic() throws {
        func percent(_ current: Int, _ maximum: Int) throws -> Int {
            let reading = try #require(
                BatteryParser.reading(
                    powerSource: [
                        "Type": "InternalBattery",
                        "Current Capacity": current,
                        "Max Capacity": maximum,
                    ]
                )
            )
            return reading.percent
        }
        #expect(try percent(71, 100) == 71)
        // An older Mac reports raw milliamp hours instead of a percentage.
        #expect(try percent(3_855, 7_542) == 51)
        #expect(try percent(0, 100) == 0)
        // Never above 100, whatever the firmware says.
        #expect(try percent(105, 100) == 100)
    }

    @Test("Health is the capacity against the design capacity, clamped to 100")
    func healthArithmetic() throws {
        func health(raw: Int, design: Int) -> Int? {
            BatteryParser.reading(
                powerSource: discharging,
                smartBattery: ["AppleRawMaxCapacity": raw, "DesignCapacity": design]
            )?.healthPercent
        }
        #expect(health(raw: 7_542, design: 8_694) == 87)
        // A new cell often measures above its design capacity, and "102 %
        // health" reads like a bug rather than like good news.
        #expect(health(raw: 8_900, design: 8_694) == 100)
        #expect(health(raw: 8_694, design: 8_694) == 100)
        #expect(health(raw: 7_542, design: 0) == nil)
    }

    @Test("Health follows the number macOS itself shows, not the raw capacity")
    func healthMatchesSystemProfiler() throws {
        // This machine, `ioreg -r -c AppleSmartBattery`: the nominal capacity
        // is 83 % of the design capacity and the raw one is 81 %.
        // `system_profiler SPPowerDataType` says "Maximum Capacity: 83%", so
        // the nominal one wins wherever both are published.
        let both = try #require(
            BatteryParser.reading(
                powerSource: discharging,
                smartBattery: [
                    "NominalChargeCapacity": 5_043,
                    "AppleRawMaxCapacity": 4_893,
                    "DesignCapacity": 6_075,
                ]
            )
        )
        #expect(both.healthPercent == 83)
        // An older Mac publishes the raw capacity alone, and that is the answer
        // there.
        let rawOnly = try #require(
            BatteryParser.reading(
                powerSource: discharging,
                smartBattery: ["AppleRawMaxCapacity": 4_893, "DesignCapacity": 6_075]
            )
        )
        #expect(rawOnly.healthPercent == 81)
    }

    @Test("Temperature is hundredths of a degree, and an impossible one is dropped")
    func temperatureArithmetic() throws {
        func celsius(_ raw: Int) -> Double? {
            BatteryParser.reading(
                powerSource: discharging,
                smartBattery: ["Temperature": raw]
            )?.temperatureCelsius
        }
        #expect(celsius(3_112) == 31.12)
        #expect(celsius(0) == 0)
        // A key that means something else on this machine.
        #expect(celsius(-5_000) == nil)
        #expect(celsius(1_000_000) == nil)
    }

    @Test("Watts are signed: into the battery is positive, out of it negative")
    func wattsArithmetic() throws {
        func watts(amperage: Int64, voltage: Int) -> Double? {
            BatteryParser.reading(
                powerSource: discharging,
                smartBattery: ["Amperage": amperage, "Voltage": voltage]
            )?.watts
        }
        let charge = try #require(watts(amperage: 2_500, voltage: 12_408))
        #expect(charge > 0)
        #expect(abs(charge - 31.02) < 0.01)
        let drain = try #require(watts(amperage: -1_512, voltage: 12_408))
        #expect(drain < 0)
        // Several Macs publish the signed milliamps as an unsigned 32-bit
        // word: the same 1512 mA out arrives as 4294965784.
        let wrapped = try #require(watts(amperage: 4_294_965_784, voltage: 12_408))
        #expect(abs(wrapped - drain) < 0.000_1)
        #expect(BatteryParser.signedMilliamps(4_294_965_784) == -1_512)
        #expect(BatteryParser.signedMilliamps(-1_512) == -1_512)
        #expect(BatteryParser.signedMilliamps(2_500) == 2_500)
        #expect(watts(amperage: 2_500, voltage: 0) == nil)
        // An Apple silicon Mac wraps the same number over 64 bits instead:
        // this is the literal `ioreg` value of a Mac drawing 2253 mA at
        // 11.167 V, and the whole 25 W is the reading `mactoolsctl battery`
        // printed next to `pmset -g batt`.
        let sixtyFourBit = try #require(
            BatteryParser.reading(
                powerSource: discharging,
                smartBattery: [
                    "Amperage": NSNumber(value: UInt64(18_446_744_073_709_549_363)),
                    "Voltage": 11_167,
                ]
            )?.watts
        )
        #expect(abs(sixtyFourBit + 25.16) < 0.01)
    }
}
