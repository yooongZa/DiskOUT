import Foundation

/// One-shot evidence latch shared by DA request joiners. A waiter timeout never completes the
/// latch; the first callback/disconnect evidence is sticky and releases every waiter exactly once.
final class StickyAsyncEvidence<Value>: @unchecked Sendable {
    let completion = DispatchGroup()
    private let lock = NSLock()
    private var value: Value?
    private var observers: [(Value) -> Void] = []

    init() {
        completion.enter()
    }

    @discardableResult
    func finishOnce(_ newValue: Value) -> Bool {
        lock.lock()
        guard value == nil else {
            lock.unlock()
            return false
        }
        value = newValue
        let callbacks = observers
        observers.removeAll()
        lock.unlock()
        completion.leave()
        callbacks.forEach { $0(newValue) }
        return true
    }

    func snapshot() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func wait(timeout: TimeInterval) -> Value? {
        if completion.wait(timeout: .now() + max(0, timeout)) == .success {
            return snapshot()
        }
        // Recheck under the latch lock at the timeout/callback boundary.
        return snapshot()
    }

    func observe(_ callback: @escaping (Value) -> Void) {
        lock.lock()
        if let value {
            lock.unlock()
            callback(value)
            return
        }
        observers.append(callback)
        lock.unlock()
    }
}

/// Tracks sleep-unmount batch workers through scheduler stalls and uncancelable DA waiter timeouts.
/// Automatic wake handling waits for true terminal evidence (including a superseded manual request)
/// instead of treating the bounded caller return as completion. A new racing worker is caught by
/// the idle callback's next state check and its independent relaunch owner.
final class SleepUnmountActivityTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var idleObservers: [() -> Void] = []

    func begin() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func finish() {
        lock.lock()
        guard count > 0 else {
            lock.unlock()
            return
        }
        count -= 1
        guard count == 0 else {
            lock.unlock()
            return
        }
        let callbacks = idleObservers
        idleObservers.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }

    func whenIdle(_ callback: @escaping () -> Void) {
        lock.lock()
        guard count > 0 else {
            lock.unlock()
            callback()
            return
        }
        idleObservers.append(callback)
        lock.unlock()
    }

    /// Linearizes an idle check with a small claim operation. `begin()` uses the same lock, so a
    /// remount token cannot be claimed in the gap between checking `activeCount` and mutating the
    /// wake coordinator.
    @discardableResult
    func performIfIdle(_ action: () -> Void) -> Bool {
        lock.lock()
        guard count == 0 else {
            lock.unlock()
            return false
        }
        action()
        lock.unlock()
        return true
    }

    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

struct SleepUnmountTarget: Equatable, Sendable {
    let name: String
    let volumePath: String
    let wholeDiskBSD: String?
    /// DAInventory가 이 mount path를 관측한 physical appearance(물리 연결 세대).
    /// BSD 이름은 재연결 뒤 재사용될 수 있으므로 둘을 함께 검증해야 한다.
    let physicalGeneration: UInt64?
    /// Exact IOMedia registry entry captured with the generation.
    let mediaRegistryEntryID: UInt64?
    /// Mounted sibling set captured in the authoritative sleep snapshot. A new sibling appearing
    /// before the whole-disk request invalidates that request and forces a fresh protection pass.
    let mountedVolumeBSDs: Set<String>?
    /// False only for an explicit user-commanded path such as Eject and Sleep.
    let enforceProtectionClosure: Bool

    init(name: String,
         volumePath: String,
         wholeDiskBSD: String?,
         physicalGeneration: UInt64?,
         mediaRegistryEntryID: UInt64?,
         mountedVolumeBSDs: Set<String>? = nil,
         enforceProtectionClosure: Bool = true) {
        self.name = name
        self.volumePath = volumePath
        self.wholeDiskBSD = wholeDiskBSD
        self.physicalGeneration = physicalGeneration
        self.mediaRegistryEntryID = mediaRegistryEntryID
        self.mountedVolumeBSDs = mountedVolumeBSDs
        self.enforceProtectionClosure = enforceProtectionClosure
    }
}

