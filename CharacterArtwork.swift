import AppKit
import ImageIO

/// Refreshed basic and approved Halloween artwork, rasterized at 1x/2x.
enum CharacterArtwork {
    static func image(visual: CharacterVisual, state: CharacterMotionState, frame: Int,
                      basicImage: NSImage? = nil, pose: CharacterRenderPose? = nil,
                      halloweenStore: HalloweenArtworkStore = .shared, renderSize: CGFloat = 21,
                      basicStore: BasicArtworkStore = .shared) -> NSImage? {
        guard visual != .numbers else { return nil }
        let pose = pose ?? .still(state: state, frame: frame)
        if case .basic(let count, _) = visual {
            guard basicStore.hasArtwork(for: count) else { return nil }
        }
        if case .halloween(let character, _) = visual {
            guard halloweenStore.hasArtwork(for: character) else { return nil }
        }
        let image = NSImage(size: NSSize(width: renderSize, height: renderSize))
        for scale in [1, 2] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(renderSize) * scale,
                pixelsHigh: Int(renderSize) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            bitmap.size = image.size
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(scale) * renderSize / 21, y: CGFloat(scale) * renderSize / 21)
            NSColor.black.setFill(); NSColor.black.setStroke()
            switch visual {
            case .numbers: break
            case .basic(let count, _):
                drawBasic(count, store: basicStore, pose: pose, state: state)
            case .halloween(let character, _):
                drawHalloween(character, store: halloweenStore, pose: pose, state: state)
            }
            if state == .rest, pose.zFrame >= 0 { sleepMarks(frame: pose.zFrame) }
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
    private static func sleepMarks(frame: Int) {
        for offset in [0, 14] {
            let progress = CGFloat((frame + offset) % 28) / 28
            let alpha = min(1, progress / 0.14) * min(1, (1 - progress) / 0.32)
            NSColor.black.withAlphaComponent(alpha).setStroke()
            let x = 15.3 + progress * 2, y = 13.8 + progress * 4
            let w = 1.35 + progress * 0.9, h = 1.3 + progress * 0.8
            line([(x, y + h), (x + w, y + h), (x, y), (x + w, y)], width: 0.65)
        }
        NSColor.black.setStroke()
    }

