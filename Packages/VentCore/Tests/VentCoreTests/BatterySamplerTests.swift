import Foundation
import Testing

@testable import SysMetrics

/// The IOKit half, against the machine the tests run on.
///
/// Every check holds on a Mac with a battery and on a Mac without one, because
/// both are shipping machines: a desktop answers nil and that is the whole
/// expectation there.
@Suite("Battery sampler")
struct BatterySamplerTests {
    @Test("A reading from this machine is plausible in every field")
    func liveReading() throws {
        guard let reading = BatterySampler.read() else { return }
        #expect((0...100).contains(reading.percent))
        // Charging is a kind of plugged in, and so is charged.
        if reading.isCharging || reading.isCharged { #expect(reading.isPluggedIn) }
        if let minutes = reading.minutesRemaining {
            #expect(minutes > 0)
            // Two days on one charge would be a parsing error, not a battery.
            #expect(minutes < 2_880)
        }
        if let cycles = reading.cycleCount { #expect((0...10_000).contains(cycles)) }
        if let health = reading.healthPercent { #expect((1...100).contains(health)) }
        if let celsius = reading.temperatureCelsius { #expect(celsius > 0 && celsius < 80) }
        if let watts = reading.watts { #expect(abs(watts) < 300) }
        if let adapter = reading.adapterWatts {
            #expect(adapter > 0 && adapter <= 1_000)
            // An adapter is only described while one is connected.
            #expect(reading.isPluggedIn)
        }
        #expect(reading.lowPowerMode == ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    @Test("Reading twice in a row gives the same battery")
    func stableAcrossReads() throws {
        guard let first = BatterySampler.read(), let second = BatterySampler.read() else { return }
        // The percentage and the cycle count cannot move between two calls a
        // microsecond apart; the watts and the countdown can.
        #expect(first.percent == second.percent)
        #expect(first.cycleCount == second.cycleCount)
        #expect(first.healthPercent == second.healthPercent)
        #expect(first.isPluggedIn == second.isPluggedIn)
    }
}