/// A user-selected eject must not depend on stable identity for unrelated external disks. The
/// selected physical group still includes all of its mounted siblings for Whole-disk revalidation.
enum SleepSnapshotGroupSelectionPolicy {
    static func shouldInspectGroup(
        mountedVolumePaths: Set<String>,
        selectedVolumePaths: Set<String>?
    ) -> Bool {
        guard let selectedVolumePaths else { return true }
        return !mountedVolumePaths.isDisjoint(with: selectedVolumePaths)
    }
}

enum SleepUnmountGroupKey: Equatable, Hashable, Sendable {
    case physicalDisk(bsd: String, generation: UInt64, mediaRegistryEntryID: UInt64)
    case unresolvedVolumePath(String)
}

enum SleepUnmountOperation: Equatable, Sendable {
    case wholeNormal
    case wholeForce
}

/// Typed view of the raw `DADissenterGetStatus` value. Automatic force fallback is intentionally
/// limited to contention: every permission, unsupported, I/O, and unknown status fails closed.
enum SleepUnmountDissenterStatus: Equatable, Sendable {
    case busy
    case exclusiveAccess
    case unixBusy
    case other(UInt32)

    init(rawValue: UInt32) {
        switch rawValue {
        case 0xF8DA0002: // kDAReturnBusy
            self = .busy
        case 0xF8DA0004: // kDAReturnExclusiveAccess
            self = .exclusiveAccess
        case 0xC010: // unix_err(EBUSY)
            self = .unixBusy
        default:
            self = .other(rawValue)
        }
    }

    var rawValue: UInt32 {
        switch self {
        case .busy:
            return 0xF8DA0002
        case .exclusiveAccess:
            return 0xF8DA0004
        case .unixBusy:
            return 0xC010
        case let .other(rawValue):
            return rawValue
        }
    }

    var isForceEligible: Bool {
        switch self {
        case .busy, .exclusiveAccess, .unixBusy:
            return true
        case .other:
            return false
        }
    }
}

/// One instance belongs to one sleep episode. Multiple callbacks or joiners may race to continue
/// the same physical request, but only the first claimant may submit its force operation.
final class SleepEpisodeForceClaimLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var claimedPhysicalRequestKeys = Set<SleepUnmountGroupKey>()

    @discardableResult
    func claimForce(for requestKey: SleepUnmountGroupKey) -> Bool {
        guard case .physicalDisk = requestKey else { return false }

        lock.lock()
        let inserted = claimedPhysicalRequestKeys.insert(requestKey).inserted
        lock.unlock()
        return inserted
    }
}

enum SleepMountedSiblingPolicy {
    static func isSnapshotStillSafe(expectedMountedVolumeBSDs: Set<String>,
                                    currentMountedVolumeBSDs: Set<String>,
                                    allowMissingExpectedSiblings: Bool,
                                    enforceProtectionClosure: Bool,
                                    hasProtectedCurrentSibling: Bool) -> Bool {
        let topologyMatches = allowMissingExpectedSiblings
            ? currentMountedVolumeBSDs.isSubset(of: expectedMountedVolumeBSDs)
            : expectedMountedVolumeBSDs == currentMountedVolumeBSDs
        return topologyMatches
            && (!enforceProtectionClosure || !hasProtectedCurrentSibling)
    }
}

struct SleepUnmountRequest: Equatable, Sendable {
    let key: SleepUnmountGroupKey
    /// 기존 설정 의미를 보존한다: 첫 요청은 항상 normal이고, policy가 허용할 때만 force를 이어서 요청한다.
    let allowsForceFallback: Bool
    let targets: [SleepUnmountTarget]

    var wholeDiskBSD: String? {
        guard case let .physicalDisk(bsdName, _, _) = key else { return nil }
        return bsdName
    }

    var physicalGeneration: UInt64? {
        guard case let .physicalDisk(_, generation, _) = key else { return nil }
        return generation
    }