    /// The refreshed basic family shares a face scale, while the free six-pose loop
    /// keeps each silhouette readable. Paid states add rest, breath and a faster gait.
    private static func drawBasic(_ count: Int, store: BasicArtworkStore,
                                  pose: CharacterRenderPose, state: CharacterMotionState) {
        guard let sprite = store.sprite(for: count), let context = NSGraphicsContext.current?.cgContext else { return }
        let sleeping = CGFloat(pose.sleepAmount)
        let moving = state == .active || state == .busy
        let phase = CGFloat(pose.frame) * .pi / 3
        let wave = moving ? sin(phase) * (1 - sleeping) : 0
        let turn = moving ? (cos(phase) - 1) * (1 - sleeping) : 0
        let energy: CGFloat = state == .busy ? 1.45 : 1
        let breath = state == .rest ? sin(CGFloat(pose.breathFrame) * .pi / 6) * 0.18 * sleeping : 0
        let width = min(18.2, 16.6 * sprite.aspect), height = width / sprite.aspect
        // Wide bicycles need their own vertical center instead of the family's ground line.
        let baseline: CGFloat = count == 2 ? (21 - height) / 2 : 1.55
        let rect = NSRect(x: (21 - width) / 2, y: baseline, width: width, height: height)
        NSGraphicsContext.current?.imageInterpolation = .high
        context.saveGState()
        // Two phase coordinates produce six real poses, rather than duplicate sine samples.
        context.translateBy(x: 10.5 + turn * 0.14 * energy, y: rect.minY + wave * 0.22 * energy + breath)
        context.rotate(by: -sleeping * 0.055 + wave * 0.014 * energy)
        context.scaleBy(x: 1 + breath * 0.02, y: 1 - sleeping * 0.025)
        context.translateBy(x: -10.5, y: -rect.minY)
        defer { context.restoreGState() }
        func part(_ region: NSRect, pivot: NSPoint, angle: CGFloat = 0) {
            context.saveGState()
            context.translateBy(x: pivot.x, y: pivot.y); context.rotate(by: angle)
            context.translateBy(x: -pivot.x, y: -pivot.y)
            sprite.draw(in: rect, part: region)
            context.restoreGState()
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        switch count {
        case 1:
            sprite.draw(in: rect, part: NSRect(x: 0, y: 0, width: 1, height: 0.49))
            part(NSRect(x: 0, y: 0.48, width: 1, height: 0.52), pivot: point(0.5, 0.48), angle: wave * 0.035 * energy)
        case 2:
            sprite.draw(in: rect)
            if moving, sleeping < 0.5 {
                for x in [0.192, 0.804] {
                    let center = point(x, 0.309), radius = rect.width * 0.166
                    for angle in [phase, phase + .pi] {
                        cut { ellipse(center.x + cos(angle) * radius - 0.22,
                                      center.y + sin(angle) * radius - 0.22, 0.44, 0.44) }
                    }
                }
            }
        case 3:
            sprite.draw(in: rect, part: NSRect(x: 0, y: 0.46, width: 1, height: 0.54))
            for index in 0..<3 {
                let x = CGFloat(index) / 3
                let stride = wave * CGFloat(index == 1 ? -1 : 1) + turn * CGFloat(index - 1) * 0.35
                part(NSRect(x: x, y: 0, width: 1 / 3, height: 0.465),
                     pivot: point(x + 1 / 6, 0.46), angle: stride * 0.045 * energy)
            }
        case 4:
            sprite.draw(in: rect, part: NSRect(x: 0, y: 0.45, width: 1, height: 0.55))
            let edges: [CGFloat] = [0, 0.17, 0.5, 0.83, 1]
            for index in 0..<4 {
                part(NSRect(x: edges[index], y: 0, width: edges[index + 1] - edges[index], height: 0.455),
                     pivot: point((edges[index] + edges[index + 1]) / 2, 0.45),
                     angle: wave * (index % 2 == 0 ? 1 : -1) * 0.038 * energy)
            }
        case 6:
            sprite.draw(in: rect, part: NSRect(x: 0.27, y: 0, width: 0.46, height: 1))
            for side in [false, true] {
                let x: CGFloat = side ? 0.73 : 0
                sprite.draw(in: rect, part: NSRect(x: x, y: 0.58, width: 0.27, height: 0.42))
                for index in 0..<3 {
                    let y = CGFloat(index) * 0.58 / 3
                    part(NSRect(x: x, y: y, width: 0.27, height: 0.58 / 3),
                         pivot: point(side ? 0.73 : 0.27, y + 0.58 / 6),
                         angle: wave * (index % 2 == 0 ? 1 : -1) * (side ? -1 : 1) * 0.045 * energy)
                }
            }
        case 8:
            sprite.draw(in: rect, part: NSRect(x: 0, y: 0.43, width: 1, height: 0.57))
            for index in 0..<4 {
                let x = CGFloat(index) / 4
                part(NSRect(x: x, y: 0, width: 0.25, height: 0.435),
                     pivot: point(x + 0.125, 0.43), angle: wave * (index % 2 == 0 ? 1 : -1) * 0.045 * energy)
            }
        case 9:
            sprite.draw(in: rect, part: NSRect(x: 0.29, y: 0, width: 0.42, height: 1))
            part(NSRect(x: 0, y: 0, width: 0.295, height: 1), pivot: point(0.29, 0.22), angle: wave * 0.022 * energy)
            part(NSRect(x: 0.705, y: 0, width: 0.295, height: 1), pivot: point(0.71, 0.22), angle: -wave * 0.022 * energy)
        case 10:
            sprite.draw(in: rect, part: NSRect(x: 0, y: 0.34, width: 1, height: 0.66))
            part(NSRect(x: 0, y: 0, width: 1, height: 0.345), pivot: point(0.5, 0.34), angle: wave * 0.035 * energy)
        case 11:
            for index in 0..<2 {
                let x = CGFloat(index) / 2
                part(NSRect(x: x, y: 0, width: 0.5, height: 1),
                     pivot: point(x + 0.25, 0.03), angle: wave * (index == 0 ? 1 : -1) * 0.022 * energy)
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
        if character == .desk {
            let key: HalloweenArtworkStore.DeskPose = sleeping >= 0.5 ? .rest : state == .busy ? .run : .walk
            guard let desk = store.desk(key) else { return }
            sprite = desk
        }
        let width = min(18, 17 * sprite.aspect), height = width / sprite.aspect
        let bounce = abs(wave) * (character == .web ? 0.1 : 0.35) * energetic
        let baseline: CGFloat = character == .bicycle ? (21 - height) / 2 : 1.6
        let bodyBreath: CGFloat = character == .bicycle ? 0 : breath
        let rect = NSRect(x: (21 - width) / 2, y: baseline + bodyBreath + bounce, width: width, height: height)
        NSGraphicsContext.current?.imageInterpolation = .high

        func transformed(_ pivot: NSPoint, angle: CGFloat = 0, xScale: CGFloat = 1, yScale: CGFloat = 1, _ draw: () -> Void) {
            context.saveGState()
            context.translateBy(x: pivot.x, y: pivot.y); context.rotate(by: angle)
            context.scaleBy(x: xScale, y: yScale); context.translateBy(x: -pivot.x, y: -pivot.y)
            draw(); context.restoreGState()
        }
        func part(_ region: NSRect, pivot: NSPoint, angle: CGFloat = 0, dy: CGFloat = 0) {
            context.saveGState(); context.translateBy(x: 0, y: dy)
            transformed(pivot, angle: angle) { sprite.draw(in: rect, part: region) }
            context.restoreGState()
        }
        switch character {
        case .pumpkin:
            transformed(NSPoint(x: rect.midX, y: rect.minY), xScale: 1 + breath * 0.025,
                yScale: 1 - sleeping * 0.035 + breath * 0.025) { sprite.draw(in: rect) }
        case .staff:
            transformed(NSPoint(x: rect.midX, y: rect.minY), angle: -sleeping * 0.08 + wave * 0.055 * energetic) { sprite.draw(in: rect) }
        case .bicycle:
            guard let foldedGhost = store.bicycleSleepingGhost else { return }
            // The same ghost descends and folds onto the saddle; only the cloth breathes.
            let float = (wave * 0.32 + breath * 0.6) * (1 - sleeping)
            if sleeping == 0, float == 0 {
                sprite.draw(in: rect)
            } else {
                // This boundary follows the empty gap in the 678×576 source, keeping
                // the handlebar and saddle outside the ghost's moving region.
                let ghost = CGMutablePath()
                let points: [(CGFloat, CGFloat)] = [(0.28, 1), (0.585, 1), (0.585, 0.60),
                    (0.44, 0.60), (0.44, 0.64), (0.28, 0.64)]
                ghost.addLines(between: points.map { NSPoint(x: rect.minX + $0.0 * rect.width,
                                                              y: rect.minY + $0.1 * rect.height) })
                ghost.closeSubpath()
                context.saveGState()
                context.addRect(rect.insetBy(dx: -1, dy: -1)); context.addPath(ghost)
                context.clip(using: .evenOdd)
                sprite.draw(in: rect)
                context.restoreGState()
                let dissolve = max(0, min(1, (sleeping - 0.35) / 0.65))
                let foldedOpacity = dissolve * dissolve * (3 - 2 * dissolve)
                let pivot = NSPoint(x: rect.minX + rect.width * 0.438,
                                    y: rect.minY + rect.height * 0.60)
                context.saveGState()
                context.translateBy(x: pivot.x - rect.width * 0.088 * sleeping, y: pivot.y + float)
                context.scaleBy(x: 1 - sleeping * 0.18, y: 1 - sleeping * 0.58)
                context.translateBy(x: -pivot.x, y: -pivot.y)
                context.addPath(ghost); context.clip()
                sprite.draw(in: rect, opacity: 1 - foldedOpacity)
                context.restoreGState()
                if foldedOpacity > 0 {
                    let foldedWidth = rect.width * 0.25
                    let foldedHeight = foldedWidth / foldedGhost.aspect * (1 + breath * 0.12)
                    let foldedRect = NSRect(x: rect.minX + rect.width * 0.35 - foldedWidth / 2,
                        y: rect.minY + rect.height * 0.60, width: foldedWidth, height: foldedHeight)
                    foldedGhost.draw(in: foldedRect, opacity: foldedOpacity)
                }
            }
            if moving, sleeping < 0.5 {
                // A rotating rim highlight keeps both original round wheels and the frame intact.
                for x in [0.20, 0.80] {
                    let cx = rect.minX + rect.width * x, cy = rect.minY + rect.height * 0.26
                    let radius = rect.width * 0.195
                    for angle in [phase, phase + .pi] {
                        cut { ellipse(cx + cos(angle) * radius - 0.27, cy + sin(angle) * radius - 0.27, 0.54, 0.54) }
                    }
                }
            }
        case .hound:
            sprite.draw(in: rect, part: NSRect(x: 0, y: 0, width: 1, height: 0.53))
            for index in 0..<3 {
                let x = CGFloat(index) / 3
                let nod = moving ? sin(phase + CGFloat(index) * .pi * 2 / 3) * 0.025 * energetic : -sleeping * 0.025
                part(NSRect(x: x, y: 0.52, width: 1 / 3, height: 0.48),
                     pivot: NSPoint(x: rect.minX + (x + 1 / 6) * rect.width, y: rect.minY + rect.height * 0.52), angle: nod)
            }
        case .desk:
            // The approved three key poses retain four connected wooden legs. Small opposite
            // rotations of the four lower regions add a gait without inventing new anatomy.
            sprite.draw(in: rect, part: NSRect(x: 0, y: 0.48, width: 1, height: 0.52))
            for index in 0..<4 {
                let x = CGFloat(index) / 4
                let step = wave * (index % 2 == 0 ? 1 : -1) * 0.055 * energetic
                part(NSRect(x: x, y: 0, width: 0.25, height: 0.485),
                     pivot: NSPoint(x: rect.minX + (x + 0.125) * rect.width, y: rect.minY + rect.height * 0.48), angle: step)
            }
        case .star:
            sprite.draw(in: rect, part: NSRect(x: 0, y: 0, width: 1, height: 0.57))
            part(NSRect(x: 0, y: 0.56, width: 1, height: 0.44),
                 pivot: NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.56), angle: wave * 0.045 * energetic - sleeping * 0.025)
        case .web:
            transformed(NSPoint(x: rect.midX, y: rect.midY), angle: wave * 0.025,
                xScale: 1 + wave * 0.014, yScale: 1 - wave * 0.014) { sprite.draw(in: rect) }
        case .scythe:
            transformed(NSPoint(x: rect.midX, y: rect.minY), angle: wave * 0.045 * energetic - sleeping * 0.035) { sprite.draw(in: rect) }
        case .spider:
            sprite.draw(in: rect, part: NSRect(x: 0.29, y: 0, width: 0.42, height: 1))
            for index in 0..<4 {
                let y = CGFloat(index) / 4
                let step = wave * (index % 2 == 0 ? 1 : -1) * 0.045 * energetic
                for side in [false, true] {
                    part(NSRect(x: side ? 0.71 : 0, y: y, width: 0.29, height: 0.25),
                         pivot: NSPoint(x: rect.minX + rect.width * (side ? 0.71 : 0.29), y: rect.minY + rect.height * (y + 0.125)),
                         angle: step * (side ? -1 : 1))
                }
            }
        case .fox:
            sprite.draw(in: rect, part: NSRect(x: 0, y: 0, width: 1, height: 0.51))
            part(NSRect(x: 0, y: 0.50, width: 1, height: 0.50),
                 pivot: NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.50), angle: wave * 0.03 * energetic)
        }
    }

}

/// Bundled, approved illustrations. Crop coordinates exclude sheet labels. White paper and
/// interior white cuts become alpha; the source silhouettes are never redrawn from primitives.
final class HalloweenArtworkStore {
    static let shared = HalloweenArtworkStore()

