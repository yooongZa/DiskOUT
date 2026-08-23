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

private final class IntRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func append(_ value: Int?) {
        guard let value else { return }
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@main
private enum SleepUnmountPolicyTests {
    static func main() {
        testTwoVolumesOnOneDiskProduceOneRequest()
        testSeparateDisksRemainSeparateStableGroups()
        testSameBSDWithNewGenerationDoesNotJoinOldMedia()
        testSameBSDAndGenerationWithDifferentMediaIDDoesNotJoin()
        testMissingBSDNameFallsBackToStablePathGrouping()
        testDissenterStatusClassification()
        testPolicyPreservesNormalThenExplicitForceFallback()
        testForceClaimLedgerIsEpisodeScopedAndPhysicalOnly()
        testForceClaimLedgerAllowsOneConcurrentClaimPerPhysicalKey()
        testOnlyExplicitCallbackSuccessIsClean()
        testDisconnectThenLateSuccessRemainsFailure()
        testSuccessThenDisconnectRemainsClean()
        testStickyEvidenceReleasesAllJoinersOnce()
        testTimeoutThenLateEvidenceRemainsObservableAndSticky()
        testHiddenProtectedSiblingBlocksVisibleWholeDiskTarget()
        testRequestTimeSiblingSetRevalidationFailsClosed()
        testMountApprovalBarrierOrdering()
        testEFIMountApprovalTracking()
        testPowerSleepMountBarrierCoversPostSnapshotApproval()
        testForceContinuationReservationsAreWaiterScoped()
        testTimeoutAndCallbackHaveDistinctForceContinuationReleaseOwners()
        testUnresolvedProtectedSiblingFailsClosed()
        print("SleepUnmountPolicyTests: PASS")
    }

    private static func testTwoVolumesOnOneDiskProduceOneRequest() {
        let targets = [
            SleepUnmountTarget(name: "Work", volumePath: "/Volumes/Work", wholeDiskBSD: "disk7", physicalGeneration: 3, mediaRegistryEntryID: 30, mountedVolumeBSDs: ["disk7s1", "disk7s2"]),
            SleepUnmountTarget(name: "Media", volumePath: "/Volumes/Media", wholeDiskBSD: "disk7", physicalGeneration: 3, mediaRegistryEntryID: 30, mountedVolumeBSDs: ["disk7s1", "disk7s2"])
        ]

        let requests = SleepUnmountPolicy.requests(for: targets, forceFallback: false)

        expect(requests.count == 1, "two volumes on one whole disk must produce one request")
        expect(requests[0].key == .physicalDisk(bsd: "disk7", generation: 3, mediaRegistryEntryID: 30), "BSD name, appearance generation, and exact media ID must form the group key")
        expect(!requests[0].allowsForceFallback, "disabled force fallback must remain disabled")
        expect(requests[0].targets.map(\.name) == ["Work", "Media"], "targets must retain input order")
        expect(requests[0].representativeVolumePath == "/Volumes/Work", "the first target must remain representative")
        expect(requests[0].mountedVolumeBSDs == ["disk7s1", "disk7s2"],
               "the authoritative mounted sibling set must propagate to the physical request")
    }

    private static func testSeparateDisksRemainSeparateStableGroups() {
        let targets = [
            SleepUnmountTarget(name: "First-A", volumePath: "/Volumes/First-A", wholeDiskBSD: "disk9", physicalGeneration: 10, mediaRegistryEntryID: 90),
            SleepUnmountTarget(name: "Second", volumePath: "/Volumes/Second", wholeDiskBSD: "disk4", physicalGeneration: 11, mediaRegistryEntryID: 40),
            SleepUnmountTarget(name: "First-B", volumePath: "/Volumes/First-B", wholeDiskBSD: "disk9", physicalGeneration: 10, mediaRegistryEntryID: 90)
        ]

        let requests = SleepUnmountPolicy.requests(for: targets, forceFallback: true)

        expect(requests.count == 2, "separate whole disks must remain separate request groups")
        expect(requests.map(\.key) == [.physicalDisk(bsd: "disk9", generation: 10, mediaRegistryEntryID: 90), .physicalDisk(bsd: "disk4", generation: 11, mediaRegistryEntryID: 40)], "group order must follow first appearance")
        expect(requests[0].targets.map(\.name) == ["First-A", "First-B"], "members of a group must retain input order")
        expect(requests.allSatisfy(\.allowsForceFallback), "force setting must be retained without changing the first normal request")
    }

