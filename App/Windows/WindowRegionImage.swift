import AppKit
import WindowKit

/// The command list's glyph as a template `NSImage`, for the status item's
/// Window submenu.
///
/// The SwiftUI glyph (`WindowRegionGlyph`) cannot be used in an `NSMenu`, so
/// this draws the same picture from the same `WindowTilePreview` region: one
/// outline, one filled region, alpha only. A template image is tinted by the
/// menu, so it follows both appearances and the highlight for free.
enum WindowRegionImage {
    static let size = NSSize(width: 20, height: 14)
    /// The screen bezel, the same inset the SwiftUI glyph uses.
    private static let inset: CGFloat = 2

    static func image(for action: WindowAction) -> NSImage? {
        guard let unit = WindowTilePreview.region(for: action, gap: 0, screenWidth: 1600) else {
            // Restore, larger, smaller and the display moves are not a region
            // of the screen: the symbol says what they do, as in the list.
            let symbol = NSImage(
                systemSymbolName: action.symbolName,
                accessibilityDescription: action.title
            )
            symbol?.isTemplate = true
            return symbol
        }

        let image = NSImage(size: size, flipped: true) { _ in
            let outline = NSRect(
                x: 0.5,
                y: 0.5,
                width: size.width - 1,
                height: size.height - 1
            )
            NSColor(white: 0, alpha: 0.5).setStroke()
            let border = NSBezierPath(roundedRect: outline, xRadius: 3, yRadius: 3)
            border.lineWidth = 1
            border.stroke()

            let field = NSRect(
                x: inset,
                y: inset,
                width: size.width - inset * 2,
                height: size.height - inset * 2
            )
            // Whole points on every edge, so the fill lands on the pixel grid
            // at 1x as well as at 2x.
            let minX = (field.minX + unit.minX * field.width).rounded()
            let minY = (field.minY + unit.minY * field.height).rounded()
            let maxX = (field.minX + unit.maxX * field.width).rounded()
            let maxY = (field.minY + unit.maxY * field.height).rounded()
            NSColor(white: 0, alpha: 0.85).setFill()
            NSBezierPath(
                roundedRect: NSRect(
                    x: minX,
                    y: minY,
                    width: max(maxX - minX, 2),
                    height: max(maxY - minY, 2)
                ),
                xRadius: 1,
                yRadius: 1
            ).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
