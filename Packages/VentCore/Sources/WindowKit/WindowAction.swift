/// Everything the window manager can do to one window.
///
/// The raw values are stored in the settings and in the shortcut set, so they
/// are written out and never derived from the case name: renaming a case must
/// not silently drop a user's binding.
public enum WindowAction: String, CaseIterable, Codable, Sendable, Hashable {
    case leftHalf = "leftHalf"
    case rightHalf = "rightHalf"
    case centerHalf = "centerHalf"
    case topHalf = "topHalf"
    case bottomHalf = "bottomHalf"
    case topLeft = "topLeft"
    case topRight = "topRight"
    case bottomLeft = "bottomLeft"
    case bottomRight = "bottomRight"
    case firstThird = "firstThird"
    case centerThird = "centerThird"
    case lastThird = "lastThird"
    case firstTwoThirds = "firstTwoThirds"
    case lastTwoThirds = "lastTwoThirds"
    case maximize = "maximize"
    case almostMaximize = "almostMaximize"
    case maximizeHeight = "maximizeHeight"
    case center = "center"
    case restore = "restore"
    case larger = "larger"
    case smaller = "smaller"
    case nextDisplay = "nextDisplay"
    case previousDisplay = "previousDisplay"

    public var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .centerHalf: "Center Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .firstThird: "First Third"
        case .centerThird: "Center Third"
        case .lastThird: "Last Third"
        case .firstTwoThirds: "First Two Thirds"
        case .lastTwoThirds: "Last Two Thirds"
        case .maximize: "Maximize"
        case .almostMaximize: "Almost Maximize"
        case .maximizeHeight: "Maximize Height"
        case .center: "Center"
        case .restore: "Restore"
        case .larger: "Larger"
        case .smaller: "Smaller"
        case .nextDisplay: "Next Display"
        case .previousDisplay: "Previous Display"
        }
    }

    /// The symbol for an action that is not a region of the screen.
    ///
    /// The command list draws a little screen for everything it can place, and
    /// falls back to this symbol for the five it cannot. They are drawn inside
    /// that same screen outline, so each one is a bare mark - a minus, a plus,
    /// an arrow - and never a framed symbol that would box a box.
    public var symbolName: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .centerHalf: "rectangle.center.inset.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .topLeft: "rectangle.inset.topleft.filled"
        case .topRight: "rectangle.inset.topright.filled"
        case .bottomLeft: "rectangle.inset.bottomleft.filled"
        case .bottomRight: "rectangle.inset.bottomright.filled"
        case .firstThird: "rectangle.leadingthird.inset.filled"
        case .centerThird: "rectangle.center.inset.filled"
        case .lastThird: "rectangle.trailingthird.inset.filled"
        case .firstTwoThirds: "rectangle.lefthalf.inset.filled.arrow.left"
        case .lastTwoThirds: "rectangle.righthalf.inset.filled.arrow.right"
        case .maximize: "arrow.up.left.and.arrow.down.right"
        case .almostMaximize: "rectangle.inset.filled"
        case .maximizeHeight: "arrow.up.and.down"
        case .center: "arrow.down.right.and.arrow.up.left"
        case .restore: "arrow.uturn.backward"
        case .larger: "plus"
        case .smaller: "minus"
        case .nextDisplay: "arrow.right"
        case .previousDisplay: "arrow.left"
        }
    }

    /// True when `WindowLayout` can compute the target frame for this action.
    ///
    /// The rest needs more than the screen: `restore` needs the memory of
    /// where the window was, `larger`/`smaller` belong to `ResizeStep` and the
    /// two display moves to `DisplayMove`.
    public var isPlacement: Bool {
        switch self {
        case .restore, .larger, .smaller, .nextDisplay, .previousDisplay: false
        default: true
        }
    }

    /// The placement actions, in the order the tile grid shows them.
    public static let placements: [WindowAction] = WindowAction.allCases.filter(\.isPlacement)

    /// True when the action does nothing at all on a Mac with one display.
    /// The command list dims these rows rather than hiding them, so the row
    /// and its chord stay where the user learned them.
    public var needsSecondDisplay: Bool {
        self == .nextDisplay || self == .previousDisplay
    }

    /// The slot this action fills, or nil when the action is not one tile.
    ///
    /// The screen decides the axis of the thirds: on a portrait display they
    /// split the long side, the way Rectangle does it.
    public func slot(on screen: ScreenFrame) -> WindowSlot? {
        let thirdsAxis: WindowSlot.Axis = screen.isPortrait ? .vertical : .horizontal
        switch self {
        case .leftHalf: return WindowSlot(axis: .horizontal, position: .first, span: .half)
        case .rightHalf: return WindowSlot(axis: .horizontal, position: .last, span: .half)
        // A half of the width, centred. It follows the halves and not the
        // thirds, so it stays a vertical band on a portrait screen too.
        case .centerHalf: return WindowSlot(axis: .horizontal, position: .center, span: .half)
        case .topHalf: return WindowSlot(axis: .vertical, position: .first, span: .half)
        case .bottomHalf: return WindowSlot(axis: .vertical, position: .last, span: .half)
        case .firstThird: return WindowSlot(axis: thirdsAxis, position: .first, span: .third)
        case .centerThird: return WindowSlot(axis: thirdsAxis, position: .center, span: .third)
        case .lastThird: return WindowSlot(axis: thirdsAxis, position: .last, span: .third)
        case .firstTwoThirds: return WindowSlot(axis: thirdsAxis, position: .first, span: .twoThirds)
        case .lastTwoThirds: return WindowSlot(axis: thirdsAxis, position: .last, span: .twoThirds)
        default: return nil
        }
    }
}
