import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

/// Every scenario owns a disposable suite; neither app preferences nor signed billing state is used.
private final class PromotionFixture {
    let suiteName = "DiskOUT.CharacterPromotionPolicyTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func store() -> CharacterPromotionStore {
        // Reconstruct both dependencies to exercise decoding of persisted state on restart.
        CharacterPromotionStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    func loadState(_ data: Data) {
        defaults.set(data, forKey: "character.promotion.state.v1")
    }

    deinit { defaults.removePersistentDomain(forName: suiteName) }
}

private final class ActivityObservationFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record(_ busy: Bool) {
        guard !busy else { return }
        lock.lock()
        count += 1
        lock.unlock()
    }

    var hasFailures: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count > 0
    }
}

@main
private enum CharacterPromotionPolicyTests {
    private static let campaign = CharacterLaunchCampaign.halloween2026
    private static let secondCampaign = CharacterLaunchCampaign(
        id: "halloween_v1.launch.second-campaign", collection: .halloween, previewCounts: [1, 3, 8])
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    // A literal contract value makes this independent of a possibly incorrect production duration.
    private static let end = start.addingTimeInterval(259_200)
    private static let purchasable: Set<CharacterPack> = [.halloween]

    private static func selection(_ display: CharacterDisplayMode,
                                  _ collection: CharacterCollection = .basic) -> CharacterSelection {
        var result = CharacterSelection()
        result.display = display
        result.collection = collection
        return result
    }

    private static func announces(_ store: CharacterPromotionStore,
                                  _ campaign: CharacterLaunchCampaign = campaign,
                                  owned: Set<CharacterPack> = [],
                                  purchasable: Set<CharacterPack> = purchasable,
                                  context: CharacterAnnouncementContext = CharacterAnnouncementContext()) -> Bool {
        store.shouldAnnounce(campaign, owned: owned, purchasable: purchasable, context: context)
    }

    private static func begin(_ store: CharacterPromotionStore,
                              _ campaign: CharacterLaunchCampaign = campaign,
                              at now: Date = start) throws {
        try expect(store.startTrial(campaign, owned: [], purchasable: purchasable, at: now),
                   "an eligible explicit opt-in must start the trial")
    }

    private static func trialStatus(_ store: CharacterPromotionStore, at now: Date,
                                   owned: Set<CharacterPack> = [],
                                   purchasable: Set<CharacterPack> = purchasable) -> CharacterTrialStatus {
        store.status(for: .halloween, owned: owned, purchasable: purchasable, at: now)
    }

    /// Corruption tests target the v1 persisted wire format, not private in-memory implementation.
    /// JSONEncoder's default Date representation is seconds since the Foundation reference date.
    private static func persistedTrial(startedAt: Any = start.timeIntervalSinceReferenceDate,
                                       expiresAt: Any = end.timeIntervalSinceReferenceDate,
                                       packID: String = CharacterPack.halloween.rawValue,
                                       includeStartedAt: Bool = true,
                                       includeExpiresAt: Bool = true) throws -> Data {
        var trial: [String: Any] = ["packID": packID]
        if includeStartedAt { trial["startedAt"] = startedAt }
        if includeExpiresAt { trial["expiresAt"] = expiresAt }
        return try JSONSerialization.data(withJSONObject: [
            "seenCampaigns": [campaign.id],
            "usedTrials": [CharacterPack.halloween.rawValue],
            "trial": trial,
        ])
    }

