import Foundation
import Testing

/// How fast the fan glyph in the menu bar turns, and every reason it stands
/// still. The source file under test is compiled into this bundle.
@Suite("Fan spin")
struct FanSpinTests {
    /// An M1 Pro: two fans, 1200 to 4200 rpm.
    private func conditions(rpm: Double?) -> FanSpinConditions {
        FanSpinConditions(rpm: rpm, minimumRPM: 1200, maximumRPM: 4200)
    }

    // MARK: - The mapping

    @Test("The slowest speed the fan reports is one revolution in three seconds")
    func slowest() {
        #expect(FanSpin.secondsPerRevolution(rpm: 1200, minimum: 1200, maximum: 4200) == FanSpin.slowestSeconds)
    }

    @Test("The fastest is one revolution in half a second")
    func fastest() {
        #expect(FanSpin.secondsPerRevolution(rpm: 4200, minimum: 1200, maximum: 4200) == FanSpin.fastestSeconds)
    }

    @Test("In between it is linear")
    func linear() {
        let middle = FanSpin.secondsPerRevolution(rpm: 2700, minimum: 1200, maximum: 4200)
        #expect(middle != nil)
        #expect(abs((middle ?? 0) - 2.75) < 0.0001)
    }

    @Test("Outside the limits it is clamped, never inverted")
    func clamped() {
        #expect(FanSpin.secondsPerRevolution(rpm: 400, minimum: 1200, maximum: 4200) == FanSpin.slowestSeconds)
        #expect(FanSpin.secondsPerRevolution(rpm: 9000, minimum: 1200, maximum: 4200) == FanSpin.fastestSeconds)
    }

    @Test("A fan at rest stands still")
    func standstill() {
        #expect(FanSpin.secondsPerRevolution(rpm: 0, minimum: 1200, maximum: 4200) == nil)
        #expect(FanSpin.secondsPerRevolution(rpm: -1, minimum: 1200, maximum: 4200) == nil)
        #expect(FanSpin.secondsPerRevolution(rpm: .nan, minimum: 1200, maximum: 4200) == nil)
    }

    @Test("Limits that say nothing fall back to the slowest turn")
    func uselessLimits() {
        #expect(FanSpin.secondsPerRevolution(rpm: 2000, minimum: 0, maximum: 0) == FanSpin.slowestSeconds)
        #expect(FanSpin.secondsPerRevolution(rpm: 2000, minimum: 4200, maximum: 1200) == FanSpin.slowestSeconds)
    }

    // MARK: - Every reason to stand still

    @Test("It turns with the fans and with nothing else")
    func turns() {
        #expect(FanSpin.secondsPerRevolution(conditions(rpm: 4200)) == FanSpin.fastestSeconds)
        #expect(FanSpin.secondsPerRevolution(conditions(rpm: 0)) == nil)
        #expect(FanSpin.secondsPerRevolution(conditions(rpm: nil)) == nil)
    }

    @Test("Each stop rule stops it on its own")
    func stopRules() {
        let stops: [(String, (inout FanSpinConditions) -> Void)] = [
            ("the setting is off", { $0.spinEnabled = false }),
            ("reduce motion", { $0.reduceMotion = true }),
            ("no glyph in the label", { $0.showsIcon = false }),
            ("the label is off screen", { $0.labelOnScreen = false }),
            ("the Mac sleeps", { $0.systemAsleep = true }),
            ("low power mode", { $0.lowPowerMode = true }),
        ]
        for (reason, apply) in stops {
            var conditions = conditions(rpm: 3000)
            apply(&conditions)
            #expect(FanSpin.secondsPerRevolution(conditions) == nil, "\(reason) has to stop the glyph")
        }
    }

    // MARK: - Re-issuing the animation

    @Test("Starting and stopping always replace the animation")
    func startAndStop() {
        #expect(FanSpin.reissues(current: nil, next: 1.5))
        #expect(FanSpin.reissues(current: 1.5, next: nil))
        #expect(!FanSpin.reissues(current: nil, next: nil))
    }

    @Test("A speed that wanders by less than a tenth is left alone")
    func smallChange() {
        #expect(!FanSpin.reissues(current: 1.0, next: 1.05))
        #expect(!FanSpin.reissues(current: 1.0, next: 0.96))
        #expect(!FanSpin.reissues(current: 1.0, next: 1.1))
        #expect(!FanSpin.reissues(current: 1.0, next: 1.0))
    }

    @Test("A speed that moves by more than a tenth replaces it")
    func largeChange() {
        #expect(FanSpin.reissues(current: 1.0, next: 1.11))
        #expect(FanSpin.reissues(current: 1.0, next: 0.5))
        #expect(FanSpin.reissues(current: 3.0, next: 0.5))
    }

    @Test("The rule reads the same on the period and on the speed")
    func symmetric() {
        // 20 rpm on a fan that runs at 2000 is far under the tolerance, in
        // either direction.
        let slow = FanSpin.secondsPerRevolution(rpm: 2000, minimum: 1200, maximum: 4200)
        let wandered = FanSpin.secondsPerRevolution(rpm: 2020, minimum: 1200, maximum: 4200)
        #expect(!FanSpin.reissues(current: slow, next: wandered))
        #expect(!FanSpin.reissues(current: wandered, next: slow))
        // 600 rpm is not.
        let faster = FanSpin.secondsPerRevolution(rpm: 2600, minimum: 1200, maximum: 4200)
        #expect(FanSpin.reissues(current: slow, next: faster))
        #expect(FanSpin.reissues(current: faster, next: slow))
    }

    @Test("A step never reaches the 45 degrees at which four blades stop reading as turning")
    func stepAngle() {
        for seconds in [FanSpin.fastestSeconds, 2.0, FanSpin.slowestSeconds] {
            let steps = FanSpin.steps(secondsPerRevolution: seconds)
            #expect(360.0 / Double(steps) <= 30.0001)
        }
        #expect(FanSpin.steps(secondsPerRevolution: 0.1) == 8)
    }
}
