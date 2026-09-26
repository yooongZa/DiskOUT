import AppKit
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum StatusCharacterFrameStoreTests {
    static func main() {
        guard CommandLine.arguments.count == 2,
              let bundle = Bundle(path: CommandLine.arguments[1]) else {
            fputs("Usage: StatusCharacterFrameStoreTests /path/to/DiskOUT.app\n", stderr)
            exit(2)
        }

        _ = NSApplication.shared
        let store = StatusCharacterFrameStore(bundle: bundle)
        expect(store.basicArtwork.hasCompleteCollection, "all 13 refreshed basic characters ship in the bundle")
        expect(StatusCharacterAnimator.frameDuration == 0.12, "free loops use the lively 120ms walking cadence")
        for count in 0...StatusCharacterFrameStore.maximumCharacterCount {
            expect(store.hasFrames(for: count), "count \(count) has all six bundled frames")
            var payloads = Set<Data>()
            var alignmentRects = Set<String>()
            let frameCount = count == 2 ? 8 : 6
            let width = count == 2 ? 30 : 21
            for frame in 0..<frameCount {
                guard let image = store.image(for: count, frame: frame) else {
                    fputs("FAIL: missing count \(count), frame \(frame)\n", stderr)
                    exit(1)
                }
                expect(image.size == NSSize(width: width, height: 21), "status image uses prominent 21pt size")
                let representationSizes = Set(image.representations.map {
                    "\($0.pixelsWide)x\($0.pixelsHigh)"
                })
                expect(representationSizes == Set(["\(width)x21", "\(width * 2)x42"]),
                       "status image renders the source artwork at 1x and 2x")
                let expectedAlignmentRect = NSRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(width),
                    height: 21
                )
                expect(abs(image.alignmentRect.minX - expectedAlignmentRect.minX) < 0.001 &&
                       abs(image.alignmentRect.minY - expectedAlignmentRect.minY) < 0.001 &&
                       abs(image.alignmentRect.width - expectedAlignmentRect.width) < 0.001 &&
                       abs(image.alignmentRect.height - expectedAlignmentRect.height) < 0.001,
                       "count \(count) keeps the full stable status canvas")
                alignmentRects.insert(NSStringFromRect(image.alignmentRect))
                expect(image.isTemplate, "status image remains a light/dark template")
                if let representation = image.tiffRepresentation {
                    payloads.insert(representation)
                }
            }
            expect(alignmentRects.count == 1,
                   "count \(count) keeps one alignment width across all animation frames")
            expect(payloads.count == frameCount,
                   "count \(count) renders all distinct free animation frames")
        }
        for count in [-1, 13] {
            expect(!store.hasFrames(for: count), "out-of-range count uses the numeric fallback")
            expect(store.image(for: count, frame: 0) == nil, "out-of-range count has no rendered frame")
        }
        expect(store.image(for: 2, frame: -1) == nil && store.image(for: 2, frame: 8) == nil,
               "out-of-range animation frames are rejected")
        let missing = StatusCharacterFrameStore(bundle: Bundle(for: NSView.self))
        expect(!missing.basicArtwork.hasCompleteCollection, "missing source is reported")
        for count in 0...StatusCharacterFrameStore.maximumCharacterCount {
            expect(!missing.hasFrames(for: count) && missing.image(for: count, frame: 0) == nil,
                   "missing source does not fall back to the replaced artwork")
        }
        var previewTime: TimeInterval = 0
        var reduceMotion = false
        var latestFrames: [NSImage?] = []
        var gallery: CharacterGalleryAnimator? = CharacterGalleryAnimator(bundle: bundle,
            now: { previewTime }, reduceMotion: { reduceMotion })
        gallery!.onFramesChanged = { latestFrames = $0 }
        gallery!.configure(collection: .basic)
        expect(!gallery!.isRunning, "hidden gallery has no timer")
        gallery!.setActive(true)
        expect(gallery!.isRunning, "visible gallery starts shared timer")
        expect(latestFrames.count == 10 && latestFrames.allSatisfy { $0 != nil }, "ten basic previews render")
        let upright = latestFrames[2]!.tiffRepresentation
        previewTime = 3; gallery!.configure(collection: .basic)
        expect(latestFrames[2]!.tiffRepresentation != upright, "preview visibly sleeps")
        let sleeping = latestFrames[2]!.tiffRepresentation
        previewTime = 4.2; gallery!.configure(collection: .basic)
        expect(latestFrames[2]!.tiffRepresentation != sleeping, "preview visibly wakes")
        gallery!.configure(collection: .halloween)
        expect(latestFrames.count == 10 && latestFrames.allSatisfy { $0 != nil }, "unowned seasonal gallery renders ten previews")
        let center = NSWorkspace.shared.notificationCenter
        reduceMotion = true
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        expect(!gallery!.isRunning, "Reduce Motion stops shared timer")
        reduceMotion = false
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        expect(gallery!.isRunning, "turning off Reduce Motion resumes visible gallery")
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        expect(!gallery!.isRunning, "system sleep stops gallery")
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        expect(gallery!.isRunning, "system wake resumes visible gallery")
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        expect(!gallery!.isRunning, "display sleep stops gallery")
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        expect(!gallery!.isRunning, "system wake cannot override a sleeping display")
        gallery!.setActive(false)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        expect(!gallery!.isRunning, "display wake never resumes a hidden gallery")
        gallery!.setActive(true)
        let isReleased = { [weak gallery] in gallery == nil }
        gallery = nil
        expect(isReleased(), "timer and observers do not retain a closed gallery")
        print("StatusCharacterFrameStoreTests: PASS")
    }
}
