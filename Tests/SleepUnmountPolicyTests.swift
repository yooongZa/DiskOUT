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
        testDuplicateDisplayNamesUsePhysicalRequestIdentity()
        testSelectedSnapshotGroupIsolation()
        testDissenterStatusClassification()
        testPolicyPreservesNormalThenExplicitForceFallback()
        testForcedSleepPolicyIsShortNormalOnlyOneShotBatch()
        testForcedSleepBoundaryRouteIsIOKitOnlyAndNeverRetries()
        testForcedSleepPolicyRecordsSuccessAfterTimeoutForWakeRemount()
        testPreparedForcedRequestStillEntersWaitAfterDeadline()
        testForcedSleepSubmissionWaveValidatesEverythingBeforeDestructiveIO()
        testForceClaimLedgerIsEpisodeScopedAndPhysicalOnly()
        testForceClaimLedgerAllowsOneConcurrentClaimPerPhysicalKey()
        testOnlyExplicitCallbackSuccessIsClean()
        testDisconnectThenLateSuccessRemainsFailure()
        testSuccessThenDisconnectRemainsClean()
        testStickyEvidenceReleasesAllJoinersOnce()
        testTimeoutThenLateEvidenceRemainsObservableAndSticky()
        testAutomaticActivityWaitsForEveryWorkerAndLateTerminal()
        testHiddenProtectedSiblingBlocksVisibleWholeDiskTarget()
        testRequestTimeSiblingSetRevalidationFailsClosed()
        testNormalWholeEscalationPolicy()
        testForceWatchdogRequiresTheFullTwoSeconds()
        testBusyAndTimeoutRaceSubmitsForceOnce()
        testForceSubmissionClaimRejectsStaleAndDuplicateRequests()
        testLateNormalAndForceCallbacksFinishOnce()
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

    private static func testSelectedSnapshotGroupIsolation() {
        let selected = Set(["/Volumes/Chosen"])
        expect(
            SleepSnapshotGroupSelectionPolicy.shouldInspectGroup(
                mountedVolumePaths: ["/Volumes/Chosen", "/Volumes/Chosen Helper"],
                selectedVolumePaths: selected
            ),
            "the selected physical group must retain all mounted siblings for Whole validation"
        )
        expect(
            !SleepSnapshotGroupSelectionPolicy.shouldInspectGroup(
                mountedVolumePaths: ["/Volumes/Unrelated"],
                selectedVolumePaths: selected
            ),
            "an unrelated external identity failure must not block a selected manual eject"
        )
        expect(
            SleepSnapshotGroupSelectionPolicy.shouldInspectGroup(
                mountedVolumePaths: ["/Volumes/Unrelated"],
                selectedVolumePaths: nil
            ),
            "automatic and eject-all snapshots must continue to inspect every mounted group"
        )
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

    private static func testDuplicateDisplayNamesUsePhysicalRequestIdentity() {
        let requests = SleepUnmountPolicy.requests(
            for: [
                SleepUnmountTarget(name: "Untitled",
                                   volumePath: "/Volumes/Untitled",
                                   wholeDiskBSD: "disk4",
                                   physicalGeneration: 1,
                                   mediaRegistryEntryID: 40),
                SleepUnmountTarget(name: "Untitled",
                                   volumePath: "/Volumes/Untitled 1",
                                   wholeDiskBSD: "disk9",
                                   physicalGeneration: 2,
                                   mediaRegistryEntryID: 90)
            ],
            forceFallback: false
        )
        let labels = SleepUnmountBatchPresentationPolicy.labelsByRequest(requests)
        let completed: Set<SleepUnmountGroupKey> = [requests[0].key]
        let unfinished = SleepUnmountBatchPresentationPolicy.unfinishedLabels(
            requests: requests,
            completedRequestKeys: completed,
            labelsByRequest: labels
        )

        expect(labels[requests[0].key] == ["Untitled (disk4)"],
               "the completed duplicate name must include its physical BSD identity")
        expect(labels[requests[1].key] == ["Untitled (disk9)"],
               "the pending duplicate name must include its distinct physical BSD identity")
        expect(unfinished == ["Untitled (disk9)"],
               "a completed same-name request must not hide a different pending physical disk")
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
               "the callback-only projection must leave watchdog escalation to the lifecycle policy")
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

    private static func testForcedSleepPolicyIsShortNormalOnlyOneShotBatch() {
        let targets = [
            SleepUnmountTarget(name: "Work",
                               volumePath: "/Volumes/Work",
                               wholeDiskBSD: "disk7",
                               physicalGeneration: 3,
                               mediaRegistryEntryID: 30),
            SleepUnmountTarget(name: "Media",
                               volumePath: "/Volumes/Media",
                               wholeDiskBSD: "disk7",
                               physicalGeneration: 3,
                               mediaRegistryEntryID: 30),
            SleepUnmountTarget(name: "Backup",
                               volumePath: "/Volumes/Backup",
                               wholeDiskBSD: "disk8",
                               physicalGeneration: 4,
                               mediaRegistryEntryID: 40)
        ]

        let requests = ForcedSleepUnmountBatchPolicy.requests(for: targets)

        expect(ForcedSleepUnmountBatchPolicy.maximumWait == 3,
               "forced sleep must use the isolated short wait cap")
        expect(requests.count == 2,
               "one forced-sleep batch must emit exactly one request per physical disk")
        expect(requests[0].targets.map(\.name) == ["Work", "Media"],
               "sibling volumes must share one physical request")
        expect(requests.allSatisfy { !$0.allowsForceFallback },
               "every forced-sleep request must remain normal-only")
        expect(
            SleepUnmountPolicy.nextOperation(
                after: .callbackFailure(.busy),
                forceFallback: ForcedSleepUnmountBatchPolicy.allowsForceFallback
            ) == nil,
            "a busy normal decline must not start force fallback in forced sleep"
        )
    }

    private static func testForcedSleepBoundaryRouteIsIOKitOnlyAndNeverRetries() {
        expect(
            ForcedSleepBoundaryRoutingPolicy.route(
                isIOKitConfirmed: true,
                isForcedSleep: true,
                isEnabled: true
            ) == .bestEffortNoRetry(maximumWait: 3),
            "an enabled IOKit-confirmed forced boundary gets one short no-retry route"
        )
        expect(
            ForcedSleepBoundaryRoutingPolicy.route(
                isIOKitConfirmed: false,
                isForcedSleep: true,
                isEnabled: true
            ) == .passThrough,
            "an NSWorkspace or otherwise unconfirmed boundary must never enter the experiment"
        )
        expect(
            ForcedSleepBoundaryRoutingPolicy.route(
                isIOKitConfirmed: true,
                isForcedSleep: false,
                isEnabled: true
            ) == .passThrough,
            "idle, lid, display, and manual triggers remain on their existing policies"
        )
        expect(
            ForcedSleepBoundaryRoutingPolicy.route(
                isIOKitConfirmed: true,
                isForcedSleep: true,
                isEnabled: false
            ) == .passThrough,
            "the default-off experiment passes through until explicitly enabled"
        )
    }

    private static func testForcedSleepPolicyRecordsSuccessAfterTimeoutForWakeRemount() {
        let policy = ForcedSleepUnmountBatchPolicy.lateSuccessRecordingPolicy

        expect(
            policy.shouldRecordCleanSuccess(timing: .beforeTimeout),
            "an explicit clean callback observed before the deadline may create a remount target"
        )
        expect(
            policy.shouldRecordCleanSuccess(timing: .afterTimeout),
            "a late clean callback must still create a wake-remount target"
        )
        expect(
            ForcedSleepCleanSuccessPolicy.shouldRecord(
                callbackSucceeded: true,
                requestWasForced: false,
                timing: .beforeTimeout
            ),
            "an on-time explicit clean callback from the one normal request may be recorded"
        )
        expect(
            !ForcedSleepCleanSuccessPolicy.shouldRecord(
                callbackSucceeded: true,
                requestWasForced: true,
                timing: .beforeTimeout
            ),
            "a forced request joined from another policy must never become forced-sleep success"
        )
        expect(ForcedSleepSubmissionModePolicy.allows(requestWasForced: false),
               "the forced-sleep path may submit or join only a normal request")
        expect(!ForcedSleepSubmissionModePolicy.allows(requestWasForced: true),
               "the forced-sleep path must refuse an existing force request before joining it")
        expect(
            SleepUnmountLateSuccessRecordingPolicy.preserveAutomaticRemountOwnership
                .shouldRecordCleanSuccess(timing: .afterTimeout),
            "all app-managed Whole requests must preserve late-clean remount ownership"
        )
    }

    private static func testPreparedForcedRequestStillEntersWaitAfterDeadline() {
        expect(PreparedSleepUnmountDeadlinePolicy.shouldEnterWait(
            hasPreparedRequest: true,
            remainingBudget: 0
        ), "a submitted prepared request must install late-terminal observation after deadline")
        expect(!PreparedSleepUnmountDeadlinePolicy.shouldEnterWait(
            hasPreparedRequest: false,
            remainingBudget: 0
        ), "an unsubmitted request must not start after its deadline")
        expect(PreparedSleepUnmountDeadlinePolicy.shouldEnterWait(
            hasPreparedRequest: false,
            remainingBudget: 0.1
        ), "an ordinary request may start while positive budget remains")
        expect(!ForcedSleepDestructiveSubmissionPolicy.allows(
            isEnabled: true,
            remainingBudget: 0
        ),
               "the destructive submission phase must stop exactly at the forced-sleep deadline")
        expect(ForcedSleepDestructiveSubmissionPolicy.allows(
            isEnabled: true,
            remainingBudget: 0.001
        ),
               "the destructive submission phase may run only while positive budget remains")
        expect(!ForcedSleepDestructiveSubmissionPolicy.allows(
            isEnabled: false,
            remainingBudget: 1
        ), "turning the experiment off must stop a staged destructive submission")

        let tracker = SleepUnmountActivityTracker()
        let lateTerminal = StickyAsyncEvidence<Int>()
        tracker.begin()
        lateTerminal.observe { _ in tracker.finish() }
        expect(tracker.activeCount == 1,
               "a prepared request remains active after its zero-time waiter returns")
        var claimedWhileBusy = false
        expect(!tracker.performIfIdle { claimedWhileBusy = true } && !claimedWhileBusy,
               "a remount claim must not cross an active unmount boundary")
        expect(lateTerminal.finishOnce(1), "the first late DA terminal is accepted")
        expect(tracker.activeCount == 0,
               "the actual late terminal releases prepared-request ownership exactly once")
        var claimedWhileIdle = false
        expect(tracker.performIfIdle { claimedWhileIdle = true } && claimedWhileIdle,
               "the remount claim may run atomically after every request is terminal")
        expect(!lateTerminal.finishOnce(2) && tracker.activeCount == 0,
               "a duplicate terminal cannot release tracking twice")
    }

    private static func testForcedSleepSubmissionWaveValidatesEverythingBeforeDestructiveIO() {
        var firstProbeStillMounted = true
        var events: [String] = []

        _ = ForcedSleepSubmissionWavePolicy.prepareAuthorizeThenSubmit(
            count: 2,
            prepare: { index -> () -> Void in
                expect(firstProbeStillMounted,
                       "every preparation must finish before the first unmount")
                events.append("prepare-\(index)")
                return {
                    events.append("submit-\(index)")
                    if index == 0 { firstProbeStillMounted = false }
                }
            },
            authorize: { submissions in
                submissions.enumerated().map { index, submission in
                    expect(firstProbeStillMounted,
                           "every final global validation must finish before the first unmount")
                    events.append("authorize-\(index)")
                    return submission
                }
            },
            submit: { _, submission in
                submission()
                return submission
            }
        )

        expect(events == [
            "prepare-0", "prepare-1", "authorize-0", "authorize-1", "submit-0", "submit-1"
        ], "forced requests must finish both safe phases before the destructive submission phase")
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

    private static func testAutomaticActivityWaitsForEveryWorkerAndLateTerminal() {
        let tracker = SleepUnmountActivityTracker()
        let recorder = IntRecorder()
        tracker.begin()
        tracker.begin()
        tracker.whenIdle { recorder.append(1) }

        tracker.finish()
        expect(tracker.activeCount == 1 && recorder.snapshot.isEmpty,
               "one terminal worker must not release a sibling pending DA request")
        tracker.finish()
        expect(tracker.activeCount == 0 && recorder.snapshot == [1],
               "the final terminal result must release idle observers exactly once")
        tracker.finish()
        expect(recorder.snapshot == [1],
               "a duplicate terminal callback must not underflow or notify twice")

        tracker.whenIdle { recorder.append(2) }
        expect(recorder.snapshot == [1, 2],
               "an already-idle tracker must continue synchronously")
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

    private static func testNormalWholeEscalationPolicy() {
        expect(SleepUnmountEscalationPolicy.normalWholeCallbackTimeout == 2,
               "a normal Whole request must receive exactly two seconds before escalation")

        let normalSuccess = SleepUnmountEscalationPolicy.transition(
            from: .awaitingNormal,
            event: .normalCallbackSuccess,
            allowsForceFallback: true
        )
        expect(
            normalSuccess == SleepUnmountEscalationTransition(
                state: .finished,
                action: .finishClean(requestWasForced: false)
            ),
            "normal callback success must finish without a force request"
        )

        let forceEligibleStatuses: [SleepUnmountDissenterStatus] = [
            .busy,
            .exclusiveAccess,
            .unixBusy
        ]
        expect(
            forceEligibleStatuses.allSatisfy { status in
                SleepUnmountEscalationPolicy.transition(
                    from: .awaitingNormal,
                    event: .normalCallbackFailure(status),
                    allowsForceFallback: true
                ) == SleepUnmountEscalationTransition(
                    state: .awaitingForce(normalPending: false),
                    action: .submitForce
                )
            },
            "each contention callback must submit one force request when fallback is allowed"
        )

        let watchdog = SleepUnmountEscalationPolicy.transition(
            from: .awaitingNormal,
            event: .normalCallbackTimedOut,
            allowsForceFallback: true
        )
        expect(
            watchdog == SleepUnmountEscalationTransition(
                state: .awaitingForce(normalPending: true),
                action: .submitForce
            ),
            "two seconds without a normal Whole callback must submit force when allowed"
        )

        let disabledWatchdog = SleepUnmountEscalationPolicy.transition(
            from: .awaitingNormal,
            event: .normalCallbackTimedOut,
            allowsForceFallback: false
        )
        expect(
            disabledWatchdog == SleepUnmountEscalationTransition(
                state: .awaitingNormal,
                action: .none
            ),
            "the watchdog must never enable force when fallback is disabled"
        )

        let disabledBusy = SleepUnmountEscalationPolicy.transition(
            from: .awaitingNormal,
            event: .normalCallbackFailure(.busy),
            allowsForceFallback: false
        )
        expect(
            disabledBusy == SleepUnmountEscalationTransition(
                state: .finished,
                action: .finishFailure(.callbackFailure(.busy))
            ),
            "a busy callback must remain a terminal failure when force is disabled"
        )

        let nonContention = SleepUnmountEscalationPolicy.transition(
            from: .awaitingNormal,
            event: .normalCallbackFailure(.other(0xF8DA0001)),
            allowsForceFallback: true
        )
        expect(
            nonContention == SleepUnmountEscalationTransition(
                state: .finished,
                action: .finishFailure(.callbackFailure(.other(0xF8DA0001)))
            ),
            "a non-contention callback must fail closed without force"
        )

        let disconnected = SleepUnmountEscalationPolicy.transition(
            from: .awaitingNormal,
            event: .normalDisconnected,
            allowsForceFallback: true
        )
        expect(
            disconnected == SleepUnmountEscalationTransition(
                state: .finished,
                action: .finishFailure(.disconnect)
            ),
            "disconnect before escalation must remain terminal"
        )
        let joinedForce = SleepUnmountEscalationPolicy.transition(
            from: .awaitingNormal,
            event: .forceRequestAlreadyPending,
            allowsForceFallback: true
        )
        expect(joinedForce == SleepUnmountEscalationTransition(
            state: .awaitingForce(normalPending: false),
            action: .none
        ), "joining an already-pending Force must not invent a normal request or submit again")
    }

    private static func testBusyAndTimeoutRaceSubmitsForceOnce() {
        let orderings: [[SleepUnmountEscalationEvent]] = [
            [.normalCallbackFailure(.busy), .normalCallbackTimedOut],
            [.normalCallbackTimedOut, .normalCallbackFailure(.busy)]
        ]

        for ordering in orderings {
            var state = SleepUnmountEscalationState.awaitingNormal
            var actions: [SleepUnmountEscalationAction] = []
            for event in ordering {
                let transition = SleepUnmountEscalationPolicy.transition(
                    from: state,
                    event: event,
                    allowsForceFallback: true
                )
                state = transition.state
                actions.append(transition.action)
            }

            expect(actions.filter { $0 == .submitForce }.count == 1,
                   "busy/watchdog ordering must emit submitForce exactly once")
            expect(actions.last == .some(.none),
                   "the second racing escalation event must be a no-op")
            expect(state == .awaitingForce(normalPending: false),
                   "the request must wait for force evidence after the race")
        }
    }

    private static func testForceWatchdogRequiresTheFullTwoSeconds() {
        expect(
            SleepUnmountForceWatchdogPolicy.normalWaitDuration(
                remainingBudget: 1.5,
                allowsForceFallback: true
            ) == 1.5,
            "a shorter enclosing deadline must cap the normal wait"
        )
        expect(
            !SleepUnmountForceWatchdogPolicy.allowsTimeoutEscalation(
                initialRemainingBudget: 1.5,
                currentRemainingBudget: 0.1,
                allowsForceFallback: true
            ),
            "a deadline under two seconds must never authorize early Force"
        )
        expect(
            SleepUnmountForceWatchdogPolicy.normalWaitDuration(
                remainingBudget: 10,
                allowsForceFallback: true
            ) == 2,
            "an eligible request must wait exactly two seconds for the normal callback"
        )
        expect(
            SleepUnmountForceWatchdogPolicy.allowsTimeoutEscalation(
                initialRemainingBudget: 10,
                currentRemainingBudget: 7.9,
                allowsForceFallback: true
            ),
            "Force may start after the full watchdog when enclosing budget remains"
        )
        expect(
            !SleepUnmountForceWatchdogPolicy.allowsTimeoutEscalation(
                initialRemainingBudget: 10,
                currentRemainingBudget: 7.9,
                allowsForceFallback: false
            ),
            "the watchdog must preserve a trigger policy that disables Force"
        )
    }

    private static func testForceSubmissionClaimRejectsStaleAndDuplicateRequests() {
        var staleRuntime = SleepUnmountEscalationRuntime()
        expect(
            staleRuntime.consume(.normalCallbackTimedOut, allowsForceFallback: true) == .submitForce,
            "the two-second watchdog must propose Force when policy allows it"
        )
        expect(
            staleRuntime.consume(.normalCallbackSuccess, allowsForceFallback: true)
                == .finishClean(requestWasForced: false),
            "a normal clean callback may win before the proposed Force is submitted"
        )
        expect(!staleRuntime.claimForceSubmission(),
               "a Force proposal must become invalid after normal clean terminal evidence")

        var claimedRuntime = SleepUnmountEscalationRuntime()
        expect(
            claimedRuntime.consume(.normalCallbackFailure(.busy), allowsForceFallback: true)
                == .submitForce,
            "a busy callback must propose Force when policy allows it"
        )
        expect(claimedRuntime.claimForceSubmission(),
               "the first live Force proposal must own submission")
        expect(!claimedRuntime.claimForceSubmission(),
               "a second racing Force submission claim must be rejected")
    }

    private static func testLateNormalAndForceCallbacksFinishOnce() {
        let lateNormalSuccess = SleepUnmountEscalationPolicy.transition(
            from: .awaitingForce(normalPending: true),
            event: .normalCallbackSuccess,
            allowsForceFallback: true
        )
        expect(
            lateNormalSuccess == SleepUnmountEscalationTransition(
                state: .finished,
                action: .finishClean(requestWasForced: false)
            ),
            "late normal success may provide the first clean terminal evidence"
        )
        let forceAfterNormal = SleepUnmountEscalationPolicy.transition(
            from: lateNormalSuccess.state,
            event: .forceCallbackSuccess,
            allowsForceFallback: true
        )
        expect(forceAfterNormal.action == .none,
               "force callback after late normal success must not complete twice")

        let forceFirst = SleepUnmountEscalationPolicy.transition(
            from: .awaitingForce(normalPending: true),
            event: .forceCallbackSuccess,
            allowsForceFallback: true
        )
        let normalAfterForce = SleepUnmountEscalationPolicy.transition(
            from: forceFirst.state,
            event: .normalCallbackSuccess,
            allowsForceFallback: true
        )
        expect(
            forceFirst.action == .finishClean(requestWasForced: true)
                && normalAfterForce.action == .none,
            "late normal callback after force success must not complete twice"
        )

        let busyForceFailure = SleepUnmountEscalationPolicy.transition(
            from: .awaitingForce(normalPending: false),
            event: .forceCallbackFailure(.other(0xF8DA0001)),
            allowsForceFallback: true
        )
        expect(
            busyForceFailure == SleepUnmountEscalationTransition(
                state: .finished,
                action: .finishFailure(.callbackFailure(.other(0xF8DA0001)))
            ),
            "force failure after a terminal busy callback must finish the operation"
        )

        let timeoutForceFailure = SleepUnmountEscalationPolicy.transition(
            from: .awaitingForce(normalPending: true),
            event: .forceCallbackFailure(.other(0xF8DA0001)),
            allowsForceFallback: true
        )
        expect(timeoutForceFailure == SleepUnmountEscalationTransition(
            state: .awaitingNormalAfterForceFailure(
                .callbackFailure(.other(0xF8DA0001))
            ),
            action: .none
        ), "Force failure must wait when the timed-out normal request is still pending")
        let normalRecoversAfterForceFailure = SleepUnmountEscalationPolicy.transition(
            from: timeoutForceFailure.state,
            event: .normalCallbackSuccess,
            allowsForceFallback: true
        )
        expect(normalRecoversAfterForceFailure == SleepUnmountEscalationTransition(
            state: .finished,
            action: .finishClean(requestWasForced: false)
        ), "a late normal clean must recover a prior Force failure")

        let timeoutForceFailureThenNormalFailure = SleepUnmountEscalationPolicy.transition(
            from: timeoutForceFailure.state,
            event: .normalCallbackFailure(.busy),
            allowsForceFallback: true
        )
        expect(timeoutForceFailureThenNormalFailure == SleepUnmountEscalationTransition(
            state: .finished,
            action: .finishFailure(.callbackFailure(.other(0xF8DA0001)))
        ), "the operation fails only after both overlapping requests have failed")

        let allCallbackEvents: [SleepUnmountEscalationEvent] = [
            .normalCallbackSuccess,
            .normalCallbackFailure(.busy),
            .normalCallbackTimedOut,
            .normalDisconnected,
            .normalUnavailable,
            .forceRequestAlreadyPending,
            .forceCallbackSuccess,
            .forceCallbackFailure(.busy),
            .forceDisconnected,
            .forceUnavailable
        ]
        expect(
            allCallbackEvents.allSatisfy { event in
                SleepUnmountEscalationPolicy.transition(
                    from: busyForceFailure.state,
                    event: event,
                    allowsForceFallback: true
                ) == SleepUnmountEscalationTransition(state: .finished, action: .none)
            },
            "every callback after a terminal force result must be a no-op"
        )
    }
}
