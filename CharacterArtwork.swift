import AppKit
import ImageIO

/// Refreshed basic and approved Halloween artwork, rasterized at 1x/2x.
enum CharacterArtwork {
    static func isBicycle(_ visual: CharacterVisual) -> Bool {
        switch visual {
        case .basic(count: 2, _), .halloween(.bicycle, _): return true
        default: return false
        }
    }

    static func frameCount(for visual: CharacterVisual) -> Int { isBicycle(visual) ? 8 : 6 }

    static func image(visual: CharacterVisual, state: CharacterMotionState, frame: Int,
                      basicImage: NSImage? = nil, pose: CharacterRenderPose? = nil,
                      halloweenStore: HalloweenArtworkStore = .shared, renderSize: CGFloat = 21,
                      basicStore: BasicArtworkStore = .shared) -> NSImage? {
        guard visual != .numbers else { return nil }
        let pose = pose ?? .init(frame: frame % frameCount(for: visual), sleepStep: state == .rest ? 8 : 0,
            breathFrame: state == .rest ? frame % 12 : 0, zFrame: state == .rest ? frame % 28 : -1)
        if case .basic(let count, _) = visual {
            guard basicStore.hasArtwork(for: count) else { return nil }
        }
        if case .halloween(let character, _) = visual {
            guard halloweenStore.hasArtwork(for: character) else { return nil }
        }
        let bicycle = isBicycle(visual)
        // The menu bar gives horizontal characters their own width. Gallery tiles
        // remain square, with the same 30 × 21 drawing fitted inside them.
        let canvasWidth: CGFloat = bicycle ? 30 : 21
        let outputSize = NSSize(width: bicycle && renderSize == 21 ? canvasWidth : renderSize, height: renderSize)
        let drawingScale = renderSize / (bicycle && renderSize != 21 ? canvasWidth : 21)
        let image = NSImage(size: outputSize)
        for scale in [1, 2] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(outputSize.width) * scale,
                pixelsHigh: Int(renderSize) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            bitmap.size = image.size
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.cgContext.translateBy(x: 0, y: (outputSize.height - 21 * drawingScale) / 2)
            context.cgContext.scaleBy(x: drawingScale, y: drawingScale)
            NSColor.black.setFill(); NSColor.black.setStroke()
            context.cgContext.saveGState()
            if needsSleepRoom(visual) {
                // Broad silhouettes settle slightly smaller and to the left,
                // leaving a clear Z column without changing their proportions.
                let amount = CGFloat(pose.sleepAmount), fit = 1 - 0.15 * amount
                context.cgContext.translateBy(x: 10.5 - 0.8 * amount, y: 1.5)
                context.cgContext.scaleBy(x: fit, y: fit)
                context.cgContext.translateBy(x: -10.5, y: -1.5)
            }
            switch visual {
            case .numbers: break
            case .basic(let count, _):
                if count == 2 { drawBicycle(basicStore: basicStore, halloweenStore: halloweenStore, halloween: false, pose: pose, state: state) }
                else { drawBasic(count, store: basicStore, pose: pose, state: state) }
            case .halloween(let character, _):
                if character == .bicycle { drawBicycle(basicStore: basicStore, halloweenStore: halloweenStore, halloween: true, pose: pose, state: state) }
                else { drawHalloween(character, store: halloweenStore, pose: pose, state: state) }
            }
            context.cgContext.restoreGState()
            if state == .rest, pose.zFrame >= 0 {
                let marks = sleepMarkLayout(for: visual)
                if renderSize <= 21 {
                    menuBarSleepMark(frame: pose.zFrame, onLeft: marks.origin < 10,
                                     canvasWidth: canvasWidth, pixelScale: CGFloat(scale) * drawingScale)
                } else {
                    sleepMarks(frame: pose.zFrame, originX: marks.origin, drift: marks.drift)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(bitmap)
        }
        image.isTemplate = true
        image.alignmentRect = NSRect(origin: .zero, size: image.size)
        return image
    }

    private static func ellipse(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: w, height: h)).fill()
    }
    private static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat = 1) {
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius).fill()
    }
    private static func shape(_ points: [(CGFloat, CGFloat)]) {
        guard let first = points.first else { return }
        let p = NSBezierPath(); p.move(to: NSPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { p.line(to: NSPoint(x: point.0, y: point.1)) }
        p.close(); p.fill()
    }
    private static func line(_ points: [(CGFloat, CGFloat)], width: CGFloat = 1.25) {
        guard let first = points.first else { return }
        let p = NSBezierPath(); p.lineWidth = width; p.lineCapStyle = .round; p.lineJoinStyle = .round
        p.move(to: NSPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { p.line(to: NSPoint(x: point.0, y: point.1)) }
        p.stroke()
    }
    private static func cut(_ body: () -> Void) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.setBlendMode(.clear); body(); context.restoreGState()
    }
    private static func needsSleepRoom(_ visual: CharacterVisual) -> Bool {
        switch visual {
        case .basic(let count, _): return [4, 5, 9].contains(count)
        case .halloween(let character, _): return [.hound, .desk, .fox].contains(character)
        case .numbers: return false
        }
    }

    private static func sleepMarkLayout(for visual: CharacterVisual) -> (origin: CGFloat, drift: CGFloat) {
        if needsSleepRoom(visual) { return (18, 0) }
        switch visual {
        case .basic(let count, _):
            switch count {
            case 0, 6, 11, 12: return (2.4, 0)
            case 2, 7, 10: return (2.4, 2.6)
            case 8: return (18, 0)
            default: return (15.3, 2.6)
            }
        case .halloween(let character, _):
            switch character {
            case .pumpkin, .star, .web, .scythe: return (2.4, 0)
            case .staff: return (1.8, 2.6)
            case .bicycle, .spider: return (2.4, 2.6)
            default: return (15.3, 2.6)
            }
        case .numbers: return (15.3, 2.6)
        }
    }

    private static func menuBarSleepMark(frame: Int, onLeft: Bool, canvasWidth: CGFloat, pixelScale: CGFloat) {
        // At 21pt, a 2pt-high Z collapses into a few gray pixels. Use one
        // 4 x 5pt glyph with solid, pixel-aligned bars and a readable diagonal.
        let step = frame % 14
        let x: CGFloat = onLeft ? 1 : canvasWidth - 5
        let y = (CGFloat(13) + CGFloat(step) / 13 * 2) * pixelScale
        let originY = y.rounded() / pixelScale
        let alpha: CGFloat = step == 0 || step == 13 ? 0.7 : 1
        NSColor.black.withAlphaComponent(alpha).setFill()
        let rows = [(0, 0, 4), (0, 1, 1), (1, 2, 1), (2, 3, 1), (0, 4, 4)]
        for (dx, dy, width) in rows {
            NSRect(x: x + CGFloat(dx), y: originY + CGFloat(dy), width: CGFloat(width), height: 1).fill()
        }
        NSColor.black.setFill()
    }

    private static func sleepMarks(frame: Int, originX: CGFloat, drift: CGFloat) {
        // Stagger the larger marks far enough apart to keep each Z legible at 1x.
        for offset in [0, 9, 18] {
            let progress = CGFloat((frame + offset) % 28) / 28
            let alpha = min(1, progress / 0.10) * min(1, (1 - progress) / 0.22)
            NSColor.black.withAlphaComponent(alpha).setStroke()
            let x = originX - 1 + progress * drift + sin(progress * .pi * 2) * 0.25
            let y = 9.2 + progress * 8.1
            let w = 1.75 + progress, h = 1.5 + progress * 0.75
            line([(x, y + h), (x + w, y + h), (x, y), (x + w, y)], width: 0.8)
        }
        NSColor.black.setStroke()
    }

    private static func bicycleRoad(frame: Int, awake: CGFloat, busy: Bool) {
        guard awake > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: CGRect(x: 1.5, y: 0.9, width: 27, height: 1))
        NSColor.black.withAlphaComponent((busy ? 0.70 : 0.55) * awake).setStroke()
        // Active travels one dash spacing per eight-pose loop, busy travels two.
        // With the 120ms/80ms cadence, busy traffic moves three times as fast.
        let shift = CGFloat((frame * (busy ? 2 : 1)) % 8)
        for dash in 0...4 {
            let x = CGFloat(dash) * 8 - shift
            line([(x, 1.3), (x + 3.6, 1.3)], width: 0.65)
        }
        context.restoreGState()
        NSColor.black.setStroke()
    }

    /// Bicycle-specific 8-pose cycle, drawn in a 30 × 21 point canvas.
    /// Tires stay circular; cranks, basket and passenger have separate motion.
    private static func drawBicycle(basicStore: BasicArtworkStore, halloweenStore: HalloweenArtworkStore,
                                    halloween: Bool, pose: CharacterRenderPose, state: CharacterMotionState) {
        guard let sprite = halloween ? halloweenStore.sprite(for: .bicycle) : basicStore.sprite(for: 2),
              let context = NSGraphicsContext.current?.cgContext else { return }
        let key = pose.frame % 8, moving = state == .active || state == .busy
        let sleeping = CGFloat(pose.sleepAmount), awake = 1 - sleeping
        let phase = CGFloat(key) * .pi / 4
        let busy = state == .busy
        if moving { bicycleRoad(frame: key, awake: awake, busy: busy) }
        let width: CGFloat = halloween ? 23.0 : 25.5
        let unit = width / sprite.sourceBounds.width
        let rect = NSRect(x: (30 - width) / 2, y: halloween ? 1.25 : 1.4,
                          width: width, height: width / sprite.aspect)
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + (x - sprite.sourceBounds.minX) * unit,
                    y: rect.minY + (sprite.sourceBounds.maxY - y) * unit)
        }
        func region(_ source: CGRect) -> CGRect {
            // Keep the mask beyond the trimmed source bounds. High-quality
            // interpolation can otherwise leave a faint edge above the old head.
            CGRect(x: rect.minX + (source.minX - sprite.sourceBounds.minX) * unit,
                   y: rect.minY + (sprite.sourceBounds.maxY - source.maxY) * unit,
                   width: source.width * unit, height: source.height * unit)
        }
        let basket = CGRect(x: 826, y: 305, width: 337, height: 248)
        // The handlebar is beside the ghost's lowest lobe. Two disjoint cuts
        // retain that handlebar without leaving a black fragment in the passenger.
        let ghostCuts = [CGRect(x: 340, y: 185, width: 430, height: 349),
                         CGRect(x: 340, y: 534, width: 375, height: 32)]
        let cutouts = halloween ? ghostCuts : [basket]
        func sourcePart(_ cuts: [CGRect], excluding: Bool = false) {
            context.saveGState()
            if excluding { context.addRect(rect.insetBy(dx: -2, dy: -2)) }
            for cutout in cuts { context.addRect(region(cutout)) }
            context.clip(using: excluding ? .evenOdd : .winding)
            sprite.draw(in: rect)
            context.restoreGState()
        }
        let back = halloween ? point(334, 895) : point(309, 775)
        let front = halloween ? point(920, 895) : point(942, 775)
        let crank = halloween ? point(613, 895) : point(611, 775)
        let radius = (halloween ? CGFloat(192) : CGFloat(208)) * unit
        let bounce: [CGFloat] = busy ? [0, -0.18, 0.05, 0.34, 0.20, -0.08, -0.13, 0.04]
                                             : [0, 0.12, 0.24, 0.15, 0, -0.08, -0.13, -0.05]
        let lean: [CGFloat] = busy ? [-0.018, -0.025, -0.01, 0.018, 0.025, 0.008, -0.015, -0.02]
                                           : [0, -0.006, -0.01, -0.005, 0.004, 0.009, 0.008, 0.003]
        let bodyLift = moving ? bounce[key] * 0.45 * awake : 0
        let bodyAngle = moving ? lean[key] * 0.65 * awake : (halloween ? 0 : -0.015 * sleeping)
        NSGraphicsContext.current?.imageInterpolation = .high
        context.saveGState()
        context.translateBy(x: crank.x, y: crank.y + bodyLift)
        context.rotate(by: bodyAngle)
        context.translateBy(x: -crank.x, y: -crank.y)
        if halloween {
            context.saveGState()
            // The bicycle base occupies only the lower band of the source. Its
            // own clip also removes interpolation residue from the detached head.
            context.clip(to: CGRect(x: 0, y: 0, width: 30, height: 15.5))
            sourcePart(cutouts, excluding: true)
            context.restoreGState()
        } else { sourcePart(cutouts, excluding: true) }

        // A single spoke per wheel reads at 1x and has a full eight-frame rotation.
        // The opaque tire ring and the hub are never cut or stretched.
        if moving {
            for hub in [back, front] {
                // AppKit's y axis points up: negative angles roll clockwise,
                // matching the forward pedal rotation and leftward road motion.
                let spoke = -phase - .pi / 4
                line([(hub.x, hub.y), (hub.x + cos(spoke) * radius * 0.67,
                      hub.y + sin(spoke) * radius * 0.67)], width: 0.6)
            }
        }
        let pedalAngle = moving ? -phase : -CGFloat.pi / 3
        let pedalLength: CGFloat = 1.7
        let pedal = NSPoint(x: crank.x + cos(pedalAngle) * pedalLength,
                            y: crank.y + sin(pedalAngle) * pedalLength)
        let opposite = NSPoint(x: crank.x - cos(pedalAngle) * pedalLength,
                               y: crank.y - sin(pedalAngle) * pedalLength)
        line([(opposite.x, opposite.y), (pedal.x, pedal.y)], width: 0.85)
        line([(pedal.x - 0.85, pedal.y), (pedal.x + 0.85, pedal.y)], width: 0.85)
        line([(opposite.x - 0.6, opposite.y), (opposite.x + 0.6, opposite.y)], width: 0.65)

        if !halloween {
            let anchor = point(863, 540)
            let basketLean: [CGFloat] = busy ? [0.01, 0.025, -0.018, -0.055, -0.02, 0.035, 0.015, -0.015]
                                                    : [0, -0.008, -0.025, -0.012, 0.01, 0.02, 0.012, 0]
            context.saveGState()
            context.translateBy(x: anchor.x, y: anchor.y)
            context.rotate(by: moving ? basketLean[key] * awake : 0)
            context.translateBy(x: -anchor.x, y: -anchor.y)
            sourcePart([basket])
            context.restoreGState()
            // Solid mounting bracket joins the smiling basket to the front fork.
            let fork = point(825, 535)
            line([(fork.x, fork.y), (anchor.x + 0.4, anchor.y + 0.15)], width: 0.8)
        }
        context.restoreGState()

        guard halloween else { return }
        let ghostSource = CGRect(x: 354, y: 202, width: 403, height: 355)
        let original = region(ghostSource)
        let float: [CGFloat] = busy ? [0.05, -0.20, -0.08, 0.35, 0.75, 0.55, 0.20, 0]
                                           : [0, 0.35, 0.65, 0.45, 0, -0.25, -0.35, -0.15]
        let tilt: [CGFloat] = busy ? [0.10, 0.16, 0.20, 0.12, -0.01, -0.04, 0.02, 0.07]
                                          : [0, 0.025, 0.05, 0.025, -0.02, -0.04, -0.025, 0]
        let hem: [CGFloat] = busy ? [-0.02, 0.04, 0.13, 0.18, 0.07, -0.12, -0.14, -0.08]
                                         : [-0.03, 0, 0.06, 0.10, 0.05, -0.02, -0.07, -0.06]
        let ghostScale: CGFloat = 7.0 / original.width
        let floatY = moving ? float[key] * 0.20 * awake : 0
        let center = NSPoint(x: 14.1 - sleeping * 4.35 - (busy ? 0.2 * awake : 0),
                             y: 16.55 + floatY - sleeping * 3.6)
        let dissolve = max(0, min(1, (sleeping - 0.30) / 0.70))
        let foldedOpacity = dissolve * dissolve * (3 - 2 * dissolve)
        if foldedOpacity < 1 {
            context.saveGState()
            context.setAlpha(1 - foldedOpacity)
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: moving ? tilt[key] * 0.45 * awake : 0)
            context.scaleBy(x: ghostScale * (1 - sleeping * 0.10), y: ghostScale * (1 - sleeping * 0.52))
            context.translateBy(x: -original.midX, y: -original.midY)
            // A shear below the face has zero displacement at its seam; the cloth
            // trails one pose behind without detaching or warping either eye.
            let seam = point(354, 417).y
            sourcePart([CGRect(x: 340, y: 185, width: 430, height: 232)])
            context.saveGState()
            let shear = moving ? hem[key] * 0.5 * awake : 0
            context.concatenate(CGAffineTransform(a: 1, b: 0, c: shear, d: 1, tx: -shear * seam, ty: 0))
            sourcePart([CGRect(x: 340, y: 417, width: 430, height: 117), ghostCuts[1]])
            context.restoreGState()
            context.restoreGState()
        }
        if foldedOpacity > 0, let resting = halloweenStore.bicycleRest {
            let breath = state == .rest ? sin(CGFloat(pose.breathFrame) * .pi / 6) * 0.08 : 0
            let restWidth: CGFloat = 7.3
            let restHeight = restWidth / resting.aspect * (1 + breath)
            let saddle = point(469, 563)
            resting.draw(in: NSRect(x: saddle.x - restWidth / 2, y: saddle.y - 0.2,
                                    width: restWidth, height: restHeight), opacity: foldedOpacity)
        }
    }

    private enum Gait {
        case run, hop, ride, float
        case gallop, spring, wheelie, flight, roll, spin, sweep, slither
    }

    /// Each action owns its poses. Busy actions change the contact pattern, axis and
    /// anticipation, rather than multiplying the walking pose by a larger amplitude.
    private static func locomotion(_ gait: Gait, rect: NSRect, pose: CharacterRenderPose,
                                   state: CharacterMotionState, legMotion: Bool = false,
                                   wheelHubY: CGFloat = 0.273, spinStep: CGFloat = .pi / 3) {
        let frame = pose.frame % 6
        let awake = CGFloat(1 - pose.sleepAmount)
        guard awake > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        if state == .active && frame == 0 { return }
        let lift: [CGFloat], stretch: [CGFloat], narrow: [CGFloat], lean: [CGFloat]
        let hop: CGFloat, angle: CGFloat, padding: CGFloat
        var side: [CGFloat] = [0, 0, 0, 0, 0, 0]
        switch gait {
        case .run:
            lift = [0, 0.65, 1, 0, 0.85, 0.30]
            stretch = [1, 0.94, 0.96, 0.86, 0.94, 0.98]
            narrow = [1, 0.98, 0.96, 1, 0.97, 0.99]
            lean = [0, -1, 0.3, 1, -0.3, -0.7]
            hop = 1.0; angle = 0.035; padding = legMotion ? 0.65 : 0.20
        case .hop:
            lift = [0, 0, 0.4, 1, 0.45, 0]
            stretch = [1, 0.86, 1.02, 0.92, 0.98, 0.84]
            narrow = [1, 1, 0.96, 0.95, 0.98, 1]
            lean = [0, -0.4, -0.2, 0, 0.2, 0.4]
            hop = 1.15; angle = 0.04; padding = 0.20
        case .ride:
            lift = [0, 0.4, 1, 0.2, 0.75, 0.3]
            // Uniform scaling preserves round wheels through every contact pose.
            stretch = [1, 0.98, 0.97, 1, 0.98, 0.99]
            narrow = stretch
            lean = [0, -0.3, -1, 0.4, 0.8, 0.2]
            hop = 0.88; angle = 0.02; padding = 0.12
        case .float:
            lift = [0, 0.7, 1, 0.25, -0.7, -1]
            stretch = [1, 0.97, 0.92, 0.99, 0.97, 0.92]
            narrow = [1, 0.98, 0.96, 0.99, 0.98, 0.96]
            lean = [0, 0.5, 1, 0.3, -0.5, -1]
            hop = 0.60; angle = 0.055; padding = 0.20
        case .gallop:
            // Low contact -> gather the pair of legs -> airborne extension -> landing.
            lift = [0, 0.1, 0.35, 1, 0.2, 0]
            stretch = [0.94, 0.84, 0.90, 0.97, 0.86, 0.93]
            narrow = [1, 1, 0.92, 0.90, 0.99, 1]
            lean = [-0.4, -1, -1.1, -0.7, -0.35, -0.2]
            hop = 1.45; angle = 0.10; padding = legMotion ? 0.85 : 0.20
            side = [0, -0.15, 0, 0.45, 0.2, 0]
        case .spring:
            // A single deep anticipation and long flight replaces the alternating walk.
            lift = [0, 0, 0.35, 1, 0.85, 0.15]
            stretch = [0.96, 0.72, 0.89, 0.97, 0.92, 0.80]
            narrow = [1, 1, 0.83, 0.89, 0.95, 1]
            lean = [0, 0.15, -0.25, -0.1, 0.15, 0]
            hop = 2.1; angle = 0.07; padding = legMotion ? 0.85 : 0.20
        case .wheelie:
            // A rear-wheel pivot raises the front tire, then sets it down.
            lift = [0, 0, 0.1, 0.2, 0, 0]
            stretch = [1, 0.99, 0.96, 0.95, 0.99, 1]
            narrow = stretch
            lean = [0, 0.25, 0.85, 1, 0.5, 0.05]
            hop = 0.25; angle = 0.18; padding = 0.16
        case .flight:
            lift = [0, 0.2, 0.6, 0.3, -0.2, -0.4]
            stretch = [1, 0.99, 0.97, 1, 0.98, 0.97]
            narrow = stretch
            lean = [-0.75, -0.82, -0.78, -0.63, -0.60, -0.68]
            side = [-0.6, 0, 0.6, 0.9, 0.1, -0.7]
            hop = 0.7; angle = 1; padding = 0.20
        case .roll:
            lift = [0, 0.05, 0.3, 0.15, 0, 0.2]
            stretch = [1, 0.95, 0.98, 0.96, 0.92, 1]
            narrow = [1, 1, 0.97, 1, 0.99, 0.97]
            lean = [0, -0.35, -0.55, 0, 0.4, 0.55]
            side = [0, -0.35, -0.65, 0, 0.45, 0.55]
            hop = 0.55; angle = 1; padding = 0.20
        case .spin:
            lift = [0, 0.3, 0.7, 0.1, -0.2, -0.4]
            stretch = [1, 0.98, 0.96, 1, 0.98, 0.96]
            narrow = stretch
            lean = (0..<6).map { CGFloat($0) * spinStep }
            hop = 0.65; angle = 1; padding = 0.20
        case .sweep:
            lift = [0, 0, 0.1, 0.5, 0.25, 0]
            stretch = [1, 0.98, 0.96, 0.95, 0.98, 1]
            narrow = stretch
            lean = [-0.35, -0.6, -0.75, -0.05, 0.7, 0.4]
            side = [-0.3, -0.6, -0.7, 0.2, 0.65, 0.35]
            hop = 0.8; angle = 1; padding = 0.20
        case .slither:
            lift = [0, 0.1, 0.4, 0.2, 0, 0]
            stretch = [0.90, 0.80, 0.78, 0.88, 0.93, 0.91]
            narrow = [1, 0.96, 0.94, 1, 0.97, 0.95]
            lean = [-0.08, -0.16, -0.2, -0.06, 0.04, 0.02]
            side = [-0.8, -0.4, 0.1, 0.6, 0.7, -0.2]
            hop = 1; angle = 1; padding = 0.60
        }
        let sx = 1 + (narrow[frame] - 1) * awake
        let sy = 1 + (stretch[frame] - 1) * awake
        let rotation = lean[frame] * angle * awake
        // Spinning shapes also inherit the outer sleep tilt during wake-up.
        let inset = 1.1 + (gait == .spin ? (1 - awake) * 0.8 : 0)
        let safe = NSRect(x: inset, y: inset, width: 21 - 2 * inset, height: 21 - 2 * inset)
        let overhang = padding * awake + CGFloat(pose.sleepAmount) * 0.3
        let envelope = rect.insetBy(dx: -overhang, dy: -overhang)
        let diameter = max(envelope.width * sx, envelope.height * sy) * 1.04
        let projectedWidth = gait == .spin ? diameter
            : abs(envelope.width * sx * cos(rotation)) + abs(envelope.height * sy * sin(rotation))
        let projectedHeight = gait == .spin ? diameter
            : abs(envelope.height * sy * cos(rotation)) + abs(envelope.width * sx * sin(rotation))
        let fit = min(1, safe.width / projectedWidth, safe.height / projectedHeight)
        let halfWidth = projectedWidth * fit / 2, halfHeight = projectedHeight * fit / 2
        let drift = (side[frame] + (state == .active ? lean[frame] * 0.10 : 0)) * awake
        var desiredX = rect.midX + drift
        // Floating objects bob about their center; runners compress toward the ground.
        let centered = [.float, .flight, .spin, .sweep].contains(gait)
        let anchorY = centered ? rect.midY : rect.minY + rect.height * sy * fit / 2
        var desiredY = anchorY + lift[frame] * hop * awake
        if gait == .wheelie {
            let dx = -rect.width * 0.30, dy = rect.height * (wheelHubY - 0.5)
            let rearY = rect.minY + rect.height * wheelHubY - rect.width * 0.166 * (1 - sx * fit)
            desiredX = rect.minX + rect.width * 0.20 - (dx * cos(rotation) - dy * sin(rotation)) * sx * fit
            desiredY = rearY - (dx * sin(rotation) + dy * cos(rotation)) * sy * fit + lift[frame] * hop * awake
        }
        let centerX = min(safe.maxX - halfWidth, max(safe.minX + halfWidth, desiredX))
        let centerY = min(safe.maxY - halfHeight, max(safe.minY + halfHeight, desiredY))
        context.translateBy(x: centerX, y: centerY)
        context.rotate(by: rotation)
        context.scaleBy(x: sx * fit, y: sy * fit)
        context.translateBy(x: -rect.midX, y: -rect.midY)
    }

    private enum LimbAction { case gallop, gather, push }

    /// Walking alternates legs; galloping pairs them, while tentacles gather and
    /// extend together. Scaling happens about the joint, keeping each limb attached.
    private static func busyLimb(_ action: LimbAction, index: Int, count: Int,
                                 pose: CharacterRenderPose) -> (angle: CGFloat, x: CGFloat, y: CGFloat) {
        let awake = CGFloat(1 - pose.sleepAmount)
        let frame = pose.frame % 6
        let direction = CGFloat(index) * 2 / CGFloat(max(1, count - 1)) - 1
        let angle: CGFloat, x: CGFloat, y: CGFloat
        switch action {
        case .gallop:
            let key = (frame + (index < count / 2 ? 0 : 3)) % 6
            angle = [0.1, 1, 0.2, -1, -0.55, 0.3][key] * 0.20
            x = 1
            y = [1, 0.86, 0.76, 0.91, 1, 0.98][key]
        case .gather:
            angle = -direction * [0, 0.8, 1, 0.35, -0.85, -0.25][frame] * 0.28
            x = [1, 0.95, 0.88, 0.94, 1, 1][frame]
            y = [1, 0.88, 0.65, 0.74, 1, 0.90][frame]
        case .push:
            angle = direction * [0, 0.55, 1, 0.15, -0.8, -0.2][frame] * 0.21
            x = [1, 0.90, 0.70, 0.80, 1, 0.94][frame]
            y = 1
        }
        return (angle * awake, 1 + (x - 1) * awake, 1 + (y - 1) * awake)
    }

    /// Only the two front paws are rigged. The face, ears and fan of tails are a
    /// single uncut layer, so the approved character identity survives the pounce.
    private static func pouncingPaws(_ sprite: HalloweenArtworkStore.Sprite, rect: NSRect,
                                    pose: CharacterRenderPose) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard pose.sleepAmount < 1 else { sprite.draw(in: rect); return }
        let paws = NSRect(x: rect.minX + rect.width * 0.30, y: rect.minY,
                          width: rect.width * 0.40, height: rect.height * 0.20)
        context.saveGState()
        context.addRect(rect.insetBy(dx: -1, dy: -1)); context.addRect(paws)
        context.clip(using: .evenOdd); sprite.draw(in: rect); context.restoreGState()
        for index in 0..<2 {
            let x = 0.30 + CGFloat(index) * 0.20
            let limb = busyLimb(.gather, index: index, count: 2, pose: pose)
            let pivot = NSPoint(x: rect.minX + rect.width * (x + 0.10), y: paws.maxY)
            context.saveGState()
            context.translateBy(x: pivot.x, y: pivot.y); context.rotate(by: limb.angle)
            context.scaleBy(x: limb.x, y: limb.y); context.translateBy(x: -pivot.x, y: -pivot.y)
            sprite.draw(in: rect, part: NSRect(x: x, y: 0, width: 0.20, height: 0.205))
            context.restoreGState()
        }
    }

    private static func propellingTentacles(_ sprite: HalloweenArtworkStore.Sprite, rect: NSRect,
                                           pose: CharacterRenderPose) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Curled tips rise above the neck. A T-shaped head mask keeps those tips
        // with the tentacle fan, rather than cutting them off with a horizontal band.
        let crown = NSRect(x: rect.minX, y: rect.minY + rect.height * 0.44,
                           width: rect.width, height: rect.height * 0.56)
        let neck = NSRect(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.315,
                          width: rect.width * 0.50, height: rect.height * 0.125)
        let awake = CGFloat(1 - pose.sleepAmount), key = pose.frame % 6
        let x = 1 + ([1, 0.86, 0.64, 0.78, 1, 0.94][key] - 1) * awake
        let y = 1 + ([1, 0.93, 0.75, 0.88, 1, 0.95][key] - 1) * awake
        let pivot = NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.34)
        context.saveGState()
        context.translateBy(x: pivot.x, y: pivot.y); context.scaleBy(x: x, y: y)
        context.translateBy(x: -pivot.x, y: -pivot.y)
        context.addRect(rect.insetBy(dx: -1, dy: -1)); context.addRect(crown); context.addRect(neck)
        context.clip(using: .evenOdd); sprite.draw(in: rect)
        context.restoreGState()
        // Paint the intact face last, covering the tentacles' moving joints.
        context.saveGState(); context.addRect(crown); context.addRect(neck); context.clip()
        sprite.draw(in: rect); context.restoreGState()
    }

    /// The refreshed basic family shares a face scale, while the free six-pose loop
    /// keeps each silhouette readable. Paid states add rest, breath and distinct actions.
    private static func drawBasic(_ count: Int, store: BasicArtworkStore,
                                  pose: CharacterRenderPose, state: CharacterMotionState) {
        guard let sprite = store.sprite(for: count), let context = NSGraphicsContext.current?.cgContext else { return }
        let sleeping = CGFloat(pose.sleepAmount)
        let moving = state == .active || state == .busy
        let phase = CGFloat(pose.frame) * .pi / 3
        let wave = moving ? sin(phase) * (1 - sleeping) : 0
        let turn = moving ? (cos(phase) - 1) * (1 - sleeping) : 0
        let energy: CGFloat = state == .busy ? 1.45 : 1
        let strideEnergy: CGFloat = state == .busy ? 3.0 : 2.0
        let breath = state == .rest ? sin(CGFloat(pose.breathFrame) * .pi / 6) * 0.18 * sleeping : 0
        let refreshed = count == 2 || count == 9
        let width = min(refreshed ? 19 : 18.2, (refreshed ? 17.5 : 16.6) * sprite.aspect)
        let height = width / sprite.aspect
        // The larger bicycle and fox use the optical center from the approved design.
        let baseline: CGFloat = refreshed ? (21 - height) / 2 : 1.55
        let rect = NSRect(x: (21 - width) / 2, y: baseline, width: width, height: height)
        NSGraphicsContext.current?.imageInterpolation = .high
        context.saveGState()
        // Keep rest and unknown pixel-identical; only the moving states use the new gait.
        let pivotY = refreshed ? rect.midY : rect.minY
        context.translateBy(x: 10.5, y: pivotY + breath)
        let restTilt: CGFloat = count == 2 ? 0.018 : 0.055
        context.rotate(by: -sleeping * restTilt)
        context.scaleBy(x: 1 + breath * 0.02, y: 1 - sleeping * 0.025)
        context.translateBy(x: -10.5, y: -pivotY)
        if moving {
            let gait: Gait
            if state == .busy {
                switch count {
                case 1: gait = .slither
                case 2: gait = .wheelie
                case 4, 6: gait = .gallop
                case 0, 12: gait = .roll
                case 5: gait = .spin
                default: gait = .spring
                }
            } else {
                gait = count == 2 ? .ride : [3, 4, 6, 8, 9, 10, 11].contains(count) ? .run : .hop
            }
            locomotion(gait, rect: rect, pose: pose, state: state,
                       legMotion: [3, 4, 6, 8, 10, 11].contains(count))
        }
        defer { context.restoreGState() }
        func part(_ region: NSRect, pivot: NSPoint, angle: CGFloat = 0,
                  xScale: CGFloat = 1, yScale: CGFloat = 1) {
            context.saveGState()
            context.translateBy(x: pivot.x, y: pivot.y); context.rotate(by: angle)
            context.scaleBy(x: xScale, y: yScale)
            context.translateBy(x: -pivot.x, y: -pivot.y)
            sprite.draw(in: rect, part: region)
            context.restoreGState()
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        func leg(_ region: NSRect, pivot: NSPoint, angle: CGFloat,
                 index: Int, count: Int, action: LimbAction) {
            if state == .busy {
                let limb = busyLimb(action, index: index, count: count, pose: pose)
                part(region, pivot: pivot, angle: limb.angle, xScale: limb.x, yScale: limb.y)
            } else { part(region, pivot: pivot, angle: angle) }
        }
        switch count {
        case 1:
            sprite.draw(in: rect, part: NSRect(x: 0, y: 0, width: 1, height: 0.49))
            let head: CGFloat = state == .busy
                ? [-0.08, -0.16, 0.08, 0.24, 0.12, -0.02][pose.frame % 6] * (1 - sleeping)
                : wave * 0.055 * energy
            part(NSRect(x: 0, y: 0.48, width: 1, height: 0.52), pivot: point(0.5, 0.48), angle: head)
        case 2: break // Rendered in the bicycle canvas.
        case 3:
            sprite.draw(in: rect, part: NSRect(x: 0, y: 0.46, width: 1, height: 0.54))
            for index in 0..<3 {
                let x = CGFloat(index) / 3
                let stride = wave * CGFloat(index == 1 ? -1 : 1) + turn * CGFloat(index - 1) * 0.35
                leg(NSRect(x: x, y: 0, width: 1 / 3, height: 0.465),
                    pivot: point(x + 1 / 6, 0.46), angle: stride * 0.045 * strideEnergy,
                    index: index, count: 3, action: .gather)
            }
        case 4:
            sprite.draw(in: rect, part: NSRect(x: 0, y: 0.45, width: 1, height: 0.55))
            let edges: [CGFloat] = [0, 0.17, 0.5, 0.83, 1]
            for index in 0..<4 {
                leg(NSRect(x: edges[index], y: 0, width: edges[index + 1] - edges[index], height: 0.455),
                     pivot: point((edges[index] + edges[index + 1]) / 2, 0.45),
                     angle: wave * (index % 2 == 0 ? 1 : -1) * 0.038 * strideEnergy,
                     index: index, count: 4, action: .gallop)
            }
        case 6:
            sprite.draw(in: rect, part: NSRect(x: 0.27, y: 0, width: 0.46, height: 1))
            for side in [false, true] {
                let x: CGFloat = side ? 0.73 : 0
                sprite.draw(in: rect, part: NSRect(x: x, y: 0.58, width: 0.27, height: 0.42))
                for index in 0..<3 {
                    let y = CGFloat(index) * 0.58 / 3
                    leg(NSRect(x: x, y: y, width: 0.27, height: 0.58 / 3),
                         pivot: point(side ? 0.73 : 0.27, y + 0.58 / 6),
                         angle: wave * (index % 2 == 0 ? 1 : -1) * (side ? -1 : 1) * 0.045 * strideEnergy,
                         index: side ? 5 - index : index, count: 6, action: .push)
                }
            }
        case 8:
            sprite.draw(in: rect, part: NSRect(x: 0, y: 0.43, width: 1, height: 0.57))
            for index in 0..<4 {
                let x = CGFloat(index) / 4
                leg(NSRect(x: x, y: 0, width: 0.25, height: 0.435),
                    pivot: point(x + 0.125, 0.43), angle: wave * (index % 2 == 0 ? 1 : -1) * 0.045 * strideEnergy,
                    index: index, count: 4, action: .gather)
            }
        case 9:
            if state == .busy { pouncingPaws(sprite, rect: rect, pose: pose) }
            else { sprite.draw(in: rect) }
        case 10:
            if state == .busy {
                propellingTentacles(sprite, rect: rect, pose: pose)
            } else {
                sprite.draw(in: rect, part: NSRect(x: 0, y: 0.34, width: 1, height: 0.66))
                part(NSRect(x: 0, y: 0, width: 1, height: 0.345), pivot: point(0.5, 0.34), angle: wave * 0.035 * strideEnergy)
            }
        case 11:
            for index in 0..<2 {
                let x = CGFloat(index) / 2
                let lean: CGFloat = state == .busy
                    ? [0, -0.025, -0.06, 0.035, 0.05, 0.015][pose.frame % 6] * (1 - sleeping)
                    : wave * (index == 0 ? 1 : -1) * 0.022 * strideEnergy
                part(NSRect(x: x, y: 0, width: 0.5, height: 1), pivot: point(x + 0.25, 0.03), angle: lean)
            }
        default:
            sprite.draw(in: rect)
        }
    }

    private static func drawHalloween(_ character: HalloweenCharacter, store: HalloweenArtworkStore,
                                      pose: CharacterRenderPose, state: CharacterMotionState) {
        guard var sprite = store.sprite(for: character), let context = NSGraphicsContext.current?.cgContext else { return }
        let sleeping = CGFloat(pose.sleepAmount)
        let moving = state == .active || state == .busy
        let phase = CGFloat(pose.frame) * .pi / 3
        let wave: CGFloat = moving ? sin(phase) * (1 - sleeping) : 0
        let breath = state == .rest ? sin(CGFloat(pose.breathFrame) * .pi / 6) * 0.18 * sleeping : 0
        let energetic: CGFloat = state == .busy ? 1.4 : 1
        let strideEnergy: CGFloat = state == .busy ? 3.0 : 2.0
        if character == .desk {
            let key: HalloweenArtworkStore.DeskPose = sleeping >= 0.5 ? .rest : state == .busy ? .run : .walk
            guard let desk = store.desk(key) else { return }
            sprite = desk
        }
        let refreshed: Bool = [.staff, .bicycle, .hound, .web, .scythe, .fox].contains(character)
        let width = min(refreshed ? 19 : 18, (refreshed ? 17.5 : 17) * sprite.aspect)
        let height = width / sprite.aspect
        let baseline: CGFloat = refreshed ? (21 - height) / 2 : 1.6
        let bodyBreath: CGFloat = character == .bicycle ? 0 : breath
        let rect = NSRect(x: (21 - width) / 2, y: baseline + bodyBreath, width: width, height: height)
        NSGraphicsContext.current?.imageInterpolation = .high
        context.saveGState()
        if moving {
            let gait: Gait
            if state == .busy {
                switch character {
                case .bicycle: gait = .wheelie
                case .hound, .fox, .star: gait = .spring
                case .desk, .spider: gait = .gallop
                case .staff: gait = .flight
                case .web: gait = .spin
                case .scythe: gait = .sweep
                case .pumpkin: gait = .roll
                }
            } else {
                switch character {
                case .bicycle: gait = .ride
                case .hound, .desk, .spider, .fox: gait = .run
                case .staff, .web, .scythe: gait = .float
                case .pumpkin, .star: gait = .hop
                }
            }
            locomotion(gait, rect: rect, pose: pose, state: state,
                       legMotion: character == .desk || character == .spider,
                       wheelHubY: 0.193, spinStep: .pi / 9)
        }
        defer { context.restoreGState() }

        func transformed(_ pivot: NSPoint, angle: CGFloat = 0, xScale: CGFloat = 1, yScale: CGFloat = 1, _ draw: () -> Void) {
            context.saveGState()
            context.translateBy(x: pivot.x, y: pivot.y); context.rotate(by: angle)
            context.scaleBy(x: xScale, y: yScale); context.translateBy(x: -pivot.x, y: -pivot.y)
            draw(); context.restoreGState()
        }
        func part(_ region: NSRect, pivot: NSPoint, angle: CGFloat = 0, dy: CGFloat = 0,
                  xScale: CGFloat = 1, yScale: CGFloat = 1) {
            context.saveGState(); context.translateBy(x: 0, y: dy)
            transformed(pivot, angle: angle, xScale: xScale, yScale: yScale) { sprite.draw(in: rect, part: region) }
            context.restoreGState()
        }
        func leg(_ region: NSRect, pivot: NSPoint, angle: CGFloat,
                 index: Int, count: Int, action: LimbAction) {
            if state == .busy {
                let limb = busyLimb(action, index: index, count: count, pose: pose)
                part(region, pivot: pivot, angle: limb.angle, xScale: limb.x, yScale: limb.y)
            } else { part(region, pivot: pivot, angle: angle) }
        }
        switch character {
        case .pumpkin:
            transformed(NSPoint(x: rect.midX, y: rect.minY), xScale: 1 + breath * 0.025,
                yScale: 1 - sleeping * 0.035 + breath * 0.025) { sprite.draw(in: rect) }
        case .staff:
            transformed(NSPoint(x: rect.midX, y: rect.minY), angle: -sleeping * 0.08) { sprite.draw(in: rect) }
        case .bicycle: break // Rendered in the bicycle canvas.
        case .hound:
            transformed(NSPoint(x: rect.midX, y: rect.midY), angle: -sleeping * 0.025) {
                if state == .busy { pouncingPaws(sprite, rect: rect, pose: pose) }
                else { sprite.draw(in: rect) }
            }
        case .desk:
            // Walking alternates the four wooden legs; galloping gathers them in pairs.
            sprite.draw(in: rect, part: NSRect(x: 0, y: 0.48, width: 1, height: 0.52))
            for index in 0..<4 {
                let x = CGFloat(index) / 4
                let step = wave * (index % 2 == 0 ? 1 : -1) * 0.055 * strideEnergy
                leg(NSRect(x: x, y: 0, width: 0.25, height: 0.485),
                    pivot: NSPoint(x: rect.minX + (x + 0.125) * rect.width, y: rect.minY + rect.height * 0.48),
                    angle: step, index: index, count: 4, action: .gallop)
            }
        case .star:
            sprite.draw(in: rect, part: NSRect(x: 0, y: 0, width: 1, height: 0.57))
            let hat: CGFloat = state == .busy
                ? [0, -0.12, 0.06, 0.22, -0.1, -0.05][pose.frame % 6] * (1 - sleeping)
                : wave * 0.045 * energetic
            part(NSRect(x: 0, y: 0.56, width: 1, height: 0.44),
                 pivot: NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.56), angle: hat - sleeping * 0.025)
        case .web:
            sprite.draw(in: rect)
        case .scythe:
            transformed(NSPoint(x: rect.midX, y: rect.minY), angle: -sleeping * 0.035) { sprite.draw(in: rect) }
        case .spider:
            sprite.draw(in: rect, part: NSRect(x: 0.29, y: 0, width: 0.42, height: 1))
            for index in 0..<4 {
                let y = CGFloat(index) / 4
                let step = wave * (index % 2 == 0 ? 1 : -1) * 0.045 * strideEnergy
                for side in [false, true] {
                    leg(NSRect(x: side ? 0.71 : 0, y: y, width: 0.29, height: 0.25),
                         pivot: NSPoint(x: rect.minX + rect.width * (side ? 0.71 : 0.29), y: rect.minY + rect.height * (y + 0.125)),
                         angle: step * (side ? -1 : 1),
                         index: side ? 7 - index : index, count: 8, action: .push)
                }
            }
        case .fox:
            transformed(NSPoint(x: rect.midX, y: rect.midY), angle: -sleeping * 0.025) {
                if state == .busy { pouncingPaws(sprite, rect: rect, pose: pose) }
                else { sprite.draw(in: rect) }
            }
        }
    }

}

