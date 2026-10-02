import Foundation

/// Campaign IDs are stable per released pack. Artwork and campaign metadata ship with the app.
struct CharacterLaunchCampaign: Equatable {
    let id: String
    let collection: CharacterCollection
    let previewCounts: [Int]

    static let halloween2026 = CharacterLaunchCampaign(
        id: "halloween_v1.launch.2026", collection: .halloween, previewCounts: [0, 2, 9])
    static let current = halloween2026
    static func campaign(for pack: CharacterPack) -> CharacterLaunchCampaign? {
        [halloween2026].first { $0.pack == pack }
    }
    var pack: CharacterPack { collection.paidPack! }
    var releaseTitle: String { String(localized: "\(collection.title): 10 New Characters!") }
}

enum CharacterTrialStatus: Equatable {
    case unavailable, available, active(until: Date), ended
}

/// UI eligibility is evaluated on the main thread after menu tracking has completely ended.
struct CharacterAnnouncementContext {
    var menuOpen = false
    var diskBusy = false
    var sleeping = false
    var otherUIVisible = false
    var terminating = false
    var onboardingComplete = true

    var allowsPresentation: Bool {
        onboardingComplete && !menuOpen && !diskBusy && !sleeping && !otherUIVisible && !terminating
    }
}

/// A local preview never creates a billing entitlement or overwrites the saved character selection.
/// This store belongs to the app's main thread; Foundation-only tests use isolated defaults suites.
final class CharacterPromotionStore {
    static let trialDuration: TimeInterval = 72 * 60 * 60
    private static let stateKey = "character.promotion.state.v1"
    private static let enabledKey = "character.promotion.announcementsEnabled"

    private struct Trial: Codable {
        let packID: String
        let startedAt: Date
        let expiresAt: Date
        func isActive(at now: Date) -> Bool {
            guard CharacterPack(rawValue: packID) != nil,
                  startedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
                  now.timeIntervalSince1970.isFinite,
                  expiresAt.timeIntervalSince(startedAt) == CharacterPromotionStore.trialDuration else { return false }
            return startedAt <= now && now < expiresAt
        }
    }
    private struct State: Codable {
        var seenCampaigns = Set<String>()
        var usedTrials = Set<String>()
        var trial: Trial?

        private enum CodingKeys: String, CodingKey { case seenCampaigns, usedTrials, trial }
        private enum TrialKey: String, CodingKey { case packID }
        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            seenCampaigns = try values.decodeIfPresent(Set<String>.self, forKey: .seenCampaigns) ?? []
            usedTrials = try values.decodeIfPresent(Set<String>.self, forKey: .usedTrials) ?? []
            // A malformed preview must not discard otherwise valid announcement/trial history.
            trial = try? values.decode(Trial.self, forKey: .trial)
            if let recorded = try? values.nestedContainer(keyedBy: TrialKey.self, forKey: .trial),
               let packID = try? recorded.decode(String.self, forKey: .packID) {
                usedTrials.insert(packID)
            }
        }
    }
    private let defaults: UserDefaults
    private var state: State

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = defaults.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    var announcementsEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    func shouldAnnounce(_ campaign: CharacterLaunchCampaign, owned: Set<CharacterPack>,
                        purchasable: Set<CharacterPack>, context: CharacterAnnouncementContext) -> Bool {
        announcementsEnabled && context.allowsPresentation && !state.seenCampaigns.contains(campaign.id)
            && !owned.contains(campaign.pack) && purchasable.contains(campaign.pack)
            && state.trial?.packID != campaign.pack.rawValue
    }

    func markAnnounced(_ campaign: CharacterLaunchCampaign) {
        state.seenCampaigns.insert(campaign.id)
        save()
    }

    func status(for pack: CharacterPack, owned: Set<CharacterPack>, purchasable: Set<CharacterPack>,
                at now: Date = Date()) -> CharacterTrialStatus {
        guard pack != .baseMotion, !owned.contains(pack) else { return .unavailable }
        if let trial = state.trial, trial.packID == pack.rawValue, trial.isActive(at: now) {
            return .active(until: trial.expiresAt)
        }
        if state.usedTrials.contains(pack.rawValue) { return .ended }
        return CharacterLaunchCampaign.campaign(for: pack) != nil && purchasable.contains(pack) ? .available : .unavailable
    }

    @discardableResult
    func startTrial(_ campaign: CharacterLaunchCampaign, owned: Set<CharacterPack>,
                    purchasable: Set<CharacterPack>, at now: Date = Date()) -> Bool {
        guard now.timeIntervalSince1970.isFinite,
              status(for: campaign.pack, owned: owned, purchasable: purchasable, at: now) == .available else { return false }
        let trial = Trial(packID: campaign.pack.rawValue, startedAt: now,
                          expiresAt: now.addingTimeInterval(Self.trialDuration))
        guard trial.isActive(at: now) else { return false }
        state.usedTrials.insert(campaign.pack.rawValue)
        state.trial = trial
        state.seenCampaigns.insert(campaign.id)
        save()
        return true
    }

    func activePack(at now: Date = Date()) -> CharacterPack? {
        guard let trial = state.trial, trial.isActive(at: now) else { return nil }
        return CharacterPack(rawValue: trial.packID)
    }

    var expiration: Date? { state.trial?.expiresAt }

    func effectiveSelection(saved: CharacterSelection, owned: Set<CharacterPack>,
                            at now: Date = Date()) -> CharacterSelection {
        guard let pack = activePack(at: now), !owned.contains(pack),
              let collection = CharacterCollection.allCases.first(where: { $0.paidPack == pack }) else { return saved }
        return CharacterSelection(display: .characters, collection: collection)
    }

    @discardableResult
    func expireTrial(at now: Date = Date()) -> Bool {
        guard let trial = state.trial, !trial.isActive(at: now) else { return false }
        state.usedTrials.insert(trial.packID)
        state.trial = nil
        save()
        return true
    }

    @discardableResult
    func cancelTrial() -> Bool {
        guard let trial = state.trial else { return false }
        state.usedTrials.insert(trial.packID)
        state.trial = nil
        save()
        return true
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.stateKey) }
    }
}

/// Observes overlapping disk calls without changing their queues, deadlines, or completion rules.
final class CharacterPromotionActivityTracker {
    private let lock = NSLock()
    private var count = 0
    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return count > 0
    }
    func begin() { lock.lock(); count += 1; lock.unlock() }
    func end() { lock.lock(); count -= 1; assert(count >= 0); lock.unlock() }
}
