import Foundation

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard condition() else {
        fputs("FAIL: \(message) (\(file):\(line))\n", stderr)
        exit(1)
    }
}

private func disk(_ bsd: String,
                  generation: UInt64 = 1,
                  registryID: UInt64? = nil) -> EjectAndSleepDiskIdentity {
    EjectAndSleepDiskIdentity(
        wholeDiskBSD: bsd,
        physicalGeneration: generation,
        mediaRegistryEntryID: registryID ?? generation
    )
}

@main
private enum EjectAndSleepPolicyTests {
    static func main() {
        testManualDeadlineIsExactlyTenSeconds()
        testAllCleanRequestsSleepExactlyOnce()
        testAllCleanAfterDeadlineDoesNotSleep()
        testPartialFailureKeepsCleanDiskUnmounted()
        testDisconnectIsTerminalAndCannotBecomeClean()
        testTimeoutKeepsPendingAndAcceptsLateCleanWithoutAutoSleep()
        testMixedLateCleanRetainsOtherDiskFailure()
        testLateCleanPresentationPreservesMixedFailureState()
        testLateTerminalPresentationCoversWorkerResumeRace()
        testPendingAttemptBlocksOverlappingRetry()
        testRetrySkipsStagedCleanDiskAndCommitsAllTargetsForWake()
        testPmsetFailureKeepsTargetsUnmountedForExplicitRetry()
        testExactIdentityRejectsReusedBSDCallback()
        testForceOutcomeAcceptsFirstCleanCallbackFromEitherRequest()
        testStagedIdentityInvalidationIsExact()
        testRemountedStagedIdentityIsRetriedAfterInvalidation()
        testBatchFailureStopsEmptyAttempt()
        testArmedAttemptCanStopWithoutRemountAndRetry()
        testTerminalHistoryIsPrunedWhenRetryBegins()
        testOutsideSleepWinsBeforeDestructiveIOCommit()
        testDestructiveIOCommitWinsBoundaryRace()
        testGateDeniedBeforeSubmissionAllowsRetry()
        testDeadlineDeniedBeforeSubmissionAllowsRetry()
        testSleepBoundaryExactlyOnceRaces()
        print("EjectAndSleepPolicyTests: PASS")
    }

    private static func testManualDeadlineIsExactlyTenSeconds() {
        let start: UInt64 = 7_000_000_000
        let deadline = EjectAndSleepDeadline(startedAtNanoseconds: start)

        expect(deadline.remainingNanoseconds(at: start) == 10_000_000_000,
               "manual budget must start at exactly ten seconds")
        expect(!deadline.hasExpired(at: start + 9_999_999_999),
               "one nanosecond before ten seconds must remain active")
        expect(deadline.remainingNanoseconds(at: start + 9_999_999_999) == 1,
               "deadline arithmetic must remain exact")
        expect(deadline.hasExpired(at: start + 10_000_000_000),
               "the attempt must expire at exactly ten seconds")
        expect(deadline.remainingNanoseconds(at: start - 1) == 10_000_000_000,
               "a synthetic backward clock must not underflow")
    }

    private static func testAllCleanRequestsSleepExactlyOnce() {
        var policy = EjectAndSleepPolicy()
        let first = disk("disk2")
        let second = disk("disk8")
        let attempt = policy.beginAttempt(targets: [first, second], nowNanoseconds: 100)!

        expect(policy.evaluate(at: 101, attemptID: attempt) == .wait(remainingNanoseconds: 9_999_999_999),
               "pending disks must wait within the deadline")
        expect(policy.record(.clean(.normal), for: first, attemptID: attempt),
               "first clean callback must update its disk")
        expect(policy.record(.clean(.normal), for: second, attemptID: attempt),
               "second clean callback must update its disk")
        expect(policy.evaluate(at: 102, attemptID: attempt) == .requestSleep(wakeTargets: [first, second]),
               "all clean disks must request sleep with staged wake identities")
        expect(policy.evaluate(at: 103, attemptID: attempt) == .noAction,
               "one attempt must never request sleep twice")
    }

