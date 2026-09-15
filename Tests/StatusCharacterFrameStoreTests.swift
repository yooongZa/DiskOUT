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
            for frame in 0..<StatusCharacterFrameStore.frameCount {
                guard let image = store.image(for: count, frame: frame) else {
                    fputs("FAIL: missing count \(count), frame \(frame)\n", stderr)
                    exit(1)
                }
                expect(image.size == NSSize(width: 21, height: 21), "status image uses prominent 21pt size")
                let representationSizes = Set(image.representations.map {
                    "\($0.pixelsWide)x\($0.pixelsHigh)"
                })
                expect(representationSizes == Set(["21x21", "42x42"]),
                       "status image renders the source artwork at 1x and 2x")
                let expectedAlignmentRect = NSRect(
                    x: 0,
                    y: 0,
                    width: 21,
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
            expect(payloads.count == StatusCharacterFrameStore.frameCount,
                   "count \(count) renders six distinct free animation frames")
        }
        for count in [-1, 13] {
            expect(!store.hasFrames(for: count), "out-of-range count uses the numeric fallback")
            expect(store.image(for: count, frame: 0) == nil, "out-of-range count has no rendered frame")
        }
        expect(store.image(for: 2, frame: -1) == nil && store.image(for: 2, frame: 6) == nil,
               "out-of-range animation frames are rejected")
        let missing = StatusCharacterFrameStore(bundle: Bundle(for: NSView.self))
        expect(!missing.basicArtwork.hasCompleteCollection, "missing source is reported")
        for count in 0...StatusCharacterFrameStore.maximumCharacterCount {
            expect(!missing.hasFrames(for: count) && missing.image(for: count, frame: 0) == nil,
                   "missing source does not fall back to the replaced artwork")
        }
        print("StatusCharacterFrameStoreTests: PASS")
    }
}
