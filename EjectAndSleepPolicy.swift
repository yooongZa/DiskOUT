import Foundation

/// Stable physical-media identity used by the manual Eject and Sleep transaction.
/// A BSD name alone is insufficient because macOS may reuse it after reconnect.
struct EjectAndSleepDiskIdentity: Hashable, Sendable, Comparable {
    let wholeDiskBSD: String
    let physicalGeneration: UInt64
    let mediaRegistryEntryID: UInt64

    static func < (lhs: EjectAndSleepDiskIdentity,
                   rhs: EjectAndSleepDiskIdentity) -> Bool {
        if lhs.wholeDiskBSD != rhs.wholeDiskBSD {
            return lhs.wholeDiskBSD < rhs.wholeDiskBSD
        }
        if lhs.physicalGeneration != rhs.physicalGeneration {
            return lhs.physicalGeneration < rhs.physicalGeneration
        }
        return lhs.mediaRegistryEntryID < rhs.mediaRegistryEntryID
    }
}

enum EjectAndSleepUnmountOperation: Equatable, Sendable {
    case normal
    case force
}

struct EjectAndSleepFailure: Equatable, Sendable {
    enum Code: Equatable, Sendable {
        case busy
        case forceDisabled
        case permissionDenied
        case unsupported
        case unavailable
        case identityChanged
        case other
    }

    let code: Code
    /// Diagnostic text is for logs only. User-facing text must be localized by the UI layer.
    let diagnostic: String?

    init(_ code: Code, diagnostic: String? = nil) {
        self.code = code
        self.diagnostic = diagnostic
    }
}

/// Per-physical-disk result. Pending-after-timeout remains non-terminal because the underlying
/// Disk Arbitration request may still deliver explicit clean evidence later.
enum EjectAndSleepDiskOutcome: Equatable, Sendable {
    case normalPending
    case forcePending
    case timedOutPending(EjectAndSleepUnmountOperation)
    case cleanNormal
    case cleanForced
    case failed(EjectAndSleepFailure)
    case disconnectedWithoutCleanProof

    var isClean: Bool {
        switch self {
        case .cleanNormal, .cleanForced:
            return true
        default:
            return false
        }
    }

    var isPending: Bool {
        switch self {
        case .normalPending, .forcePending, .timedOutPending:
            return true
        default:
            return false
        }
    }
}

enum EjectAndSleepDiskEvent: Equatable, Sendable {
    case forceStarted
    case clean(EjectAndSleepUnmountOperation)
    case failed(EjectAndSleepFailure)
    case disconnected
}

enum EjectAndSleepStopReason: Equatable, Sendable {
    case deadlineExpired
    case terminalFailure
}

enum EjectAndSleepLateCleanPresentation: Equatable, Sendable {
    case allOutcomesClean
    case otherOutcomeStillUnsafe(hasPending: Bool, hasTerminalFailure: Bool)

    init(allOutcomesClean: Bool,
         hasPending: Bool,
         hasTerminalFailure: Bool) {
        self = allOutcomesClean
            ? .allOutcomesClean
            : .otherOutcomeStillUnsafe(
                hasPending: hasPending,
                hasTerminalFailure: hasTerminalFailure
            )
    }
}

enum EjectAndSleepLateTerminalPresentationPolicy {
    /// A DA callback can finish before the deadline while its worker resumes after the bounded
    /// batch has already returned. That terminal result needs one follow-up presentation.
    static func shouldPresent(batchHasReturned: Bool,
                              hasTerminalRecord: Bool) -> Bool {
        batchHasReturned && hasTerminalRecord
    }
}

/// `requestSleep` is emitted at most once per explicit user attempt. It is not a successful
/// transaction until the caller reports that the pmset request itself succeeded.
enum EjectAndSleepDecision: Equatable, Sendable {
    case wait(remainingNanoseconds: UInt64)
    case doNotSleep(reason: EjectAndSleepStopReason,
                    outcomes: [EjectAndSleepDiskIdentity: EjectAndSleepDiskOutcome])
    case requestSleep(wakeTargets: Set<EjectAndSleepDiskIdentity>)
    case noAction
}

enum EjectAndSleepRequestResult: Equatable, Sendable {
    /// The caller may now commit these identities to its wake-remount ledger.
    case commitForWake(Set<EjectAndSleepDiskIdentity>)
    /// No remount is requested. The clean disks stay unmounted for a later explicit retry.
    case keepUnmounted(Set<EjectAndSleepDiskIdentity>)
}

struct EjectAndSleepAttemptID: Hashable, Sendable {
    fileprivate let rawValue: UInt64
}

enum EjectAndSleepBoundaryResolution: Equatable, Sendable {
    case noAction
    case keepUnmounted(nonce: UInt64)
    case commitForWake(nonce: UInt64)
}