    private static func testAllCleanAfterDeadlineDoesNotSleep() {
        var policy = EjectAndSleepPolicy()
        let target = disk("disk2-late")
        let attempt = policy.beginAttempt(targets: [target], nowNanoseconds: 100)!
        _ = policy.record(.clean(.normal), for: target, attemptID: attempt)

        guard case let .doNotSleep(reason, outcomes) = policy.evaluate(
            at: 10_000_000_100,
            attemptID: attempt
        ) else {
            expect(false, "clean evidence evaluated at the hard deadline must not start sleep")
            return
        }
        expect(reason == .deadlineExpired,
               "the exact ten-second boundary must win over a late all-clean state")
        expect(outcomes[target] == .cleanNormal,
               "late clean evidence must still remain staged without being remounted")
        expect(policy.stagedCleanIdentities == [target],
               "deadline cancellation must keep the clean disk unmounted for explicit retry")
    }

    private static func testPartialFailureKeepsCleanDiskUnmounted() {
        var policy = EjectAndSleepPolicy()
        let clean = disk("disk3")
        let failed = disk("disk4")
        let attempt = policy.beginAttempt(targets: [clean, failed], nowNanoseconds: 0)!

        _ = policy.record(.clean(.normal), for: clean, attemptID: attempt)
        _ = policy.record(.failed(EjectAndSleepFailure(.permissionDenied)),
                          for: failed,
                          attemptID: attempt)
        let decision = policy.evaluate(at: 1, attemptID: attempt)

        guard case let .doNotSleep(reason, outcomes) = decision else {
            expect(false, "a terminal partial failure must cancel DiskOUT's sleep request")
            return
        }
        expect(reason == .terminalFailure, "an explicit failure must be reported precisely")
        expect(outcomes[clean] == .cleanNormal, "the clean disk result must be retained")
        expect(policy.stagedCleanIdentities == [clean],
               "a clean disk must stay staged and unmounted, not be remounted after failure")
    }

    private static func testDisconnectIsTerminalAndCannotBecomeClean() {
        var policy = EjectAndSleepPolicy()
        let target = disk("disk5")
        let attempt = policy.beginAttempt(targets: [target], nowNanoseconds: 0)!

        expect(policy.record(.disconnected, for: target, attemptID: attempt),
               "disconnect must record missing clean proof")
        expect(!policy.record(.clean(.normal), for: target, attemptID: attempt),
               "a late callback must not overwrite disconnect evidence")
        expect(policy.outcomes(for: attempt)?[target] == .disconnectedWithoutCleanProof,
               "disconnect must remain a distinct typed outcome")
        expect(policy.stagedCleanIdentities.isEmpty,
               "disconnect without callback must never stage a wake remount identity")
    }

    private static func testTimeoutKeepsPendingAndAcceptsLateCleanWithoutAutoSleep() {
        var policy = EjectAndSleepPolicy()
        let target = disk("disk6")
        let attempt = policy.beginAttempt(targets: [target], nowNanoseconds: 1_000)!

        let deadlineDecision = policy.evaluate(at: 10_000_001_000, attemptID: attempt)
        guard case let .doNotSleep(reason, outcomes) = deadlineDecision else {
            expect(false, "ten-second timeout must decline sleep")
            return
        }
        expect(reason == .deadlineExpired, "timeout must retain its own reason")
        expect(outcomes[target] == .timedOutPending(.normal),
               "timeout must not invent terminal failure or cancellation")
        expect(policy.hasUnresolvedPendingRequest,
               "the underlying DA request must remain pending after waiter timeout")

        expect(policy.record(.clean(.normal), for: target, attemptID: attempt),
               "late explicit clean evidence must still be accepted")
        expect(policy.stagedCleanIdentities == [target],
               "late-clean disk must remain unmounted for a user retry")
        expect(policy.evaluate(at: 20_000_001_000, attemptID: attempt) == .noAction,
               "late clean evidence must never auto-start sleep")
    }

    private static func testMixedLateCleanRetainsOtherDiskFailure() {
        var policy = EjectAndSleepPolicy()
        let pending = disk("disk6-pending")
        let failed = disk("disk6-failed")
        let attempt = policy.beginAttempt(targets: [pending, failed], nowNanoseconds: 0)!

        _ = policy.record(.failed(EjectAndSleepFailure(.permissionDenied)),
                          for: failed,
                          attemptID: attempt)
        guard case let .doNotSleep(_, deadlineOutcomes) = policy.evaluate(
            at: EjectAndSleepDeadline.manualBudgetNanoseconds,
            attemptID: attempt
        ) else {
            expect(false, "the mixed pending/failure attempt must stop at the deadline")
            return
        }
        expect(deadlineOutcomes[pending] == .timedOutPending(.normal),
               "the unresolved sibling must remain explicitly pending")
        expect(deadlineOutcomes[failed] == .failed(EjectAndSleepFailure(.permissionDenied)),
               "the terminal sibling failure must remain typed")

        expect(policy.record(.clean(.normal), for: pending, attemptID: attempt),
               "late clean evidence must still stage its own disk")
        let finalOutcomes = policy.outcomes(for: attempt)!
        expect(finalOutcomes[pending] == .cleanNormal,
               "the late-clean disk must become clean")
        expect(finalOutcomes[failed] == .failed(EjectAndSleepFailure(.permissionDenied)),
               "a sibling late success must not erase the terminal failure")
        expect(!finalOutcomes.values.allSatisfy(\.isClean),
               "aggregate presentation must not become successful while another disk failed")
    }