    var mediaRegistryEntryID: UInt64? {
        guard case let .physicalDisk(_, _, entryID) = key else { return nil }
        return entryID
    }

    var mountedVolumeBSDs: Set<String>? {
        targets.first?.mountedVolumeBSDs
    }

    var enforceProtectionClosure: Bool {
        targets.first?.enforceProtectionClosure ?? true
    }

    var representativeVolumePath: String? {
        targets.first?.volumePath
    }
}

enum SleepUnmountCleanSuccessTiming: Equatable, Sendable {
    case beforeTimeout
    case afterTimeout
}

enum SleepUnmountLateSuccessRecordingPolicy: Equatable, Sendable {
    /// Existing automatic sleep flows preserve remount ownership when a clean DA callback arrives
    /// after their bounded waiter returns.
    case preserveAutomaticRemountOwnership
    /// Legacy opt-out retained for older callers. New app-managed eject routes preserve every
    /// explicit clean Whole/Whole|Force callback for a wake remount.
    case discardAfterTimeout

    func shouldRecordCleanSuccess(timing: SleepUnmountCleanSuccessTiming) -> Bool {
        switch timing {
        case .beforeTimeout:
            return true
        case .afterTimeout:
            return self == .preserveAutomaticRemountOwnership
        }
    }
}

/// Dedicated best-effort contract for an IOKit-confirmed forced-sleep boundary. This remains
/// separate from `SleepEjectTrigger` so none of the established idle/lid/display/manual contracts
/// or their deadlines are changed by enabling the experimental path.
enum ForcedSleepUnmountBatchPolicy {
    static let maximumWait: TimeInterval = 3
    static let allowsForceFallback = false
    static let lateSuccessRecordingPolicy: SleepUnmountLateSuccessRecordingPolicy =
        .preserveAutomaticRemountOwnership

    static func requests(for targets: [SleepUnmountTarget]) -> [SleepUnmountRequest] {
        SleepUnmountPolicy.requests(for: targets, forceFallback: allowsForceFallback)
    }
}

enum ForcedSleepCleanSuccessPolicy {
    /// A clean callback from a joined force request is not proof of the requested normal-only
    /// operation. A normal callback remains remount evidence even after the short power deadline.
    static func shouldRecord(callbackSucceeded: Bool,
                             requestWasForced: Bool,
                             timing: SleepUnmountCleanSuccessTiming) -> Bool {
        callbackSucceeded
            && !requestWasForced
            && ForcedSleepUnmountBatchPolicy.lateSuccessRecordingPolicy
                .shouldRecordCleanSuccess(timing: timing)
    }
}

enum ForcedSleepSubmissionModePolicy {
    /// A pending normal request may be joined without issuing a duplicate. A pending force request
    /// belongs to another policy and must not be joined by the normal-only forced-sleep path.
    static func allows(requestWasForced: Bool) -> Bool {
        !requestWasForced
    }
}

enum PreparedSleepUnmountDeadlinePolicy {
    /// A prepared DA request may already be submitted even when its worker reaches the deadline.
    /// It must still enter a zero-time wait so late-terminal observation retains ownership until
    /// the uncancelable request actually terminates.
    static func shouldEnterWait(hasPreparedRequest: Bool,
                                remainingBudget: TimeInterval) -> Bool {
        hasPreparedRequest || remainingBudget > 0
    }
}

enum ForcedSleepDestructiveSubmissionPolicy {
    static func allows(isEnabled: Bool, remainingBudget: TimeInterval) -> Bool {
        isEnabled && remainingBudget > 0
    }
}

enum ForcedSleepSubmissionWavePolicy {
    /// Execute all preparations, then all final authorizations, before the first destructive
    /// submission. The caller supplies queue confinement; the three-phase ordering is testable.
    static func prepareAuthorizeThenSubmit<Prepared>(
        count: Int,
        prepare: (Int) -> Prepared,
        authorize: ([Prepared]) -> [Prepared],
        submit: (Int, Prepared) -> Prepared
    ) -> [Prepared] {
        let staged = (0..<count).map(prepare)
        let authorized = authorize(staged)
        return authorized.enumerated().map { submit($0.offset, $0.element) }
    }
}