    private static func testSameBSDWithNewGenerationDoesNotJoinOldMedia() {
        let targets = [
            SleepUnmountTarget(name: "Old", volumePath: "/Volumes/Old", wholeDiskBSD: "disk9", physicalGeneration: 40, mediaRegistryEntryID: 400),
            SleepUnmountTarget(name: "Replacement", volumePath: "/Volumes/New", wholeDiskBSD: "disk9", physicalGeneration: 41, mediaRegistryEntryID: 401)
        ]
        let requests = SleepUnmountPolicy.requests(for: targets, forceFallback: true)

        expect(requests.count == 2, "a reused BSD name from a new physical generation must not join the old media")
        expect(requests.map(\.physicalGeneration) == [40, 41], "each physical generation must remain distinct")
    }

    private static func testSameBSDAndGenerationWithDifferentMediaIDDoesNotJoin() {
        let targets = [
            SleepUnmountTarget(name: "Old", volumePath: "/Volumes/Old", wholeDiskBSD: "disk9", physicalGeneration: 50, mediaRegistryEntryID: 500),
            SleepUnmountTarget(name: "Replacement", volumePath: "/Volumes/New", wholeDiskBSD: "disk9", physicalGeneration: 50, mediaRegistryEntryID: 501)
        ]

        let requests = SleepUnmountPolicy.requests(for: targets, forceFallback: true)
        expect(requests.count == 2, "different exact IOMedia IDs must never share an unmount request")
    }

    private static func testMissingBSDNameFallsBackToStablePathGrouping() {
        let targets = [
            SleepUnmountTarget(name: "No-BSD-A", volumePath: "/Volumes/Unknown", wholeDiskBSD: nil, physicalGeneration: nil, mediaRegistryEntryID: nil),
            SleepUnmountTarget(name: "No-BSD-A-Duplicate", volumePath: "/Volumes/Unknown", wholeDiskBSD: nil, physicalGeneration: nil, mediaRegistryEntryID: nil),
            SleepUnmountTarget(name: "No-BSD-B", volumePath: "/Volumes/Other", wholeDiskBSD: nil, physicalGeneration: nil, mediaRegistryEntryID: nil),
            SleepUnmountTarget(name: "Empty-BSD", volumePath: "/Volumes/Empty", wholeDiskBSD: "", physicalGeneration: nil, mediaRegistryEntryID: nil)
        ]

        let requests = SleepUnmountPolicy.requests(for: targets, forceFallback: false)

        expect(requests.count == 3, "missing or empty BSD names must dedupe only by matching volume path")
        expect(
            requests.map(\.key) == [
                .unresolvedVolumePath("/Volumes/Unknown"),
                .unresolvedVolumePath("/Volumes/Other"),
                .unresolvedVolumePath("/Volumes/Empty")
            ],
            "path fallback groups must retain first-seen order"
        )
        expect(requests[0].targets.count == 2, "identical fallback paths must share one request")
        expect(requests.allSatisfy { $0.wholeDiskBSD == nil }, "path-keyed requests must not invent a BSD name")
    }

