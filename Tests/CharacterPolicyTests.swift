import Foundation

@main enum CharacterPolicyTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }
    static func main() {
        var selection = CharacterSelection()
        for count in 0...12 {
            check(CharacterPresentationPolicy.visual(selection: selection, owned: [], count: count) == .basic(count: count, reactive: false), "all existing characters free")
        }
        selection.basicReactive = true
        check(CharacterPresentationPolicy.visual(selection: selection, owned: [.halloween], count: 2) == .basic(count: 2, reactive: false), "Halloween cannot unlock basic motion")
        check(CharacterPresentationPolicy.visual(selection: selection, owned: [.baseMotion], count: 2) == .basic(count: 2, reactive: true), "base motion permission")
        check(CharacterPresentationPolicy.visual(selection: selection, owned: [.baseMotion], count: 13) == .numbers, "legacy overflow")
        selection.collection = .halloween
        let expectedCharacters: [HalloweenCharacter] = [.pumpkin, .staff, .bicycle, .hound, .desk,
                                                       .star, .web, .scythe, .spider, .fox]
        check(HalloweenCharacter.allCases == expectedCharacters, "gallery follows the approved 0 through 9 order")
        for (count, character) in expectedCharacters.enumerated() {
            check(character.driveCount == count, "each character has the approved drive count")
            check(HalloweenCharacter.character(for: count) == character, "count lookup matches the gallery")
            check(CharacterPresentationPolicy.visual(selection: selection, owned: [.halloween], count: count) == .halloween(character, animated: true), "Halloween maps each actual count")
        }
        for count in [-1, 10, 11, 12, 13, 30] {
            check(CharacterPresentationPolicy.visual(selection: selection, owned: [.halloween], count: count) == .numbers, "out of range stays exact numeric")
        }
        // Buying or refunding either pack never changes the other pack's permission.
        let ownerships: [Set<CharacterPack>] = [[], [.baseMotion], [.halloween], Set(CharacterPack.allCases)]
        for owned in ownerships {
            for collection in CharacterCollection.allCases {
                selection.collection = collection
                for motionEnabled in [false, true] {
                    selection.basicReactive = motionEnabled
                    selection.halloweenAnimated = motionEnabled
                    for count in -1...13 {
                        let expected: CharacterVisual
                        if collection == .halloween && owned.contains(.halloween) {
                            expected = (0...9).contains(count)
                                ? .halloween(expectedCharacters[count], animated: motionEnabled) : .numbers
                        } else {
                            expected = (0...12).contains(count)
                                ? .basic(count: count, reactive: motionEnabled && owned.contains(.baseMotion)) : .numbers
                        }
                        check(CharacterPresentationPolicy.visual(selection: selection, owned: owned, count: count) == expected,
                              "collection, ownership and motion combinations preserve fallback")
                    }
                }
            }
        }
        selection.collection = .halloween
        selection.halloweenAnimated = false
        check(CharacterPresentationPolicy.visual(selection: selection, owned: [.halloween], count: 7) == .halloween(.scythe, animated: false), "manual motion off preserved")
        check(CharacterPresentationPolicy.visual(selection: selection, owned: [.baseMotion], count: 0) == .basic(count: 0, reactive: true), "Halloween refund restores basic egg with separately owned motion")
        check(CharacterPresentationPolicy.visual(selection: selection, owned: [], count: 9) == .basic(count: 9, reactive: false), "all packs refunded restores free basic artwork")
        let suite = "DiskOUT.CharacterPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("frankenstein", forKey: "character.halloween")
        selection.save(to: defaults)
        check(defaults.object(forKey: "character.halloween") == nil, "manual character preference removed")
        check(CharacterSelection(defaults: defaults) == selection, "display, collection and motion survive migration")
        // Active finishes a stride in 720ms; busy runs the same six poses in 480ms.
        for (state, step) in [(CharacterMotionState.active, 0.12), (.busy, 0.08)] {
            var stride = CharacterMotionTimeline()
            stride.setState(state, at: 10)
            for tick in 0..<18 {
                let time = 10 + (Double(tick) + 0.5) * step
                check(stride.pose(at: time).frame == tick % 6, "every running pose appears at the intended cadence")
                check(stride.pose(at: time).zFrame == -1, "running never shows sleep marks")
            }
            stride.setState(state, at: 11)
            check(stride.startedAt == 10, "activity polling does not restart a stride")
            check(stride.pose(at: 10 + 31.5 * step).frame == 1,
                  "late rendering follows elapsed time instead of replaying missed frames")
            check(stride.pose(at: 12, animated: false) == .still(state: .unknown),
                  "disabled running effects remain neutral")
        }
        var bicycleClock = CharacterMotionTimeline()
        bicycleClock.setState(.active, at: 0, reset: true)
        for tick in 0..<24 {
            check(bicycleClock.pose(at: (Double(tick) + 0.2) * CharacterMotionState.active.frameDuration, frameCount: 8).frame == tick % 8,
                  "bicycle timeline plays all eight poses and wraps")
        }
        var timeline = CharacterMotionTimeline()
        timeline.setState(.rest, at: 0)
        check(timeline.pose(at: 0).sleepStep == 0, "rest starts upright")
        check(timeline.pose(at: 0.4).sleepStep == 4, "crouch halfway")
        check(timeline.pose(at: 0.8).sleepStep == 8, "fully tucked after 0.8 seconds")
        check(timeline.pose(at: 0.7).zFrame == -1, "Z waits for tuck")
        check(timeline.pose(at: 1).zFrame != timeline.pose(at: 1.7).zFrame, "Z advances independently")
        check(timeline.pose(at: 0.95).zFrame == 1 && timeline.pose(at: 1.05).zFrame == 2,
              "sleep marks retain their 100ms clock")
        check(timeline.pose(at: 0.35).breathFrame == 1 && timeline.pose(at: 0.65).breathFrame == 2,
              "breathing retains its 300ms clock")
        timeline.setState(.rest, at: 1)
        check(timeline.startedAt == 0, "polling same state never restarts animation")
        timeline.setState(.active, at: 2)
        check(timeline.pose(at: 2).sleepStep == 8, "wake begins tucked")
        check(timeline.pose(at: 2.2).sleepStep == 4, "wake halfway")
        check(timeline.pose(at: 2.4).sleepStep == 0, "upright after 0.4 seconds")
        check(timeline.pose(at: 2).zFrame == -1, "Z stops immediately on wake")
        check(timeline.pose(at: 3, animated: false) == .still(state: .unknown), "disabled effects are neutral")
        timeline.setState(.rest, at: 4)
        timeline.setState(.active, at: 4.4)
        check(timeline.pose(at: 4.4).sleepStep == 4, "interrupted tuck reverses without jump")
        timeline.setState(.unknown, at: 5)
        check(timeline.pose(at: 6) == .still(state: .unknown), "unknown never sleeps")
        check(CharacterPresentationPolicy.visual(selection: selection, owned: [], count: 3) == .basic(count: 3, reactive: false), "refund fallback free")
        selection.display = .numbers
        for owned in ownerships {
            for count in [0, 1, 9, 10, 12, 30] {
                check(CharacterPresentationPolicy.visual(selection: selection, owned: owned, count: count) == .numbers, "number selection wins for all pack ownerships")
            }
        }
        var activity = CharacterActivityPolicy()
        func sample(_ t: Double, _ rate: Double?, _ generation: UInt64 = 1, _ count: Int = 1) -> CharacterActivitySample {
            .init(generation: generation, time: t, bytesPerSecond: rate, diskCount: count)
        }
        check(activity.consume(sample(1, 100_000)) == .unknown, "one spike does not move")
        check(activity.consume(sample(2, 100_000)) == .active, "sustained activity walks")
        for t in 3...6 { _ = activity.consume(sample(Double(t), 20_000_000)) }
        check(activity.state == .busy, "heavy I/O moves fast")
        check(activity.consume(sample(5, 0)) == .busy, "old sample ignored")
        for t in 7...19 { _ = activity.consume(sample(Double(t), 0)) }
        check(activity.state == .rest, "quiet period sleeps")
        check(activity.current(at: 25, diskCount: 1) == .unknown, "stale data not sleep")
        check(activity.consume(sample(26, nil, 2)) == .unknown, "new mapping invalidates state")
        check(activity.consume(sample(27, nil, 2, 0)) == .rest, "no drives rests")
        let now = Date()
        func lease(_ packs: Set<CharacterPack>, revision: Int64 = 10, ids: [String]? = nil, issued: Date? = nil, expiry: Date? = nil) -> CharacterEntitlementPayload {
            .init(schemaVersion: 3, installID: "test", revision: revision, issuedAt: issued ?? now,
                  expiresAt: expiry ?? now.addingTimeInterval(600), entitlements: (ids ?? CharacterPack.allCases.map(\.rawValue)).map {
                      .init(id: $0, status: CharacterPack(rawValue: $0).map { packs.contains($0) } == true ? .active : .free)
                  })
        }
        let both = lease(Set(CharacterPack.allCases))
        check(both.accepts(installID: "test", now: now), "two grants valid")
        check(lease([.halloween]).activePacks == [.halloween], "independent grants")
        check(!lease([], revision: 9).accepts(installID: "test", now: now, previous: both), "old revision rejected")
        check(!both.accepts(installID: "other", now: now), "bound installation")
        check(!lease([], ids: ["base_motion_v1", "base_motion_v1"]).accepts(installID: "test", now: now), "duplicate grants rejected")
        check(!lease([], expiry: now.addingTimeInterval(901)).accepts(installID: "test", now: now), "denial limited to 15 minutes")
        check(!lease([.baseMotion], expiry: now).accepts(installID: "test", now: now), "expiry enforced")
        print("CharacterPolicyTests: PASS")
    }
}
