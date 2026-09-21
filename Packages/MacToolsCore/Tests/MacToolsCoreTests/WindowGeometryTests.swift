import CoreGraphics
import Testing

import WindowKit

// MARK: - Larger and smaller

private let visible = Screens.builtIn.visibleFrame

@Test("larger grows by the step on both axes and keeps the centre")
func largerGrows() throws {
    let frame = rect(100, 100, 800, 600)
    let grown = try #require(ResizeStep.larger(frame: frame, in: visible))
    #expect(grown == rect(85, 85, 830, 630))
    #expect(grown.midX == frame.midX)
    #expect(grown.midY == frame.midY)
}

@Test("smaller shrinks by the step and keeps the centre")
func smallerShrinks() throws {
    let frame = rect(100, 100, 800, 600)
    let shrunk = try #require(ResizeStep.smaller(frame: frame, in: visible))
    #expect(shrunk == rect(115, 115, 770, 570))
    #expect(shrunk.midX == frame.midX)
}

@Test("larger and smaller undo each other away from the bounds")
func resizeRoundTrip() throws {
    let frame = rect(100, 100, 800, 600)
    let grown = try #require(ResizeStep.larger(frame: frame, in: visible))
    #expect(ResizeStep.smaller(frame: grown, in: visible) == frame)
}

@Test("larger stops at the visible frame and stays there")
func largerClampsToScreen() throws {
    var frame = rect(0, 0, 1512, 949)
    for _ in 0..<5 {
        frame = try #require(ResizeStep.larger(frame: frame, in: visible))
        #expect(frame == visible)
    }
}

@Test("a window wider than the screen is pulled back inside")
func largerPullsAnOversizedWindowIn() throws {
    let huge = rect(-500, -500, 4000, 3000)
    #expect(ResizeStep.larger(frame: huge, in: visible) == visible)
}

@Test("smaller stops at 200 x 120 and stays there")
func smallerClampsToMinimum() throws {
    var frame = rect(600, 400, 260, 180)
    frame = try #require(ResizeStep.smaller(frame: frame, in: visible))
    #expect(frame.size == CGSize(width: 230, height: 150))
    frame = try #require(ResizeStep.smaller(frame: frame, in: visible))
    #expect(frame.size == CGSize(width: 200, height: 120))
    let atMinimum = try #require(ResizeStep.smaller(frame: frame, in: visible))
    #expect(atMinimum == frame)
}

/// A screen smaller than the minimum window is not a reason to push a window
/// off it.
@Test("a screen below the minimum size lowers the minimum")
func minimumFollowsATinyScreen() throws {
    let tiny = rect(0, 0, 150, 100)
    let frame = try #require(ResizeStep.smaller(frame: rect(0, 0, 150, 100), in: tiny))
    #expect(frame == tiny)
}

@Test("the step can be changed")
func resizeWithOtherStep() throws {
    let frame = rect(100, 100, 800, 600)
    #expect(ResizeStep.larger(frame: frame, in: visible, step: 100) == rect(50, 50, 900, 700))
    #expect(ResizeStep.smaller(frame: frame, in: visible, step: 100) == rect(150, 150, 700, 500))
}

@Test("a negative step still grows for larger and shrinks for smaller")
func resizeIgnoresTheSignOfTheStep() {
    let frame = rect(100, 100, 800, 600)
    #expect(ResizeStep.larger(frame: frame, in: visible, step: -30) == rect(85, 85, 830, 630))
    #expect(ResizeStep.smaller(frame: frame, in: visible, step: -30) == rect(115, 115, 770, 570))
}

@Test("a resize with nonsense input answers with nothing")
func resizeRefusesNonsense() {
    let frame = rect(100, 100, 800, 600)
    #expect(ResizeStep.larger(frame: frame, in: .zero) == nil)
    #expect(ResizeStep.larger(frame: rect(.nan, 0, 800, 600), in: visible) == nil)
    #expect(ResizeStep.larger(frame: frame, in: visible, step: .nan) == nil)
}

@Test("a resize result is whole points")
func resizeResultIsIntegral() throws {
    let frame = rect(100.5, 100.5, 801, 601)
    let grown = try #require(ResizeStep.larger(frame: frame, in: visible))
    #expect(grown.minX == grown.minX.rounded())
    #expect(grown.width == grown.width.rounded())
}

// MARK: - The display moves

private let twoScreens = [Screens.builtIn, Screens.right]

@Test("next and previous walk the displays from left to right")
func displayOrder() throws {
    let ordered = ScreenFrame.ordered([Screens.right, Screens.above, Screens.left, Screens.builtIn])
    #expect(ordered.map(\.id) == [3, 1, 4, 2])
}