    private static func testPolicyPreservesNormalThenExplicitForceFallback() {
        let target = SleepUnmountTarget(name: "SSD", volumePath: "/Volumes/SSD", wholeDiskBSD: "disk12", physicalGeneration: 7, mediaRegistryEntryID: 120)
        let normalRequests = SleepUnmountPolicy.requests(for: [target], forceFallback: false)
        let forceRequests = SleepUnmountPolicy.requests(for: [target], forceFallback: true)

        expect(normalRequests.count == 1, "normal policy must emit exactly one request")
        expect(!normalRequests[0].allowsForceFallback, "normal policy must not enable a force retry")
        expect(forceRequests.count == 1, "force setting must still emit one initial request")
        expect(forceRequests[0].allowsForceFallback, "force setting must permit a later force retry")
        expect(SleepUnmountPolicy.nextOperation(after: .callbackFailure(.busy), forceFallback: true) == .wholeForce,
               "kDAReturnBusy may start the force retry")
        expect(SleepUnmountPolicy.nextOperation(after: .callbackFailure(.exclusiveAccess), forceFallback: true) == .wholeForce,
               "kDAReturnExclusiveAccess may start the force retry")
        expect(SleepUnmountPolicy.nextOperation(after: .callbackFailure(.unixBusy), forceFallback: true) == .wholeForce,
               "unix_err(EBUSY) may start the force retry")
        expect(SleepUnmountPolicy.nextOperation(after: .callbackFailure(.other(0xF8DA0001)), forceFallback: true) == nil,
               "a non-contention DA failure must not start a force retry")
        expect(SleepUnmountPolicy.nextOperation(after: .callbackFailure(.other(0xC005)), forceFallback: true) == nil,
               "a non-EBUSY Unix failure must not start a force retry")
        expect(SleepUnmountPolicy.nextOperation(after: .timeout, forceFallback: true) == nil,
               "timeout must never overlap the still-pending normal request")
        expect(SleepUnmountPolicy.nextOperation(after: .disconnect, forceFallback: true) == nil,
               "disconnect must never start a fallback")
        expect(SleepUnmountPolicy.nextOperation(after: .unavailable, forceFallback: true) == nil,
               "unavailable identity must fail closed")
        expect(SleepUnmountPolicy.nextOperation(after: .callbackFailure(.busy), forceFallback: false) == nil,
               "disabled force fallback must remain disabled")
        expect(SleepUnmountPolicy.nextOperation(after: .callbackFailure(.busy),
                                                requestWasForced: true,
                                                forceFallback: true) == nil,
               "a joined force request failure must not be reinterpreted as a normal decline")

        let timedOut = SleepUnmountEvidenceReducer.reduce(.pending, event: .timeout)
        let lateSuccess = SleepUnmountEvidenceReducer.reduce(timedOut, event: .callbackSuccess)
        expect(timedOut == .pendingAfterTimeout, "timeout must keep the underlying request pending")
        expect(lateSuccess == .clean, "a later explicit callback may provide positive clean proof")
    }

    private static func testDissenterStatusClassification() {
        let busy = SleepUnmountDissenterStatus(rawValue: 0xF8DA0002)
        let exclusive = SleepUnmountDissenterStatus(rawValue: 0xF8DA0004)
        let unixBusy = SleepUnmountDissenterStatus(rawValue: 0xC010)
        let unknown = SleepUnmountDissenterStatus(rawValue: 0xDEADBEEF)

        expect(busy == .busy && busy.rawValue == 0xF8DA0002,
               "kDAReturnBusy must round-trip through the typed status")
        expect(exclusive == .exclusiveAccess && exclusive.rawValue == 0xF8DA0004,
               "kDAReturnExclusiveAccess must round-trip through the typed status")
        expect(unixBusy == .unixBusy && unixBusy.rawValue == 0xC010,
               "unix_err(EBUSY) must round-trip through the typed status")
        expect(unknown == .other(0xDEADBEEF) && unknown.rawValue == 0xDEADBEEF,
               "unknown raw statuses must be preserved for diagnostics")
        expect(busy.isForceEligible && exclusive.isForceEligible && unixBusy.isForceEligible,
               "all three contention statuses must be force eligible")
        expect(!unknown.isForceEligible,
               "an unknown status must fail closed")
    }

    private static func testForceClaimLedgerIsEpisodeScopedAndPhysicalOnly() {
        let key = SleepUnmountGroupKey.physicalDisk(
            bsd: "disk12",
            generation: 7,
            mediaRegistryEntryID: 120
        )
        let replacement = SleepUnmountGroupKey.physicalDisk(
            bsd: "disk12",
            generation: 8,
            mediaRegistryEntryID: 121
        )
        let firstEpisode = SleepEpisodeForceClaimLedger()

        expect(firstEpisode.claimForce(for: key),
               "the first force claimant for a physical request must win")
        expect(!firstEpisode.claimForce(for: key),
               "the same physical request must not claim force twice in one episode")
        expect(firstEpisode.claimForce(for: replacement),
               "a replacement physical generation must have an independent claim")
        expect(!firstEpisode.claimForce(for: .unresolvedVolumePath("/Volumes/Unknown")),
               "an unresolved path must never receive a physical force claim")

        let nextEpisode = SleepEpisodeForceClaimLedger()
        expect(nextEpisode.claimForce(for: key),
               "a new sleep episode must receive a fresh claim ledger")
    }

