import CoreGraphics
import Foundation
import Testing

import WindowKit

private let start = Date(timeIntervalSince1970: 1_700_000_000)

private func press(
    _ ladder: inout CycleLadder,
    _ action: WindowAction,
    current: CGRect?,
    after seconds: TimeInterval
) -> CGRect? {
    ladder.resolve(
        action: action,
        on: Screens.builtIn,
        current: current,
        gap: 0,
        now: start.addingTimeInterval(seconds)
    )
}

@Test("a left half pressed three times walks 1/2, 2/3, 1/3")
func leftHalfLadder() throws {
    var ladder = CycleLadder()
    let half = try #require(press(&ladder, .leftHalf, current: sampleWindow, after: 0))
    #expect(half == rect(0, 0, 756, 949))
    let twoThirds = try #require(press(&ladder, .leftHalf, current: half, after: 0.5))
    #expect(twoThirds == rect(0, 0, 1008, 949))
    let third = try #require(press(&ladder, .leftHalf, current: twoThirds, after: 1))
    #expect(third == rect(0, 0, 504, 949))
    let again = try #require(press(&ladder, .leftHalf, current: third, after: 1.5))
    #expect(again == half)
}

@Test("the right half walks the same ladder on its own side")
func rightHalfLadder() throws {
    var ladder = CycleLadder()
    let half = try #require(press(&ladder, .rightHalf, current: sampleWindow, after: 0))
    #expect(half == rect(756, 0, 756, 949))
    let twoThirds = try #require(press(&ladder, .rightHalf, current: half, after: 0.5))
    #expect(twoThirds == rect(504, 0, 1008, 949))
    let third = try #require(press(&ladder, .rightHalf, current: twoThirds, after: 1))
    #expect(third == rect(1008, 0, 504, 949))
}

@Test("the top half walks down the vertical axis")
func topHalfLadder() throws {
    var ladder = CycleLadder()
    let half = try #require(press(&ladder, .topHalf, current: sampleWindow, after: 0))
    #expect(half == rect(0, 475, 1512, 474))
    // Two thirds of the height, measured from the top.
    let twoThirds = try #require(press(&ladder, .topHalf, current: half, after: 0.5))
    #expect(twoThirds == rect(0, 316, 1512, 633))
    let third = try #require(press(&ladder, .topHalf, current: twoThirds, after: 1))
    #expect(third == rect(0, 633, 1512, 316))
}

@Test("the bottom half walks up the vertical axis")
func bottomHalfLadder() throws {
    var ladder = CycleLadder()
    let half = try #require(press(&ladder, .bottomHalf, current: sampleWindow, after: 0))
    #expect(half == rect(0, 0, 1512, 475))
    let twoThirds = try #require(press(&ladder, .bottomHalf, current: half, after: 0.5))
    #expect(twoThirds == rect(0, 0, 1512, 633))
    let third = try #require(press(&ladder, .bottomHalf, current: twoThirds, after: 1))
    #expect(third == rect(0, 0, 1512, 316))
}

@Test("thirds walk first, center, last")
func thirdsLadder() throws {
    var ladder = CycleLadder()
    let first = try #require(press(&ladder, .firstThird, current: sampleWindow, after: 0))
    #expect(first == rect(0, 0, 504, 949))
    let center = try #require(press(&ladder, .firstThird, current: first, after: 0.5))
    #expect(center == rect(504, 0, 504, 949))
    let last = try #require(press(&ladder, .firstThird, current: center, after: 1))
    #expect(last == rect(1008, 0, 504, 949))
    let around = try #require(press(&ladder, .firstThird, current: last, after: 1.5))
    #expect(around == first)
}

@Test("the center third starts where it was pressed")
func centerThirdLadder() throws {
    var ladder = CycleLadder()
    let center = try #require(press(&ladder, .centerThird, current: sampleWindow, after: 0))
    #expect(center == rect(504, 0, 504, 949))
    let last = try #require(press(&ladder, .centerThird, current: center, after: 0.5))
    #expect(last == rect(1008, 0, 504, 949))
    let first = try #require(press(&ladder, .centerThird, current: last, after: 1))
    #expect(first == rect(0, 0, 504, 949))
}

@Test("the last third starts at the last third")
func lastThirdLadder() throws {
    var ladder = CycleLadder()
    let last = try #require(press(&ladder, .lastThird, current: sampleWindow, after: 0))
    #expect(last == rect(1008, 0, 504, 949))
    let first = try #require(press(&ladder, .lastThird, current: last, after: 0.5))
    #expect(first == rect(0, 0, 504, 949))
}

@Test("two seconds later the ladder starts over")
func ladderTimesOut() throws {
    var ladder = CycleLadder()
    let half = try #require(press(&ladder, .leftHalf, current: sampleWindow, after: 0))
    // Exactly two seconds is already too late, and so is any longer wait.
    #expect(press(&ladder, .leftHalf, current: half, after: 2) == half)
    #expect(press(&ladder, .leftHalf, current: half, after: 4.5) == half)
    // 1.3 s after the last press, so this one does advance.
    #expect(press(&ladder, .leftHalf, current: half, after: 5.8) == rect(0, 0, 1008, 949))
}

@Test("a window the user moved away starts the ladder over")
func ladderResetsOnExternalMove() throws {
    var ladder = CycleLadder()
    let half = try #require(press(&ladder, .leftHalf, current: sampleWindow, after: 0))
    let moved = half.offsetBy(dx: 40, dy: 0)
    #expect(press(&ladder, .leftHalf, current: moved, after: 0.5) == half)
}