/// Bundled, approved illustrations. Crop coordinates exclude sheet labels. White paper and
/// interior white cuts become alpha; the source silhouettes are never redrawn from primitives.
final class HalloweenArtworkStore {
    static let shared = HalloweenArtworkStore()

    struct Sprite {
        let image: NSImage
        /// Ink/canvas bounds in the original PNG's top-left coordinate system.
        let sourceBounds: CGRect
        var aspect: CGFloat { image.size.width / image.size.height }
        func region(forSourceRect source: CGRect) -> NSRect {
            NSRect(x: (source.minX - sourceBounds.minX) / sourceBounds.width,
                   y: (sourceBounds.maxY - source.maxY) / sourceBounds.height,
                   width: source.width / sourceBounds.width, height: source.height / sourceBounds.height)
                .intersection(NSRect(x: 0, y: 0, width: 1, height: 1))
        }
        func draw(in destination: NSRect, part: NSRect = NSRect(x: 0, y: 0, width: 1, height: 1),
                  opacity: CGFloat = 1) {
            let source = NSRect(x: part.minX * image.size.width, y: part.minY * image.size.height,
                width: part.width * image.size.width, height: part.height * image.size.height)
            let target = NSRect(x: destination.minX + part.minX * destination.width,
                y: destination.minY + part.minY * destination.height,
                width: part.width * destination.width, height: part.height * destination.height)
            image.draw(in: target, from: source, operation: .sourceOver, fraction: opacity)
        }
    }
    enum DeskPose: CaseIterable { case rest, walk, run }
    private var sprites: [HalloweenCharacter: Sprite] = [:]
    private var deskPoses: [DeskPose: Sprite] = [:]
    private(set) var bicycleRest: Sprite?