    struct Sprite {
        let image: NSImage
        var aspect: CGFloat { image.size.width / image.size.height }
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
    private(set) var bicycleSleepingGhost: Sprite?

    init(bundle: Bundle = .main) {
        if let sheet = Self.load("HalloweenCharacters", bundle: bundle) {
            let regions: [(HalloweenCharacter, CGRect)] = [
                (.pumpkin, .init(x: 40, y: 68, width: 301, height: 313)),
                (.staff, .init(x: 412, y: 44, width: 190, height: 337)),
                (.hound, .init(x: 1038, y: 92, width: 337, height: 288)),
                (.desk, .init(x: 1425, y: 119, width: 318, height: 261)),
                (.star, .init(x: 43, y: 475, width: 279, height: 313)),
                (.web, .init(x: 356, y: 475, width: 297, height: 313)),
                (.scythe, .init(x: 716, y: 475, width: 256, height: 316)),
                (.spider, .init(x: 997, y: 545, width: 343, height: 216)),
                (.fox, .init(x: 1353, y: 457, width: 401, height: 334)),
            ]
            for (character, rect) in regions { sprites[character] = Self.mask(sheet, crop: rect) }
        }
        // The floating ghost bicycle replaces only this character; the family sheet stays intact.
        if let bicycle = Self.load("HalloweenBicycle", bundle: bundle, width: 678, height: 576) {
            sprites[.bicycle] = Self.mask(bicycle, crop: CGRect(x: 0, y: 0, width: 678, height: 576))
        }
        if let foldedGhost = Self.load("HalloweenBicycleSleepingGhost", bundle: bundle) {
            bicycleSleepingGhost = Self.mask(foldedGhost, crop: CGRect(x: 0, y: 0, width: 1774, height: 887))
        }
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
            && (character != .bicycle || bicycleSleepingGhost != nil)
            && (character != .desk || DeskPose.allCases.allSatisfy { deskPoses[$0] != nil })
    }
    var hasCompleteCollection: Bool {
        HalloweenCharacter.allCases.allSatisfy { hasArtwork(for: $0) }
    }

