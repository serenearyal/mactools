import CoreGraphics
import Testing

import WindowKit

/// The user's own machine: a 14-inch MacBook Pro with the notch, so the
/// visible frame is 33 pt shorter than the frame.
enum Screens {
    static let builtIn = ScreenFrame(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949)
    )

    /// A 27-inch display to the right of the built-in one.
    static let right = ScreenFrame(
        id: 2,
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415)
    )

    /// The same display to the LEFT: everything on it has a negative x.
    static let left = ScreenFrame(
        id: 3,
        frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: -2560, y: 0, width: 2560, height: 1415)
    )

    /// And above, which is a negative y in AX and a positive one in NS.
    static let above = ScreenFrame(
        id: 4,
        frame: CGRect(x: 0, y: 982, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 982, width: 2560, height: 1415)
    )

    static let portrait = ScreenFrame(
        id: 5,
        frame: CGRect(x: 0, y: 0, width: 1080, height: 1920),
        visibleFrame: CGRect(x: 0, y: 0, width: 1080, height: 1920)
    )
}

func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: width, height: height)
}

/// The window the actions that keep part of the geometry work from.
let sampleWindow = rect(100, 100, 800, 600)

func placed(_ action: WindowAction, gap: CGFloat, on screen: ScreenFrame = Screens.builtIn) -> CGRect? {
    WindowLayout.target(action: action, on: screen, current: sampleWindow, gap: gap)
}

// MARK: - The exact numbers, gap by gap

/// Every placement at gap 0 on the real screen. The expected rectangles were
/// worked out by hand from the visible frame, not read back from the code.
@Test(
    "every placement at gap 0",
    arguments: [
        (WindowAction.leftHalf, rect(0, 0, 756, 949)),
        (.rightHalf, rect(756, 0, 756, 949)),
        (.centerHalf, rect(378, 0, 756, 949)),
        (.topHalf, rect(0, 475, 1512, 474)),
        (.bottomHalf, rect(0, 0, 1512, 475)),
        (.topLeft, rect(0, 475, 756, 474)),
        (.topRight, rect(756, 475, 756, 474)),
        (.bottomLeft, rect(0, 0, 756, 475)),
        (.bottomRight, rect(756, 0, 756, 475)),
        (.firstThird, rect(0, 0, 504, 949)),
        (.centerThird, rect(504, 0, 504, 949)),
        (.lastThird, rect(1008, 0, 504, 949)),
        (.firstTwoThirds, rect(0, 0, 1008, 949)),
        (.lastTwoThirds, rect(504, 0, 1008, 949)),
        (.maximize, rect(0, 0, 1512, 949)),
        (.almostMaximize, rect(76, 47, 1360, 855)),
        (.maximizeHeight, rect(100, 0, 800, 949)),
        (.center, rect(356, 175, 800, 600)),
    ]
)
func placementsAtGapZero(action: WindowAction, expected: CGRect) {
    #expect(placed(action, gap: 0) == expected)
}

@Test(
    "every placement at gap 8",
    arguments: [
        (WindowAction.leftHalf, rect(8, 8, 744, 933)),
        (.rightHalf, rect(760, 8, 744, 933)),
        (.centerHalf, rect(386, 8, 740, 933)),
        (.topHalf, rect(8, 479, 1496, 462)),
        (.bottomHalf, rect(8, 8, 1496, 463)),
        (.topLeft, rect(8, 479, 744, 462)),
        (.topRight, rect(760, 479, 744, 462)),
        (.bottomLeft, rect(8, 8, 744, 463)),
        (.bottomRight, rect(760, 8, 744, 463)),
        (.firstThird, rect(8, 8, 495, 933)),
        (.centerThird, rect(511, 8, 490, 933)),
        (.lastThird, rect(1009, 8, 495, 933)),
        (.firstTwoThirds, rect(8, 8, 993, 933)),
        (.lastTwoThirds, rect(511, 8, 993, 933)),
        (.maximize, rect(8, 8, 1496, 933)),
        (.almostMaximize, rect(83, 55, 1346, 839)),
        (.maximizeHeight, rect(100, 8, 800, 933)),
        (.center, rect(356, 175, 800, 600)),
    ]
)
func placementsAtGapEight(action: WindowAction, expected: CGRect) {
    #expect(placed(action, gap: 8) == expected)
}