    private static func testForceClaimLedgerAllowsOneConcurrentClaimPerPhysicalKey() {
        let ledger = SleepEpisodeForceClaimLedger()
        let firstKey = SleepUnmountGroupKey.physicalDisk(
            bsd: "disk20",
            generation: 1,
            mediaRegistryEntryID: 200
        )
        let secondKey = SleepUnmountGroupKey.physicalDisk(
            bsd: "disk21",
            generation: 1,
            mediaRegistryEntryID: 210
        )
        let winners = IntRecorder()
        let contenders = DispatchGroup()
        let queue = DispatchQueue(label: "SleepForceClaimLedgerTests", attributes: .concurrent)

        for contender in 0..<512 {
            contenders.enter()
            queue.async {
                let key = contender.isMultiple(of: 2) ? firstKey : secondKey
                if ledger.claimForce(for: key) {
                    winners.append(contender.isMultiple(of: 2) ? 1 : 2)
                }
                contenders.leave()
            }
        }

        expect(contenders.wait(timeout: .now() + 2) == .success,
               "all concurrent force claimants must finish")
        let result = winners.snapshot
        expect(result.count == 2,
               "exactly one concurrent claimant per physical request key must win")
        expect(result.filter { $0 == 1 }.count == 1 && result.filter { $0 == 2 }.count == 1,
               "each physical request key must have one independent winner")
    }

    private static func testOnlyExplicitCallbackSuccessIsClean() {
        expect(
            SleepUnmountEvidenceReducer.reduce(.pending, event: .callbackSuccess) == .clean,
            "an explicit callback success must be clean"
        )
        expect(
            SleepUnmountEvidenceReducer.reduce(.pending, event: .callbackFailure(.busy)) == .failure(.callbackFailure(.busy)),
            "callback failure must remain failure"
        )
        expect(
            SleepUnmountEvidenceReducer.reduce(.pending, event: .timeout) == .pendingAfterTimeout,
            "timeout must not pretend that the underlying DA request was canceled"
        )
        expect(
            SleepUnmountEvidenceReducer.reduce(.pending, event: .disconnect) == .failure(.disconnect),
            "disconnect without prior callback success must remain failure"
        )
        expect(
            SleepUnmountEvidenceReducer.reduce(.pending, event: .unavailable) == .failure(.unavailable),
            "unavailable evidence must remain failure"
        )
    }

    private static func testDisconnectThenLateSuccessRemainsFailure() {
        let timedOut = SleepUnmountEvidenceReducer.reduce(.pending, event: .timeout)
        let disconnected = SleepUnmountEvidenceReducer.reduce(timedOut, event: .disconnect)
        let afterLateSuccess = SleepUnmountEvidenceReducer.reduce(disconnected, event: .callbackSuccess)

        expect(timedOut == .pendingAfterTimeout, "wait timeout must preserve pending request state")
        expect(disconnected == .failure(.disconnect), "disconnect must be terminal failure")
        expect(afterLateSuccess == .failure(.disconnect), "late callback success must not overturn terminal disconnect")
    }

    private static func testSuccessThenDisconnectRemainsClean() {
        let succeeded = SleepUnmountEvidenceReducer.reduce(.pending, event: .callbackSuccess)
        let afterDisconnect = SleepUnmountEvidenceReducer.reduce(succeeded, event: .disconnect)

        expect(succeeded == .clean, "callback success must produce clean evidence")
        expect(afterDisconnect == .clean, "disconnect after callback success must preserve clean evidence")
    }

    private static func testStickyEvidenceReleasesAllJoinersOnce() {
        let latch = StickyAsyncEvidence<Int>()
        let recorder = IntRecorder()
        let waiters = DispatchGroup()
        for _ in 0..<50 {
            waiters.enter()
            DispatchQueue.global().async {
                recorder.append(latch.wait(timeout: 1))
                waiters.leave()
            }
        }

        Thread.sleep(forTimeInterval: 0.01)
        expect(latch.finishOnce(7), "the first terminal evidence must be accepted")
        expect(waiters.wait(timeout: .now() + 1) == .success,
               "one completion must release every joined waiter")
        expect(recorder.snapshot.count == 50 && recorder.snapshot.allSatisfy { $0 == 7 },
               "every joiner must observe the same terminal evidence")
        expect(!latch.finishOnce(8), "late terminal evidence must not replace the first value")
        expect(latch.snapshot() == 7, "the first terminal evidence must remain sticky")
    }

