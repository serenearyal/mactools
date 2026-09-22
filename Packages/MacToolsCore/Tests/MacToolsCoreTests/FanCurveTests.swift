import Testing

import FanControl

/// The boundary matrix of the ramp. Every one of these has a way of going
/// wrong that ends with a fan at the wrong speed, so they are all spelled out.
@Test(
    "the curve holds at its ends and is linear in between",
    arguments: [
        // temperature, expected
        (0.0, 1200.0),      // far below the start
        (44.9, 1200.0),     // just below the start
        (45.0, 1200.0),     // at the start
        (55.0, 2345.5),     // a quarter up
        (65.0, 3491.0),     // the midpoint
        (85.0, 5782.0),     // at the maximum
        (99.0, 5782.0),     // above the maximum
        (300.0, 5782.0),    // nonsense, still clamped
    ]
)
func curveMatrix(temperature: Double, expected: Double) {
    let value = FanCurve.targetRPM(temp: temperature, min: 1200, max: 5782, start: 45, maxTemp: 85)
    #expect(value != nil)
    #expect(abs((value ?? 0) - expected) < 0.001)
}

@Test("an equal start and maximum is a step at that temperature")
func curveStep() {
    func rpm(_ temp: Double) -> Double? {
        FanCurve.targetRPM(temp: temp, min: 1200, max: 5000, start: 60, maxTemp: 60)
    }
    #expect(rpm(59.9) == 1200)
    #expect(rpm(60) == 5000)
    #expect(rpm(60.1) == 5000)
}

@Test("an inverted temperature range is refused")
func curveInvertedTemperatures() {
    #expect(FanCurve.targetRPM(temp: 70, min: 1200, max: 5000, start: 85, maxTemp: 45) == nil)
}

@Test("an inverted or empty speed range is refused")
func curveInvertedSpeeds() {
    #expect(FanCurve.targetRPM(temp: 70, min: 5000, max: 1200, start: 45, maxTemp: 85) == nil)
    // A fan whose Mn/Mx keys did not answer reads 0/0 here.
    #expect(FanCurve.targetRPM(temp: 70, min: 0, max: 0, start: 45, maxTemp: 85) == nil)
    #expect(FanCurve.targetRPM(temp: 70, min: -100, max: 5000, start: 45, maxTemp: 85) == nil)
}

/// Fail safe: a NaN anywhere gives nil, never a speed. The governor turns that
/// into Auto plus a fault.
@Test("a value that is not a number is refused, never guessed")
func curveNaN() {
    #expect(FanCurve.targetRPM(temp: .nan, min: 1200, max: 5000, start: 45, maxTemp: 85) == nil)
    #expect(FanCurve.targetRPM(temp: 70, min: .nan, max: 5000, start: 45, maxTemp: 85) == nil)
    #expect(FanCurve.targetRPM(temp: 70, min: 1200, max: .nan, start: 45, maxTemp: 85) == nil)
    #expect(FanCurve.targetRPM(temp: 70, min: 1200, max: 5000, start: .nan, maxTemp: 85) == nil)
    #expect(FanCurve.targetRPM(temp: 70, min: 1200, max: 5000, start: 45, maxTemp: .nan) == nil)
    #expect(FanCurve.targetRPM(temp: .infinity, min: 1200, max: 5000, start: 45, maxTemp: 85) == nil)
}

@Test("a curve holds a fan from its start and lets go below the release band")
func curveHoldsFan() {
    #expect(FanCurve.holdsFan(temp: 59.9, start: 60, wasHolding: false) == false)
    #expect(FanCurve.holdsFan(temp: 60, start: 60, wasHolding: false) == true)
    #expect(FanCurve.holdsFan(temp: 58.5, start: 60, wasHolding: true) == true)
    #expect(FanCurve.holdsFan(temp: 60 - Fans.curveReleaseCelsius, start: 60, wasHolding: true) == false)
}
