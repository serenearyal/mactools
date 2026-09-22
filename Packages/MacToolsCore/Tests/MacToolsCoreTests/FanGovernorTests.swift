import Foundation
import Testing

import FanControl
import SMCKit

/// Two fans with the limits of a MacBookPro18,3 and no interlock sensor by
/// default, so a test only deals with what it set up itself.
private func makeGovernor(
    hardware: InMemoryFanHardware = InMemoryFanHardware.macBookPro(),
    interlockKeys: [String] = []
) -> (FanGovernor, InMemoryFanHardware) {
    let governor = FanGovernor(hardware: hardware, interlockSensorKeys: interlockKeys)
    governor.tick(now: 0)
    hardware.clearCalls()
    return (governor, hardware)
}

@Test("a fan left in Auto is not written to at all")
func governorLeavesAutoAlone() {
    let (governor, hardware) = makeGovernor()
    governor.tick(now: 2)
    #expect(hardware.calls == [.readFans])
    #expect(governor.isActive == false)
}

@Test("a constant mode forces the fan and writes the setpoint once")
func governorConstant() {
    let (governor, hardware) = makeGovernor()
    #expect(governor.setMode(.constant(rpm: 2500), forFan: 0, now: 0) == nil)
    #expect(hardware.calls.contains(.setManual(0, 2500)))
    #expect(hardware.fans[0].manual == true)
    #expect(hardware.fans[0].target == 2500)
    #expect(hardware.fans[1].manual == false)
    #expect(governor.isActive == true)

    // The same setpoint on the next tick is not worth an SMC write.
    hardware.clearCalls()
    governor.tick(now: 2)
    #expect(hardware.calls == [.readFans])

    // A move of less than the deadband is ignored too, a larger one is not.
    governor.setMode(.constant(rpm: 2505), forFan: 0, now: 4)
    #expect(hardware.fans[0].target == 2505)
    hardware.clearCalls()
    governor.tick(now: 6)
    #expect(hardware.calls == [.readFans])
}

@Test("a request outside the limits reaches the fan clamped")
func governorClampsConstant() {
    let (governor, hardware) = makeGovernor()
    governor.setMode(.constant(rpm: 99_999), forFan: 0, now: 0)
    #expect(hardware.fans[0].target == 5779)
    governor.setMode(.constant(rpm: -400), forFan: 1, now: 0)
    #expect(hardware.fans[1].target == 1200)
}

@Test("going back to Auto writes mode 0 and target 0")
func governorBackToAuto() {
    let (governor, hardware) = makeGovernor()
    governor.setMode(.constant(rpm: 3000), forFan: 0, now: 0)
    hardware.clearCalls()

    governor.setMode(.auto, forFan: 0, now: 2)
    #expect(hardware.calls.contains(.setAuto(0)))
    #expect(hardware.fans[0].manual == false)
    #expect(hardware.fans[0].target == 0)
    #expect(governor.isActive == false)

    // And it is not written again on every tick afterwards.
    hardware.clearCalls()
    governor.tick(now: 4)
    #expect(hardware.calls == [.readFans])
}

@Test("a curve follows its sensor")
func governorCurve() {
    let hardware = InMemoryFanHardware.macBookPro()
    hardware.setTemperature(45, forKey: "Tp01")
    let (governor, _) = makeGovernor(hardware: hardware)

    governor.setMode(.curve(sensorKey: "Tp01", startTemp: 45, maxTemp: 85), forFan: 0, now: 0)
    #expect(hardware.fans[0].target == 1200)

    // Halfway up the ramp, far enough away that the slew limit needs time.
    hardware.setTemperature(65, forKey: "Tp01")
    governor.tick(now: 2)
    #expect(hardware.fans[0].target == 1200 + 400)
    governor.tick(now: 12)
    #expect(abs(hardware.fans[0].target - (1200 + 5779) / 2) < 0.5)
}

@Test("a curve on a sensor that is gone falls back to Auto with a fault")
func governorMissingSensor() {
    let hardware = InMemoryFanHardware.macBookPro()
    let (governor, _) = makeGovernor(hardware: hardware)
    governor.setMode(.curve(sensorKey: "Tp01", startTemp: 45, maxTemp: 85), forFan: 0, now: 0)
    #expect(hardware.fans[0].manual == true)

    hardware.hideSensor("Tp01")
    governor.tick(now: 2)

    #expect(hardware.fans[0].manual == false)
    #expect(governor.isActive == false)
    let snapshot = governor.snapshot()
    #expect(snapshot.fans[0].mode == .auto)
    #expect(snapshot.fault(forFan: 0)?.contains("Tp01") == true)
    #expect(snapshot.fault(forFan: 0)?.contains("back to Auto") == true)
}