@Test("a window keeps its share of the screen it moves to")
func displayRemapKeepsTheShare() throws {
    // The right half of the built-in screen, sent to the 2560 pt display.
    let frame = try #require(WindowLayout.target(action: .rightHalf, on: Screens.builtIn, gap: 0))
    let moved = try #require(
        DisplayMove.target(screens: twoScreens, current: 1, direction: .next, frame: frame)
    )
    #expect(moved.screen.id == 2)
    #expect(moved.frame == rect(2792, 0, 1280, 1415))
    #expect(moved.frame.maxX == Screens.right.visibleFrame.maxX)
}

@Test("a full screen window fills the destination")
func displayRemapOfAMaximizedWindow() throws {
    let moved = try #require(
        DisplayMove.target(
            screens: twoScreens,
            current: 1,
            direction: .next,
            frame: Screens.builtIn.visibleFrame
        )
    )
    #expect(moved.frame == Screens.right.visibleFrame)
}

@Test("the move back gives the original frame again")
func displayRemapRoundTrip() throws {
    let frame = rect(100, 100, 800, 600)
    let there = try #require(
        DisplayMove.target(screens: twoScreens, current: 1, direction: .next, frame: frame)
    )
    let back = try #require(
        DisplayMove.target(screens: twoScreens, current: 2, direction: .previous, frame: there.frame)
    )
    #expect(back.screen.id == 1)
    #expect(back.frame == frame)
}

@Test("a display to the left is reached by going backwards")
func displayRemapToANegativeOrigin() throws {
    let screens = [Screens.builtIn, Screens.left]
    let moved = try #require(
        DisplayMove.target(
            screens: screens,
            current: 1,
            direction: .previous,
            frame: rect(0, 0, 756, 949)
        )
    )
    #expect(moved.screen.id == 3)
    #expect(moved.frame == rect(-2560, 0, 1280, 1415))
}

@Test("a display above works the same way")
func displayRemapUpwards() throws {
    let screens = [Screens.builtIn, Screens.above]
    let moved = try #require(
        DisplayMove.target(
            screens: screens,
            current: 1,
            direction: .next,
            frame: rect(0, 0, 1512, 949)
        )
    )
    #expect(moved.screen.id == 4)
    #expect(moved.frame == Screens.above.visibleFrame)
}

@Test("the walk wraps around at both ends")
func displayWrap() throws {
    let screens = [Screens.left, Screens.builtIn, Screens.right]
    let frame = rect(100, 100, 400, 300)
    let forward = try #require(
        DisplayMove.target(screens: screens, current: 2, direction: .next, frame: frame)
    )
    #expect(forward.screen.id == 3)
    let backward = try #require(
        DisplayMove.target(screens: screens, current: 3, direction: .previous, frame: frame)
    )
    #expect(backward.screen.id == 2)
}

@Test("one display has nowhere to go")
func displayMoveNeedsTwoScreens() {
    #expect(
        DisplayMove.target(
            screens: [Screens.builtIn],
            current: 1,
            direction: .next,
            frame: sampleWindow
        ) == nil
    )
    #expect(DisplayMove.target(screens: [], current: 1, direction: .next, frame: sampleWindow) == nil)
}

@Test("an unknown screen has nowhere to go")
func displayMoveNeedsTheCurrentScreen() {
    #expect(
        DisplayMove.target(screens: twoScreens, current: 99, direction: .next, frame: sampleWindow)
            == nil
    )
}

@Test("a window that is not a number does not move")
func displayMoveRefusesNonsense() {
    #expect(
        DisplayMove.target(
            screens: twoScreens,
            current: 1,
            direction: .next,
            frame: rect(.nan, 0, 100, 100)
        ) == nil
    )
}

@Test("a remapped window never leaves the destination")
func displayRemapStaysInside() throws {
    let screens = [Screens.right, Screens.builtIn]
    for frame in [rect(1512, 0, 2560, 1415), rect(3000, 700, 1000, 700), rect(4000, 1400, 72, 15)] {
        let moved = try #require(
            DisplayMove.target(screens: screens, current: 2, direction: .next, frame: frame)
        )
        let destination = Screens.builtIn.visibleFrame
        #expect(moved.frame.minX >= destination.minX)
        #expect(moved.frame.minY >= destination.minY)
        #expect(moved.frame.maxX <= destination.maxX)
        #expect(moved.frame.maxY <= destination.maxY)
    }
}

// MARK: - The AX flip