enum ForcedSleepBoundaryRoute: Equatable, Sendable {
    case passThrough
    /// The caller starts at most one short batch, then returns directly to the power ACK path.
    /// There is intentionally no route from this case into the established refresh/retry chain.
    case bestEffortNoRetry(maximumWait: TimeInterval)
}

enum ForcedSleepBoundaryRoutingPolicy {
    static func route(isIOKitConfirmed: Bool,
                      isForcedSleep: Bool,
                      isEnabled: Bool) -> ForcedSleepBoundaryRoute {
        guard isIOKitConfirmed, isForcedSleep, isEnabled else { return .passThrough }
        return .bestEffortNoRetry(maximumWait: ForcedSleepUnmountBatchPolicy.maximumWait)
    }
}

enum SleepUnmountPolicy {
    static func requests(
        for targets: [SleepUnmountTarget],
        forceFallback: Bool
    ) -> [SleepUnmountRequest] {
        var groups: [(key: SleepUnmountGroupKey, targets: [SleepUnmountTarget])] = []
        var groupIndexByKey: [SleepUnmountGroupKey: Int] = [:]

        for target in targets {
            let key = groupKey(for: target)
            if let existingIndex = groupIndexByKey[key] {
                groups[existingIndex].targets.append(target)
            } else {
                groupIndexByKey[key] = groups.count
                groups.append((key: key, targets: [target]))
            }
        }

        return groups.map { group in
            SleepUnmountRequest(
                key: group.key,
                allowsForceFallback: forceFallback,
                targets: group.targets
            )
        }
    }

    /// Callback-only projection retained for callers that do not own a normal-request watchdog.
    /// The complete normal/force lifecycle, including the two-second watchdog, is modeled by
    /// `SleepUnmountEscalationPolicy` below.
    static func nextOperation(after event: SleepUnmountEvidenceEvent,
                              requestWasForced: Bool = false,
                              forceFallback: Bool) -> SleepUnmountOperation? {
        guard forceFallback,
              !requestWasForced,
              case let .callbackFailure(status) = event,
              status.isForceEligible else { return nil }
        return .wholeForce
    }

    private static func groupKey(for target: SleepUnmountTarget) -> SleepUnmountGroupKey {
        if let wholeDiskBSD = target.wholeDiskBSD,
           !wholeDiskBSD.isEmpty,
           let generation = target.physicalGeneration,
           let entryID = target.mediaRegistryEntryID {
            return .physicalDisk(bsd: wholeDiskBSD,
                                 generation: generation,
                                 mediaRegistryEntryID: entryID)
        }
        return .unresolvedVolumePath(target.volumePath)
    }
}

/// User-facing labels and timeout accounting are derived from the same physical request keys.
/// Display names are not identities: two separate disks may both be named "Untitled".
enum SleepUnmountBatchPresentationPolicy {
    static func labelsByRequest(
        _ requests: [SleepUnmountRequest]
    ) -> [SleepUnmountGroupKey: [String]] {
        let nameCounts = Dictionary(
            grouping: requests.flatMap(\.targets),
            by: \.name
        ).mapValues(\.count)

        return Dictionary(uniqueKeysWithValues: requests.map { request in
            let labels = request.targets.map { target in
                guard nameCounts[target.name, default: 0] > 1 else {
                    return target.name
                }
                let discriminator: String
                switch request.key {
                case let .physicalDisk(bsd, _, _):
                    discriminator = bsd
                case let .unresolvedVolumePath(path):
                    discriminator = URL(fileURLWithPath: path).lastPathComponent
                }
                return "\(target.name) (\(discriminator))"
            }
            return (request.key, labels)
        })
    }

    static func unfinishedLabels(
        requests: [SleepUnmountRequest],
        completedRequestKeys: Set<SleepUnmountGroupKey>,
        labelsByRequest: [SleepUnmountGroupKey: [String]]
    ) -> [String] {
        requests
            .filter { !completedRequestKeys.contains($0.key) }
            .flatMap { labelsByRequest[$0.key] ?? $0.targets.map(\.name) }
    }
}