@Test("a write the SMC refuses puts that fan back to Auto with a fault")
func governorWriteError() {
    let hardware = InMemoryFanHardware.macBookPro()
    let (governor, _) = makeGovernor(hardware: hardware)
    hardware.failWrites(forFan: 0)

    governor.setMode(.constant(rpm: 3000), forFan: 0, now: 0)

    #expect(hardware.calls.contains(.setManual(0, 3000)))
    // The fallback is attempted even though it fails too, and the fault says so.
    #expect(hardware.calls.contains(.setAuto(0)))
    #expect(hardware.fans[0].manual == false)
    #expect(governor.isActive == false)
    #expect(governor.snapshot().fault(forFan: 0)?.contains("refused") == true)

    // The other fan is not affected.
    governor.setMode(.constant(rpm: 3000), forFan: 1, now: 2)
    #expect(hardware.fans[1].target == 3000)
}

@Test("a die at 100 C forces every fan to Auto until it is below 90 C")
func governorInterlock() {
    let hardware = InMemoryFanHardware.macBookPro()
    let (governor, _) = makeGovernor(hardware: hardware, interlockKeys: ["Tp01"])
    hardware.setTemperature(60, forKey: "Tp01")
    governor.setMode(.constant(rpm: 3000), forFan: 0, now: 0)
    governor.setMode(.constant(rpm: 3200), forFan: 1, now: 0)
    #expect(hardware.fans[0].manual == true)

    hardware.setTemperature(100, forKey: "Tp01")
    governor.tick(now: 2)
    #expect(hardware.fans[0].manual == false)
    #expect(hardware.fans[1].manual == false)
    #expect(governor.snapshot().interlockEngaged == true)
    // The wish is kept, so the fans come back by themselves.
    #expect(governor.snapshot().fans[0].mode == .constant(rpm: 3000))

    hardware.setTemperature(92, forKey: "Tp01")
    governor.tick(now: 4)
    #expect(hardware.fans[0].manual == false)

    hardware.setTemperature(89, forKey: "Tp01")
    governor.tick(now: 6)
    #expect(governor.snapshot().interlockEngaged == false)
    #expect(hardware.fans[0].target == 3000)
    #expect(hardware.fans[1].target == 3200)
}

@Test("restoring all fans clears every mode and every setpoint")
func governorRestoreAll() {
    let hardware = InMemoryFanHardware.macBookPro()
    let (governor, _) = makeGovernor(hardware: hardware)
    governor.setMode(.constant(rpm: 3000), forFan: 0, now: 0)
    governor.setMode(.constant(rpm: 4000), forFan: 1, now: 0)

    governor.restoreAllAuto()

    #expect(hardware.fans.allSatisfy { !$0.manual && $0.target == 0 })
    #expect(governor.isActive == false)
    #expect(governor.snapshot().isAllAuto)
    #expect(governor.desiredModes.isEmpty)
}

@Test("sleep parks the fans and wake writes the modes again")
func governorSuspendAndReapply() {
    let hardware = InMemoryFanHardware.macBookPro()
    let (governor, _) = makeGovernor(hardware: hardware)
    governor.setMode(.constant(rpm: 3000), forFan: 0, now: 0)

    governor.suspend()
    #expect(hardware.fans[0].manual == false)
    // The wish survives, which is what the wake path re-applies.
    #expect(governor.desiredModes[0] == .constant(rpm: 3000))
    #expect(governor.isActive == true)

    // The 2 s timer keeps firing until the machine is asleep.
    governor.tick(now: 2)
    #expect(hardware.fans[0].manual == false)

    governor.reapplyDesired(now: 10)
    #expect(hardware.fans[0].manual == true)
    #expect(hardware.fans[0].target == 3000)
}

@Test("a fan the SMC will not describe is not written to")
func governorReadFailure() {
    let hardware = InMemoryFanHardware.macBookPro()
    let (governor, _) = makeGovernor(hardware: hardware)
    hardware.failReadFans("the SMC is not answering")
    hardware.clearCalls()

    // Nothing was written, and the reply says why instead of claiming success.
    #expect(governor.setMode(.constant(rpm: 3000), forFan: 0, now: 0) == "the SMC is not answering")

    #expect(hardware.calls == [.readFans])
    #expect(governor.snapshot().readError == "the SMC is not answering")
}

@Test("the snapshot names the fans the way the UI shows them")
func governorSnapshotNames() {
    let (governor, _) = makeGovernor()
    let snapshot = governor.snapshot()
    #expect(snapshot.fans.map(\.name) == ["Left fan", "Right fan"])
    #expect(snapshot.fans[0].minimumRPM == 1200)
    #expect(snapshot.fans[1].maximumRPM == 6241)
}

@Test("a snapshot survives the trip through JSON")
func snapshotRoundTrip() throws {
    let (governor, _) = makeGovernor()
    governor.setMode(.curve(sensorKey: "Tp01", startTemp: 45, maxTemp: 85), forFan: 0, now: 0)
    let snapshot = governor.snapshot()
    let data = try #require(snapshot.jsonData)
    #expect(FanSnapshot(json: data) == snapshot)

    let mode = FanMode.curve(sensorKey: "Tp01", startTemp: 45, maxTemp: 85)
    let modeData = try #require(mode.jsonData)
    #expect(FanMode(json: modeData) == mode)
    #expect(FanMode(json: Data("not json".utf8)) == nil)
}