@Test(
    "every placement at gap 16",
    arguments: [
        (WindowAction.leftHalf, rect(16, 16, 732, 917)),
        (.rightHalf, rect(764, 16, 732, 917)),
        (.centerHalf, rect(394, 16, 724, 917)),
        (.topHalf, rect(16, 483, 1480, 450)),
        (.bottomHalf, rect(16, 16, 1480, 451)),
        (.topLeft, rect(16, 483, 732, 450)),
        (.topRight, rect(764, 483, 732, 450)),
        (.bottomLeft, rect(16, 16, 732, 451)),
        (.bottomRight, rect(764, 16, 732, 451)),
        (.firstThird, rect(16, 16, 485, 917)),
        (.centerThird, rect(517, 16, 478, 917)),
        (.lastThird, rect(1011, 16, 485, 917)),
        (.firstTwoThirds, rect(16, 16, 979, 917)),
        (.lastTwoThirds, rect(517, 16, 979, 917)),
        (.maximize, rect(16, 16, 1480, 917)),
        (.almostMaximize, rect(90, 62, 1332, 825)),
        (.maximizeHeight, rect(100, 16, 800, 917)),
        (.center, rect(356, 175, 800, 600)),
    ]
)
func placementsAtGapSixteen(action: WindowAction, expected: CGRect) {
    #expect(placed(action, gap: 16) == expected)
}

// MARK: - The properties the numbers have to keep

/// The promise of the gap model: neighbours are exactly `gap` apart, whatever
/// the rounding did to the shared edge.
@Test("tiles sit exactly one gap apart", arguments: [0, 1, 8, 9, 16, 40] as [CGFloat])
func tileAdjacency(gap: CGFloat) throws {
    let left = try #require(placed(.leftHalf, gap: gap))
    let right = try #require(placed(.rightHalf, gap: gap))
    #expect(left.maxX + gap == right.minX)

    let bottom = try #require(placed(.bottomHalf, gap: gap))
    let top = try #require(placed(.topHalf, gap: gap))
    #expect(bottom.maxY + gap == top.minY)

    let first = try #require(placed(.firstThird, gap: gap))
    let center = try #require(placed(.centerThird, gap: gap))
    let last = try #require(placed(.lastThird, gap: gap))
    #expect(first.maxX + gap == center.minX)
    #expect(center.maxX + gap == last.minX)

    let firstTwo = try #require(placed(.firstTwoThirds, gap: gap))
    let lastTwo = try #require(placed(.lastTwoThirds, gap: gap))
    #expect(firstTwo.maxX + gap == last.minX)
    #expect(first.maxX + gap == lastTwo.minX)
}

@Test("quarters sit one gap apart on both axes", arguments: [0, 8, 16] as [CGFloat])
func quarterAdjacency(gap: CGFloat) throws {
    let topLeft = try #require(placed(.topLeft, gap: gap))
    let topRight = try #require(placed(.topRight, gap: gap))
    let bottomLeft = try #require(placed(.bottomLeft, gap: gap))
    let bottomRight = try #require(placed(.bottomRight, gap: gap))
    #expect(topLeft.maxX + gap == topRight.minX)
    #expect(bottomLeft.maxX + gap == bottomRight.minX)
    #expect(bottomLeft.maxY + gap == topLeft.minY)
    #expect(bottomRight.maxY + gap == topRight.minY)
}

/// The outer edges keep exactly the gap from the visible frame, so the row of
/// tiles is centred in it.
@Test("every tile keeps the gap from the screen edge", arguments: [0, 8, 16, 40] as [CGFloat])
func tilesKeepScreenGap(gap: CGFloat) throws {
    let visible = Screens.builtIn.visibleFrame
    for action in WindowAction.placements where action != .center {
        let frame = try #require(placed(action, gap: gap))
        #expect(frame.minX >= visible.minX + gap)
        #expect(frame.minY >= visible.minY + gap)
        #expect(frame.maxX <= visible.maxX - gap)
        #expect(frame.maxY <= visible.maxY - gap)
    }
}