struct SleepProtectionCandidate: Equatable, Sendable {
    let physicalDiskID: String?
    let isEjectTarget: Bool
    let isProtected: Bool
}

struct SleepProtectionDecision: Equatable, Sendable {
    let allowedTargetIndices: Set<Int>
    let blockedTargetIndices: Set<Int>
    let skippedTargetCount: Int
}

enum SleepProtectionPolicy {
    static func evaluate(_ candidates: [SleepProtectionCandidate]) -> SleepProtectionDecision {
        let unresolvedProtected = candidates.contains {
            $0.isProtected && ($0.physicalDiskID?.isEmpty != false)
        }
        if unresolvedProtected {
            let blocked = Set(candidates.indices.filter {
                candidates[$0].isEjectTarget && !candidates[$0].isProtected
            })
            let skipped = candidates.indices.filter {
                candidates[$0].isEjectTarget && candidates[$0].isProtected
            }.count
            return SleepProtectionDecision(allowedTargetIndices: [],
                                           blockedTargetIndices: blocked,
                                           skippedTargetCount: skipped)
        }

        let protectedDisks = Set(candidates.compactMap { candidate in
            candidate.isProtected ? candidate.physicalDiskID : nil
        })
        let allowed = Set(candidates.indices.filter { index in
            let candidate = candidates[index]
            guard candidate.isEjectTarget,
                  !candidate.isProtected else { return false }
            guard let diskID = candidate.physicalDiskID else {
                // Preserve the legacy path-only attempt when no protected sibling has unresolved
                // identity. The sleep path still rejects it later because clean DA proof needs ID.
                return true
            }
            return !protectedDisks.contains(diskID)
        })
        let targetCount = candidates.filter(\.isEjectTarget).count
        return SleepProtectionDecision(allowedTargetIndices: allowed,
                                       blockedTargetIndices: [],
                                       skippedTargetCount: targetCount - allowed.count)
    }
}

enum SleepUnmountFailure: Equatable, Sendable {
    case disconnect
    case unavailable
    case callbackFailure(SleepUnmountDissenterStatus)
}

enum SleepUnmountEvidenceState: Equatable, Sendable {
    case pending
    /// caller deadline은 지났지만 취소할 수 없는 DA request는 계속 진행 중이다.
    case pendingAfterTimeout
    case clean
    case failure(SleepUnmountFailure)
}

enum SleepUnmountEvidenceEvent: Equatable, Sendable {
    case callbackSuccess
    case callbackFailure(SleepUnmountDissenterStatus)
    case timeout
    case disconnect
    case unavailable
}

enum SleepUnmountEvidenceReducer {
    static func reduce(
        _ state: SleepUnmountEvidenceState,
        event: SleepUnmountEvidenceEvent
    ) -> SleepUnmountEvidenceState {
        guard state == .pending || state == .pendingAfterTimeout else { return state }

        switch event {
        case .callbackSuccess:
            return .clean
        case let .callbackFailure(status):
            return .failure(.callbackFailure(status))
        case .timeout:
            return .pendingAfterTimeout
        case .disconnect:
            return .failure(.disconnect)
        case .unavailable:
            return .failure(.unavailable)
        }
    }
}

enum SleepUnmountEscalationState: Equatable, Sendable {
    case awaitingNormal
    /// `normalPending` is true only after the two-second watchdog. A busy callback has already
    /// terminated the normal request, while a watchdog timeout leaves it able to succeed later.
    case awaitingForce(normalPending: Bool)
    /// Force failed first, but the timed-out normal request is still allowed to provide clean proof.
    case awaitingNormalAfterForceFailure(SleepUnmountFailure)
    case finished
}

