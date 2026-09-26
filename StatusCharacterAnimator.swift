import AppKit
/// Renders each basic character into its own fixed-size cached frame cycle.
final class StatusCharacterFrameStore {
    static let maximumCharacterCount = 12
    static let frameCount = 6

    let halloweenArtwork: HalloweenArtworkStore
    let basicArtwork: BasicArtworkStore

    private var frames: [[NSImage?]] = (0...maximumCharacterCount).map {
        Array(repeating: nil, count: CharacterArtwork.frameCount(for: .basic(count: $0, reactive: false)))
    }

    init(bundle: Bundle = .main) {
        halloweenArtwork = HalloweenArtworkStore(bundle: bundle)
        basicArtwork = BasicArtworkStore(bundle: bundle)
        for count in 0...Self.maximumCharacterCount {
            guard basicArtwork.hasArtwork(for: count) else { continue }
            for frame in frames[count].indices {
                frames[count][frame] = CharacterArtwork.image(
                    visual: .basic(count: count, reactive: false), state: .active, frame: frame,
                    halloweenStore: halloweenArtwork, basicStore: basicArtwork
                )
            }
        }
    }

    func hasFrames(for count: Int) -> Bool {
        guard (0...Self.maximumCharacterCount).contains(count) else { return false }
        return frames[count].allSatisfy { $0 != nil }
    }

    func image(for count: Int, frame: Int) -> NSImage? {
        guard (0...Self.maximumCharacterCount).contains(count),
              frames[count].indices.contains(frame) else { return nil }
        return frames[count][frame]
    }
}

/// Main-run-loop animation driver. It never mutates the status item directly; AppDelegate
/// decides whether a frame may replace the current eject-progress/result symbol.
final class StatusCharacterAnimator {
    static let frameDuration: TimeInterval = 0.12

    private let frameStore: StatusCharacterFrameStore
    private let renderSize: CGFloat
    private var timer: Timer?
    private var accessibilityObserver: NSObjectProtocol?
    private var isActive = false
    private var visual: CharacterVisual?
    private var motionState: CharacterMotionState = .active
    private var timeline = CharacterMotionTimeline()
    private let now: () -> TimeInterval
    private let reduceMotion: () -> Bool
    private var framesCache: [String: NSImage] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var displayAwake = true
    private var systemAwake = true
    private(set) var frameIndex = 0

    var onFrameChanged: (() -> Void)?