@Test("halves and quarters cover the whole field at gap 0")
func tilesCoverTheField() throws {
    let maximized = try #require(placed(.maximize, gap: 0))
    let left = try #require(placed(.leftHalf, gap: 0))
    let right = try #require(placed(.rightHalf, gap: 0))
    #expect(left.width + right.width == maximized.width)
    let top = try #require(placed(.topHalf, gap: 0))
    let bottom = try #require(placed(.bottomHalf, gap: 0))
    #expect(top.height + bottom.height == maximized.height)
    let first = try #require(placed(.firstThird, gap: 0))
    let center = try #require(placed(.centerThird, gap: 0))
    let last = try #require(placed(.lastThird, gap: 0))
    #expect(first.width + center.width + last.width == maximized.width)
}

@Test("every result is whole points", arguments: [0, 7, 8, 13, 16, 40] as [CGFloat])
func resultsAreIntegral(gap: CGFloat) throws {
    for action in WindowAction.placements {
        let frame = try #require(placed(action, gap: gap))
        #expect(frame.minX == frame.minX.rounded())
        #expect(frame.minY == frame.minY.rounded())
        #expect(frame.width == frame.width.rounded())
        #expect(frame.height == frame.height.rounded())
    }
}

// MARK: - The actions that need the window

@Test("center keeps the size and ignores the gap")
func centerKeepsSize() throws {
    for gap in [0, 8, 16, 40] as [CGFloat] {
        let frame = try #require(placed(.center, gap: gap))
        #expect(frame.size == sampleWindow.size)
        #expect(frame == rect(356, 175, 800, 600))
    }
}

@Test("center clamps a window that is larger than the screen")
func centerClampsOversizedWindow() {
    let huge = rect(-100, -100, 4000, 3000)
    let frame = WindowLayout.target(action: .center, on: Screens.builtIn, current: huge, gap: 0)
    #expect(frame == Screens.builtIn.visibleFrame)
}

@Test("maximize height keeps x and width")
func maximizeHeightKeepsWidth() throws {
    let frame = try #require(placed(.maximizeHeight, gap: 8))
    #expect(frame.minX == sampleWindow.minX)
    #expect(frame.width == sampleWindow.width)
    #expect(frame.minY == 8)
    #expect(frame.height == 933)
}

@Test("center and maximize height need a window", arguments: [WindowAction.center, .maximizeHeight])
func actionsThatNeedAWindow(action: WindowAction) {
    #expect(WindowLayout.target(action: action, on: Screens.builtIn, current: nil, gap: 0) == nil)
    let broken = rect(.nan, 0, 100, 100)
    #expect(WindowLayout.target(action: action, on: Screens.builtIn, current: broken, gap: 0) == nil)
}

@Test(
    "the actions that are not a placement have no frame",
    arguments: [WindowAction.restore, .larger, .smaller, .nextDisplay, .previousDisplay]
)
func nonPlacementActions(action: WindowAction) {
    #expect(action.isPlacement == false)
    #expect(placed(action, gap: 0) == nil)
}

@Test("almost maximize is 90 % of the field, centred")
func almostMaximizeIsNinetyPercent() throws {
    let frame = try #require(placed(.almostMaximize, gap: 0))
    let visible = Screens.builtIn.visibleFrame
    #expect(abs(frame.width - visible.width * 0.9) <= 1)
    #expect(abs(frame.height - visible.height * 0.9) <= 1)
    #expect(abs(frame.midX - visible.midX) <= 1)
    #expect(abs(frame.midY - visible.midY) <= 1)
}

// MARK: - Portrait

/// Rectangle splits the thirds along the long side, so on a portrait display
/// the first third is the top one.
@Test("thirds run down a portrait screen")
func portraitThirds() throws {
    let first = try #require(placed(.firstThird, gap: 0, on: Screens.portrait))
    let center = try #require(placed(.centerThird, gap: 0, on: Screens.portrait))
    let last = try #require(placed(.lastThird, gap: 0, on: Screens.portrait))
    #expect(first == rect(0, 1280, 1080, 640))
    #expect(center == rect(0, 640, 1080, 640))
    #expect(last == rect(0, 0, 1080, 640))
    #expect(last.maxY == center.minY)
    #expect(center.maxY == first.minY)
}

