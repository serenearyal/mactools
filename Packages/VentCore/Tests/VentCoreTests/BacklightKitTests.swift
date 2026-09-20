import Foundation
import Testing

import BacklightKit

@Test("the ladder has seventeen rungs from 0 to 1")
func backlightLadder() {
    #expect(BacklightScale.steps == 16)
    #expect(BacklightScale.levels.count == 17)
    #expect(BacklightScale.levels.first == 0)
    #expect(BacklightScale.levels.last == 1)
    #expect(BacklightScale.levels[1] == 0.0625)
}

@Test(
    "a rung is asked for by its number",
    arguments: [(0, 0.0), (1, 0.0625), (8, 0.5), (16, 1.0), (-3, 0.0), (99, 1.0)]
)
func backlightLevelAtIndex(index: Int, level: Double) {
    #expect(BacklightScale.level(at: index) == level)
}

@Test(
    "an arbitrary value finds its nearest rung",
    arguments: [(0.0, 0), (0.03, 0), (0.04, 1), (0.06, 1), (0.5, 8), (0.97, 16), (1.0, 16)]
)
func backlightNearestIndex(value: Double, index: Int) {
    #expect(BacklightScale.index(for: value) == index)
}

/// The value the framework reports on this Mac is 0.06, which is the first
/// rung read back with a rounding error. One press of the key has to move one
/// rung from there, not two and not none.
@Test(
    "the key moves exactly one rung up",
    arguments: [
        (0.0, 0.0625),
        (0.06, 0.0625),
        (0.0625, 0.125),
        (0.5, 0.5625),
        (0.9375, 1.0),
        (0.99, 1.0),
        (1.0, 1.0),
    ]
)
func backlightNextUp(value: Double, next: Double) {
    #expect(BacklightScale.nextUp(from: value) == next)
}

@Test(
    "the key moves exactly one rung down",
    arguments: [
        (1.0, 0.9375),
        (0.99, 0.9375),
        (0.5, 0.4375),
        (0.0625, 0.0),
        (0.06, 0.0),
        (0.0, 0.0),
    ]
)
func backlightNextDown(value: Double, next: Double) {
    #expect(BacklightScale.nextDown(from: value) == next)
}

@Test("up and down undo each other in the middle of the ladder")
func backlightRoundTrip() {
    for index in 1..<BacklightScale.steps {
        let level = BacklightScale.level(at: index)
        #expect(BacklightScale.nextDown(from: BacklightScale.nextUp(from: level)) == level)
        #expect(BacklightScale.nextUp(from: BacklightScale.nextDown(from: level)) == level)
    }
}

@Test("every rung is reached by pressing the key sixteen times")
func backlightWalksTheWholeLadder() {
    var value = 0.0
    for step in 1...BacklightScale.steps {
        value = BacklightScale.nextUp(from: value)
        #expect(value == BacklightScale.level(at: step))
    }
    #expect(value == 1)
    for step in (0..<BacklightScale.steps).reversed() {
        value = BacklightScale.nextDown(from: value)
        #expect(value == BacklightScale.level(at: step))
    }
    #expect(value == 0)
}

@Test(
    "a value out of range, or none at all, is clamped",
    arguments: [
        (-1.0, 0.0),
        (0.0, 0.0),
        (0.5, 0.5),
        (1.0, 1.0),
        (2.0, 1.0),
        (Double.nan, 0.0),
        (Double.infinity, 1.0),
        (-Double.infinity, 0.0),
    ]
)
func backlightClamp(value: Double, clamped: Double) {
    #expect(BacklightScale.clamp(value) == clamped)
}

@Test("a value that is not a number does not break the ladder")
func backlightSurvivesNonsense() {
    #expect(BacklightScale.nextUp(from: .nan) == 0.0625)
    #expect(BacklightScale.nextDown(from: .nan) == 0)
    #expect(BacklightScale.index(for: .nan) == 0)
    #expect(BacklightScale.percentText(.nan) == "0%")
}

@Test(
    "the percent is whole",
    arguments: [(0.0, "0%"), (0.0625, "6%"), (0.5, "50%"), (0.9375, "94%"), (1.0, "100%")]
)
func backlightPercentText(value: Double, text: String) {
    #expect(BacklightScale.percentText(value) == text)
}

// MARK: - Availability

@Test("a keyboard that answered is available")
func backlightAvailable() {
    let availability = BacklightAvailability.available(ids: [95_159_106])
    #expect(availability.isAvailable)
    #expect(availability.keyboardIDs == [95_159_106])
    #expect(availability.reason == nil)
}

@Test("no keyboard is not an availability")
func backlightWithoutAKeyboard() {
    let availability = BacklightAvailability.available(ids: [])
    #expect(availability.isAvailable == false)
    #expect(availability.reason == .noKeyboard)
    #expect(availability.keyboardIDs.isEmpty)
}

@Test("every reason tells the user something", arguments: BacklightAvailability.Reason.allCases)
func backlightReasons(reason: BacklightAvailability.Reason) {
    let availability = BacklightAvailability.unavailable(reason: reason)
    #expect(availability.isAvailable == false)
    #expect(availability.reason == reason)
    #expect(reason.message.isEmpty == false)
    #expect(reason.message.hasSuffix("."))
}

@Test("the reasons are stored as their names")
func backlightReasonRawValues() {
    #expect(BacklightAvailability.Reason.frameworkMissing.rawValue == "frameworkMissing")
    #expect(BacklightAvailability.Reason.allCases.count == 4)
}