enum SleepUnmountEscalationEvent: Equatable, Sendable {
    case normalCallbackSuccess
    case normalCallbackFailure(SleepUnmountDissenterStatus)
    case normalCallbackTimedOut
    case normalDisconnected
    case normalUnavailable
    case forceRequestAlreadyPending
    case forceCallbackSuccess
    case forceCallbackFailure(SleepUnmountDissenterStatus)
    case forceDisconnected
    case forceUnavailable
}

enum SleepUnmountEscalationAction: Equatable, Sendable {
    case none
    case submitForce
    case finishClean(requestWasForced: Bool)
    case finishFailure(SleepUnmountFailure)
}

struct SleepUnmountEscalationTransition: Equatable, Sendable {
    let state: SleepUnmountEscalationState
    let action: SleepUnmountEscalationAction
}

/// Keeps the reducer state and the one-shot destructive submission claim in one serialized value.
/// Its owner must still provide synchronization when callbacks can arrive concurrently.
struct SleepUnmountEscalationRuntime: Sendable {
    private(set) var state: SleepUnmountEscalationState = .awaitingNormal
    private var forceSubmissionClaimed = false

    mutating func consume(
        _ event: SleepUnmountEscalationEvent,
        allowsForceFallback: Bool
    ) -> SleepUnmountEscalationAction {
        let transition = SleepUnmountEscalationPolicy.transition(
            from: state,
            event: event,
            allowsForceFallback: allowsForceFallback
        )
        state = transition.state
        return transition.action
    }

    /// The action returned by `consume` is only a proposal. Rechecking the current state here
    /// prevents a late normal-clean callback from being followed by a stale Force submission.
    mutating func claimForceSubmission() -> Bool {
        guard !forceSubmissionClaimed,
              case .awaitingForce = state else { return false }
        forceSubmissionClaimed = true
        return true
    }
}

enum SleepUnmountForceWatchdogPolicy {
    static func normalWaitDuration(
        remainingBudget: TimeInterval,
        allowsForceFallback: Bool
    ) -> TimeInterval {
        let budget = max(0, remainingBudget)
        guard allowsForceFallback else { return budget }
        return min(budget, SleepUnmountEscalationPolicy.normalWholeCallbackTimeout)
    }

    /// A shorter enclosing operation deadline must never turn into an early Force request.
    /// Busy evidence remains independently eligible for immediate Force escalation.
    static func allowsTimeoutEscalation(
        initialRemainingBudget: TimeInterval,
        currentRemainingBudget: TimeInterval,
        allowsForceFallback: Bool
    ) -> Bool {
        allowsForceFallback
            && initialRemainingBudget >= SleepUnmountEscalationPolicy.normalWholeCallbackTimeout
            && currentRemainingBudget > 0
    }
}

/// Pure lifecycle policy for one physical Whole-disk request.
///
/// The owner must serialize an event and the returned state update on one queue. That atomic
/// ownership is what makes a busy callback racing the watchdog produce exactly one force submit.
enum SleepUnmountEscalationPolicy {
    static let normalWholeCallbackTimeout: TimeInterval = 2

    static func transition(
        from state: SleepUnmountEscalationState,
        event: SleepUnmountEscalationEvent,
        allowsForceFallback: Bool
    ) -> SleepUnmountEscalationTransition {
        switch state {
        case .awaitingNormal:
            return transitionWhileAwaitingNormal(
                event: event,
                allowsForceFallback: allowsForceFallback
            )

        case let .awaitingForce(normalPending):
            return transitionWhileAwaitingForce(
                event: event,
                normalPending: normalPending
            )

        case let .awaitingNormalAfterForceFailure(forceFailure):
            return transitionWhileAwaitingNormalAfterForceFailure(
                event: event,
                forceFailure: forceFailure
            )

        case .finished:
            return SleepUnmountEscalationTransition(state: .finished, action: .none)
        }
    }