/// Exactly-once policy for the pmset process result and IOKit/NSWorkspace sleep boundaries.
/// A late command failure cannot undo an already-observed sleep transition.
struct EjectAndSleepBoundaryState: Equatable, Sendable {
    private enum Phase: Equatable, Sendable {
        case awaitingCommand
        case commandStarted
        case sleepBoundaryObserved
    }

    private var nonce: UInt64?
    private var phase: Phase?

    var isArmed: Bool { nonce != nil }

    mutating func arm(nonce: UInt64) -> Bool {
        guard nonce != 0, self.nonce == nil else { return false }
        self.nonce = nonce
        phase = .awaitingCommand
        return true
    }

    /// Prevents a queued pmset worker from launching after another sleep boundary already won.
    mutating func beginSleepCommand(nonce expectedNonce: UInt64) -> Bool {
        guard nonce == expectedNonce, phase == .awaitingCommand else { return false }
        phase = .commandStarted
        return true
    }

    /// Idempotently consumes matching will-sleep notifications.
    mutating func observeSleepBoundary() -> Bool {
        guard nonce != nil else { return false }
        phase = .sleepBoundaryObserved
        return true
    }

    /// A pmset failure/timeout wins only before WillSleep. Once the boundary is observed, the
    /// process result may simply be late because execution was suspended for real sleep.
    mutating func commandFailed(nonce expectedNonce: UInt64) -> EjectAndSleepBoundaryResolution {
        guard nonce == expectedNonce else { return .noAction }
        guard phase != .sleepBoundaryObserved else { return .noAction }
        clear()
        return .keepUnmounted(nonce: expectedNonce)
    }

    mutating func systemDidWake() -> EjectAndSleepBoundaryResolution {
        guard let nonce, phase == .sleepBoundaryObserved else { return .noAction }
        clear()
        return .commitForWake(nonce: nonce)
    }

    private mutating func clear() {
        nonce = nil
        phase = nil
    }
}

/// Serializes an outside sleep boundary with destructive Disk Arbitration submissions. Preparation
/// stays cancelable; submitted requests retain their callbacks, while the boundary closes the gate
/// before any not-yet-submitted sibling or Force request can start.
struct EjectAndSleepUnmountGate: Equatable, Sendable {
    private enum Phase: Equatable, Sendable {
        case preparing
        case destructiveIOStarted
        case abortedBeforeDestructiveIO
        case outsideSleepObservedAfterDestructiveIO
    }

    private var phase: Phase?

    mutating func reserve() -> Bool {
        guard phase == nil else { return false }
        phase = .preparing
        return true
    }

    /// Authorizes submissions only while no outside sleep boundary has intervened. The caller must
    /// serialize this transition with the actual submission call.
    mutating func authorizeDestructiveIO() -> Bool {
        switch phase {
        case .preparing:
            phase = .destructiveIOStarted
            return true
        case .destructiveIOStarted:
            return true
        case .abortedBeforeDestructiveIO,
             .outsideSleepObservedAfterDestructiveIO,
             nil:
            return false
        }
    }

    /// Returns true only when the outside boundary canceled work before any unmount submission.
    @discardableResult
    mutating func observeOutsideSleepBoundary() -> Bool {
        switch phase {
        case .preparing:
            phase = .abortedBeforeDestructiveIO
            return true
        case .destructiveIOStarted:
            // Already-submitted requests keep their callbacks, but no sibling or Force request may
            // start after this boundary (including after wake).
            phase = .outsideSleepObservedAfterDestructiveIO
            return false
        case .abortedBeforeDestructiveIO,
             .outsideSleepObservedAfterDestructiveIO,
             nil:
            return false
        }
    }

    var shouldAbortBeforeDestructiveIO: Bool {
        phase == .abortedBeforeDestructiveIO
    }

    mutating func reset() {
        phase = nil
    }
}

/// A deterministic deadline fed by a monotonic timestamp such as
/// `DispatchTime.now().uptimeNanoseconds`. Tests can supply exact integer timestamps.
struct EjectAndSleepDeadline: Equatable, Sendable {
    static let manualBudgetNanoseconds: UInt64 = 10_000_000_000

    let startedAtNanoseconds: UInt64
    let budgetNanoseconds: UInt64

    init(startedAtNanoseconds: UInt64,
         budgetNanoseconds: UInt64 = EjectAndSleepDeadline.manualBudgetNanoseconds) {
        self.startedAtNanoseconds = startedAtNanoseconds
        self.budgetNanoseconds = budgetNanoseconds
    }

