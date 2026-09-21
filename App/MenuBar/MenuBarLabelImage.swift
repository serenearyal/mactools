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
/// The appearance is only part of it while a cell is tinted. With nothing hot
/// the image is a template, one image serves the light and the dark menu bar,
/// and the cache holds one entry per set of numbers rather than two.
struct MenuBarLabelKey: Hashable {
    let cells: [MenuBarCell]
    let style: MenuBarLabelStyle
    let icon: Bool
    let awake: Bool
    let scale: CGFloat
    /// The heat of each cell, in the order of `cells`. Empty, and equal for
    /// every label, while nothing is hot.
    var tints: [HeatLevel] = []
    /// The menu bar appearance the colours were resolved against. nil for the
    /// template image, which needs none.
    var appearance: String?
    /// False while the fan glyph is drawn by `FanIconLayer` instead: the
    /// bitmap then keeps the box and leaves it empty.
    var drawsIcon: Bool = true
}

enum MenuBarLabelImage {
    /// The label the status item shows.
    ///
    /// Two paths, and the first one is the one that runs all day. With no cell
    /// tinted it is the template image it has always been - black on
    /// transparent, tinted by the system for the menu bar it ends up in. With a
    /// cell tinted a template cannot carry the colour, so the image is a plain
    /// one and everything that is not tinted is drawn in `baseColor`, the
    /// colour the menu bar would have given the template.
    static func image(
        cells: [MenuBarCell],
        style: MenuBarLabelStyle,
        showIcon: Bool,
        awake: Bool,
        scale: CGFloat,
        tints: [HeatLevel] = [],
        baseColor: NSColor? = nil,
        appearance: NSAppearance? = nil,
        drawsIcon: Bool = true
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

        let tinted = tints.contains { $0.isTinted }
        let base = tinted ? (baseColor ?? .black) : .black

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        // `systemYellow` and its two neighbours are dynamic colours, and a
        // bitmap context has no appearance of its own; drawing inside the menu
        // bar's appearance is what picks the right variant of each.
        let body = {
            draw(
                cells: cells,
                style: style,
                icon: drawsIcon ? icon : nil,
                iconBox: icon.map { iconBox(for: $0, in: size) },
                tints: tints,
                base: base,
                in: size
            )
        }
        if tinted, let appearance {
            appearance.performAsCurrentDrawingAppearance(body)
        } else {
            body()
        }
        context.flushGraphics()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        // A template image is a mask: it carries alpha and nothing else, so a
        // tinted label has to give that up to keep its colours.
        image.isTemplate = !tinted
        return image
    }

    /// The colour the menu bar gives a template image, so the untinted half of
    /// a tinted label looks exactly like the label beside it.
    static func templateColor(for appearance: NSAppearance?) -> NSColor {
        let match = appearance?.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ])
        return match == .darkAqua || match == .accessibilityHighContrastDarkAqua ? .white : .black
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

    /// Where the fan symbol sits in the label, in the label's own bottom-left
    /// coordinates. Nil when the label draws no symbol at all.
    ///
    /// The one source for both the bitmap and the layer that turns: whether the
    /// glyph is drawn into the image or floated over it, it is in the same box
    /// to the pixel.
    static func iconFrame(cells: [MenuBarCell], style: MenuBarLabelStyle, showIcon: Bool, awake: Bool) -> CGRect? {
        guard showIcon || cells.isEmpty, let icon = symbol(awake: awake, solo: cells.isEmpty) else {
            return nil
        }
        return iconBox(for: icon, in: size(cells: cells, style: style, icon: icon))
    }

    /// The same box, once the symbol and the label size are already in hand.
    private static func iconBox(for icon: NSImage, in size: CGSize) -> CGRect {
        CGRect(
            x: MenuBarMetrics.horizontalPadding,
            // Centred on the height of the whole label, like every other child
            // of the stack, and lifted to make room for the status light.
            y: ((size.height - icon.size.height) / 2).rounded() + MenuBarMetrics.ledLift,
            width: icon.size.width,
            height: icon.size.height
        )
    }

    /// Where the status light sits in the label, in the label's own
    /// bottom-left coordinates: centred under the symbol. Nil with no symbol.
    static func ledFrame(cells: [MenuBarCell], showIcon: Bool) -> CGRect? {
        guard showIcon || cells.isEmpty, let icon = symbol(awake: false, solo: cells.isEmpty) else {
            return nil
        }
        let diameter = MenuBarMetrics.ledDiameter
        return CGRect(
            x: MenuBarMetrics.horizontalPadding + ((icon.size.width - diameter) / 2),
            y: MenuBarMetrics.ledBottom,
            width: diameter,
            height: diameter
        )
    }

    // MARK: - Drawing

    /// `iconBox` reserves the symbol's width even when `icon` is nil, which is
    /// what keeps every cell at the same x once the glyph moves to its own
    /// layer: the label does not shift by a pixel.
    private static func draw(
        cells: [MenuBarCell],
        style: MenuBarLabelStyle,
        icon: NSImage?,
        iconBox: CGRect?,
        tints: [HeatLevel],
        base: NSColor,
        in size: CGSize
    ) {
        var x = MenuBarMetrics.horizontalPadding
        if let iconBox {
            if let icon {
                icon.draw(
                    in: iconBox,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: nil
                )
                // The symbol is a template and draws black. In the tinted path
                // nothing will tint it afterwards, so it is painted here - a
                // black fan on a dark menu bar is the bug this prevents.
                if base != .black {
                    base.set()
                    iconBox.fill(using: .sourceAtop)
                }
            }
            x += iconBox.width
            if !cells.isEmpty { x += MenuBarMetrics.iconSpacing }
        }
        for (index, cell) in cells.enumerated() {
            if index > 0 { x += MenuBarMetrics.cellSpacing }
            let width = MenuBarMetrics.width(of: cell, style: style)
            let level = index < tints.count ? tints[index] : .normal
            draw(
                cell: cell,
                style: style,
                base: base,
                tint: level.color,
                in: CGRect(x: x, y: 0, width: width, height: size.height)
            )
            x += width
        }
    }

    /// Only the value carries the heat. The caption stays where it was: a
    /// four-letter word at 7 pt in amber is unreadable, and the number beside
    /// it is what the colour is about.
    private static func draw(
        cell: MenuBarCell,
        style: MenuBarLabelStyle,
        base: NSColor,
        tint: NSColor?,
        in box: CGRect
    ) {
        let caption = attributed(
            cell.caption,
            font: MenuBarMetrics.captionFont(style),
            tracking: MenuBarMetrics.tracking(style),
            alpha: 0.75,
            color: base
        )
        let value = attributed(
            cell.value,
            font: MenuBarMetrics.valueFont(style),
            tracking: 0,
            alpha: 1,
            color: tint ?? base
        )
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
        alpha: CGFloat,
        color: NSColor
    ) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .kern: tracking,
                .foregroundColor: color.withAlphaComponent(alpha),
            ]
        )
    }
}

extension HeatLevel {
    /// The colour the value is drawn in, or nil for the level that is drawn
    /// like everything else.
    ///
    /// The system colours, not three of our own: they are what every other
    /// warning on this Mac uses, they carry their own high-contrast and dark
    /// variants, and the label resolves them inside the menu bar's appearance.
    var color: NSColor? {
        switch self {
        case .normal: nil
        case .warm: .systemYellow
        case .hot: .systemOrange
        case .critical: .systemRed
        }
    }
}