    private static func testTimeoutThenLateEvidenceRemainsObservableAndSticky() {
        let latch = StickyAsyncEvidence<Int>()
        expect(latch.wait(timeout: 0.001) == nil,
               "a waiter timeout must not complete the underlying request")

        let observed = IntRecorder()
        latch.observe { observed.append($0) }
        expect(latch.finishOnce(9), "late callback evidence must still complete the request")
        expect(observed.snapshot == [9], "a timeout observer must receive the later terminal evidence once")
        expect(!latch.finishOnce(10), "a later callback must not overturn terminal evidence")
    }

    private static func testHiddenProtectedSiblingBlocksVisibleWholeDiskTarget() {
        let decision = SleepProtectionPolicy.evaluate([
            SleepProtectionCandidate(physicalDiskID: "disk7#3#70", isEjectTarget: true, isProtected: false),
            SleepProtectionCandidate(physicalDiskID: "disk7#3#70", isEjectTarget: false, isProtected: true)
        ])

        expect(decision.allowedTargetIndices.isEmpty,
               "a hidden/non-target protected sibling must block the visible whole-disk target")
        expect(decision.skippedTargetCount == 1,
               "the blocked visible target must be counted as skipped")
    }

    private static func testRequestTimeSiblingSetRevalidationFailsClosed() {
        expect(
            SleepMountedSiblingPolicy.isSnapshotStillSafe(
                expectedMountedVolumeBSDs: ["disk7s1"],
                currentMountedVolumeBSDs: ["disk7s1"],
                allowMissingExpectedSiblings: false,
                enforceProtectionClosure: true,
                hasProtectedCurrentSibling: false
            ),
            "an unchanged unprotected sibling set may proceed"
        )
        expect(
            !SleepMountedSiblingPolicy.isSnapshotStillSafe(
                expectedMountedVolumeBSDs: ["disk7s1"],
                currentMountedVolumeBSDs: ["disk7s1", "disk7s2"],
                allowMissingExpectedSiblings: false,
                enforceProtectionClosure: true,
                hasProtectedCurrentSibling: true
            ),
            "a sibling mounted after the snapshot must invalidate whole-disk unmount"
        )
        expect(
            !SleepMountedSiblingPolicy.isSnapshotStillSafe(
                expectedMountedVolumeBSDs: ["disk7s1"],
                currentMountedVolumeBSDs: ["disk7s1"],
                allowMissingExpectedSiblings: false,
                enforceProtectionClosure: true,
                hasProtectedCurrentSibling: true
            ),
            "new protection metadata on an existing sibling must fail closed"
        )
        expect(
            SleepMountedSiblingPolicy.isSnapshotStillSafe(
                expectedMountedVolumeBSDs: ["disk7s1"],
                currentMountedVolumeBSDs: ["disk7s1"],
                allowMissingExpectedSiblings: false,
                enforceProtectionClosure: false,
                hasProtectedCurrentSibling: true
            ),
            "explicit user eject must preserve the existing protection-filter bypass"
        )
        expect(
            SleepMountedSiblingPolicy.isSnapshotStillSafe(
                expectedMountedVolumeBSDs: ["disk7s1", "disk7s2"],
                currentMountedVolumeBSDs: ["disk7s2"],
                allowMissingExpectedSiblings: true,
                enforceProtectionClosure: true,
                hasProtectedCurrentSibling: false
            ),
            "sequential force may continue after normal Whole partially unmounted expected siblings"
        )
        expect(
            !SleepMountedSiblingPolicy.isSnapshotStillSafe(
                expectedMountedVolumeBSDs: ["disk7s1", "disk7s2"],
                currentMountedVolumeBSDs: ["disk7s2", "disk7s3"],
                allowMissingExpectedSiblings: true,
                enforceProtectionClosure: true,
                hasProtectedCurrentSibling: false
            ),
            "force fallback must still reject a newly mounted sibling"
        )
    }

