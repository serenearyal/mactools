import AppKit
import QuartzCore

/// The fan glyph of the status item, as a layer of its own.
///
/// It used to be part of the label bitmap. A bitmap cannot turn without being
/// drawn again, and drawing a status item thirty times a second is exactly the
/// thing this app promises not to do, so the glyph moved out of the image and
/// onto the button, next to the status light: one `CABasicAnimation` on
/// `transform.rotation.z`, and Core Animation makes every frame in the window
/// server. The app itself does nothing at all while the fan turns.
///
/// The label bitmap still reserves the same box, so the cells beside it do not
/// move by a pixel when the glyph leaves the image.
@MainActor
final class FanIconLayer {
    let layer = CALayer()

    /// What the current `contents` were drawn from. A re-render only happens
    /// when one of these changes: a new colour after a wallpaper flip, the
    /// filled variant while Keep Awake holds, a different screen scale.
    private struct ContentsKey: Equatable {
        var symbol: String
        var pointSize: CGFloat
        var color: NSColor
        var side: CGFloat
        var scale: CGFloat
    }

    private var contentsKey: ContentsKey?
    /// The anchor the rotation turns about, in unit coordinates: the hub of the
    /// fan, measured from the pixels rather than assumed to be the middle of
    /// the box. The symbol's own box is not centred on its hub, and a rotation
    /// about the box centre makes the hub orbit - a wobble that is obvious at
    /// any size in a menu bar.
    private var hub = CGPoint(x: 0.5, y: 0.5)
    /// The period on screen, nil when the glyph stands still.
    private(set) var secondsPerRevolution: Double?

    private static let animationKey = "spin"

    init() {
        // Over the label bitmap, under the status light.
        layer.zPosition = 0.5
        layer.isHidden = true
        layer.contentsGravity = .resize
    }

    /// Whether the animation is really attached, for the capture status file.
    var isSpinning: Bool { layer.animation(forKey: FanIconLayer.animationKey) != nil }

    /// The angle the glyph is at right now, in radians. The presentation layer
    /// is the only honest source while an animation runs.
    var currentAngle: CGFloat {
        let layer = self.layer.presentation() ?? self.layer
        return layer.value(forKeyPath: "transform.rotation.z") as? CGFloat ?? 0
    }

