import AppKit

/// The status item label, drawn straight into a bitmap.
///
/// `MenuBarLabelView` is the same label in SwiftUI, and `ImageRenderer` is what
/// used to draw it once a second for the menu bar. A renderer builds a whole
/// SwiftUI graph, lays it out and rasterises it; this draws two strings and a
/// symbol. The geometry comes from `MenuBarMetrics`, the same source the
/// SwiftUI view measures its cells with, so the two cannot drift apart, and
/// `--label-bench` renders both and reports the pixel difference between them.
/// Everything one rendered label depends on.
///
/// The appearance is deliberately not part of it: the image is a template, so
/// the system tints the one image for the light and the dark menu bar.
struct MenuBarLabelKey: Hashable {
    let cells: [MenuBarCell]
    let style: MenuBarLabelStyle
    let icon: Bool
    let awake: Bool
    let scale: CGFloat
}

enum MenuBarLabelImage {
    /// The template image the status item shows. Black on transparent: the
    /// system tints it for the menu bar it ends up in.
    static func image(
        cells: [MenuBarCell],
        style: MenuBarLabelStyle,
        showIcon: Bool,
        awake: Bool,
        scale: CGFloat
    ) -> NSImage? {
        let icon = (showIcon || cells.isEmpty) ? symbol(awake: awake, solo: cells.isEmpty) : nil
        let size = size(cells: cells, style: style, icon: icon)
        guard size.width > 0, size.height > 0 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        draw(cells: cells, style: style, icon: icon, in: size)
        context.flushGraphics()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    // MARK: - Geometry

    /// The same box the SwiftUI view lays out: the symbol, the cells, the
    /// spacing between them and one point of padding on each side.
    static func size(cells: [MenuBarCell], style: MenuBarLabelStyle, icon: NSImage?) -> CGSize {
        var width = MenuBarMetrics.horizontalPadding * 2
        if let icon {
            width += icon.size.width
            if !cells.isEmpty { width += MenuBarMetrics.iconSpacing }
        }
        for (index, cell) in cells.enumerated() {
            if index > 0 { width += MenuBarMetrics.cellSpacing }
            width += MenuBarMetrics.width(of: cell, style: style)
        }
        return CGSize(width: width, height: MenuBarMetrics.height)
    }

    /// `fan` and `fan.fill` at the size the view asks for. Both variants have
    /// the same advance width, so the item never changes size.
    private static func symbol(awake: Bool, solo: Bool) -> NSImage? {
        let name = awake ? "fan.fill" : "fan"
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let configured = image.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: solo ? MenuBarMetrics.soloIconSize : MenuBarMetrics.iconSize,
                weight: .medium
            )
        )
        configured?.isTemplate = true
        return configured
    }

    // MARK: - Drawing

    private static func draw(
        cells: [MenuBarCell],
        style: MenuBarLabelStyle,
        icon: NSImage?,
        in size: CGSize
    ) {
        var x = MenuBarMetrics.horizontalPadding
        if let icon {
            // Centred on the height of the whole label, like every other child
            // of the stack.
            icon.draw(
                in: CGRect(
                    x: x,
                    y: ((size.height - icon.size.height) / 2).rounded(),
                    width: icon.size.width,
                    height: icon.size.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
            x += icon.size.width
            if !cells.isEmpty { x += MenuBarMetrics.iconSpacing }
        }
        for (index, cell) in cells.enumerated() {
            if index > 0 { x += MenuBarMetrics.cellSpacing }
            let width = MenuBarMetrics.width(of: cell, style: style)
            draw(cell: cell, style: style, in: CGRect(x: x, y: 0, width: width, height: size.height))
            x += width
        }
    }

    private static func draw(cell: MenuBarCell, style: MenuBarLabelStyle, in box: CGRect) {
        let caption = attributed(
            cell.caption,
            font: MenuBarMetrics.captionFont(style),
            tracking: MenuBarMetrics.tracking(style),
            alpha: 0.75
        )
        let value = attributed(cell.value, font: MenuBarMetrics.valueFont(style), tracking: 0, alpha: 1)
        let captionSize = caption.size()
        let valueSize = value.size()

        switch style {
        case .twoLine:
            // The caption sits on the value with no spacing, and the pair is
            // centred in the cell, which is what `VStack(spacing: 0)` inside a
            // fixed-width frame does.
            let total = captionSize.height + valueSize.height
            let top = ((box.height - total) / 2).rounded()
            caption.draw(at: CGPoint(
                x: box.minX + ((box.width - captionSize.width) / 2).rounded(),
                y: (box.height - top - captionSize.height).rounded()
            ))
            value.draw(at: CGPoint(
                x: box.minX + ((box.width - valueSize.width) / 2).rounded(),
                y: (box.height - top - total).rounded()
            ))
        case .oneLine:
            let height = max(captionSize.height, valueSize.height)
            let baseline = (box.height - height) / 2
            caption.draw(at: CGPoint(
                x: box.minX,
                y: baseline + (height - captionSize.height) / 2
            ))
            value.draw(at: CGPoint(
                x: box.minX + captionSize.width + MenuBarMetrics.oneLineGap,
                y: baseline + (height - valueSize.height) / 2
            ))
        }
    }

    private static func attributed(
        _ text: String,
        font: NSFont,
        tracking: CGFloat,
        alpha: CGFloat
    ) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .kern: tracking,
                .foregroundColor: NSColor.black.withAlphaComponent(alpha),
            ]
        )
    }
}