    init(frameStore: StatusCharacterFrameStore = StatusCharacterFrameStore(),
         renderSize: CGFloat = 21,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.frameStore = frameStore; self.renderSize = renderSize; self.now = now; self.reduceMotion = reduceMotion
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.accessibilityOptionsDidChange()
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if name == NSWorkspace.screensDidSleepNotification { self.displayAwake = false }
                if name == NSWorkspace.screensDidWakeNotification { self.displayAwake = true }
                if name == NSWorkspace.willSleepNotification { self.systemAwake = false }
                if name == NSWorkspace.didWakeNotification { self.systemAwake = true }
                self.stopTimer()
                if self.shouldAnimate { self.startTimer() }
                self.onFrameChanged?()
            })
        }
    }

    private var shouldAnimate: Bool {
        guard isActive, displayAwake, systemAwake,
              !reduceMotion() else { return false }
        if case .basic(let count, _) = visual {
            guard frameStore.hasFrames(for: count) else { return false }
        }
        if case .halloween(let character, let animated) = visual {
            guard animated, frameStore.halloweenArtwork.hasArtwork(for: character) else { return false }
        }
        return motionState != .unknown
    }

    func configure(visual: CharacterVisual, state: CharacterMotionState) {
        precondition(Thread.isMainThread)
        let effective: CharacterMotionState
        switch visual {
        case .basic(_, let reactive): effective = reactive ? state : .active
        case .halloween(_, let animated): effective = animated ? state : .unknown
        case .numbers: effective = .unknown
        }
        guard self.visual != visual || motionState != effective || !isActive else { return }
        let reset = self.visual != visual || !isActive
        if self.visual != visual { framesCache.removeAll(keepingCapacity: true) }
        timeline.setState(effective, at: now(), reset: reset)
        self.visual = visual; motionState = effective; frameIndex = 0
        isActive = visual != .numbers
        stopTimer()
        if shouldAnimate { startTimer() }
    }

    func currentImage() -> NSImage? {
        guard let visual else { return nil }
        let frame = shouldAnimate ? frameIndex : 0
        if case .basic(let count, let reactive) = visual, !reactive {
            guard frameStore.hasFrames(for: count) else { return nil }
            if renderSize == 21 { return frameStore.image(for: count, frame: frame) }
            // Gallery images use the source artwork at their own resolution and keep each character’s full cycle.
            let key = "basic-free-\(count)-\(frame)"
            if let cached = framesCache[key] { return cached }
            let image = CharacterArtwork.image(visual: visual, state: .active, frame: frame,
                halloweenStore: frameStore.halloweenArtwork, renderSize: renderSize,
                basicStore: frameStore.basicArtwork)
            if let image { framesCache[key] = image }
            return image
        }
        let state = shouldAnimate ? motionState : CharacterMotionState.unknown
        let pose = timeline.pose(at: now(), animated: shouldAnimate, frameCount: CharacterArtwork.frameCount(for: visual))
        let key = "\(visual)-\(state.rawValue)-\(pose)"
        if let cached = framesCache[key] { return cached }
        let base: NSImage?
        if case .basic(let count, _) = visual {
            base = frameStore.image(for: count, frame: state == .rest || state == .unknown ? 0 : pose.frame)
        } else { base = nil }
        let image = CharacterArtwork.image(visual: visual, state: state, frame: pose.frame, basicImage: base, pose: pose,
            halloweenStore: frameStore.halloweenArtwork, renderSize: renderSize, basicStore: frameStore.basicArtwork)
        if let image {
            if framesCache.count >= 384 { framesCache.removeAll(keepingCapacity: true) }
            framesCache[key] = image
        }
        return image
    }

    func hasFrames(for count: Int) -> Bool {
        frameStore.hasFrames(for: count)
    }

    func image(for count: Int) -> NSImage? {
        let displayedFrame = reduceMotion() ? 0 : frameIndex
        return frameStore.image(for: count, frame: displayedFrame)
    }

    func setActive(_ active: Bool) {
        precondition(Thread.isMainThread)
        guard isActive != active else { return }
        isActive = active
        if active { timeline.setState(motionState, at: now(), reset: true) }
        frameIndex = 0
        if shouldAnimate {
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
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
            self.accessibilityObserver = nil
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let duration: TimeInterval
        if case .basic(_, let reactive) = visual, !reactive { duration = Self.frameDuration }
        // Keep the sleep effects' 100ms clock, while waking motion gets every pose.
        else { duration = motionState == .rest ? 0.1 : motionState.frameDuration }
        let timer = Timer(timeInterval: duration, repeats: true) { [weak self] _ in
            guard let self, self.isActive else { return }
            self.frameIndex = (self.frameIndex + 1) % CharacterArtwork.frameCount(for: self.visual ?? .numbers)
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
        stopTimer()
        if shouldAnimate { startTimer() }
        onFrameChanged?()
    }

    deinit {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        timer?.invalidate()
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }
}

/// Ten settings previews share one clock and bounded bitmap cache. No disk activity is simulated outside this gallery.
final class CharacterGalleryAnimator {
    private let basicArtwork: BasicArtworkStore
    private let halloweenArtwork: HalloweenArtworkStore
    private let renderSize: CGFloat
    private let now: () -> TimeInterval
    private let reduceMotion: () -> Bool
    private var collection: CharacterCollection = .basic
    private var active = false
    private var displayAwake = true
    private var systemAwake = true
    private var startedAt: TimeInterval = 0
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cache: [String: NSImage] = [:]
    var onFramesChanged: (([NSImage?]) -> Void)?
    var isRunning: Bool { timer != nil }

    init(bundle: Bundle = .main, renderSize: CGFloat = 21,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        basicArtwork = BasicArtworkStore(bundle: bundle)
        halloweenArtwork = HalloweenArtworkStore(bundle: bundle)
        self.renderSize = renderSize; self.now = now; self.reduceMotion = reduceMotion
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if name == NSWorkspace.screensDidSleepNotification { self.displayAwake = false }
                if name == NSWorkspace.screensDidWakeNotification { self.displayAwake = true }
                if name == NSWorkspace.willSleepNotification { self.systemAwake = false }
                if name == NSWorkspace.didWakeNotification { self.systemAwake = true }
                self.updatePlayback()
            })
        }
    }

    func configure(collection: CharacterCollection) {
        precondition(Thread.isMainThread)
        if self.collection != collection {
            self.collection = collection; startedAt = now(); cache.removeAll(keepingCapacity: true)
        }
        renderFrame()
    }

    func setActive(_ active: Bool) {
        precondition(Thread.isMainThread)
        guard self.active != active else { return }
        self.active = active
        updatePlayback()
    }

    private func updatePlayback() {
        let shouldPlay = active && displayAwake && systemAwake && !reduceMotion()
        if shouldPlay && timer == nil {
            startedAt = now()
            let timer = Timer(timeInterval: CharacterMotionState.busy.frameDuration, repeats: true) { [weak self] _ in
                self?.renderFrame()
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if !shouldPlay {
            timer?.invalidate(); timer = nil
        }
        renderFrame()
    }

    private func renderFrame() {
        let elapsed = max(0, now() - startedAt)
        let state: CharacterMotionState = isRunning ? CharacterPreviewTimeline.state(at: elapsed) : .unknown
        let images = (0..<CharacterPreviewTimeline.characterCount).map { index -> NSImage? in
            let visual: CharacterVisual = collection == .basic ? .basic(count: index, reactive: true)
                : .halloween(HalloweenCharacter.allCases[index], animated: true)
            let pose = isRunning ? CharacterPreviewTimeline.pose(at: elapsed, frameCount: CharacterArtwork.frameCount(for: visual))
                : CharacterRenderPose.still(state: .unknown)
            let key = "\(index)-\(state.rawValue)-\(pose)"
            if let cached = cache[key] { return cached }
            let image = CharacterArtwork.image(visual: visual, state: state, frame: pose.frame, pose: pose,
                halloweenStore: halloweenArtwork, renderSize: renderSize, basicStore: basicArtwork)
            if let image {
                if cache.count >= 384 { cache.removeAll(keepingCapacity: true) }
                cache[key] = image
            }
            return image
        }
        onFramesChanged?(images)
    }

    deinit {
        timer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