@Test("a restore during a sleep does not leave the governor suspended")
func governorRestoreClearsSuspension() {
    let hardware = InMemoryFanHardware.macBookPro()
    let (governor, _) = makeGovernor(hardware: hardware)
    governor.setMode(.constant(rpm: 3000), forFan: 0, now: 0)
    governor.suspend()
    governor.restoreAllAuto()

    governor.setMode(.constant(rpm: 2500), forFan: 0, now: 20)
    #expect(hardware.fans[0].manual == true)
    #expect(hardware.fans[0].target == 2500)
}

@Test("a curve holds the fan off below its start temperature")
func governorCurveBelowStart() {
    let hardware = InMemoryFanHardware.macBookPro()
    hardware.setTemperature(50, forKey: "Tp01")
    let (governor, _) = makeGovernor(hardware: hardware)

    governor.setMode(.curve(sensorKey: "Tp01", startTemp: 60, maxTemp: 85), forFan: 0, now: 0)
    #expect(hardware.fans[0].manual == true)
    #expect(hardware.fans[0].target == 0)
    #expect(governor.isActive == true)
    let snapshot = governor.snapshot()
    #expect(snapshot.fans[0].mode == .curve(sensorKey: "Tp01", startTemp: 60, maxTemp: 85))
    #expect(snapshot.fans[0].sensorCelsius == 50)
    #expect(snapshot.fault(forFan: 0) == nil)

    // Idle below the start reads the sensor and writes nothing.
    hardware.clearCalls()
    governor.tick(now: 2)
    #expect(hardware.calls == [.readFans, .readTemperature("Tp01")])
}

@Test("a curve starts the fan at its start and stops it a little below it")
func governorCurveReleaseBand() {
    let hardware = InMemoryFanHardware.macBookPro()
    hardware.setTemperature(50, forKey: "Tp01")
    let (governor, _) = makeGovernor(hardware: hardware)
    governor.setMode(.curve(sensorKey: "Tp01", startTemp: 60, maxTemp: 85), forFan: 0, now: 0)

    hardware.setTemperature(60, forKey: "Tp01")
    governor.tick(now: 2)
    #expect(hardware.fans[0].manual == true)
    #expect(hardware.fans[0].target == 1200)

    // Inside the release band the fan keeps spinning.
    hardware.setTemperature(59, forKey: "Tp01")
    governor.tick(now: 4)
    #expect(hardware.fans[0].target == 1200)

    hardware.setTemperature(Double(60) - Fans.curveReleaseCelsius, forKey: "Tp01")
    governor.tick(now: 6)
    #expect(hardware.fans[0].manual == true)
    #expect(hardware.fans[0].target == 0)

    // Back above the start the ramp applies again, at once.
    hardware.setTemperature(70, forKey: "Tp01")
    governor.tick(now: 8)
    #expect(hardware.fans[0].manual == true)
    #expect(abs(hardware.fans[0].target - (1200 + (5779 - 1200) * 10 / 25)) < 0.5)
}

@Test("a wake lifts the sleep hold even when the wish went away during the sleep")
func governorWakeAfterWishDropped() {
    let hardware = InMemoryFanHardware.macBookPro()
    hardware.setTemperature(70, forKey: "Tp01")
    let (governor, _) = makeGovernor(hardware: hardware)
    governor.setMode(.curve(sensorKey: "Tp01", startTemp: 45, maxTemp: 85), forFan: 0, now: 0)
    governor.suspend()

    // A client sets Auto during a dark wake. Nothing is desired any more.
    governor.setMode(.auto, forFan: 0, now: 2)
    #expect(governor.desiredModes.isEmpty)

    // The wake path with nothing desired writes nothing, and ends the hold.
    hardware.clearCalls()
    governor.reapplyDesired(now: 10)
    #expect(hardware.calls == [.readFans])

    governor.setMode(.constant(rpm: 2500), forFan: 0, now: 12)
    #expect(hardware.fans[0].manual == true)
    #expect(hardware.fans[0].target == 2500)
}

@Test("the fake fans stand still in Auto, like Apple silicon at idle")
func fakeFansIdleAtZero() {
    let hardware = InMemoryFanHardware.macBookPro()
    #expect(hardware.fans.allSatisfy { $0.actual == 0 })

    try? hardware.setManual(fan: 0, rpm: 2400)
    hardware.advance(seconds: 2)
    #expect(hardware.fans[0].actual == 1200)
    #expect(hardware.fans[1].actual == 0)

    try? hardware.setAuto(fan: 0)
    hardware.advance(seconds: 4)
    #expect(hardware.fans[0].actual == 0)
}