    private static func testUnresolvedProtectedSiblingFailsClosed() {
        let decision = SleepProtectionPolicy.evaluate([
            SleepProtectionCandidate(physicalDiskID: "disk8#1#80", isEjectTarget: true, isProtected: false),
            SleepProtectionCandidate(physicalDiskID: nil, isEjectTarget: false, isProtected: true)
        ])

        expect(decision.allowedTargetIndices.isEmpty,
               "an unresolved protected sibling must allow no automatic whole-disk request")
        expect(decision.blockedTargetIndices == [0],
               "unprotected targets must surface as blocked failures when closure is unknowable")
    }

    private static func testMountApprovalBarrierOrdering() {
        expect(
            SleepMountApprovalPolicy.decision(
                hasActiveUnmountBarrier: true,
                volumeAlreadyMounted: false
            ) == .rejectBusy,
            "a mount approval arriving after the unmount barrier must be rejected"
        )
        expect(
            SleepMountApprovalPolicy.decision(
                hasActiveUnmountBarrier: false,
                volumeAlreadyMounted: false
            ) == .approveAndTrackPending,
            "an approval before the barrier must remain pending until its mounted event is visible"
        )
        expect(
            !SleepMountApprovalPolicy.canBeginAutomaticUnmount(hasPendingApprovedMount: true),
            "an already-approved but not-yet-visible mount must block the stale snapshot, even when new media has no mounted group yet"
        )
        expect(
            SleepMountApprovalPolicy.decision(
                hasActiveUnmountBarrier: false,
                volumeAlreadyMounted: true
            ) == .approve,
            "a redundant mount request for an already-mounted volume needs no pending topology marker"
        )
        expect(
            SleepMountApprovalPolicy.canBeginAutomaticUnmount(hasPendingApprovedMount: false),
            "automatic unmount may begin after the approved mount becomes visible"
        )
        expect(
            SleepMountApprovalPolicy.pendingApprovalMatchesCapturedMedia(
                pendingMediaRegistryEntryID: 100,
                capturedMediaRegistryEntryID: 100
            ),
            "a pending approval for the exact captured media must block its snapshot"
        )
        expect(
            !SleepMountApprovalPolicy.pendingApprovalMatchesCapturedMedia(
                pendingMediaRegistryEntryID: 99,
                capturedMediaRegistryEntryID: 100
            ),
            "a stale approval from a replaced media generation must not bleed into the replacement"
        )
        expect(
            SleepMountApprovalPolicy.pendingApprovalMatchesCapturedMedia(
                pendingMediaRegistryEntryID: nil,
                capturedMediaRegistryEntryID: 100
            ),
            "an unresolved approval identity must fail closed"
        )
        expect(
            SleepMountApprovalPolicy.shouldRetainBarrierAfterNormalTerminal(
                callbackWasDecline: true,
                forceContinuationReserved: true
            ),
            "an on-time normal decline must retain the barrier into sequential force"
        )
        expect(
            !SleepMountApprovalPolicy.shouldRetainBarrierAfterNormalTerminal(
                callbackWasDecline: true,
                forceContinuationReserved: false
            ),
            "a late decline after waiter timeout must not retain an abandoned force barrier"
        )
    }

    private static func testEFIMountApprovalTracking() {
        expect(
            SleepMountApprovalPolicy.decision(
                hasActiveUnmountBarrier: false,
                isExternalCandidate: true,
                mediaContent: "EFI",
                volumeAlreadyMounted: false
            ) == .approve,
            "an unmounted external EFI helper may be approved without a pending topology marker"
        )
        expect(
            SleepMountApprovalPolicy.decision(
                hasActiveUnmountBarrier: true,
                isExternalCandidate: true,
                mediaContent: "EFI",
                volumeAlreadyMounted: false
            ) == .rejectBusy,
            "the active unmount barrier must reject external EFI before its tracking exemption"
        )
        expect(
            SleepMountApprovalPolicy.decision(
                hasActiveUnmountBarrier: false,
                hasPowerSleepBarrier: true,
                isExternalCandidate: true,
                mediaContent: "EFI",
                volumeAlreadyMounted: false
            ) == .rejectBusy,
            "the power-sleep barrier must reject external EFI before its tracking exemption"
        )
        expect(
            SleepMountApprovalPolicy.decision(
                hasActiveUnmountBarrier: false,
                isExternalCandidate: false,
                mediaContent: "EFI",
                volumeAlreadyMounted: false
            ) == .approveAndTrackPending,
            "internal EFI approvals must preserve the existing pending behavior"
        )
        expect(
            SleepMountApprovalPolicy.decision(
                hasActiveUnmountBarrier: false,
                isExternalCandidate: true,
                mediaContent: "Recovery",
                volumeAlreadyMounted: false
            ) == .approveAndTrackPending,
            "unobserved helper categories must preserve the existing fail-closed pending behavior"
        )
        expect(
            SleepMountApprovalPolicy.decision(
                hasActiveUnmountBarrier: false,
                isExternalCandidate: true,
                mediaContent: nil,
                volumeAlreadyMounted: false
            ) == .approveAndTrackPending,
            "an unresolved volume must retain the fail-closed pending marker"
        )
    }