    private static func activityTrackerTests(_ test: (String, () throws -> Void) -> Void) {
        test("activity tracker remains busy until both overlapping workers finish") {
            let tracker = CharacterPromotionActivityTracker()
            let outerStarted = DispatchSemaphore(value: 0)
            let innerStarted = DispatchSemaphore(value: 0)
            let releaseOuter = DispatchSemaphore(value: 0)
            let releaseInner = DispatchSemaphore(value: 0)
            let outerFinished = DispatchSemaphore(value: 0)
            let innerFinished = DispatchSemaphore(value: 0)
            defer { releaseOuter.signal(); releaseInner.signal() }
            try expect(!tracker.isBusy, "no reservation means idle")

            DispatchQueue.global().async {
                tracker.begin()
                outerStarted.signal()
                releaseOuter.wait()
                tracker.end()
                outerFinished.signal()
            }
            DispatchQueue.global().async {
                tracker.begin()
                innerStarted.signal()
                releaseInner.wait()
                tracker.end()
                innerFinished.signal()
            }
            try expect(outerStarted.wait(timeout: .now() + 5) == .success,
                       "outer worker must reserve before observation")
            try expect(innerStarted.wait(timeout: .now() + 5) == .success,
                       "inner worker must reserve before observation")
            try expect(tracker.isBusy, "main-thread observation must see overlapping workers")
            releaseInner.signal()
            try expect(innerFinished.wait(timeout: .now() + 5) == .success, "inner worker must finish")
            try expect(tracker.isBusy, "ending the inner operation must not hide the outer operation")
            releaseOuter.signal()
            try expect(outerFinished.wait(timeout: .now() + 5) == .success, "outer worker must finish")
            try expect(!tracker.isBusy, "the final completion must restore idle")
        }

        test("activity tracker observations stay busy during concurrent nested reservations") {
            let tracker = CharacterPromotionActivityTracker()
            let observations = ActivityObservationFailures()
            // A long operation overlaps every short one, so no observer may see an idle gap.
            tracker.begin()
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                for _ in 0..<256 {
                    tracker.begin()
                    observations.record(tracker.isBusy)
                    tracker.end()
                    observations.record(tracker.isBusy)
                }
            }
            try expect(!observations.hasFailures,
                       "background readers must never see idle while the long operation is reserved")
            try expect(tracker.isBusy, "all short completions must preserve the long reservation")
            tracker.end()
            try expect(!tracker.isBusy, "2048 concurrent nested reservations must balance to idle")
        }
    }

    static func main() {
        var passed = 0
        var failed = 0
        func test(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                passed += 1
                print("PASS: \(name)")
            } catch {
                failed += 1
                print("FAIL: \(name): \(error)")
            }
        }

        if CommandLine.arguments.contains("--activity-tracker-only") {
            activityTrackerTests(test)
            print("CharacterPromotionActivityTrackerTests: \(passed) passed, \(failed) failed")
            if failed > 0 { exit(1) }
            return
        }

        test("announcement is consumed only by markAnnounced and persists across restart") {
            let fixture = PromotionFixture()
            let store = fixture.store()
            try expect(announces(store), "a fresh eligible campaign must be announced")
            try expect(announces(store), "eligibility checks must not consume the announcement")
            try expect(store.expiration == nil, "an announcement must not opt the user into a trial")
            try expect(trialStatus(store, at: start) == .available, "announcement checks keep trial available")
            store.markAnnounced(campaign)
            store.markAnnounced(campaign)
            try expect(!announces(store), "a marked campaign must not be announced twice")
            try expect(!announces(fixture.store()), "the announcement history must survive restart")
            try expect(trialStatus(fixture.store(), at: start) == .available,
                       "seeing an announcement must not consume the trial")
        }

        test("announcement preference persists and does not disable explicit trial opt-in") {
            let fixture = PromotionFixture()
            let store = fixture.store()
            try expect(store.announcementsEnabled, "announcements default to enabled")
            store.announcementsEnabled = false
            let restarted = fixture.store()
            try expect(!restarted.announcementsEnabled, "opt-out must survive restart")
            try expect(!announces(restarted) && !announces(restarted, secondCampaign),
                       "opt-out suppresses every campaign")
            try begin(restarted)
            try expect(trialStatus(restarted, at: start) == .active(until: end),
                       "a settings opt-in remains available while announcements are disabled")
            restarted.announcementsEnabled = true
            try expect(fixture.store().announcementsEnabled, "re-enabling must survive restart")
            try expect(!announces(fixture.store()), "re-enabling must preserve campaign history")
        }

        test("ownership and purchasability gate announcement and trial independently") {
            let ownerships: [Set<CharacterPack>] = [[], [.baseMotion], [.halloween], [.baseMotion, .halloween]]
            let products: [Set<CharacterPack>] = [[], [.baseMotion], [.halloween], [.baseMotion, .halloween]]
            for owned in ownerships {
                for products in products {
                    let fixture = PromotionFixture()
                    let store = fixture.store()
                    let eligible = !owned.contains(.halloween) && products.contains(.halloween)
                    try expect(announces(store, owned: owned, purchasable: products) == eligible,
                               "announcement must depend on this campaign's pack, not another pack")
                    let expected: CharacterTrialStatus = eligible ? .available : .unavailable
                    try expect(trialStatus(store, at: start, owned: owned, purchasable: products) == expected,
                               "trial eligibility must respect seasonal ownership and sale availability")
                    try expect(store.status(for: .baseMotion, owned: owned, purchasable: products, at: start) == .unavailable,
                               "retired base motion must never offer a trial")
                    try expect(store.startTrial(campaign, owned: owned, purchasable: products, at: start) == eligible,
                               "trial start must enforce the same pack eligibility")
                    if !eligible {
                        try expect(store.expiration == nil, "a rejected start must not create a trial")
                        try expect(announces(store), "a rejected start must not consume the campaign")
                        try begin(store)
                    }
                }
            }
        }

        let contextBlockers: [(String, WritableKeyPath<CharacterAnnouncementContext, Bool>, Bool)] = [
            ("menu tracking", \.menuOpen, true),
            ("disk operation", \.diskBusy, true),
            ("sleep", \.sleeping, true),
            ("another UI", \.otherUIVisible, true),
            ("termination", \.terminating, true),
            ("incomplete onboarding", \.onboardingComplete, false),
        ]
        for (name, keyPath, blockedValue) in contextBlockers {
            test("context suppresses \(name) without consuming the campaign") {
                let fixture = PromotionFixture()
                let store = fixture.store()
                var blocked = CharacterAnnouncementContext()
                blocked[keyPath: keyPath] = blockedValue
                try expect(!announces(store, context: blocked), "the blocker must suppress presentation")
                try expect(!announces(fixture.store(), context: blocked), "restart must still respect the blocker")
                try expect(announces(store), "clearing the blocker must leave the announcement eligible")
                try expect(store.expiration == nil, "a context check must not start a trial")
            }
        }

        test("second campaign has independent persisted announcement history") {
            let fixture = PromotionFixture()
            let store = fixture.store()
            store.markAnnounced(campaign)
            let restarted = fixture.store()
            try expect(!announces(restarted), "first campaign stays consumed")
            try expect(announces(restarted, secondCampaign), "a new campaign ID has independent eligibility")
            restarted.markAnnounced(secondCampaign)
            let again = fixture.store()
            try expect(!announces(again) && !announces(again, secondCampaign),
                       "both campaign histories must survive another restart")
        }

        test("trial begins at opt-in and expires exactly at 72 hours") {
            let fixture = PromotionFixture()
            let store = fixture.store()
            try begin(store)
            try expect(store.expiration == end, "deadline must be exactly 259200 seconds after opt-in")
            try expect(trialStatus(store, at: start) == .active(until: end), "start boundary is inclusive")
            try expect(store.activePack(at: end.addingTimeInterval(-0.001)) == .halloween,
                       "trial remains active immediately before the deadline")
            try expect(trialStatus(store, at: end.addingTimeInterval(-0.001)) == .active(until: end),
                       "status must use the original exact deadline")
            try expect(store.activePack(at: end) == nil, "expiry boundary is exclusive")
            try expect(trialStatus(store, at: end) == .ended, "status must end at exactly 72 hours")
            try expect(store.activePack(at: end.addingTimeInterval(0.001)) == nil,
                       "trial must remain inactive after the deadline")
            try expect(store.expireTrial(at: end), "reconciliation must remove the expired overlay")
            try expect(store.expiration == nil, "reconciliation must clear the overlay deadline")
            try expect(!store.expireTrial(at: end), "duplicate reconciliation must be harmless")
        }

        test("restart keeps the original active deadline and cannot renew the trial") {
            let fixture = PromotionFixture()
            try begin(fixture.store())
            let restarted = fixture.store()
            let halfway = start.addingTimeInterval(129_600)
            try expect(trialStatus(restarted, at: halfway) == .active(until: end),
                       "restart must restore the original deadline, not add another 72 hours")
            try expect(restarted.expiration == end, "deadline is persisted")
            try expect(!restarted.startTrial(campaign, owned: [], purchasable: purchasable, at: halfway),
                       "starting an active trial again must be rejected")
            try expect(!restarted.expireTrial(at: end.addingTimeInterval(-0.001)),
                       "wake before expiry must not end the trial")
            try expect(fixture.store().expiration == end, "rejected renewals cannot rewrite the deadline")
        }

        test("restart after expiry reconciles once and preserves the ended history") {
            let fixture = PromotionFixture()
            try begin(fixture.store())
            let restarted = fixture.store()
            let after = end.addingTimeInterval(1)
            try expect(trialStatus(restarted, at: after) == .ended, "offline elapsed time counts toward expiry")
            try expect(restarted.activePack(at: after) == nil, "restart after expiry has no overlay")
            try expect(!restarted.startTrial(secondCampaign, owned: [], purchasable: purchasable, at: after),
                       "another campaign cannot reset an expired pack trial")
            try expect(restarted.expireTrial(at: after), "wake reconciliation must persist expiration")
            let again = fixture.store()
            try expect(trialStatus(again, at: after) == .ended, "ended history survives restart")
            try expect(!again.startTrial(campaign, owned: [], purchasable: purchasable, at: after),
                       "an ended trial cannot restart")
            try expect(again.activePack(at: start.addingTimeInterval(60)) == nil,
                       "rolling the clock back after reconciled expiry must not revive the overlay")
        }

        for saved in [selection(.numbers), selection(.numbers, .halloween), selection(.characters)] {
            test("temporary overlay preserves saved \(saved.display)/\(saved.collection) through restart and expiry") {
                let fixture = PromotionFixture()
                saved.save(to: fixture.defaults)
                let store = fixture.store()
                try expect(store.effectiveSelection(saved: saved, owned: [], at: start) == saved,
                           "announcement availability alone must preserve saved selection")
                try begin(store)
                try expect(store.effectiveSelection(saved: saved, owned: [], at: start) == selection(.characters, .halloween),
                           "explicit trial temporarily overlays the seasonal collection")
                try expect(CharacterSelection(defaults: fixture.defaults) == saved,
                           "overlay must not overwrite saved display or collection")
                let restarted = fixture.store()
                let restored = CharacterSelection(defaults: UserDefaults(suiteName: fixture.suiteName)!)
                try expect(restored == saved, "saved selection survives store restart")
                try expect(restarted.effectiveSelection(saved: restored, owned: [], at: start.addingTimeInterval(60))
                    == selection(.characters, .halloween), "active overlay survives restart")
                try expect(restarted.effectiveSelection(saved: restored, owned: [], at: end) == saved,
                           "expiry immediately exposes the prior selection even before reconciliation")
                try expect(restarted.expireTrial(at: end), "expired trial can be reconciled")
                try expect(fixture.store().effectiveSelection(saved: restored, owned: [], at: end) == saved,
                           "reconciled expiry preserves prior selection after another restart")
                try expect(CharacterSelection(defaults: fixture.defaults) == saved,
                           "ending the overlay must not write a fallback over the user's preference")
            }
        }

        test("preference changed during the trial is the selection revealed when it ends") {
            let fixture = PromotionFixture()
            selection(.numbers).save(to: fixture.defaults)
            try begin(fixture.store())
            let changed = selection(.characters)
            changed.save(to: fixture.defaults)
            let restarted = fixture.store()
            let saved = CharacterSelection(defaults: fixture.defaults)
            try expect(restarted.effectiveSelection(saved: saved, owned: [], at: start.addingTimeInterval(1))
                == selection(.characters, .halloween), "an active overlay remains temporary")
            try expect(restarted.expireTrial(at: end), "expiry is reconciled")
            try expect(restarted.effectiveSelection(saved: saved, owned: [], at: end) == changed,
                       "expiry must reveal the latest saved preference, not a stale start-time snapshot")
            try expect(CharacterSelection(defaults: fixture.defaults) == changed,
                       "the changed preference stays persisted")
        }

        test("cancel is persistent, removes overlay, and prohibits a second campaign trial") {
            let fixture = PromotionFixture()
            let saved = selection(.numbers)
            saved.save(to: fixture.defaults)
            let store = fixture.store()
            try expect(!store.cancelTrial(), "cancel with no trial must be harmless")
            try begin(store)
            try expect(!announces(store) && !announces(store, secondCampaign),
                       "an active pack trial suppresses both campaigns")
            try expect(store.cancelTrial(), "the user can end an active trial early")
            try expect(!store.cancelTrial(), "duplicate cancellation must be harmless")
            let restarted = fixture.store()
            let now = start.addingTimeInterval(60)
            try expect(trialStatus(restarted, at: now) == .ended, "cancellation preserves consumed history")
            try expect(restarted.expiration == nil && restarted.activePack(at: now) == nil,
                       "cancelled trial must have no deadline or overlay after restart")
            try expect(restarted.effectiveSelection(saved: saved, owned: [], at: now) == saved,
                       "cancel must restore the saved number selection")
            try expect(!restarted.startTrial(campaign, owned: [], purchasable: purchasable, at: now),
                       "cancelled trial cannot restart")
            try expect(!restarted.startTrial(secondCampaign, owned: [], purchasable: purchasable, at: now),
                       "a new campaign ID cannot grant another trial of the same pack")
            try expect(!announces(restarted) && announces(restarted, secondCampaign),
                       "pack trial history and per-campaign announcement history remain independent")
            try expect(CharacterSelection(defaults: fixture.defaults) == saved, "cancel does not rewrite preferences")
        }

        test("purchase acquired during a trial excludes trial status and every overlay") {
            let fixture = PromotionFixture()
            let store = fixture.store()
            try begin(store)
            let owned: Set<CharacterPack> = [.halloween]
            let now = start.addingTimeInterval(1)
            try expect(trialStatus(store, at: now, owned: owned) == .unavailable,
                       "verified ownership takes precedence over an active trial")
            try expect(!announces(store, secondCampaign, owned: owned), "owners never receive the pack promotion")
            try expect(!store.startTrial(secondCampaign, owned: owned, purchasable: purchasable, at: now),
                       "owners cannot opt into another trial")
            for saved in [selection(.numbers), selection(.characters), selection(.characters, .halloween)] {
                saved.save(to: fixture.defaults)
                try expect(store.effectiveSelection(saved: saved, owned: owned, at: now) == saved,
                           "ownership must preserve every saved display and collection")
                try expect(fixture.store().effectiveSelection(saved: saved, owned: owned, at: now) == saved,
                           "restart must not reapply a trial overlay to an owner")
                try expect(CharacterSelection(defaults: fixture.defaults) == saved,
                           "ownership exclusion must not overwrite saved selection")
            }
            try expect(store.cancelTrial(), "remaining local trial metadata can be cancelled")
            try expect(trialStatus(store, at: now, owned: owned) == .unavailable,
                       "cancelling local metadata must not remove purchased access")
        }

        test("active opt-in remains local when sale availability or announcement preference changes") {
            let fixture = PromotionFixture()
            let store = fixture.store()
            try begin(store)
            store.announcementsEnabled = false
            let now = start.addingTimeInterval(1)
            try expect(trialStatus(store, at: now, purchasable: []) == .active(until: end),
                       "sale configuration changes must not silently shorten a started local trial")
            try expect(store.effectiveSelection(saved: selection(.numbers), owned: [], at: now)
                == selection(.characters, .halloween), "announcement opt-out must not cancel an explicit trial")
            try expect(!announces(store, secondCampaign, purchasable: []),
                       "no sale availability still suppresses announcements")
        }

        test("nonfinite opt-in timestamps are rejected without consuming a trial") {
            for seconds in [Double.nan, Double.infinity, -Double.infinity] {
                let fixture = PromotionFixture()
                let store = fixture.store()
                let malformed = Date(timeIntervalSince1970: seconds)
                try expect(!store.startTrial(campaign, owned: [], purchasable: purchasable, at: malformed),
                           "nonfinite now must be rejected")
                try expect(store.expiration == nil && store.activePack(at: start) == nil,
                           "invalid opt-in cannot create a persisted overlay")
                try expect(trialStatus(fixture.store(), at: start) == .available,
                           "invalid opt-in must leave a real future opt-in available")
                try expect(announces(fixture.store()), "invalid opt-in must not consume the campaign")
                try begin(fixture.store())
            }
        }

        test("nonfinite query timestamps never grant an active overlay") {
            let fixture = PromotionFixture()
            let store = fixture.store()
            try begin(store)
            let saved = selection(.numbers)
            for seconds in [Double.nan, Double.infinity, -Double.infinity] {
                let malformed = Date(timeIntervalSince1970: seconds)
                try expect(store.activePack(at: malformed) == nil, "invalid now must not grant trial access")
                try expect(store.effectiveSelection(saved: saved, owned: [], at: malformed) == saved,
                           "invalid now must preserve the saved selection")
            }
            try expect(trialStatus(store, at: start) == .active(until: end),
                       "read-only invalid queries must not mutate a valid trial")
        }

        test("clock rollback before opt-in fails closed and reconciliation permanently ends the trial") {
            let fixture = PromotionFixture()
            try begin(fixture.store())
            let restarted = fixture.store()
            let earlier = start.addingTimeInterval(-1)
            let saved = selection(.characters)
            try expect(restarted.activePack(at: earlier) == nil, "trial cannot be active before its opt-in time")
            try expect(restarted.effectiveSelection(saved: saved, owned: [], at: earlier) == saved,
                       "rollback must reveal the saved preference")
            try expect(trialStatus(restarted, at: earlier) == .ended, "rollback invalidates the local trial window")
            try expect(restarted.expireTrial(at: earlier), "reconciliation must remove invalid rolled-back trial")
            let again = fixture.store()
            try expect(again.activePack(at: start.addingTimeInterval(60)) == nil,
                       "moving time forward again cannot revive an invalidated trial")
            try expect(trialStatus(again, at: start) == .ended, "rollback-ended history is persistent")
            try expect(!again.startTrial(secondCampaign, owned: [], purchasable: purchasable, at: start),
                       "rollback cannot be used to opt into another campaign trial")
        }

        let invalidWindows: [(String, Date, Date)] = [
            ("shortened duration", start, end.addingTimeInterval(-1)),
            ("extended duration", start, end.addingTimeInterval(1)),
            ("zero duration", start, start),
            ("reversed timestamps", end, start),
            ("future opt-in", start.addingTimeInterval(60), end.addingTimeInterval(60)),
        ]
        for (name, began, expires) in invalidWindows {
            test("persisted malformed window: \(name)") {
                let fixture = PromotionFixture()
                fixture.loadState(try persistedTrial(startedAt: began.timeIntervalSinceReferenceDate,
                                                     expiresAt: expires.timeIntervalSinceReferenceDate))
                let store = fixture.store()
                try expect(store.activePack(at: start) == nil, "an invalid persisted window must not grant access")
                try expect(store.effectiveSelection(saved: selection(.numbers), owned: [], at: start) == selection(.numbers),
                           "invalid persisted time must not override a saved number preference")
                try expect(trialStatus(store, at: start) == .ended, "used history must survive an invalid trial window")
                try expect(store.expireTrial(at: start), "invalid persisted window must be removable")
                let restarted = fixture.store()
                try expect(restarted.expiration == nil, "reconciliation must persist removal of malformed trial")
                try expect(!restarted.startTrial(secondCampaign, owned: [], purchasable: purchasable, at: start),
                           "malformed window must not reset the pack's trial history")
            }
        }

        test("unknown persisted pack never grants access and preserves the used seasonal history") {
            let fixture = PromotionFixture()
            fixture.loadState(try persistedTrial(packID: "unknown_future_pack"))
            let store = fixture.store()
            try expect(store.activePack(at: start) == nil, "an unknown persisted pack cannot grant access")
            try expect(trialStatus(store, at: start) == .ended, "valid used history still blocks another seasonal trial")
            try expect(store.expireTrial(at: start), "unrecognized trial metadata can be reconciled")
            try expect(!fixture.store().startTrial(campaign, owned: [], purchasable: purchasable, at: start),
                       "removing unknown metadata cannot erase known consumed history")
        }

        let invalidDates: [(String, () throws -> Data)] = [
            ("missing opt-in date", { try persistedTrial(includeStartedAt: false) }),
            ("missing expiration date", { try persistedTrial(includeExpiresAt: false) }),
            ("string opt-in date", { try persistedTrial(startedAt: "NaN") }),
            ("null expiration date", { try persistedTrial(expiresAt: NSNull()) }),
        ]
        for (name, data) in invalidDates {
            test("malformed persisted date preserves consumed history: \(name)") {
                let fixture = PromotionFixture()
                fixture.loadState(try data())
                let store = fixture.store()
                try expect(store.activePack(at: start) == nil, "undecodable trial dates cannot grant an overlay")
                let repeatsAnnouncement = announces(store)
                let before = trialStatus(store, at: start)
                let restartsTrial = store.startTrial(secondCampaign, owned: [], purchasable: purchasable, at: start)
                let afterReload = trialStatus(fixture.store(), at: start)
                try expect(!repeatsAnnouncement && before == .ended && !restartsTrial && afterReload == .ended,
                           "valid histories must survive a malformed date; announcement=\(repeatsAnnouncement), "
                           + "status=\(before), restartedTrial=\(restartsTrial), reloadedStatus=\(afterReload)")
            }
        }

        test("valid persisted timestamps without a consumed marker cannot be cancelled into a new trial") {
            let fixture = PromotionFixture()
            let data = try JSONSerialization.data(withJSONObject: [
                "seenCampaigns": [campaign.id], "usedTrials": [String](),
                "trial": ["packID": CharacterPack.halloween.rawValue,
                          "startedAt": start.timeIntervalSinceReferenceDate,
                          "expiresAt": end.timeIntervalSinceReferenceDate] as [String: Any],
            ])
            fixture.loadState(data)
            let store = fixture.store()
            // Either reject this inconsistent record or repair its marker; cancellation must remain final.
            _ = store.cancelTrial()
            let restarted = fixture.store()
            let statusAfterCancel = trialStatus(restarted, at: start)
            let restartsTrial = restarted.startTrial(secondCampaign, owned: [], purchasable: purchasable, at: start)
            try expect(statusAfterCancel == .ended && !restartsTrial,
                       "cancellation must remain final when a persisted marker is missing; "
                       + "status=\(statusAfterCancel), restartedTrial=\(restartsTrial)")
        }

        test("finite timestamp unable to represent an exact 72-hour deadline cannot consume opt-in") {
            let fixture = PromotionFixture()
            let store = fixture.store()
            let unrepresentable = Date(timeIntervalSince1970: Double.greatestFiniteMagnitude)
            let accepted = store.startTrial(campaign, owned: [], purchasable: purchasable, at: unrepresentable)
            let grantsOverlay = store.activePack(at: unrepresentable) != nil
            let reloadedStatus = trialStatus(fixture.store(), at: start)
            try expect(!accepted && store.expiration == nil && reloadedStatus == .available,
                       "unrepresentable deadline must be rejected without consuming opt-in; "
                       + "accepted=\(accepted), grantsOverlay=\(grantsOverlay), reloadedStatus=\(reloadedStatus)")
        }

        activityTrackerTests(test)
        print("CharacterPromotionPolicyTests: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