@Test("halves keep their side on a portrait screen")
func portraitHalves() throws {
    #expect(placed(.leftHalf, gap: 0, on: Screens.portrait) == rect(0, 0, 540, 1920))
    #expect(placed(.topHalf, gap: 0, on: Screens.portrait) == rect(0, 960, 1080, 960))
    // Center Half follows the halves, not the thirds: a band down the middle
    // on a portrait screen as much as on a landscape one.
    #expect(placed(.centerHalf, gap: 0, on: Screens.portrait) == rect(270, 0, 540, 1920))
}

/// Center Half is the left half moved to the middle: the same width, centred
/// on the screen, and it covers the inner halves of both side halves.
@Test("center half is a half of the width in the middle", arguments: [0, 8, 16] as [CGFloat])
func centerHalfIsCentred(gap: CGFloat) throws {
    let left = try #require(placed(.leftHalf, gap: gap))
    let center = try #require(placed(.centerHalf, gap: gap))
    let maximized = try #require(placed(.maximize, gap: gap))
    #expect(center.height == left.height)
    // Both of its edges are internal, so it gives up half a gap on each side
    // where the left half gives up half a gap on one.
    #expect(abs(center.width - (left.width - gap / 2)) <= 1)
    #expect(abs(center.midX - maximized.midX) <= 1)
}

@Test("two thirds run down a portrait screen too")
func portraitTwoThirds() throws {
    let first = try #require(placed(.firstTwoThirds, gap: 0, on: Screens.portrait))
    #expect(first == rect(0, 640, 1080, 1280))
}

// MARK: - Degenerate input

@Test("an empty visible frame places nothing")
func emptyScreen() {
    let empty = ScreenFrame(id: 9, frame: .zero, visibleFrame: .zero)
    for action in WindowAction.allCases {
        #expect(WindowLayout.target(action: action, on: empty, current: sampleWindow, gap: 0) == nil)
    }
}

@Test("a screen that is not a number places nothing")
func notANumberScreen() {
    let broken = ScreenFrame(
        id: 9,
        frame: rect(0, 0, 100, 100),
        visibleFrame: rect(.nan, 0, 100, 100)
    )
    #expect(WindowLayout.target(action: .maximize, on: broken, current: nil, gap: 0) == nil)
}

/// A gap wider than the screen leaves no field at all, and a tile that would
/// come out inside out is refused instead of returned with a negative size.
@Test("a screen too small for the gap places nothing")
func screenTooSmallForTheGap() {
    let tiny = ScreenFrame(id: 9, frame: rect(0, 0, 60, 60), visibleFrame: rect(0, 0, 60, 60))
    for action in WindowAction.placements {
        #expect(WindowLayout.target(action: action, on: tiny, current: sampleWindow, gap: 40) == nil)
    }

    let small = ScreenFrame(id: 9, frame: rect(0, 0, 100, 100), visibleFrame: rect(0, 0, 100, 100))
    #expect(WindowLayout.target(action: .maximize, on: small, gap: 40) == rect(40, 40, 20, 20))
    #expect(WindowLayout.target(action: .leftHalf, on: small, gap: 40) == nil)
}

@Test(
    "the gap is clamped to 0...40 and to whole points",
    arguments: [
        (-10 as CGFloat, 0 as CGFloat),
        (0, 0),
        (8.4, 8),
        (8.6, 9),
        (40, 40),
        (1000, 40),
        (.infinity, 0),
        (.nan, 0),
    ]
)
func gapClamping(gap: CGFloat, expected: CGFloat) {
    #expect(WindowLayout.clampGap(gap) == expected)
    #expect(placed(.leftHalf, gap: gap) == placed(.leftHalf, gap: expected))
}

@Test("the second screen gets its own tiles")
func secondScreenTiles() {
    #expect(
        WindowLayout.target(action: .leftHalf, on: Screens.right, gap: 0) == rect(1512, 0, 1280, 1415)
    )
    #expect(
        WindowLayout.target(action: .rightHalf, on: Screens.left, gap: 0) == rect(-1280, 0, 1280, 1415)
    )
    // The screen above the primary one: its visible frame runs from 982 to
    // 2397, so the top half starts at the rounded midpoint 1690.
    #expect(
        WindowLayout.target(action: .topHalf, on: Screens.above, gap: 0) == rect(0, 1690, 2560, 707)
    )
}