@Test(
    "the flip uses the height of the primary screen",
    arguments: [
        // NS rectangle, the AX rectangle it becomes
        (rect(0, 0, 1512, 949), rect(0, 33, 1512, 949)),
        (rect(0, 949, 1512, 33), rect(0, 0, 1512, 33)),
        (rect(100, 100, 800, 600), rect(100, 282, 800, 600)),
        // A display to the left keeps its negative x.
        (rect(-2560, 0, 1280, 1415), rect(-2560, -433, 1280, 1415)),
        // A display above the primary one: a large NS y is a negative AX y.
        (rect(0, 982, 2560, 1415), rect(0, -1415, 2560, 1415)),
    ]
)
func axFlip(ns: CGRect, ax: CGRect) {
    let primary = Screens.builtIn.frame
    #expect(AXGeometry.toAX(ns, primaryFrame: primary) == ax)
    #expect(AXGeometry.fromAX(ax, primaryFrame: primary) == ns)
}

@Test(
    "the flip is exact in both directions",
    arguments: [
        rect(0, 0, 1512, 949),
        rect(-2560, -100, 1280, 1415),
        rect(0, 982, 2560, 1415),
        rect(12.5, 33.25, 640.5, 480.75),
    ]
)
func axRoundTrip(frame: CGRect) {
    let primary = Screens.builtIn.frame
    #expect(AXGeometry.fromAX(AXGeometry.toAX(frame, primaryFrame: primary), primaryFrame: primary) == frame)
    #expect(AXGeometry.toAX(AXGeometry.fromAX(frame, primaryFrame: primary), primaryFrame: primary) == frame)
}

// MARK: - The drag zones

@Test(
    "the pointer at an edge asks for a tile",
    arguments: [
        // A point on the built-in screen, and the action it means.
        (CGPoint(x: 2, y: 500), WindowAction.leftHalf),
        (CGPoint(x: 0, y: 500), .leftHalf),
        (CGPoint(x: 1510, y: 500), .rightHalf),
        (CGPoint(x: 1512, y: 500), .rightHalf),
        (CGPoint(x: 0, y: 981), .topLeft),
        (CGPoint(x: 0, y: 982), .topLeft),
        (CGPoint(x: 1512, y: 982), .topRight),
        (CGPoint(x: 0, y: 0), .bottomLeft),
        (CGPoint(x: 1512, y: 0), .bottomRight),
        (CGPoint(x: 756, y: 982), .maximize),
        (CGPoint(x: 756, y: 975), .maximize),
        (CGPoint(x: 200, y: 0), .firstThird),
        (CGPoint(x: 756, y: 2), .centerThird),
        (CGPoint(x: 1400, y: 0), .lastThird),
    ]
)
func snapZones(point: CGPoint, expected: WindowAction) {
    #expect(SnapZone.action(for: point, in: Screens.builtIn) == expected)
}

@Test(
    "the pointer away from every edge asks for nothing",
    arguments: [
        CGPoint(x: 756, y: 500),
        CGPoint(x: 20, y: 500),
        CGPoint(x: 756, y: 960),
        CGPoint(x: 756, y: 20),
        // Off the screen.
        CGPoint(x: -1, y: 500),
        CGPoint(x: 1513, y: 500),
        CGPoint(x: 756, y: 983),
        CGPoint(x: CGFloat.nan, y: 500),
    ]
)
func snapZoneMisses(point: CGPoint) {
    #expect(SnapZone.action(for: point, in: Screens.builtIn) == nil)
}

@Test("the corner reaches a quarter of the side")
func snapZoneCornerDepth() {
    // The screen is 982 pt high, so a corner reaches 245.5 pt up.
    #expect(SnapZone.action(for: CGPoint(x: 0, y: 245), in: Screens.builtIn) == .bottomLeft)
    #expect(SnapZone.action(for: CGPoint(x: 0, y: 246), in: Screens.builtIn) == .leftHalf)
}

@Test("the margin can be widened")
func snapZoneMargin() {
    #expect(SnapZone.action(for: CGPoint(x: 30, y: 500), in: Screens.builtIn) == nil)
    #expect(SnapZone.action(for: CGPoint(x: 30, y: 500), in: Screens.builtIn, margin: 40) == .leftHalf)
    #expect(SnapZone.action(for: CGPoint(x: 30, y: 500), in: Screens.builtIn, margin: 0) == nil)
}

@Test("a screen with no size has no zones")
func snapZoneOnAnEmptyScreen() {
    let empty = ScreenFrame(id: 9, frame: .zero, visibleFrame: .zero)
    #expect(SnapZone.action(for: .zero, in: empty) == nil)
}