    private static func testLateCleanPresentationPreservesMixedFailureState() {
        expect(
            EjectAndSleepLateCleanPresentation(
                allOutcomesClean: true,
                hasPending: false,
                hasTerminalFailure: false
            ) == .allOutcomesClean,
            "late clean may use success presentation only when every outcome is clean"
        )
        expect(
            EjectAndSleepLateCleanPresentation(
                allOutcomesClean: false,
                hasPending: false,
                hasTerminalFailure: true
            ) == .otherOutcomeStillUnsafe(hasPending: false, hasTerminalFailure: true),
            "late clean must retain failure presentation while another disk is unsafe"
        )
        expect(
            EjectAndSleepLateCleanPresentation(
                allOutcomesClean: false,
                hasPending: true,
                hasTerminalFailure: true
            ) == .otherOutcomeStillUnsafe(hasPending: true, hasTerminalFailure: true),
            "late clean must preserve both pending and terminal sibling guidance"
        )
    }

    private static func testLateTerminalPresentationCoversWorkerResumeRace() {
        expect(
            EjectAndSleepLateTerminalPresentationPolicy.shouldPresent(
                batchHasReturned: true,
                hasTerminalRecord: true
            ),
            "a terminal callback recorded after the bounded batch return needs a follow-up"
        )
        expect(
            !EjectAndSleepLateTerminalPresentationPolicy.shouldPresent(
                batchHasReturned: false,
                hasTerminalRecord: true
            ),
            "an on-time worker result must stay in the aggregate notification"
        )
        expect(
            !EjectAndSleepLateTerminalPresentationPolicy.shouldPresent(
                batchHasReturned: true,
                hasTerminalRecord: false
            ),
            "a still-pending DA request must wait for its actual terminal observer"
        )
    }

    private static func testPendingAttemptBlocksOverlappingRetry() {
        var policy = EjectAndSleepPolicy()
        let target = disk("disk7")
        let attempt = policy.beginAttempt(targets: [target], nowNanoseconds: 0)!
        _ = policy.evaluate(at: 10_000_000_000, attemptID: attempt)

        expect(policy.beginAttempt(targets: [target], nowNanoseconds: 11_000_000_000) == nil,
               "a timed-out underlying request must block an overlapping retry")
        _ = policy.record(.failed(EjectAndSleepFailure(.busy)), for: target, attemptID: attempt)
        expect(!policy.hasUnresolvedPendingRequest,
               "a late terminal callback must release the retry barrier")
        expect(policy.beginAttempt(targets: [target], nowNanoseconds: 12_000_000_000) != nil,
               "retry may start only after the old request becomes terminal")
    }

    private static func testRetrySkipsStagedCleanDiskAndCommitsAllTargetsForWake() {
        var policy = EjectAndSleepPolicy()
        let first = disk("disk8")
        let second = disk("disk9")
        let initial = policy.beginAttempt(targets: [first, second], nowNanoseconds: 0)!

        _ = policy.record(.clean(.normal), for: first, attemptID: initial)
        _ = policy.record(.failed(EjectAndSleepFailure(.busy)), for: second, attemptID: initial)
        _ = policy.evaluate(at: 1, attemptID: initial)

        let retry = policy.beginAttempt(targets: [first, second], nowNanoseconds: 2)!
        expect(policy.outcomes(for: retry).map { Set($0.keys) } == Set([second]),
               "retry must not re-eject a disk that is already clean and unmounted")
        _ = policy.record(.clean(.normal), for: second, attemptID: retry)
        expect(policy.evaluate(at: 3, attemptID: retry) == .requestSleep(wakeTargets: [first, second]),
               "successful retry must include both old and new staged targets")

        let result = policy.finishSleepRequest(succeeded: true, attemptID: retry)
        expect(result == .commitForWake([first, second]),
               "pmset success must commit all staged identities for wake")
        expect(policy.stagedCleanIdentities.isEmpty,
               "committed identities must leave transient staging")
    }