    func remainingNanoseconds(at nowNanoseconds: UInt64) -> UInt64 {
        // A monotonic clock must not move backwards. Fail predictably if a synthetic/test clock
        // does: treat no time as elapsed instead of underflowing UInt64.
        let elapsed = nowNanoseconds >= startedAtNanoseconds
            ? nowNanoseconds - startedAtNanoseconds
            : 0
        return elapsed >= budgetNanoseconds ? 0 : budgetNanoseconds - elapsed
    }

    func hasExpired(at nowNanoseconds: UInt64) -> Bool {
        remainingNanoseconds(at: nowNanoseconds) == 0
    }
}

/// Pure state machine for manual Eject and Sleep. It deliberately does not expose a remount
/// action: clean identities remain staged until a later explicit sleep request succeeds.
struct EjectAndSleepPolicy: Sendable {
    private enum AttemptPhase: Sendable {
        case active
        case stopped
        case awaitingSleepResult
        case completed
    }

    private struct Attempt: Sendable {
        let deadline: EjectAndSleepDeadline
        var outcomes: [EjectAndSleepDiskIdentity: EjectAndSleepDiskOutcome]
        var phase: AttemptPhase
    }

    private var nextAttemptRawValue: UInt64 = 0
    private var currentAttemptID: EjectAndSleepAttemptID?
    private var attempts: [EjectAndSleepAttemptID: Attempt] = [:]

    private(set) var stagedCleanIdentities = Set<EjectAndSleepDiskIdentity>()

    /// A retry is rejected while any prior DA request remains pending, preventing an overlapping
    /// normal/force request against the same physical disk.
    var hasUnresolvedPendingRequest: Bool {
        attempts.values.contains { attempt in
            attempt.outcomes.values.contains(where: \.isPending)
        }
    }

    var canBeginAttempt: Bool {
        guard !hasUnresolvedPendingRequest else { return false }
        guard let currentAttemptID, let attempt = attempts[currentAttemptID] else { return true }
        switch attempt.phase {
        case .active, .awaitingSleepResult:
            return false
        case .stopped, .completed:
            return true
        }
    }

    /// Starts one explicit user attempt. Already-clean identities are excluded so a retry only
    /// submits requests for disks that still need work. An empty target set is valid: it retries
    /// pmset after an earlier pmset failure without remounting or re-ejecting any disk.
    mutating func beginAttempt(targets: Set<EjectAndSleepDiskIdentity>,
                               nowNanoseconds: UInt64) -> EjectAndSleepAttemptID? {
        guard canBeginAttempt else { return nil }

        // canBeginAttempt proves that no DA callback is unresolved. Historical terminal attempts
        // no longer participate in safety decisions, so retaining them would only grow process-
        // lifetime state and make every pending check more expensive.
        attempts.removeAll(keepingCapacity: true)
        currentAttemptID = nil

        nextAttemptRawValue &+= 1
        if nextAttemptRawValue == 0 { nextAttemptRawValue = 1 }
        let id = EjectAndSleepAttemptID(rawValue: nextAttemptRawValue)
        let unresolvedTargets = targets.subtracting(stagedCleanIdentities)
        let outcomes: [EjectAndSleepDiskIdentity: EjectAndSleepDiskOutcome] =
            Dictionary(uniqueKeysWithValues: unresolvedTargets.map { ($0, .normalPending) })
        attempts[id] = Attempt(
            deadline: EjectAndSleepDeadline(startedAtNanoseconds: nowNanoseconds),
            outcomes: outcomes,
            phase: .active
        )
        currentAttemptID = id
        return id
    }

    /// Records DA evidence only for an identity captured by that exact attempt. Historical late
    /// evidence may update/stage a disk, but never reactivates a stopped attempt or auto-sleeps.
    @discardableResult
    mutating func record(_ event: EjectAndSleepDiskEvent,
                         for identity: EjectAndSleepDiskIdentity,
                         attemptID: EjectAndSleepAttemptID) -> Bool {
        guard var attempt = attempts[attemptID],
              let current = attempt.outcomes[identity] else {
            return false
        }

        let next = Self.reduce(current, event: event)
        guard next != current else { return false }
        attempt.outcomes[identity] = next
        attempts[attemptID] = attempt
        if next.isClean {
            stagedCleanIdentities.insert(identity)
        }
        return true
    }

    /// Evaluates the active attempt exactly once. Callers may invoke this after each event and at
    /// the deadline; a concluded attempt always returns `noAction`.
    mutating func evaluate(at nowNanoseconds: UInt64,
                           attemptID: EjectAndSleepAttemptID) -> EjectAndSleepDecision {
        guard var attempt = attempts[attemptID], attempt.phase == .active else {
            return .noAction
        }

        // The ten-second budget is a hard boundary. A clean callback that only becomes visible
        // after it has elapsed may still stage the disk, but must never start sleep automatically.
        if attempt.deadline.hasExpired(at: nowNanoseconds) {
            expire(&attempt, attemptID: attemptID)
            return .doNotSleep(reason: .deadlineExpired, outcomes: attempt.outcomes)
        }

        if attempt.outcomes.values.allSatisfy(\.isClean) {
            attempt.phase = .awaitingSleepResult
            attempts[attemptID] = attempt
            return .requestSleep(wakeTargets: stagedCleanIdentities)
        }

        if attempt.outcomes.values.contains(where: Self.isTerminalFailure) {
            attempt.phase = .stopped
            attempts[attemptID] = attempt
            return .doNotSleep(reason: .terminalFailure, outcomes: attempt.outcomes)
        }

        return .wait(remainingNanoseconds: attempt.deadline.remainingNanoseconds(at: nowNanoseconds))
    }