    init(bundle: Bundle = .main) {
        if let sheet = Self.load("HalloweenCharacters", bundle: bundle) {
            let regions: [(HalloweenCharacter, CGRect)] = [
                (.pumpkin, .init(x: 40, y: 68, width: 301, height: 313)),
                (.desk, .init(x: 1425, y: 119, width: 318, height: 261)),
                (.star, .init(x: 43, y: 475, width: 279, height: 313)),
                (.spider, .init(x: 997, y: 545, width: 343, height: 216)),
            ]
            for (character, rect) in regions { sprites[character] = Self.mask(sheet, crop: rect) }
        }
        // Standalone originals avoid repacking or resampling the other approved characters.
        let replacements: [(HalloweenCharacter, String)] = [
            (.staff, "HalloweenBroom"), (.hound, "HalloweenHound"), (.web, "HalloweenWeb"),
            (.scythe, "HalloweenScythe"), (.fox, "HalloweenFox"), (.bicycle, "HalloweenBicycle")
        ]
        for (character, name) in replacements {
            sprites[character] = Self.standalone(name, bundle: bundle)
        }
        bicycleRest = Self.standalone("HalloweenBicycleRest", bundle: bundle)
        if let sheet = Self.load("HalloweenDeskPoses", bundle: bundle) {
            // The rest sheet's decorative z is deliberately excluded; the common clock draws Zzz.
            for (pose, rect) in [(DeskPose.rest, CGRect(x: 62, y: 320, width: 464, height: 302)),
                                 (.walk, CGRect(x: 596, y: 261, width: 546, height: 378)),
                                 (.run, CGRect(x: 1164, y: 221, width: 579, height: 405))] {
                deskPoses[pose] = Self.mask(sheet, crop: rect)
            }
        }
    }

