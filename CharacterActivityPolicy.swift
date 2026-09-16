import Foundation

enum CharacterMotionState: String, CaseIterable, Codable {
    case unknown, rest, active, busy

    var title: String {
        switch self {
        case .unknown: return String(localized: "Checking Activity")
        case .rest: return String(localized: "Resting")
        case .active: return String(localized: "Active")
        case .busy: return String(localized: "Busy")
        }
    }
    var frameDuration: TimeInterval {
        switch self { case .unknown: return 1; case .rest: return 0.6; case .active: return 0.12; case .busy: return 0.08 }
    }
}

/// Display-only data. Never consumed by disk, unmount, or sleep authorization policies.
struct CharacterActivitySample {
    let generation: UInt64?
    let time: TimeInterval
    let bytesPerSecond: Double?
    let diskCount: Int
}

struct CharacterActivityPolicy {
    private(set) var state: CharacterMotionState = .unknown
    private var generation: UInt64?
    private var lastTime: TimeInterval?
    private var quietSince: TimeInterval?
    private var recentRates: [Double] = []
    private var candidate: CharacterMotionState = .unknown
    private var candidateCount = 0
    // Presentation thresholds only; existing read/write safety thresholds remain untouched.
    static let activeRate: Double = 32 * 1024
    static let busyRate: Double = 8 * 1024 * 1024

    mutating func consume(_ sample: CharacterActivitySample) -> CharacterMotionState {
        guard sample.time.isFinite else { return state }
        if let lastTime, sample.time <= lastTime { return state }
        if generation != sample.generation || lastTime.map({ sample.time - $0 > 5 }) == true {
            recentRates.removeAll(); quietSince = nil; candidateCount = 0; state = .unknown
        }
        generation = sample.generation
        lastTime = sample.time
        guard sample.diskCount > 0 else {
            recentRates.removeAll(); quietSince = nil; state = .rest; candidateCount = 0
            return state
        }
        guard let rate = sample.bytesPerSecond, rate.isFinite, rate >= 0 else {
            recentRates.removeAll(); quietSince = nil; state = .unknown; candidateCount = 0
            return state
        }
        recentRates.append(rate)
        if recentRates.count > 3 { recentRates.removeFirst() }
        let average = recentRates.reduce(0, +) / Double(recentRates.count)
        if average < Self.activeRate {
            if quietSince == nil { quietSince = sample.time }
            candidateCount = 0
            if sample.time - (quietSince ?? sample.time) >= 10 { state = .rest }
        } else {
            quietSince = nil
            let next: CharacterMotionState = average >= Self.busyRate ? .busy : .active
            candidateCount = next == candidate ? candidateCount + 1 : 1
            candidate = next
            if candidateCount >= 2 { state = next }
        }
        return state
    }

    func current(at time: TimeInterval, diskCount: Int) -> CharacterMotionState {
        guard diskCount > 0 else { return .rest }
        guard let lastTime, time - lastTime <= 5, time >= lastTime else { return .unknown }
        return state
    }
}

/// Finite render coordinates keep cached bitmaps bounded while independent effects share one clock.
struct CharacterRenderPose: Hashable {
    let frame: Int
    let sleepStep: Int // 0 = upright, 8 = tucked into the sleeping pose
    let breathFrame: Int
    let zFrame: Int // -1 disables all sleep marks
    var sleepAmount: Double { Double(sleepStep) / 8 }

    static func still(state: CharacterMotionState, frame: Int = 0) -> Self {
        .init(frame: frame % 6, sleepStep: state == .rest ? 8 : 0,
              breathFrame: state == .rest ? frame % 12 : 0,
              zFrame: state == .rest ? frame % 28 : -1)
    }
}

struct CharacterMotionTimeline {
    private(set) var state: CharacterMotionState = .unknown
    private(set) var startedAt: TimeInterval = 0
    private var sleepingFrom: Double = 0

    mutating func setState(_ next: CharacterMotionState, at time: TimeInterval, reset: Bool = false) {
        guard reset || next != state else { return }
        sleepingFrom = reset ? 0 : sleepAmount(at: time)
        state = next; startedAt = time
    }

    func sleepAmount(at time: TimeInterval) -> Double {
        guard state != .unknown else { return 0 }
        let target: Double = state == .rest ? 1 : 0
        let progress = max(0, min(1, (time - startedAt) / (state == .rest ? 0.8 : 0.4)))
        let eased = progress * progress * (3 - 2 * progress)
        return sleepingFrom + (target - sleepingFrom) * eased
    }

    func pose(at time: TimeInterval, animated: Bool = true, frameCount: Int = 6) -> CharacterRenderPose {
        guard animated, state != .unknown else { return .still(state: .unknown) }
        let elapsed = max(0, time - startedAt)
        let asleep = sleepAmount(at: time)
        return .init(frame: Int(elapsed / state.frameDuration) % max(1, frameCount),
                     sleepStep: Int((asleep * 8).rounded()),
                     breathFrame: state == .rest ? Int(elapsed / 0.3) % 12 : 0,
                     zFrame: state == .rest && elapsed >= 0.8 ? Int((elapsed - 0.8) / 0.1) % 28 : -1)
    }
}