    private static func transitionWhileAwaitingNormal(
        event: SleepUnmountEscalationEvent,
        allowsForceFallback: Bool
    ) -> SleepUnmountEscalationTransition {
        switch event {
        case .normalCallbackSuccess:
            return SleepUnmountEscalationTransition(
                state: .finished,
                action: .finishClean(requestWasForced: false)
            )

        case let .normalCallbackFailure(status):
            if allowsForceFallback && status.isForceEligible {
                return SleepUnmountEscalationTransition(
                    state: .awaitingForce(normalPending: false),
                    action: .submitForce
                )
            }
            return SleepUnmountEscalationTransition(
                state: .finished,
                action: .finishFailure(.callbackFailure(status))
            )

        case .normalCallbackTimedOut:
            guard allowsForceFallback else {
                return SleepUnmountEscalationTransition(
                    state: .awaitingNormal,
                    action: .none
                )
            }
            return SleepUnmountEscalationTransition(
                state: .awaitingForce(normalPending: true),
                action: .submitForce
            )

        case .forceRequestAlreadyPending:
            return SleepUnmountEscalationTransition(
                state: .awaitingForce(normalPending: false),
                action: .none
            )

        case .normalDisconnected:
            return SleepUnmountEscalationTransition(
                state: .finished,
                action: .finishFailure(.disconnect)
            )

        case .normalUnavailable:
            return SleepUnmountEscalationTransition(
                state: .finished,
                action: .finishFailure(.unavailable)
            )

        case .forceCallbackSuccess,
             .forceCallbackFailure,
             .forceDisconnected,
             .forceUnavailable:
            return SleepUnmountEscalationTransition(
                state: .awaitingNormal,
                action: .none
            )
        }
    }

    private static func transitionWhileAwaitingForce(
        event: SleepUnmountEscalationEvent,
        normalPending: Bool
    ) -> SleepUnmountEscalationTransition {
        switch event {
        case .normalCallbackSuccess:
            return SleepUnmountEscalationTransition(
                state: .finished,
                action: .finishClean(requestWasForced: false)
            )

        case .normalCallbackFailure,
             .normalDisconnected,
             .normalUnavailable:
            return SleepUnmountEscalationTransition(
                state: .awaitingForce(normalPending: false),
                action: .none
            )

        case .normalCallbackTimedOut,
             .forceRequestAlreadyPending:
            return SleepUnmountEscalationTransition(
                state: .awaitingForce(normalPending: normalPending),
                action: .none
            )

        case .forceCallbackSuccess:
            return SleepUnmountEscalationTransition(
                state: .finished,
                action: .finishClean(requestWasForced: true)
            )

        case let .forceCallbackFailure(status):
            return forceFailureTransition(
                .callbackFailure(status),
                normalPending: normalPending
            )

        case .forceDisconnected:
            return forceFailureTransition(.disconnect, normalPending: normalPending)

        case .forceUnavailable:
            return forceFailureTransition(.unavailable, normalPending: normalPending)
        }
    }

    private static func forceFailureTransition(
        _ failure: SleepUnmountFailure,
        normalPending: Bool
    ) -> SleepUnmountEscalationTransition {
        if normalPending {
            return SleepUnmountEscalationTransition(
                state: .awaitingNormalAfterForceFailure(failure),
                action: .none
            )
        }
        return SleepUnmountEscalationTransition(
            state: .finished,
            action: .finishFailure(failure)
        )
    }

    private static func transitionWhileAwaitingNormalAfterForceFailure(
        event: SleepUnmountEscalationEvent,
        forceFailure: SleepUnmountFailure
    ) -> SleepUnmountEscalationTransition {
        switch event {
        case .normalCallbackSuccess:
            return SleepUnmountEscalationTransition(
                state: .finished,
                action: .finishClean(requestWasForced: false)
            )
        case .normalCallbackFailure,
             .normalDisconnected,
             .normalUnavailable:
            return SleepUnmountEscalationTransition(
                state: .finished,
                action: .finishFailure(forceFailure)
            )
        case .normalCallbackTimedOut,
             .forceRequestAlreadyPending,
             .forceCallbackSuccess,
             .forceCallbackFailure,
             .forceDisconnected,
             .forceUnavailable:
            return SleepUnmountEscalationTransition(
                state: .awaitingNormalAfterForceFailure(forceFailure),
                action: .none
            )
        }
    }
}
