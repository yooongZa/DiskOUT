import AppKit
import ImageIO

/// Loads the bundled 0...12 status-character atlas once and exposes cached template images.
/// The atlas is 6 columns (animation frames) by 13 rows (mounted-drive count).
final class StatusCharacterFrameStore {
    static let maximumCharacterCount = 12
    static let frameCount = 6

    private static let atlasCellPoints = 22
    /// 메뉴바가 21pt canvas 를 다시 축소하므로 atlas 의 투명 여백만 안전하게 덜어
    /// 캐릭터의 실제 잉크 크기를 키운다. 1x/2x 78개 frame 의 중심 18pt 안에
    /// alpha 64 초과 픽셀이 모두 들어오는 것을 사전 asset 분석으로 확인했다.
    private static let atlasCropPoints = 18
    private static let renderedStatusSize = NSSize(width: 21, height: 21)
    /// 6개 pose 전체의 오른쪽 투명 여백만 count 별로 layout 에서 제외한다.
    /// bitmap 과 21pt 높이는 유지하므로 캐릭터가 찌그러지거나 frame 마다 흔들리지 않는다.
    private static let trailingAlignmentTrimAtlasPoints = [
        2, 3, 3, 1, 0, 0, 2, 0, 0, 0, 1, 0, 1,
    ]

    private var frames: [[NSImage?]] = Array(
        repeating: Array(repeating: nil, count: frameCount),
        count: maximumCharacterCount + 1
    )

    init(bundle: Bundle = .main) {
        var atlases = [
            Self.loadAtlas(named: "PremiumStatusCharacters", scale: 1, bundle: bundle),
            Self.loadAtlas(named: "PremiumStatusCharacters@2x", scale: 2, bundle: bundle),
        ].compactMap { $0 }
        // Xcode's Resources phase combines a foo.png + foo@2x.png pair into one multi-page TIFF.
        // Direct swiftc tests and some alternate packaging paths keep the PNGs, so support both.
        if atlases.isEmpty {
            atlases = Self.loadCombinedTIFF(bundle: bundle)
        }

        guard !atlases.isEmpty else { return }

        for count in 0...Self.maximumCharacterCount {
            for frame in 0..<Self.frameCount {
                let image = NSImage(size: Self.renderedStatusSize)
                for atlas in atlases {
                    let cellPixels = Self.atlasCellPoints * atlas.scale
                    let cropPixels = Self.atlasCropPoints * atlas.scale
                    let cropInsetPixels = (cellPixels - cropPixels) / 2
                    let crop = CGRect(
                        x: frame * cellPixels + cropInsetPixels,
                        y: count * cellPixels + cropInsetPixels,
                        width: cropPixels,
                        height: cropPixels
                    )
                    guard let cropped = atlas.image.cropping(to: crop) else { continue }
                    let representation = NSBitmapImageRep(cgImage: cropped)
                    representation.size = Self.renderedStatusSize
                    image.addRepresentation(representation)
                }
                if !image.representations.isEmpty {
                    let trailingTrim = CGFloat(Self.trailingAlignmentTrimAtlasPoints[count])
                        * Self.renderedStatusSize.width / CGFloat(Self.atlasCropPoints)
                    image.alignmentRect = NSRect(
                        x: 0,
                        y: 0,
                        width: Self.renderedStatusSize.width - trailingTrim,
                        height: Self.renderedStatusSize.height
                    )
                    image.isTemplate = true
                    frames[count][frame] = image
                }
            }
        }
    }

    func hasFrames(for count: Int) -> Bool {
        guard (0...Self.maximumCharacterCount).contains(count) else { return false }
        return frames[count].allSatisfy { $0 != nil }
    }

    func image(for count: Int, frame: Int) -> NSImage? {
        guard (0...Self.maximumCharacterCount).contains(count),
              (0..<Self.frameCount).contains(frame) else { return nil }
        return frames[count][frame]
    }

    private struct Atlas {
        let image: CGImage
        let scale: Int
    }

    private static func loadAtlas(named name: String, scale: Int, bundle: Bundle) -> Atlas? {
        guard let url = bundle.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let expectedWidth = atlasCellPoints * frameCount * scale
        let expectedHeight = atlasCellPoints * (maximumCharacterCount + 1) * scale
        guard image.width == expectedWidth, image.height == expectedHeight else { return nil }
        return Atlas(image: image, scale: scale)
    }

    private static func loadCombinedTIFF(bundle: Bundle) -> [Atlas] {
        guard let url = bundle.url(forResource: "PremiumStatusCharacters", withExtension: "tiff"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }

        let oneXWidth = atlasCellPoints * frameCount
        let oneXHeight = atlasCellPoints * (maximumCharacterCount + 1)
        var loaded: [Atlas] = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil),
                  image.width % oneXWidth == 0,
                  image.height % oneXHeight == 0 else { continue }
            let scale = image.width / oneXWidth
            guard (scale == 1 || scale == 2), image.height == oneXHeight * scale else { continue }
            loaded.append(Atlas(image: image, scale: scale))
        }
        return loaded.sorted { $0.scale < $1.scale }
    }
}

/// Main-run-loop animation driver. It never mutates the status item directly; AppDelegate
/// decides whether a frame may replace the current eject-progress/result symbol.
final class StatusCharacterAnimator {
    static let frameDuration: TimeInterval = 0.14

    private let frameStore: StatusCharacterFrameStore
    private var timer: Timer?
    private var accessibilityObserver: NSObjectProtocol?
    private var isActive = false
    private(set) var frameIndex = 0

    var onFrameChanged: (() -> Void)?

    init(frameStore: StatusCharacterFrameStore = StatusCharacterFrameStore()) {
        self.frameStore = frameStore
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.accessibilityOptionsDidChange()
        }
    }

    func hasFrames(for count: Int) -> Bool {
        frameStore.hasFrames(for: count)
    }

    func image(for count: Int) -> NSImage? {
        let displayedFrame = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : frameIndex
        return frameStore.image(for: count, frame: displayedFrame)
    }

    func setActive(_ active: Bool) {
        precondition(Thread.isMainThread)
        guard isActive != active else { return }
        isActive = active
        frameIndex = 0
        if active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            startTimer()
        } else {
            stopTimer()
        }
        onFrameChanged?()
    }

    func invalidate() {
        precondition(Thread.isMainThread)
        isActive = false
        stopTimer()
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
            self.accessibilityObserver = nil
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.frameDuration, repeats: true) { [weak self] _ in
            guard let self, self.isActive else { return }
            self.frameIndex = (self.frameIndex + 1) % StatusCharacterFrameStore.frameCount
            self.onFrameChanged?()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func accessibilityOptionsDidChange() {
        guard isActive else { return }
        frameIndex = 0
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopTimer()
        } else {
            startTimer()
        }
        onFrameChanged?()
    }

    deinit {
        timer?.invalidate()
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }
}