    private static func testForceContinuationReservationsAreWaiterScoped() {
        var reservations = SleepForceContinuationReservationCounter()
        reservations.reserve()
        reservations.reserve()
        reservations.release()
        expect(
            reservations.isReserved && reservations.count == 1,
            "one waiter timeout must not cancel another waiter's force continuation"
        )
        reservations.release()
        reservations.release()
        expect(
            !reservations.isReserved && reservations.count == 0,
            "the barrier may release only after every waiter reservation is consumed"
        )
    }

    private static func testTimeoutAndCallbackHaveDistinctForceContinuationReleaseOwners() {
        var reservations = SleepForceContinuationReservationCounter()
        reservations.reserve()
        reservations.reserve()

        expect(
            !SleepForceContinuationReleasePolicy.callerOwnsRelease(
                forceContinuationReserved: true,
                requestWasForced: false,
                dissenterStatus: nil
            ),
            "a timeout waiter must not release again in its caller after DAInventory releases it"
        )
        reservations.release()
        expect(reservations.count == 1,
               "one callback waiter must retain its barrier reservation after its peer times out")

        expect(
            SleepForceContinuationReleasePolicy.callerOwnsRelease(
                forceContinuationReserved: true,
                requestWasForced: false,
                dissenterStatus: .busy
            ),
            "an explicit dissenter callback caller must release its retained handoff reservation"
        )
        reservations.release()
        expect(!reservations.isReserved,
               "the callback caller release must balance the remaining reservation")
        expect(
            !SleepForceContinuationReleasePolicy.callerOwnsRelease(
                forceContinuationReserved: false,
                requestWasForced: false,
                dissenterStatus: .busy
            ),
            "a normal-only trigger must never own a force continuation reservation"
        )
        expect(
            !SleepForceContinuationReleasePolicy.callerOwnsRelease(
                forceContinuationReserved: true,
                requestWasForced: true,
                dissenterStatus: .busy
            ),
            "a caller that joined an already-pending force request never reserved a continuation"
        )
    }

    private static func testPowerSleepMountBarrierCoversPostSnapshotApproval() {
        var barrier = SleepPowerMountBarrier()
        let firstToken = barrier.begin()
        expect(
            barrier.blocks(isExternalCandidate: true),
            "an external approval arriving after the final snapshot must remain blocked through sleep ACK"
        )
        expect(
            !barrier.blocks(isExternalCandidate: false),
            "the external-media boundary must not reject unrelated internal mounts"
        )
        expect(
            SleepMountApprovalPolicy.decision(
                hasActiveUnmountBarrier: false,
                hasPowerSleepBarrier: true,
                isExternalCandidate: true,
                volumeAlreadyMounted: false
            ) == .rejectBusy,
            "the power boundary must reject a new external mount even without a per-disk request"
        )
        let workerToken = barrier.begin()
        expect(workerToken != firstToken,
               "a nested eject worker must own an independent barrier token")

        barrier.end(token: workerToken &+ 1)
        expect(barrier.blocks(isExternalCandidate: true),
               "a stale wake token must not clear the active power boundary")
        barrier.end(token: workerToken)
        expect(barrier.blocks(isExternalCandidate: true),
               "ending the worker lease must not clear the enclosing power boundary")
        barrier.end(token: firstToken)
        expect(!barrier.blocks(isExternalCandidate: true),
               "the matching wake edge must release the power boundary")

        let secondToken = barrier.begin()
        expect(secondToken != firstToken,
               "a later power cycle must receive a distinct token")
    }
}