    fileprivate static func load(_ name: String, bundle: Bundle, width: Int = 1774, height: Int = 887) -> CGImage? {
        guard let url = bundle.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height else { return nil }
        return image
    }

    fileprivate static func mask(_ sheet: CGImage, crop: CGRect) -> Sprite? {
        guard let image = sheet.cropping(to: crop) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        var prepared: CGImage?
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
            let bounds = CGRect(x: max(0, minX - 1), y: max(0, minY - 1),
                width: min(width - max(0, minX - 1), maxX - minX + 3),
                height: min(height - max(0, minY - 1), maxY - minY + 3))
            prepared = context.makeImage()?.cropping(to: bounds)
        }
        guard let prepared else { return nil }
        return Sprite(image: NSImage(cgImage: prepared, size: NSSize(width: prepared.width, height: prepared.height)))
    }
}

/// The free 0...12 family uses the master sheet plus the approved basket bicycle.
/// Labels and empty cells are outside these regions. The original atlas remains archived.
final class BasicArtworkStore {
    static let shared = BasicArtworkStore()
    private var sprites: [Int: HalloweenArtworkStore.Sprite] = [:]

    init(bundle: Bundle = .main) {
        guard let sheet = HalloweenArtworkStore.load("BasicCharacters", bundle: bundle, width: 1536, height: 1024) else { return }
        // Five columns by three rows. The final two cells are intentionally empty.
        let columns: [(CGFloat, CGFloat)] = [(12, 305), (330, 590), (606, 914), (947, 1180), (1231, 1510)]
        let rows: [(CGFloat, CGFloat)] = [(50, 283), (368, 600), (675, 923)]
        for count in 0...12 where count != 2 {
            let (left, right) = columns[count % 5], (top, bottom) = rows[count / 5]
            sprites[count] = HalloweenArtworkStore.mask(sheet,
                crop: CGRect(x: left, y: top, width: right - left, height: bottom - top))
        }
        if let bicycle = HalloweenArtworkStore.load("BasicBicycle", bundle: bundle, width: 1536, height: 1024) {
            sprites[2] = HalloweenArtworkStore.mask(bicycle, crop: CGRect(x: 0, y: 0, width: 1536, height: 1024))
        }
    }
    func sprite(for count: Int) -> HalloweenArtworkStore.Sprite? { sprites[count] }
    func hasArtwork(for count: Int) -> Bool { sprites[count] != nil }
    var hasCompleteCollection: Bool { (0...12).allSatisfy { hasArtwork(for: $0) } }
}