    /// Puts the glyph exactly where the bitmap used to draw it.
    ///
    /// `box` is the symbol's own rectangle in the coordinate system of the
    /// layer that hosts this one; nil means there is no glyph in the label at
    /// all. The layer itself is the square around that box, so no rotation ever
    /// clips a corner.
    func place(
        box: CGRect?,
        awake: Bool,
        solo: Bool,
        color: NSColor,
        scale: CGFloat,
        geometryFlipped: Bool
    ) {
        guard let box, box.width > 0, box.height > 0 else {
            stop()
            layer.isHidden = true
            return
        }
        let side = hypot(box.width, box.height).rounded(.up)
        let key = ContentsKey(
            symbol: awake ? "fan.fill" : "fan",
            pointSize: solo ? MenuBarMetrics.soloIconSize : MenuBarMetrics.iconSize,
            color: color,
            side: side,
            scale: scale
        )
        if key != contentsKey {
            guard let rendered = FanIconLayer.render(key: key) else { return }
            contentsKey = key
            layer.contents = rendered.image
            layer.contentsScale = scale
            // Two things that are easy to get wrong, and both were.
            //
            // The contents image is displayed the right way up whatever the
            // host view does with its geometry, so it is never drawn flipped:
            // the button of a status item is a flipped view, and compensating
            // for that mirrored the glyph.
            //
            // The unit square the anchor lives in does follow the host. In a
            // flipped view the layer's y runs down, so the anchor is the hub's
            // fraction from the top of the image, which is how it is measured;
            // in an ordinary view it is the other way up.
            hub = geometryFlipped
                ? rendered.hub
                : CGPoint(x: rendered.hub.x, y: 1 - rendered.hub.y)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = false
        layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        layer.anchorPoint = hub
        layer.position = CGPoint(
            x: box.midX - side / 2 + hub.x * side,
            y: box.midY - side / 2 + hub.y * side
        )
        CATransaction.commit()
    }

    /// Turns the glyph at one revolution per `seconds`, or stops it.
    ///
    /// The new animation starts from the angle the presentation layer is at, so
    /// a speed change is a change of speed and not a jump back to zero.
    func spin(secondsPerRevolution seconds: Double?) {
        guard FanSpin.reissues(current: secondsPerRevolution, next: seconds) else { return }
        guard let seconds else {
            stop()
            return
        }
        let from = currentAngle
        secondsPerRevolution = seconds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: FanIconLayer.animationKey)
        layer.setValue(from, forKeyPath: "transform.rotation.z")
        CATransaction.commit()

        // Stepped, not smooth. A smooth rotation makes the window server
        // composite the menu bar strip at the panel's 120 Hz for as long as
        // the fans turn: measured at 2.5 to 4.7 points of WindowServer CPU on
        // this M1 Pro. `FanSpin.framesPerSecond` discrete steps read as
        // turning and ask for a new frame only when the angle really changes.
        let steps = FanSpin.steps(secondsPerRevolution: seconds)
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        // Negative: a fan whose blades are drawn leading edge first turns this
        // way, and it is the direction the SF Symbol's own animation uses.
        animation.values = (0...steps).map { from - 2 * .pi * CGFloat($0) / CGFloat(steps) }
        animation.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        animation.calculationMode = .discrete
        animation.duration = seconds
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: FanIconLayer.animationKey)
    }

    /// Removes the animation and leaves the glyph upright.
    func stop() {
        secondsPerRevolution = nil
        guard layer.animation(forKey: FanIconLayer.animationKey) != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: FanIconLayer.animationKey)
        layer.setValue(CGFloat(0), forKeyPath: "transform.rotation.z")
        CATransaction.commit()
    }

    // MARK: - The glyph

    /// How finely the hub is measured, whatever the screen gets.
    ///
    /// At a 2x backing the glyph is 26 px across, and the centre of mass of
    /// that much antialiasing lands a fifth of a point away from the real hub -
    /// which is a fifth of a point of wobble, and a fifth of a point of
    /// difference from where the bitmap used to draw the glyph. Measuring the
    /// same drawing at 8x costs one more bitmap per colour change.
    private static let hubScale: CGFloat = 8

    /// The symbol in the menu bar's own colour, inside the square the rotation
    /// needs, plus where its hub is in that square.
    private static func render(key: ContentsKey) -> (image: CGImage, hub: CGPoint)? {
        guard let rep = draw(key: key, scale: key.scale), let image = rep.cgImage else { return nil }
        guard key.scale >= hubScale else {
            guard let fine = draw(key: key, scale: hubScale) else { return nil }
            return (image, hub(of: fine))
        }
        return (image, hub(of: rep))
    }

    /// One render of the glyph at one scale.
    private static func draw(key: ContentsKey, scale: CGFloat) -> NSBitmapImageRep? {
        guard let symbol = NSImage(systemSymbolName: key.symbol, accessibilityDescription: nil),
              let configured = symbol.withSymbolConfiguration(
                  NSImage.SymbolConfiguration(pointSize: key.pointSize, weight: .medium)
              )
        else { return nil }
        configured.isTemplate = true

        let pixels = Int((key.side * scale).rounded())
        guard pixels > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = CGSize(width: key.side, height: key.side)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        let drawn = CGRect(
            x: ((key.side - configured.size.width) / 2),
            y: ((key.side - configured.size.height) / 2),
            width: configured.size.width,
            height: configured.size.height
        )
        configured.draw(
            in: drawn,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        // A template image draws black; the menu bar would tint it, and here
        // nothing will, so the colour is applied to the ink itself.
        key.color.set()
        NSRect(x: 0, y: 0, width: key.side, height: key.side).fill(using: .sourceAtop)
        context.flushGraphics()
        return rep
    }

    /// The centre of mass of the ink, in unit coordinates measured from the top
    /// left of the bitmap.
    ///
    /// The fan has four identical blades around its hub, so the centroid of
    /// what is drawn *is* the hub, to the pixel, and it costs one pass over a
    /// bitmap the size of a menu bar icon, once per colour change.
    private static func hub(of rep: NSBitmapImageRep) -> CGPoint {
        var total = 0.0
        var x = 0.0
        var y = 0.0
        for row in 0..<rep.pixelsHigh {
            for column in 0..<rep.pixelsWide {
                guard let alpha = rep.colorAt(x: column, y: row)?.alphaComponent, alpha > 0 else {
                    continue
                }
                total += alpha
                x += alpha * (Double(column) + 0.5)
                y += alpha * (Double(row) + 0.5)
            }
        }
        guard total > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: x / total / Double(rep.pixelsWide), y: y / total / Double(rep.pixelsHigh))
    }
}