    private static func testPmsetFailureKeepsTargetsUnmountedForExplicitRetry() {
        var policy = EjectAndSleepPolicy()
        let target = disk("disk10")
        let first = policy.beginAttempt(targets: [target], nowNanoseconds: 0)!
        _ = policy.record(.clean(.normal), for: target, attemptID: first)
        _ = policy.evaluate(at: 1, attemptID: first)

        expect(policy.finishSleepRequest(succeeded: false, attemptID: first) == .keepUnmounted([target]),
               "pmset failure must issue no automatic remount")
        expect(policy.stagedCleanIdentities == [target],
               "pmset failure must retain the clean disk for explicit retry")

        let retry = policy.beginAttempt(targets: [target], nowNanoseconds: 2)!
        expect(policy.outcomes(for: retry)?.isEmpty == true,
               "sleep-only retry must not submit another eject for the staged disk")
        expect(policy.evaluate(at: 3, attemptID: retry) == .requestSleep(wakeTargets: [target]),
               "explicit retry may request sleep using the retained staged identity")
        expect(policy.finishSleepRequest(succeeded: true, attemptID: retry) == .commitForWake([target]),
               "successful explicit retry must finally commit the wake target")
    }

    private static func testExactIdentityRejectsReusedBSDCallback() {
        var policy = EjectAndSleepPolicy()
        let original = disk("disk11", generation: 1, registryID: 100)
        let replacement = disk("disk11", generation: 2, registryID: 200)
        let attempt = policy.beginAttempt(targets: [original], nowNanoseconds: 0)!

        expect(!policy.record(.clean(.normal), for: replacement, attemptID: attempt),
               "same BSD from another physical generation must not satisfy the old request")
        expect(policy.outcomes(for: attempt)?[original] == .normalPending,
               "the original request must remain pending without matching evidence")
        expect(policy.stagedCleanIdentities.isEmpty,
               "replacement media must never enter the old attempt's staging set")
    }

    private static func testForceOutcomeAcceptsFirstCleanCallbackFromEitherRequest() {
        var policy = EjectAndSleepPolicy()
        let target = disk("disk12")
        let attempt = policy.beginAttempt(targets: [target], nowNanoseconds: 0)!

        expect(policy.record(.forceStarted, for: target, attemptID: attempt),
               "busy-authorized force submission must have a typed pending state")
        expect(policy.outcomes(for: attempt)?[target] == .forcePending,
               "force pending must remain distinct from normal pending")
        expect(policy.record(.clean(.normal), for: target, attemptID: attempt),
               "the overlapping normal request may still provide the first clean callback")
        expect(policy.outcomes(for: attempt)?[target] == .cleanNormal,
               "the winning normal callback must remain visible for explanation")
        expect(!policy.record(.clean(.force), for: target, attemptID: attempt),
               "a later force callback must not complete the same disk twice")

        var timedOutPolicy = EjectAndSleepPolicy()
        let timedOutTarget = disk("disk13")
        let timedOutAttempt = timedOutPolicy.beginAttempt(
            targets: [timedOutTarget],
            nowNanoseconds: 1
        )!
        _ = timedOutPolicy.record(.forceStarted,
                                  for: timedOutTarget,
                                  attemptID: timedOutAttempt)
        timedOutPolicy.expireAttempt(timedOutAttempt)
        expect(timedOutPolicy.record(.clean(.normal),
                                     for: timedOutTarget,
                                     attemptID: timedOutAttempt),
               "a late normal clean must remain valid after the Force waiter timed out")
        expect(timedOutPolicy.outcomes(for: timedOutAttempt)?[timedOutTarget] == .cleanNormal,
               "late normal clean evidence must replace timed-out Force pending state")
    }

    private static func testStagedIdentityInvalidationIsExact() {
        var policy = EjectAndSleepPolicy()
        let old = disk("disk13", generation: 1, registryID: 130)
        let replacement = disk("disk13", generation: 2, registryID: 131)
        let attempt = policy.beginAttempt(targets: [old], nowNanoseconds: 0)!
        _ = policy.record(.clean(.normal), for: old, attemptID: attempt)

        policy.invalidateStagedIdentity(replacement)
        expect(policy.stagedCleanIdentities == [old],
               "invalidating a reused BSD identity must not discard the old generation")
        policy.invalidateStagedIdentity(old)
        expect(policy.stagedCleanIdentities.isEmpty,
               "authoritative invalidation must remove the exact staged identity")
    }