    /// Stops an attempt for a batch-level failure that cannot be attached to one stable identity,
    /// such as an unavailable inventory or an unresolved protected target.
    mutating func stopAttempt(_ attemptID: EjectAndSleepAttemptID) {
        guard var attempt = attempts[attemptID] else { return }
        switch attempt.phase {
        case .active, .awaitingSleepResult:
            attempt.phase = .stopped
            attempts[attemptID] = attempt
        case .stopped, .completed:
            break
        }
    }

    /// Marks every still-running request as timed-out pending before late terminal observers are
    /// installed. This ordering prevents a callback just after ten seconds from auto-sleeping.
    mutating func expireAttempt(_ attemptID: EjectAndSleepAttemptID) {
        guard var attempt = attempts[attemptID], attempt.phase == .active else { return }
        expire(&attempt, attemptID: attemptID)
    }

    /// Completes the pmset boundary. Failure intentionally emits no mount action and retains all
    /// staged identities. Success moves them to the wake ledger result and clears the staging set.
    mutating func finishSleepRequest(succeeded: Bool,
                                     attemptID: EjectAndSleepAttemptID) -> EjectAndSleepRequestResult? {
        guard var attempt = attempts[attemptID], attempt.phase == .awaitingSleepResult else {
            return nil
        }

        if succeeded {
            let targets = stagedCleanIdentities
            stagedCleanIdentities.subtract(targets)
            attempt.phase = .completed
            attempts[attemptID] = attempt
            return .commitForWake(targets)
        }

        attempt.phase = .stopped
        attempts[attemptID] = attempt
        return .keepUnmounted(stagedCleanIdentities)
    }

    /// Call after authoritative inventory proves that staged media was reconnected/replaced.
    /// Exact identity matching prevents a reused BSD name from discarding another generation.
    mutating func invalidateStagedIdentity(_ identity: EjectAndSleepDiskIdentity) {
        stagedCleanIdentities.remove(identity)
    }

    func outcomes(for attemptID: EjectAndSleepAttemptID)
        -> [EjectAndSleepDiskIdentity: EjectAndSleepDiskOutcome]? {
        attempts[attemptID]?.outcomes
    }

    func hasPendingOutcome(for attemptID: EjectAndSleepAttemptID) -> Bool {
        attempts[attemptID]?.outcomes.values.contains(where: \.isPending) == true
    }

    private static func reduce(_ current: EjectAndSleepDiskOutcome,
                               event: EjectAndSleepDiskEvent) -> EjectAndSleepDiskOutcome {
        switch (current, event) {
        case (.normalPending, .forceStarted):
            return .forcePending
        case (.normalPending, .clean(.normal)),
             (.timedOutPending(.normal), .clean(.normal)):
            return .cleanNormal
        case (.forcePending, .clean(.force)),
             (.timedOutPending(.force), .clean(.force)):
            return .cleanForced
        case (.normalPending, let .failed(reason)),
             (.forcePending, let .failed(reason)),
             (.timedOutPending, let .failed(reason)):
            return .failed(reason)
        case (.normalPending, .disconnected),
             (.forcePending, .disconnected),
             (.timedOutPending, .disconnected):
            return .disconnectedWithoutCleanProof
        default:
            // Clean, failure, and disconnect evidence are terminal. Mismatched normal/force
            // callbacks are ignored rather than upgrading an unproven request to clean.
            return current
        }
    }

    private static func isTerminalFailure(_ outcome: EjectAndSleepDiskOutcome) -> Bool {
        switch outcome {
        case .failed, .disconnectedWithoutCleanProof:
            return true
        default:
            return false
        }
    }

    private mutating func expire(_ attempt: inout Attempt,
                                 attemptID: EjectAndSleepAttemptID) {
        for (identity, outcome) in attempt.outcomes {
            switch outcome {
            case .normalPending:
                attempt.outcomes[identity] = .timedOutPending(.normal)
            case .forcePending:
                attempt.outcomes[identity] = .timedOutPending(.force)
            default:
                break
            }
        }
        attempt.phase = .stopped
        attempts[attemptID] = attempt
    }
}
