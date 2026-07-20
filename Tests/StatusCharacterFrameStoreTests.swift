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

        let store = StatusCharacterFrameStore(bundle: bundle)
        let expectedTrailingTrimAtlasPoints = [
            2, 3, 3, 1, 0, 0, 2, 0, 0, 0, 1, 0, 1,
        ]
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
                expect(representationSizes == Set(["18x18", "36x36"]),
                       "status image crops transparent atlas padding at 1x and 2x")
                let expectedTrim = CGFloat(expectedTrailingTrimAtlasPoints[count]) * 21 / 18
                let expectedAlignmentRect = NSRect(
                    x: 0,
                    y: 0,
                    width: 21 - expectedTrim,
                    height: 21
                )
                expect(abs(image.alignmentRect.minX - expectedAlignmentRect.minX) < 0.001 &&
                       abs(image.alignmentRect.minY - expectedAlignmentRect.minY) < 0.001 &&
                       abs(image.alignmentRect.width - expectedAlignmentRect.width) < 0.001 &&
                       abs(image.alignmentRect.height - expectedAlignmentRect.height) < 0.001,
                       "count \(count) uses its safe character-to-number alignment trim")
                alignmentRects.insert(NSStringFromRect(image.alignmentRect))
                expect(image.isTemplate, "status image remains a light/dark template")
                if let representation = image.tiffRepresentation {
                    payloads.insert(representation)
                }
            }
            expect(alignmentRects.count == 1,
                   "count \(count) keeps one alignment width across all animation frames")
            expect(payloads.count == StatusCharacterFrameStore.frameCount,
                   "count \(count) keeps six distinct animation frames after bundle processing")
        }
        expect(!store.hasFrames(for: 13), "count 13 has no premium frame")
        print("StatusCharacterFrameStoreTests: PASS")
    }
}