    private static func testSleepBoundaryExactlyOnceRaces() {
        var failureFirst = EjectAndSleepBoundaryState()
        expect(failureFirst.arm(nonce: 1), "the first sleep request must arm")
        expect(!failureFirst.beginSleepCommand(nonce: 2),
               "a stale worker must not start another request")
        expect(failureFirst.beginSleepCommand(nonce: 1),
               "the matching worker may start the command once")
        expect(!failureFirst.beginSleepCommand(nonce: 1),
               "the same command must not start twice")
        expect(failureFirst.commandFailed(nonce: 2) == .noAction,
               "a stale pmset result must not disarm another request")
        expect(failureFirst.commandFailed(nonce: 1) == .keepUnmounted(nonce: 1),
               "pmset failure before WillSleep must retain staged disks without remount")
        expect(failureFirst.commandFailed(nonce: 1) == .noAction,
               "duplicate command failure must be exactly once")

        var boundaryFirst = EjectAndSleepBoundaryState()
        expect(boundaryFirst.arm(nonce: 3), "a new request must arm")
        expect(boundaryFirst.beginSleepCommand(nonce: 3),
               "the request must record command launch before waiting for WillSleep")
        expect(boundaryFirst.observeSleepBoundary(), "WillSleep must mark the real boundary")
        expect(boundaryFirst.commandFailed(nonce: 3) == .noAction,
               "late pmset failure after WillSleep must not undo real sleep")
        expect(boundaryFirst.systemDidWake() == .commitForWake(nonce: 3),
               "only wake after WillSleep may commit wake-remount targets")
        expect(boundaryFirst.systemDidWake() == .noAction,
               "duplicate wake must not commit twice")

        var boundaryBeforeWorker = EjectAndSleepBoundaryState()
        expect(boundaryBeforeWorker.arm(nonce: 4), "queued request must arm")
        expect(boundaryBeforeWorker.observeSleepBoundary(),
               "an already-starting system sleep must win the boundary")
        expect(!boundaryBeforeWorker.beginSleepCommand(nonce: 4),
               "a queued pmset worker must not launch after WillSleep")
        expect(boundaryBeforeWorker.systemDidWake() == .commitForWake(nonce: 4),
               "the real boundary still completes the user's already-clean transaction")
    }

    private static func testRemountedStagedIdentityIsRetriedAfterInvalidation() {
        var policy = EjectAndSleepPolicy()
        let target = disk("disk14", generation: 4, registryID: 140)
        let first = policy.beginAttempt(targets: [target], nowNanoseconds: 0)!
        _ = policy.record(.clean(.normal), for: target, attemptID: first)
        _ = policy.evaluate(at: 1, attemptID: first)
        _ = policy.finishSleepRequest(succeeded: false, attemptID: first)

        policy.invalidateStagedIdentity(target)
        let retry = policy.beginAttempt(targets: [target], nowNanoseconds: 2)!
        expect(policy.outcomes(for: retry)?[target] == .normalPending,
               "an exact staged disk that is mounted again must be unmounted on retry")
    }

    private static func testBatchFailureStopsEmptyAttempt() {
        var policy = EjectAndSleepPolicy()
        let attempt = policy.beginAttempt(targets: [], nowNanoseconds: 0)!
        policy.stopAttempt(attempt)
        expect(policy.evaluate(at: 1, attemptID: attempt) == .noAction,
               "an inventory-level failure must prevent an empty attempt from requesting sleep")
        expect(policy.canBeginAttempt,
               "a stopped batch-level failure must allow a later explicit retry")
    }

    private static func testArmedAttemptCanStopWithoutRemountAndRetry() {
        var policy = EjectAndSleepPolicy()
        let target = disk("disk15")
        let attempt = policy.beginAttempt(targets: [target], nowNanoseconds: 0)!
        _ = policy.record(.clean(.normal), for: target, attemptID: attempt)
        expect(policy.evaluate(at: 1, attemptID: attempt) == .requestSleep(wakeTargets: [target]),
               "clean attempt must enter the sleep-request boundary")

        policy.stopAttempt(attempt)
        expect(policy.canBeginAttempt,
               "a boundary failure before pmset must not permanently block explicit retry")
        expect(policy.stagedCleanIdentities == [target],
               "stopping an armed attempt must not remount or discard its clean target")
        let retry = policy.beginAttempt(targets: [], nowNanoseconds: 2)
        expect(retry != nil,
               "explicit retry must be available after an arm/state failure")
    }

