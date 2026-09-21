import Foundation
import Testing

/// When the temperature in the menu bar label turns amber, orange and red.
///
/// The source file under test is compiled into this bundle (see `project.yml`),
/// so the app and the tests share one copy of the rule.
@Suite("Heat tint")
struct HeatTintTests {
    // MARK: - The thresholds

    @Test("Below 70 C nothing is tinted")
    func normalRange() {
        #expect(HeatTint.level(celsius: 0) == .normal)
        #expect(HeatTint.level(celsius: 45.2) == .normal)
        #expect(HeatTint.level(celsius: 69.9) == .normal)
    }

    @Test("Every threshold is inclusive, to the tenth below it")
    func boundaries() {
        #expect(HeatTint.level(celsius: 69.99) == .normal)
        #expect(HeatTint.level(celsius: 70) == .warm)
        #expect(HeatTint.level(celsius: 79.99) == .warm)
        #expect(HeatTint.level(celsius: 80) == .hot)
        #expect(HeatTint.level(celsius: 89.99) == .hot)
        #expect(HeatTint.level(celsius: 90) == .critical)
        #expect(HeatTint.level(celsius: 105) == .critical)
    }

    @Test("A reading that is not a number is not hot")
    func notANumber() {
        // A sensor that answers NaN or infinity is a sensor that is not
        // answering; a red menu bar is the wrong way to say so.
        #expect(HeatTint.level(celsius: .nan) == .normal)
        #expect(HeatTint.level(celsius: .infinity) == .normal)
        #expect(HeatTint.level(celsius: .nan, previous: .critical) == .normal)
    }

    @Test("Only the normal level is untinted")
    func tinted() {
        #expect(!HeatLevel.normal.isTinted)
        #expect(HeatLevel.warm.isTinted)
        #expect(HeatLevel.hot.isTinted)
        #expect(HeatLevel.critical.isTinted)
        #expect(HeatLevel.normal < HeatLevel.warm)
        #expect(HeatLevel.hot < HeatLevel.critical)
    }

    // MARK: - The hysteresis

    @Test("Heat rises the moment the threshold is reached")
    func risesAtOnce() {
        #expect(HeatTint.level(celsius: 70, previous: .normal) == .warm)
        #expect(HeatTint.level(celsius: 80, previous: .warm) == .hot)
        #expect(HeatTint.level(celsius: 90, previous: .hot) == .critical)
        // And all the way up in one step, which is what a sudden load does.
        #expect(HeatTint.level(celsius: 92, previous: .normal) == .critical)
    }

    @Test("A value that hovers at the threshold does not flicker")
    func hovering() {
        var level = HeatLevel.normal
        // The die sits at 70 and jitters by a degree, once a second.
        for celsius in [70.0, 69.4, 70.2, 69.1, 70.5, 68.7, 70.0] {
            level = HeatTint.level(celsius: celsius, previous: level)
            #expect(level == .warm)
        }
    }

    @Test("The colour goes back two degrees under the threshold that raised it")
    func fallsAfterHysteresis() {
        #expect(HeatTint.level(celsius: 68.1, previous: .warm) == .warm)
        #expect(HeatTint.level(celsius: 68, previous: .warm) == .warm)
        #expect(HeatTint.level(celsius: 67.99, previous: .warm) == .normal)

        #expect(HeatTint.level(celsius: 78, previous: .hot) == .hot)
        #expect(HeatTint.level(celsius: 77.9, previous: .hot) == .warm)

        #expect(HeatTint.level(celsius: 88, previous: .critical) == .critical)
        #expect(HeatTint.level(celsius: 87.9, previous: .critical) == .hot)
    }

    @Test("A fan that catches up drops several steps at once")
    func fallsThroughSeveralSteps() {
        #expect(HeatTint.level(celsius: 40, previous: .critical) == .normal)
        #expect(HeatTint.level(celsius: 72, previous: .critical) == .warm)
        // It falls through the guard band of every step, not past them: 79 is
        // under red's band (88) but still inside orange's (78), so a die on
        // its way down from 95 holds orange there. On the way up 79 is amber.
        #expect(HeatTint.level(celsius: 79, previous: .critical) == .hot)
        #expect(HeatTint.level(celsius: 79, previous: .normal) == .warm)
        #expect(HeatTint.level(celsius: 77.9, previous: .critical) == .warm)
    }

    @Test("The hysteresis never holds a colour above the one the value has")
    func neverRaises() {
        for tenth in stride(from: 300, through: 1100, by: 1) {
            let celsius = Double(tenth) / 10
            for previous in HeatLevel.allCases {
                let level = HeatTint.level(celsius: celsius, previous: previous)
                #expect(level <= max(previous, HeatTint.level(celsius: celsius)))
                #expect(level >= HeatTint.level(celsius: celsius))
            }
        }
    }
}