    func sprite(for character: HalloweenCharacter) -> Sprite? { sprites[character] }
    func desk(_ pose: DeskPose) -> Sprite? { deskPoses[pose] }
    func hasArtwork(for character: HalloweenCharacter) -> Bool {
        sprites[character] != nil
            && (character != .bicycle || bicycleRest != nil)
            && (character != .desk || DeskPose.allCases.allSatisfy { deskPoses[$0] != nil })
    }
    var hasCompleteCollection: Bool {
        HalloweenCharacter.allCases.allSatisfy { hasArtwork(for: $0) }
    }

    fileprivate static func load(_ name: String, bundle: Bundle, width: Int? = 1774, height: Int? = 887) -> CGImage? {
        guard let url = bundle.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              (width == nil || image.width == width), (height == nil || image.height == height) else { return nil }
        return image
    }

    fileprivate static func standalone(_ name: String, bundle: Bundle) -> Sprite? {
        guard let source = load(name, bundle: bundle, width: nil, height: nil) else { return nil }
        return mask(source, crop: CGRect(x: 0, y: 0, width: source.width, height: source.height))
    }

    fileprivate static func mask(_ sheet: CGImage, crop: CGRect, trim: Bool = true) -> Sprite? {
        guard let image = sheet.cropping(to: crop) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        var prepared: CGImage?
        var sourceBounds = crop
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = buffer.bindMemory(to: UInt8.self)
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let luminance = (Int(pixels[offset]) * 77 + Int(pixels[offset + 1]) * 150 + Int(pixels[offset + 2]) * 29) / 256
                    let alpha = UInt8(max(0, 235 - luminance) * Int(pixels[offset + 3]) / 235)
                    pixels[offset] = 0; pixels[offset + 1] = 0; pixels[offset + 2] = 0; pixels[offset + 3] = alpha
                    if alpha > 20 {
                        minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                }
            }
            guard maxX >= minX, maxY >= minY else { return }
            // CG bitmap rows and CGImage crop coordinates share this origin.
            let bounds = trim ? CGRect(x: max(0, minX - 1), y: max(0, minY - 1),
                width: min(width - max(0, minX - 1), maxX - minX + 3),
                height: min(height - max(0, minY - 1), maxY - minY + 3))
                : CGRect(x: 0, y: 0, width: width, height: height)
            sourceBounds = bounds.offsetBy(dx: crop.minX, dy: crop.minY)
            prepared = context.makeImage()?.cropping(to: bounds)
        }
        guard let prepared else { return nil }
        return Sprite(image: NSImage(cgImage: prepared, size: NSSize(width: prepared.width, height: prepared.height)),
                      sourceBounds: sourceBounds)
    }
}