    private static func testTerminalHistoryIsPrunedWhenRetryBegins() {
        var policy = EjectAndSleepPolicy()
        let target = disk("disk16")
        let first = policy.beginAttempt(targets: [target], nowNanoseconds: 0)!
        _ = policy.record(.failed(EjectAndSleepFailure(.busy)),
                          for: target,
                          attemptID: first)
        _ = policy.evaluate(at: 1, attemptID: first)

        let retry = policy.beginAttempt(targets: [target], nowNanoseconds: 2)!
        expect(policy.outcomes(for: first) == nil,
               "terminal attempt history must not accumulate for the process lifetime")
        expect(policy.outcomes(for: retry)?[target] == .normalPending,
               "history pruning must preserve the new retry state")
    }

    private static func testOutsideSleepWinsBeforeDestructiveIOCommit() {
        var gate = EjectAndSleepUnmountGate()
        expect(gate.reserve(), "a new manual operation must enter preparation")
        expect(gate.observeOutsideSleepBoundary(),
               "an outside sleep during preparation must cancel destructive work")
        expect(gate.shouldAbortBeforeDestructiveIO,
               "the worker must observe that pre-unmount cancellation")
        expect(!gate.authorizeDestructiveIO(),
               "wake must not let a canceled worker submit a late unmount")
        gate.reset()
        expect(gate.reserve(), "cleanup must permit an explicit retry")
    }

    private static func testDestructiveIOCommitWinsBoundaryRace() {
        var gate = EjectAndSleepUnmountGate()
        expect(gate.reserve(), "a new manual operation must enter preparation")
        expect(gate.authorizeDestructiveIO(),
               "the worker may atomically commit its first unmount batch")
        expect(gate.authorizeDestructiveIO(),
               "sibling requests may submit while no sleep boundary has intervened")
        expect(!gate.observeOutsideSleepBoundary(),
               "a later boundary must not pretend committed DA work was canceled")
        expect(!gate.shouldAbortBeforeDestructiveIO,
               "committed DA callbacks must be allowed to reach terminal evidence")
        expect(!gate.authorizeDestructiveIO(),
               "a sibling or Force request must not start after the outside sleep boundary")
    }

    private static func testGateDeniedBeforeSubmissionAllowsRetry() {
        var gate = EjectAndSleepUnmountGate()
        var policy = EjectAndSleepPolicy()
        let target = disk("disk17")
        let attempt = policy.beginAttempt(targets: [target], nowNanoseconds: 0)!

        expect(gate.reserve(), "the manual worker must reserve preparation")
        expect(gate.observeOutsideSleepBoundary(), "the outside boundary must win the gate")
        if !gate.authorizeDestructiveIO() {
            _ = policy.record(.failed(EjectAndSleepFailure(.unavailable)),
                              for: target,
                              attemptID: attempt)
        }
        guard case .doNotSleep = policy.evaluate(at: 1, attemptID: attempt) else {
            expect(false, "a denied submission must terminate without requesting sleep")
            return
        }
        expect(!policy.hasUnresolvedPendingRequest,
               "a request that was never submitted must not remain pending")
        expect(policy.beginAttempt(targets: [target], nowNanoseconds: 2) != nil,
               "outside-sleep cancellation before submission must allow explicit retry")
    }

    private static func testDeadlineDeniedBeforeSubmissionAllowsRetry() {
        var policy = EjectAndSleepPolicy()
        let target = disk("disk18")
        let attempt = policy.beginAttempt(targets: [target], nowNanoseconds: 0)!

        _ = policy.record(.failed(EjectAndSleepFailure(.unavailable)),
                          for: target,
                          attemptID: attempt)
        guard case .doNotSleep = policy.evaluate(
            at: EjectAndSleepDeadline.manualBudgetNanoseconds,
            attemptID: attempt
        ) else {
            expect(false, "a deadline-denied submission must not request sleep")
            return
        }
        expect(!policy.hasUnresolvedPendingRequest,
               "deadline denial before DA submission must not invent a pending callback")
        expect(policy.beginAttempt(
            targets: [target],
            nowNanoseconds: EjectAndSleepDeadline.manualBudgetNanoseconds + 1
        ) != nil, "deadline denial before submission must allow explicit retry")
    }
}
