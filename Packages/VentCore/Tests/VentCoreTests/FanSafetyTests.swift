import Testing

import FanControl

@Test("a request outside the limits is clamped to them")
func clampToLimits() {
    #expect(FanSafety.clamp(99_999, minimum: 1200, maximum: 5782) == 5782)
    #expect(FanSafety.clamp(-500, minimum: 1200, maximum: 5782) == 1200)
    #expect(FanSafety.clamp(0, minimum: 1200, maximum: 5782) == 1200)
    #expect(FanSafety.clamp(2500, minimum: 1200, maximum: 5782) == 2500)
    #expect(FanSafety.clamp(1200, minimum: 1200, maximum: 5782) == 1200)
    #expect(FanSafety.clamp(5782, minimum: 1200, maximum: 5782) == 5782)
}

/// A range that is not a range would otherwise clamp every request to 0 and
/// stop the fan.
@Test("a range the firmware did not give is refused")
func clampRefusesDegenerateRange() {
    #expect(FanSafety.clamp(2500, minimum: 0, maximum: 0) == nil)
    #expect(FanSafety.clamp(2500, minimum: 5000, maximum: 1200) == nil)
    #expect(FanSafety.clamp(.nan, minimum: 1200, maximum: 5782) == nil)
    #expect(FanSafety.clamp(2500, minimum: 1200, maximum: .nan) == nil)
}

@Test("the interlock trips at 100 C and holds until 90 C")
func interlockHysteresis() {
    var interlock = ThermalInterlock()
    #expect(interlock.update(hottestDie: 99.9) == false)
    #expect(interlock.update(hottestDie: 100) == true)
    // Still engaged all the way down to the release threshold.
    #expect(interlock.update(hottestDie: 95) == true)
    #expect(interlock.update(hottestDie: 90) == true)
    #expect(interlock.update(hottestDie: 89.9) == false)
}

/// Neither tripping nor releasing is safe when no die answered, so the state
/// is kept.
@Test("a missing die reading leaves the interlock where it is")
func interlockKeepsStateWithoutReading() {
    var interlock = ThermalInterlock()
    #expect(interlock.update(hottestDie: 101) == true)
    #expect(interlock.update(hottestDie: nil) == true)
    #expect(interlock.update(hottestDie: .nan) == true)
    #expect(interlock.update(hottestDie: 50) == false)
    #expect(interlock.update(hottestDie: nil) == false)
}

@Test("a falling temperature is followed only after half a degree")
func hysteresisOnTheWayDown() {
    var smoother = FanSmoother()
    #expect(smoother.temperature(60) == 60)
    // Noise below the threshold keeps the held value.
    #expect(smoother.temperature(59.9) == 60)
    #expect(smoother.temperature(59.6) == 60)
    // Half a degree exactly is a real fall.
    #expect(smoother.temperature(59.5) == 59.5)
    #expect(smoother.temperature(59.2) == 59.5)
    // A rise is followed at once, however small.
    #expect(smoother.temperature(59.6) == 59.6)
    #expect(smoother.temperature(80) == 80)
}

@Test("the setpoint moves no faster than 200 rpm per second")
func slewLimit() {
    var smoother = FanSmoother()
    // The first call has nothing to ramp from: the fan was on the firmware
    // curve until now.
    #expect(smoother.slew(toward: 2000, now: 100) == 2000)
    // Two seconds, so 400 rpm.
    #expect(smoother.slew(toward: 5000, now: 102) == 2400)
    #expect(smoother.slew(toward: 5000, now: 104) == 2800)
    // Downwards the limit is the same.
    #expect(smoother.slew(toward: 1200, now: 106) == 2400)
    // A step inside the limit arrives in one go.
    #expect(smoother.slew(toward: 2300, now: 107) == 2300)
}

@Test("a clock that did not move cannot move the fan")
func slewWithoutTime() {
    var smoother = FanSmoother()
    #expect(smoother.slew(toward: 2000, now: 10) == 2000)
    #expect(smoother.slew(toward: 5000, now: 10) == 2000)
}