/// The free 0...12 family uses the master sheet plus the approved bicycle and fox.
/// Labels and empty cells are outside these regions. The original atlas remains archived.
final class BasicArtworkStore {
    static let shared = BasicArtworkStore()
    private var sprites: [Int: HalloweenArtworkStore.Sprite] = [:]

    init(bundle: Bundle = .main) {
        if let sheet = HalloweenArtworkStore.load("BasicCharacters", bundle: bundle, width: 1536, height: 1024) {
            // Five columns by three rows. The final two cells are intentionally empty.
            let columns: [(CGFloat, CGFloat)] = [(12, 305), (330, 590), (606, 914), (947, 1180), (1231, 1510)]
            let rows: [(CGFloat, CGFloat)] = [(50, 283), (368, 600), (675, 923)]
            for count in 0...12 where count != 2 && count != 9 {
                let (left, right) = columns[count % 5], (top, bottom) = rows[count / 5]
                sprites[count] = HalloweenArtworkStore.mask(sheet,
                    crop: CGRect(x: left, y: top, width: right - left, height: bottom - top))
            }
        }
        sprites[2] = HalloweenArtworkStore.standalone("BasicBicycle", bundle: bundle)
        sprites[9] = HalloweenArtworkStore.standalone("BasicFox", bundle: bundle)
    }
    func sprite(for count: Int) -> HalloweenArtworkStore.Sprite? { sprites[count] }
    func hasArtwork(for count: Int) -> Bool { sprites[count] != nil }
    var hasCompleteCollection: Bool { (0...12).allSatisfy { hasArtwork(for: $0) } }
}