/// The window may come back a point or two off a scaled display, which is not
/// the user moving it.
@Test("a window off by a point or two still counts as ours")
func ladderToleratesTwoPoints() throws {
    var ladder = CycleLadder()
    let half = try #require(press(&ladder, .leftHalf, current: sampleWindow, after: 0))
    let nudged = half.offsetBy(dx: 2, dy: -2)
    #expect(press(&ladder, .leftHalf, current: nudged, after: 0.5) == rect(0, 0, 1008, 949))

    var second = CycleLadder()
    let again = try #require(press(&second, .leftHalf, current: sampleWindow, after: 0))
    #expect(press(&second, .leftHalf, current: again.offsetBy(dx: 3, dy: 0), after: 0.5) == again)
}

@Test("another action starts the ladder over")
func ladderResetsOnOtherAction() throws {
    var ladder = CycleLadder()
    let left = try #require(press(&ladder, .leftHalf, current: sampleWindow, after: 0))
    let right = try #require(press(&ladder, .rightHalf, current: left, after: 0.2))
    #expect(right == rect(756, 0, 756, 949))
    #expect(press(&ladder, .leftHalf, current: right, after: 0.4) == left)
}

@Test("a window with no known frame cannot be a repeat")
func ladderNeedsTheCurrentFrame() throws {
    var ladder = CycleLadder()
    let half = try #require(press(&ladder, .leftHalf, current: sampleWindow, after: 0))
    #expect(press(&ladder, .leftHalf, current: nil, after: 0.5) == half)
}

@Test("the same action on another screen starts the ladder over")
func ladderResetsOnOtherScreen() throws {
    var ladder = CycleLadder()
    let first = ladder.resolve(
        action: .leftHalf,
        on: Screens.builtIn,
        current: sampleWindow,
        now: start
    )
    let half = try #require(first)
    let other = ladder.resolve(
        action: .leftHalf,
        on: Screens.right,
        current: half,
        now: start.addingTimeInterval(0.5)
    )
    #expect(other == rect(1512, 0, 1280, 1415))
    #expect(ladder.state?.slot.span == .half)
}

@Test("an action that does not cycle clears the state")
func nonCyclingActionResets() throws {
    var ladder = CycleLadder()
    _ = press(&ladder, .leftHalf, current: sampleWindow, after: 0)
    #expect(ladder.state != nil)
    let maximized = press(&ladder, .maximize, current: sampleWindow, after: 0.2)
    #expect(maximized == rect(0, 0, 1512, 949))
    #expect(ladder.state == nil)
}

@Test("reset forgets the last press")
func explicitReset() throws {
    var ladder = CycleLadder()
    let half = try #require(press(&ladder, .leftHalf, current: sampleWindow, after: 0))
    ladder.reset()
    #expect(press(&ladder, .leftHalf, current: half, after: 0.5) == half)
}

@Test("the clock running backwards does not advance the ladder")
func ladderIgnoresTimeGoingBackwards() throws {
    var ladder = CycleLadder()
    let half = try #require(press(&ladder, .leftHalf, current: sampleWindow, after: 10))
    #expect(press(&ladder, .leftHalf, current: half, after: 9) == half)
}

@Test("the ladder keeps the gap between the rungs")
func ladderWithGap() throws {
    var ladder = CycleLadder()
    let first = ladder.resolve(
        action: .leftHalf,
        on: Screens.builtIn,
        current: sampleWindow,
        gap: 8,
        now: start
    )
    let half = try #require(first)
    #expect(half == rect(8, 8, 744, 933))
    let twoThirds = ladder.resolve(
        action: .leftHalf,
        on: Screens.builtIn,
        current: half,
        gap: 8,
        now: start.addingTimeInterval(0.5)
    )
    #expect(twoThirds == rect(8, 8, 993, 933))
}

@Test("on a portrait screen the thirds ladder runs down the screen")
func ladderOnPortrait() throws {
    var ladder = CycleLadder()
    let first = ladder.resolve(
        action: .firstThird,
        on: Screens.portrait,
        current: sampleWindow,
        now: start
    )
    #expect(first == rect(0, 1280, 1080, 640))
    #expect(ladder.state?.slot.axis == .vertical)
}

/// A window with a minimum size refuses the narrow rungs of the ladder. The
/// mover tells the ladder where the window really landed, so the next press
/// still counts as a repeat instead of starting over.
@Test("the ladder follows a window that refused to shrink")
func ladderRemembersTheAppliedFrame() throws {
    var ladder = CycleLadder()
    let half = try #require(press(&ladder, .leftHalf, current: sampleWindow, after: 0))
    let twoThirds = try #require(press(&ladder, .leftHalf, current: half, after: 0.5))
    // The app refused anything under 800 pt wide, so the two thirds rung is
    // 800 pt wide and not the 1008 pt it was given.
    let applied = rect(0, 0, 800, 949)
    #expect(twoThirds != applied)
    ladder.rememberApplied(frame: applied)
    #expect(ladder.state?.frame == applied)
    #expect(ladder.state?.slot.span == .twoThirds)
    // The third rung, from a window that is where the mover left it.
    #expect(press(&ladder, .leftHalf, current: applied, after: 1) == rect(0, 0, 504, 949))
}

@Test("remembering an applied frame does nothing without a state")
func rememberAppliedNeedsAState() {
    var ladder = CycleLadder()
    ladder.rememberApplied(frame: rect(0, 0, 100, 100))
    #expect(ladder.state == nil)
}
