import AppKit

@main enum CharacterArtworkTests {
    static func main() throws {
        _ = NSApplication.shared
        guard CommandLine.arguments.count >= 2, let bundle = Bundle(path: CommandLine.arguments[1]) else { fatalError("Pass built app path") }
        let store = StatusCharacterFrameStore(bundle: bundle)
        precondition(store.halloweenArtwork.hasCompleteCollection, "Both approved Halloween sheets must ship in the app")
        precondition(store.basicArtwork.hasCompleteCollection, "The refreshed 13-character basic sheet must ship in the app")
        let missingStore = StatusCharacterFrameStore(bundle: Bundle(for: NSView.self))
        let missingAnimator = StatusCharacterAnimator(frameStore: missingStore, reduceMotion: { false })
        defer { missingAnimator.invalidate() }
        var missingTicks = 0
        missingAnimator.onFrameChanged = { missingTicks += 1 }
        let missingVisuals: [CharacterVisual] = (0...12).flatMap { count in
            [CharacterVisual.basic(count: count, reactive: false), .basic(count: count, reactive: true)]
        } + HalloweenCharacter.allCases.map { .halloween($0, animated: true) }
        for visual in missingVisuals {
            missingAnimator.configure(visual: visual, state: .active)
            precondition(missingAnimator.currentImage() == nil, "Missing artwork uses the existing numeric fallback")
        }
        // Exercise both branches long enough for an incorrectly started timer to fire.
        for visual in [CharacterVisual.basic(count: 2, reactive: false), .basic(count: 2, reactive: true),
                       .halloween(.fox, animated: true)] {
            missingAnimator.configure(visual: visual, state: .active)
            missingTicks = 0
            RunLoop.main.run(until: Date().addingTimeInterval(0.24))
            precondition(missingTicks == 0, "Missing resources do not keep an animation timer alive")
        }
        var images: [[NSImage]] = []
        let states: [CharacterMotionState] = [.rest, .active, .busy]
        let visuals: [CharacterVisual] = (0...12).map { .basic(count: $0, reactive: true) }
            + HalloweenCharacter.allCases.map { .halloween($0, animated: true) }
        for visual in visuals {
            var row: [NSImage] = []
            for state in states {
                var poses = Set<Data>()
                for frame in 0..<6 {
                    let basic: NSImage?
                    if case .basic(let count, _) = visual { basic = store.image(for: count, frame: state == .rest ? 0 : frame) }
                    else { basic = nil }
                    guard let icon = CharacterArtwork.image(visual: visual, state: state, frame: frame,
                        basicImage: basic, halloweenStore: store.halloweenArtwork, basicStore: store.basicArtwork) else { fatalError("Missing image") }
                    precondition(icon.representations.count == 2 && icon.isTemplate)
                    for representation in icon.representations {
                        let bitmap = representation as! NSBitmapImageRep
                        var ink = 0
                        for x in 0..<bitmap.pixelsWide {
                            for y in 0..<bitmap.pixelsHigh {
                                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { ink += 1 }
                            }
                        }
                        precondition(ink > 10 && ink < bitmap.pixelsWide * bitmap.pixelsHigh * 8 / 10, "Artwork must have ink and transparent margin")
                    }
                    poses.insert(icon.tiffRepresentation!)
                    row.append(icon)
                }
                if state != .rest { precondition(poses.count > 1, "Active and busy must move") }
            }
            images.append(row)
        }
        // Wide bicycles must stay vertically centered beside the menu-bar count.
        // Inspect rendered pixels so sprite padding and animation transforms are covered too.
        func bicycleBounds(_ icon: NSImage, context: String, centered: Bool = false) {
            for representation in icon.representations {
                let bitmap = representation as! NSBitmapImageRep
                var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 else { continue }
                        minX = min(minX, x); minY = min(minY, y)
                        maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                }
                let detail = "\(context), \(bitmap.pixelsWide)px, ink bounds (\(minX), \(minY))...(\(maxX), \(maxY))"
                precondition(maxX >= minX && maxY >= minY, "Bicycle has visible artwork: \(detail)")
                precondition(minX > 0 && minY > 0 && maxX < bitmap.pixelsWide - 1 && maxY < bitmap.pixelsHigh - 1,
                    "Bicycle and sleep marks stay clear of the bitmap edges: \(detail)")
                if centered {
                    let inkCenterY = Double(minY + maxY + 1) / 2
                    precondition(abs(inkCenterY - Double(bitmap.pixelsHigh) / 2) <= 1,
                        "Neutral bicycle is vertically centered within one output pixel: \(detail)")
                }
            }
        }
        for visual in [CharacterVisual.basic(count: 2, reactive: true), .halloween(.bicycle, animated: true)] {
            func renderBicycle(_ state: CharacterMotionState, pose: CharacterRenderPose) -> NSImage {
                CharacterArtwork.image(visual: visual, state: state, frame: pose.frame, pose: pose,
                    halloweenStore: store.halloweenArtwork, basicStore: store.basicArtwork)!
            }
            bicycleBounds(renderBicycle(.unknown, pose: .still(state: .unknown)), context: "\(visual) neutral", centered: true)
            for state in [CharacterMotionState.active, .busy] {
                for frame in 0..<6 {
                    bicycleBounds(renderBicycle(state, pose: .still(state: state, frame: frame)),
                        context: "\(visual) \(state) frame \(frame)")
                }
            }
            var timeline = CharacterMotionTimeline()
            timeline.setState(.rest, at: 0, reset: true)
            // Cover settling plus a complete breath and Z cycle with the actual timeline.
            for sample in 0...72 {
                let instant = Double(sample) / 20
                bicycleBounds(renderBicycle(.rest, pose: timeline.pose(at: instant)),
                    context: "\(visual) resting at \(instant)")
            }
            timeline.setState(.active, at: 3.6)
            for sample in 0...8 {
                let instant = 3.6 + Double(sample) / 20
                bicycleBounds(renderBicycle(.active, pose: timeline.pose(at: instant)),
                    context: "\(visual) waking at \(instant)")
            }
        }
        // The ghost folds onto the saddle while the original bicycle stays unchanged.
        // Freeze breathing and sleep marks so this checks only the folding transition.
        let ghostSleepFrames = [0, 4, 8].map { step in
            CharacterArtwork.image(visual: .halloween(.bicycle, animated: true), state: .rest, frame: 0,
                pose: .init(frame: 0, sleepStep: step, breathFrame: 0, zFrame: -1),
                halloweenStore: store.halloweenArtwork, renderSize: 64, basicStore: store.basicArtwork)!
        }
        precondition(Set(ghostSleepFrames.map { $0.tiffRepresentation! }).count == 3,
            "Halloween ghost has distinct floating, folding and folded poses")
        for representationIndex in ghostSleepFrames[0].representations.indices {
            let reference = ghostSleepFrames[0].representations[representationIndex] as! NSBitmapImageRep
            var minY = reference.pixelsHigh, maxY = -1
            for y in 0..<reference.pixelsHigh {
                for x in 0..<reference.pixelsWide where (reference.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            // Bitmap rows run downwards: the lower 55% of the artwork contains the
            // wheels and frame, below the saddle and the folding ghost.
            let firstBikeRow = minY + Int(ceil(Double(maxY - minY + 1) * 0.45))
            for image in ghostSleepFrames.dropFirst() {
                let bitmap = image.representations[representationIndex] as! NSBitmapImageRep
                for y in firstBikeRow..<reference.pixelsHigh {
                    for x in 0..<reference.pixelsWide {
                        precondition(bitmap.colorAt(x: x, y: y)?.alphaComponent == reference.colorAt(x: x, y: y)?.alphaComponent,
                            "Folding the ghost preserves the bicycle wheels and frame at \(reference.pixelsWide)px")
                    }
                }
            }
        }
        let gallery = StatusCharacterAnimator(frameStore: store, renderSize: 64, now: { 0 }, reduceMotion: { false })
        defer { gallery.invalidate() }
        for character in HalloweenCharacter.allCases {
            gallery.configure(visual: .halloween(character, animated: false), state: .unknown)
            let preview = gallery.currentImage()!
            precondition(preview.size == NSSize(width: 64, height: 64))
            precondition(preview.representations.map(\.pixelsWide) == [64, 128], "Gallery renders from the original source at its own resolution")
        }
        for count in 0...12 {
            for reactive in [false, true] {
                gallery.configure(visual: .basic(count: count, reactive: reactive), state: .active)
                let preview = gallery.currentImage()!
                precondition(preview.size == NSSize(width: 64, height: 64))
                precondition(preview.representations.map(\.pixelsWide) == [64, 128],
                    "Free and premium basic previews render from the source at gallery resolution")
                precondition(gallery.currentImage() === preview, "Unchanged preview poses reuse the cache")
            }
            for frame in 0..<6 {
                let pose = CharacterRenderPose(frame: frame, sleepStep: 0, breathFrame: 0, zFrame: -1)
                let free = store.image(for: count, frame: frame)!
                let premium = CharacterArtwork.image(visual: .basic(count: count, reactive: true),
                    state: .active, frame: frame, pose: pose, halloweenStore: store.halloweenArtwork,
                    basicStore: store.basicArtwork)!
                precondition(premium.tiffRepresentation == free.tiffRepresentation,
                    "Free and premium active frames share the refreshed character artwork")
            }
        }
        // Check the live driver with a controlled monotonic clock, including stopped effects.
        var time: TimeInterval = 0
        var reduced = false
        let animator = StatusCharacterAnimator(frameStore: store, now: { time }, reduceMotion: { reduced })
        defer { animator.invalidate() }
        let bicycle: CharacterVisual = .basic(count: 2, reactive: true)
        func pixels() -> Data { animator.currentImage()!.tiffRepresentation! }
        animator.configure(visual: bicycle, state: .rest)
        let upright = pixels()
        time = 0.4; let halfway = pixels()
        time = 1; let asleep = pixels()
        precondition(upright != halfway && halfway != asleep, "bicycle settling into rest has intermediate poses")
        animator.configure(visual: bicycle, state: .rest)
        precondition(pixels() == asleep, "live activity polling preserves the timeline")
        time = 1.7; precondition(pixels() != asleep, "sleep breath and Z continue")
        animator.configure(visual: bicycle, state: .active)
        let waking = pixels(); time = 2.2
        precondition(pixels() != waking, "bicycle wakes from its resting pose")
        reduced = true
        let stopped = pixels(); time = 3.7
        precondition(pixels() == stopped, "Reduce Motion freezes every effect")
        reduced = false
        animator.configure(visual: .halloween(.fox, animated: false), state: .rest)
        let manualOff = pixels(); time = 5
        precondition(pixels() == manualOff, "manual off freezes Halloween including Z")
        animator.configure(visual: .halloween(.spider, animated: true), state: .unknown)
        let unknown = pixels(); time = 7
        precondition(pixels() == unknown, "unknown stays neutral")
        animator.configure(visual: bicycle, state: .rest)
        animator.setActive(false)
        let hidden = pixels(); time = 9
        precondition(pixels() == hidden, "hidden preview freezes every effect")
        animator.configure(visual: .numbers, state: .busy)
        precondition(animator.currentImage() == nil, "numeric display has no animated image")
        animator.configure(visual: .basic(count: 2, reactive: false), state: .rest)
        precondition(pixels() == store.image(for: 2, frame: 0)!.tiffRepresentation!, "free bicycle reuses the refreshed cached frame")
        animator.configure(visual: bicycle, state: .rest)
        let center = NSWorkspace.shared.notificationCenter
        for pair in [(NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
                     (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification)] {
            center.post(name: pair.0, object: nil)
            let paused = pixels(); time += 1
            precondition(pixels() == paused, "sleep notification stops rendering effects")
            var ticks = 0
            animator.onFrameChanged = { ticks += 1 }
            RunLoop.main.run(until: Date().addingTimeInterval(0.24))
            precondition(ticks == 0, "sleep stops timer callbacks")
            center.post(name: pair.1, object: nil)
            ticks = 0
            RunLoop.main.run(until: Date().addingTimeInterval(0.24))
            precondition(ticks > 0, "wake resumes the single animation timer")
        }
        if CommandLine.arguments.count > 2 {
            let width = 1050, height = 850
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]
            for (index, row) in images.enumerated() {
                let y = CGFloat(height - 55 - index * 34)
                let title = index < 13 ? "Basic \(index)" : HalloweenCharacter.allCases[index - 13].rawValue
                (title as NSString).draw(at: NSPoint(x: 10, y: y + 4), withAttributes: attributes)
                for (col, icon) in row.enumerated() {
                    let x = CGFloat(140 + col * 48)
                    // Draw raw template pixels to review the actual transparent bitmap on light backgrounds.
                    let display = NSImage(size: icon.size)
                    display.addRepresentation(icon.representations.last!)
                    display.draw(in: NSRect(x: x, y: y, width: 28, height: 28), from: .zero,
                        operation: .sourceOver, fraction: 1)
                }
            }
            for (index, label) in ["REST — 6 frames", "ACTIVE — 6 frames", "BUSY — 6 frames"].enumerated() {
                (label as NSString).draw(at: NSPoint(x: 140 + index * 288, y: height - 22), withAttributes: attributes)
            }
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        print("CharacterArtworkTests: PASS (23 characters × 3 states × 6 frames × 2 resolutions; live transitions and stop/resume)")
    }
}
