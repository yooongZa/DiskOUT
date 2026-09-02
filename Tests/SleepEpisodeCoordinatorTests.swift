import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func disk(_ bsd: String,
                  generation: UInt64 = 1,
                  mediaRegistryEntryID: UInt64? = nil) -> SleepRemountTarget {
    SleepRemountTarget(wholeDiskBSD: bsd,
                       physicalGeneration: generation,
                       mediaRegistryEntryID: mediaRegistryEntryID ?? generation)
}

@main
private enum SleepEpisodeCoordinatorTests {
    static func main() {
        testWorkspaceWakeCannotConsumeIOKitOwnedBoundary()
        testWakeMountWaitAndMenuPolicies()
        testSleepEjectTriggerPolicyForEveryCase()
        testSystemSleepTriggerClassification()
        testLidAttributionRequiresARecentPhysicalClose()
        testRepeatedCloseAndRealRecloseEpisodes()
        testAutomaticLibraryAppRelaunchOwnership()
        testAmphetamineLidOpenWithoutWakeSchedulesRemount()
        testSystemSleepDarkWakeWaitsForFullWake()
        testDisplayOnlyScreenWakeStillSchedulesRemount()
        testDisplayAndSystemSleepOverlapWaitsForFullWake()
        testLidOpenInsideSystemSleepWaitsForFullWake()
        testWakeWhileClosedDoesNotRemount()
        testOpenBeforeCleanCallbackSchedulesWhenTargetArrives()
        testDuplicateWakeSchedulesOnce()
        testRecloseCancelsScheduledRemountWithoutLosingTargets()
        testRecloseDuringActiveRemountRequeuesCanceledTargets()
        testLateTargetDuringActiveRemountSchedulesFollowUp()
        testLateTargetAfterFinishedRemountStillSchedules()
        testManualTargetWaitsForNextWakeWithoutCancelingCurrentSchedule()
        testFailedEjectAndSleepTargetRemountsAtNextWake()
        testPhysicalGenerationRemainsPartOfRemountIdentity()
        testUnknownStaleCompletionCannotInjectTargets()
        testNewEjectInvalidatesStaleWakeRequest()
        testNewEjectDoesNotRescheduleCanceledRemountBeforeWake()
        testNewSystemSleepInvalidatesActiveRemountWithoutLosingTarget()
        testMatchingLidSleepGetsOnlyOneFailedEpisodeRetry()
        testNewCloseGenerationJoinedToActiveWorkRequiresFreshInventory()
        testRepeatedLidJoinPreservesEpisodeForceLedger()
        testCurrentLidRefreshPrefersItsEpisodeForceLedger()
        testPowerBoundaryWaitsForRefreshAndRetriesAtMostOnce()
        print("SleepEpisodeCoordinatorTests: PASS")
    }

    private static func testWorkspaceWakeCannotConsumeIOKitOwnedBoundary() {
        expect(!SystemWakeBoundarySourcePolicy.workspaceOwnsBoundary(
            powerObserverIsActive: true
        ), "a late NSWorkspace wake must not consume a newer IOKit-owned sleep cycle")
        expect(SystemWakeBoundarySourcePolicy.workspaceOwnsBoundary(
            powerObserverIsActive: false
        ), "NSWorkspace must retain wake ownership when IOKit registration is unavailable")
    }

    private static func testWakeMountWaitAndMenuPolicies() {
        expect(WakeMountWaitPolicy.action(for: .callbackSuccess) == .success,
               "an explicit clean mount callback must complete the remount")
        expect(WakeMountWaitPolicy.action(for: .callbackFailure) == .retryFailure,
               "an explicit mount failure may enter the existing bounded retry flow")
        expect(WakeMountWaitPolicy.action(for: .unavailable) == .retryFailure,
               "an unavailable request may retry only after the next identity check")
        expect(WakeMountWaitPolicy.action(for: .identityChangedBeforeCallback) == .userDisconnected,
               "a changed physical identity must be handled as user disconnect")
        expect(WakeMountWaitPolicy.action(for: .timedOutPending) == .awaitTerminalSilently,
               "a live DA request whose waiter timed out must not become a failure alert")
        expect(WakeMenuPresentationPolicy.shouldExposeUnmountedDisk(
            systemSleepAwaitingWake: false,
            physicalMediaPresent: true
        ), "ordinary awake menus must keep the mountable-disk recovery section")
        expect(!WakeMenuPresentationPolicy.shouldExposeUnmountedDisk(
            systemSleepAwaitingWake: true,
            physicalMediaPresent: true
        ), "DarkWake menus must not expose a stale pre-sleep IOMedia object")
        expect(!WakeMenuPresentationPolicy.shouldExposeUnmountedDisk(
            systemSleepAwaitingWake: false,
            physicalMediaPresent: false
        ), "a DA row whose physical IOMedia disappeared must not remain mountable")
        expect(WakeMenuPresentationPolicy.physicalMediaMatches(
            expectedRegistryEntryID: 41,
            actualRegistryEntryID: 41
        ), "the exact cached IOMedia identity must remain mountable")
        expect(!WakeMenuPresentationPolicy.physicalMediaMatches(
            expectedRegistryEntryID: 41,
            actualRegistryEntryID: 42
        ), "a replacement media that reused diskN must not inherit the stale row")
        expect(WakeMenuPresentationPolicy.physicalMediaMatches(
            expectedRegistryEntryID: nil,
            actualRegistryEntryID: 42
        ), "a cold-start diskutil row may use a live IOMedia without a captured identity")
        expect(!WakeMenuPresentationPolicy.physicalMediaMatches(
            expectedRegistryEntryID: nil,
            actualRegistryEntryID: nil
        ), "an absent live IOMedia must never be shown as mountable")
    }

    private static func testSleepEjectTriggerPolicyForEveryCase() {
        let cases: [(trigger: SleepEjectTrigger,
                     participatesInEjectFlow: Bool,
                     force: Bool,
                     label: String,
                     display: Bool,
                     system: Bool)] = [
            (.lidClose, true, true, "lidClose", false, true),
            (.systemForced, true, false, "systemForced", false, true),
            (.systemIdle, true, false, "systemIdle", false, true),
            (.displaySleep, true, false, "displaySleep", true, false),
            (.ejectAndSleep, true, true, "ejectAndSleep", false, false),
            (.powerOff, true, false, "powerOff", false, false),
            (.unknownSystemSleep, true, false, "unknownSystemSleep", false, true),
        ]

        for item in cases {
            expect(item.trigger.participatesInEjectFlow == item.participatesInEjectFlow,
                   "\(item.label) participation must match the established eject-flow policy")
            expect(item.trigger.allowsForceFallback == item.force,
                   "\(item.label) force fallback policy must match its explicit trigger intent")
            expect(item.trigger.effectiveForceFallback(masterEnabled: true) == item.force,
                   "\(item.label) must honor its trigger policy while the master switch is on")
            expect(!item.trigger.effectiveForceFallback(masterEnabled: false),
                   "the master force switch must remain an opt-out for \(item.label)")
            expect(item.trigger.logLabel == item.label,
                   "\(item.label) must have a stable log label")
            expect(item.trigger.isDisplaySleep == item.display,
                   "\(item.label) display-sleep classification must be exact")
            expect(item.trigger.isSystemSleep == item.system,
                   "\(item.label) system-sleep classification must be exact")
        }

        expect(Set(cases.map { $0.trigger.logLabel }).count == cases.count,
               "every trigger must have a unique log label")
    }

    private static func testSystemSleepTriggerClassification() {
        expect(SleepEjectTrigger.systemSleep(isIdle: true, lidAttributed: false) == .systemIdle,
               "CanSystemSleep-origin sleep must remain idle and normal-only")
        expect(SleepEjectTrigger.systemSleep(isIdle: false, lidAttributed: false) == .systemForced,
               "WillSleep without an idle candidate must remain forced")
        expect(SleepEjectTrigger.systemSleep(isIdle: nil, lidAttributed: false) == .unknownSystemSleep,
               "an unclassified fallback must fail closed")
        expect(SleepEjectTrigger.systemSleep(isIdle: true, lidAttributed: true) == .lidClose,
               "a lid-attributed boundary must override an idle candidate")
        expect(SleepEjectTrigger.systemSleep(isIdle: false, lidAttributed: true) == .lidClose,
               "a lid-attributed forced boundary must use the lid policy")
        expect(SleepEjectTrigger.systemSleep(isIdle: nil, lidAttributed: true) == .lidClose,
               "a fallback boundary with positive lid attribution must use the lid policy")
    }

    private static func testLidAttributionRequiresARecentPhysicalClose() {
        let close: UInt64 = 1_000
        let window: UInt64 = 15_000
        let first = SleepLidAttributionPolicy.updatedCloseTimestamp(
            previousNanoseconds: nil,
            observedAtNanoseconds: close,
            isNewPhysicalClose: true
        )
        let duplicate = SleepLidAttributionPolicy.updatedCloseTimestamp(
            previousNanoseconds: first,
            observedAtNanoseconds: close + 10_000,
            isNewPhysicalClose: false
        )

        expect(first == close,
               "a new physical close must establish the attribution timestamp")
        expect(duplicate == close,
               "a repeated closed notification must not make an old lid edge recent again")

        expect(
            SleepLidAttributionPolicy.isRecentClose(
                closedAtNanoseconds: close,
                nowNanoseconds: close + window - 1,
                windowNanoseconds: window
            ),
            "a WillSleep inside the close window must retain lid ownership"
        )
        expect(
            !SleepLidAttributionPolicy.isRecentClose(
                closedAtNanoseconds: close,
                nowNanoseconds: close + window,
                windowNanoseconds: window
            ),
            "a lid that merely remains closed must not capture an outside active sleep"
        )
        expect(
            !SleepLidAttributionPolicy.isRecentClose(
                closedAtNanoseconds: nil,
                nowNanoseconds: close,
                windowNanoseconds: window
            ),
            "missing physical close evidence must pass through as non-lid"
        )
        expect(
            !SleepLidAttributionPolicy.isRecentClose(
                closedAtNanoseconds: close + 1,
                nowNanoseconds: close,
                windowNanoseconds: window
            ),
            "a synthetic backward monotonic clock must not create lid ownership"
        )
    }

    private static func testRepeatedCloseAndRealRecloseEpisodes() {
        var state = SleepEpisodeCoordinator()
        let first = state.lidDidClose()
        let duplicate = state.lidDidClose()
        _ = state.lidDidOpen()
        let second = state.lidDidClose()

        expect(first.isNewEpisode, "first close must create an episode")
        expect(!duplicate.isNewEpisode && duplicate.generation == first.generation,
               "repeated closed notification must join the same episode")
        expect(second.isNewEpisode && second.generation != first.generation,
               "open then close must create a new episode even within ten seconds")
    }

    private static func testAutomaticLibraryAppRelaunchOwnership() {
        var state = SleepEpisodeCoordinator()
        expect(!state.hasAutomaticLibraryAppRelaunchOwner,
               "an idle coordinator must not retain the shared library-app ledger")

        _ = state.lidDidClose()
        expect(!state.hasAutomaticLibraryAppRelaunchOwner,
               "a closed lid alone must not claim ownership when auto eject did not start")
        state.lidEjectDidStart()
        expect(state.hasAutomaticLibraryAppRelaunchOwner,
               "a started lid eject must retain relaunch ownership until lid open")

        state.displayEjectDidStart()
        _ = state.lidDidOpen()
        expect(state.hasAutomaticLibraryAppRelaunchOwner,
               "opening the lid must not drain an overlapping display-sleep owner")
        state.displayDidWake()
        expect(!state.hasAutomaticLibraryAppRelaunchOwner,
               "the final matching wake must release an empty automatic episode")

        let schedule = state.recordCleanUnmountTargets([disk("disk-owner")],
                                                        operationID: "owner",
                                                        reason: "displaySleep")!
        expect(state.hasAutomaticLibraryAppRelaunchOwner,
               "a pending clean target must retain ownership after the wake edge")
        let work = state.claimRemount(schedule.token)!
        expect(state.hasAutomaticLibraryAppRelaunchOwner,
               "an active remount must retain ownership after targets are claimed")
        _ = state.finishRemount(work.token, canceledDisks: [])
        expect(!state.hasAutomaticLibraryAppRelaunchOwner,
               "completed remount work must release automatic ownership")
    }

    private static func testAmphetamineLidOpenWithoutWakeSchedulesRemount() {
        var state = SleepEpisodeCoordinator()
        _ = state.lidDidClose()
        expect(state.recordCleanUnmountTargets([disk("disk7")], operationID: "op", reason: "clamshell") == nil,
               "closed lid must retain targets without remounting")
        let schedule = state.lidDidOpen()
        expect(schedule != nil, "lid open alone must schedule remount when no didWake is emitted")
        let work = schedule.flatMap { state.claimRemount($0.token) }
        expect(work?.disks == [disk("disk7")], "lid-open work must contain the clean target")
    }

    private static func testSystemSleepDarkWakeWaitsForFullWake() {
        var state = SleepEpisodeCoordinator()
        state.systemSleepDidStart()
        expect(state.systemSleepAwaitingWake,
               "system will-sleep must close the remount boundary")
        expect(state.recordCleanUnmountTargets([disk("disk-system")],
                                               operationID: "system",
                                               reason: "powerSleep") == nil,
               "a clean system-sleep target must remain pending before full wake")
        expect(state.wakeDidOccur(source: .screen) == nil,
               "DarkWake screen notification must not consume a system-sleep target")
        expect(state.pendingTargets == [disk("disk-system")],
               "the suppressed screen wake must preserve the exact target")

        let schedule = state.wakeDidOccur(source: .system)
        expect(schedule != nil,
               "the ordered full-system wake must schedule the preserved target")
        expect(!state.systemSleepAwaitingWake,
               "full wake must reopen the system remount boundary")
        expect(state.wakeDidOccur(source: .system) == nil,
               "a duplicate full-wake notification must not create another schedule")
        expect(schedule.flatMap { state.claimRemount($0.token) }?.disks == [disk("disk-system")],
               "full wake must claim exactly the pre-sleep physical target")
    }

    private static func testDisplayOnlyScreenWakeStillSchedulesRemount() {
        var state = SleepEpisodeCoordinator()
        state.displayEjectDidStart()
        _ = state.recordCleanUnmountTargets([disk("disk-display")],
                                            operationID: "display",
                                            reason: "displaySleep")
        state.displayDidWake()
        let schedule = state.wakeDidOccur(source: .screen)
        expect(schedule != nil,
               "a display-only sleep must continue to remount on screen wake")
        expect(schedule.flatMap { state.claimRemount($0.token) }?.disks == [disk("disk-display")],
               "screen wake must claim the display-only target")
    }

    private static func testDisplayAndSystemSleepOverlapWaitsForFullWake() {
        var state = SleepEpisodeCoordinator()
        state.displayEjectDidStart()
        state.systemSleepDidStart()
        _ = state.recordCleanUnmountTargets([disk("disk-overlap")],
                                            operationID: "overlap",
                                            reason: "powerSleep")
        state.displayDidWake()
        expect(state.wakeDidOccur(source: .screen) == nil,
               "display wake inside a system-sleep episode must remain DarkWake")
        expect(state.wakeDidOccur(source: .system) != nil,
               "the overlapping episode must become eligible at full-system wake")
    }

    private static func testLidOpenInsideSystemSleepWaitsForFullWake() {
        var state = SleepEpisodeCoordinator()
        _ = state.lidDidClose()
        state.systemSleepDidStart()
        _ = state.recordCleanUnmountTargets([disk("disk-lid-system")],
                                            operationID: "lid-system",
                                            reason: "clamshell")
        expect(state.lidDidOpen() == nil,
               "lid open before the ordered powered-on edge must not mount during DarkWake")
        expect(state.wakeDidOccur(source: .system) != nil,
               "full wake after lid open must schedule the retained target")
    }

    private static func testWakeWhileClosedDoesNotRemount() {
        var state = SleepEpisodeCoordinator()
        _ = state.lidDidClose()
        _ = state.recordCleanUnmountTargets([disk("disk2")], operationID: "op", reason: "clamshell")
        expect(state.wakeDidOccur() == nil, "dark wake while lid is closed must not mount")
        expect(state.pendingTargets == [disk("disk2")], "suppressed dark wake must retain target")
    }

    private static func testOpenBeforeCleanCallbackSchedulesWhenTargetArrives() {
        var state = SleepEpisodeCoordinator()
        _ = state.lidDidClose()
        expect(state.lidDidOpen() == nil, "open before callback has no target yet")
        let schedule = state.recordCleanUnmountTargets([disk("disk10")], operationID: "late", reason: "clamshell")
        expect(schedule != nil, "late clean callback after open must schedule remount")
    }

    private static func testDuplicateWakeSchedulesOnce() {
        var state = SleepEpisodeCoordinator()
        _ = state.recordCleanUnmountTargets([disk("disk4")], operationID: "display", reason: "displaySleep")
        let first = state.wakeDidOccur(source: .screen)
        let second = state.wakeDidOccur(source: .system)
        expect(first != nil && second == nil, "didWake and screensDidWake must share one scheduled token")
    }

    private static func testRecloseCancelsScheduledRemountWithoutLosingTargets() {
        var state = SleepEpisodeCoordinator()
        _ = state.recordCleanUnmountTargets([disk("disk8")], operationID: "op", reason: "sleep")
        let scheduled = state.wakeDidOccur()!
        _ = state.lidDidClose()
        expect(state.claimRemount(scheduled.token) == nil, "stale timer must be rejected after re-close")
        expect(state.pendingTargets == [disk("disk8")], "cancelled scheduled work must retain targets")
    }

    private static func testRecloseDuringActiveRemountRequeuesCanceledTargets() {
        var state = SleepEpisodeCoordinator()
        _ = state.recordCleanUnmountTargets([disk("disk1"), disk("disk3")], operationID: "op", reason: "sleep")
        let schedule = state.wakeDidOccur()!
        let work = state.claimRemount(schedule.token)!
        _ = state.lidDidClose()
        expect(!state.isRemountAllowed(work.token), "active token must become invalid when lid closes")
        expect(state.finishRemount(work.token, canceledDisks: [disk("disk3")]) == nil,
               "canceled disk must stay pending while closed")
        expect(state.pendingTargets == [disk("disk3")], "only canceled work must be requeued")
        expect(state.lidDidOpen() != nil, "next lid open must reschedule the requeued disk")
    }

    private static func testLateTargetDuringActiveRemountSchedulesFollowUp() {
        var state = SleepEpisodeCoordinator()
        _ = state.recordCleanUnmountTargets([disk("diskA")], operationID: "op", reason: "clamshell")
        let first = state.wakeDidOccur()!
        let work = state.claimRemount(first.token)!

        expect(state.recordCleanUnmountTargets([disk("diskB")], operationID: "op", reason: "clamshell") == nil,
               "a second clean target must wait while the first remount is active")
        let followUp = state.finishRemount(work.token, canceledDisks: [])
        expect(followUp != nil, "finishing the active remount must schedule the late clean target")
        let secondWork = followUp.flatMap { state.claimRemount($0.token) }
        expect(secondWork?.disks == [disk("diskB")], "follow-up work must contain only the late target")
    }

    private static func testLateTargetAfterFinishedRemountStillSchedules() {
        var state = SleepEpisodeCoordinator()
        _ = state.recordCleanUnmountTargets([disk("diskA")], operationID: "op", reason: "clamshell")
        let first = state.wakeDidOccur()!
        let work = state.claimRemount(first.token)!
        expect(state.finishRemount(work.token, canceledDisks: []) == nil,
               "a completed batch with no pending target needs no immediate follow-up")

        let late = state.recordCleanUnmountTargets([disk("diskB")], operationID: "op", reason: "clamshell")
        expect(late != nil, "a clean target arriving after the prior worker finished must still schedule")
        let lateWork = late.flatMap { state.claimRemount($0.token) }
        expect(lateWork?.disks == [disk("diskB")], "post-finish late callback must not be stranded")
    }

    private static func testManualTargetWaitsForNextWakeWithoutCancelingCurrentSchedule() {
        var coordinator = SleepEpisodeCoordinator()
        let automatic = disk("disk30", generation: 1)
        let manual = disk("disk31", generation: 2)

        _ = coordinator.recordCleanUnmountTargets(
            [automatic],
            operationID: "automatic",
            reason: "lidClose"
        )
        let currentSchedule = coordinator.wakeDidOccur()
        expect(currentSchedule != nil, "the current automatic target must schedule at wake")

        coordinator.stageCleanUnmountTargetsForNextWake(
            [manual],
            operationID: "manual",
            reason: "manualEject"
        )
        expect(coordinator.nextWakeTargets == [manual],
               "manual eject must remain isolated in the next-wake ledger")
        expect(coordinator.pendingTargets == [automatic],
               "manual eject must not enter the already-open automatic wake batch")

        let currentWork = coordinator.claimRemount(currentSchedule!.token)
        expect(currentWork?.disks == [automatic],
               "staging a manual target must not cancel or modify the current schedule")
        expect(coordinator.finishRemount(currentSchedule!.token, canceledDisks: []) == nil,
               "finishing the current remount must not consume the next-wake target")

        let nextSchedule = coordinator.wakeDidOccur()
        expect(nextSchedule != nil, "the following wake must promote the manual target")
        expect(coordinator.nextWakeTargets.isEmpty,
               "promotion must consume the next-wake ledger exactly once")
        expect(coordinator.claimRemount(nextSchedule!.token)?.disks == [manual],
               "the following wake must remount exactly the manually ejected target")
    }

    private static func testFailedEjectAndSleepTargetRemountsAtNextWake() {
        var coordinator = SleepEpisodeCoordinator()
        let cleanBeforeSleepFailure = disk("disk32", generation: 4)

        coordinator.stageCleanUnmountTargetsForNextWake(
            [cleanBeforeSleepFailure],
            operationID: "eject-and-sleep-failed",
            reason: "pmsetFailed"
        )
        expect(coordinator.pendingTargets.isEmpty,
               "a failed sleep request must not remount its clean disk without a wake")

        let schedule = coordinator.wakeDidOccur()
        expect(schedule != nil,
               "the next independent wake must promote a disk cleanly unmounted before sleep failed")
        expect(coordinator.claimRemount(schedule!.token)?.disks == [cleanBeforeSleepFailure],
               "the wake must remount the exact clean media from the failed command")
    }

    private static func testPhysicalGenerationRemainsPartOfRemountIdentity() {
        var state = SleepEpisodeCoordinator()
        let original = disk("disk7", generation: 8)
        let replacement = disk("disk7", generation: 9)
        _ = state.recordCleanUnmountTargets([original, replacement], operationID: "op", reason: "sleep")
        let schedule = state.wakeDidOccur()!
        let work = state.claimRemount(schedule.token)!

        expect(work.disks == [original, replacement],
               "a reused BSD name must not collapse two physical generations during remount")
    }

    private static func testUnknownStaleCompletionCannotInjectTargets() {
        var state = SleepEpisodeCoordinator()
        _ = state.recordCleanUnmountTargets([disk("disk1")], operationID: "op", reason: "sleep")
        _ = state.wakeDidOccur()
        let unknown = SleepEpisodeCoordinator.RemountToken(lidGeneration: 999, nonce: 999)

        expect(state.finishRemount(unknown, canceledDisks: [disk("replacement")]) == nil,
               "an unknown stale worker must not schedule work")
        expect(!state.pendingTargets.contains(disk("replacement")),
               "an unknown stale worker must not inject a disk into the current episode")
    }

    private static func testNewEjectInvalidatesStaleWakeRequest() {
        var state = SleepEpisodeCoordinator()
        state.automaticEjectDidStart(operationID: "old", reason: "sleep")
        expect(state.wakeDidOccur() == nil, "wake with no clean target has nothing to schedule")
        state.automaticEjectDidStart(operationID: "new", reason: "ejectAndSleep")
        expect(state.recordCleanUnmountTargets([disk("disk5")], operationID: "new", reason: "ejectAndSleep") == nil,
               "a later eject must not inherit an unrelated stale wake request")
    }

    private static func testNewEjectDoesNotRescheduleCanceledRemountBeforeWake() {
        var state = SleepEpisodeCoordinator()
        state.automaticEjectDidStart(operationID: "old", reason: "sleep")
        _ = state.recordCleanUnmountTargets([disk("disk6")], operationID: "old", reason: "sleep")
        let schedule = state.wakeDidOccur()!
        let work = state.claimRemount(schedule.token)!

        state.automaticEjectDidStart(operationID: "new", reason: "displaySleep")
        expect(state.finishRemount(work.token, canceledDisks: work.disks) == nil,
               "a new eject must keep canceled targets pending until its next wake")
        expect(state.pendingTargets == [disk("disk6")], "canceled target must remain preserved")
        expect(state.wakeDidOccur() != nil, "the next real wake must schedule the preserved target")
    }

    private static func testNewSystemSleepInvalidatesActiveRemountWithoutLosingTarget() {
        var state = SleepEpisodeCoordinator()
        let target = disk("disk-resleep")
        _ = state.recordCleanUnmountTargets([target], operationID: "old", reason: "displaySleep")
        let schedule = state.wakeDidOccur(source: .screen)!
        let work = state.claimRemount(schedule.token)!

        state.systemSleepDidStart()
        expect(!state.isRemountAllowed(work.token),
               "a new system sleep must cancel an active wake worker")
        expect(state.hasAutomaticLibraryAppRelaunchOwner,
               "an invalidated worker must retain library ownership until it requeues its target")
        expect(state.finishRemount(work.token, canceledDisks: [target]) == nil,
               "the canceled worker must requeue its target behind the new sleep boundary")
        expect(state.scheduleAfterObservedWake() == nil,
               "an old deferred callback must not clear the newer system-sleep gate")
        expect(state.wakeDidOccur(source: .screen) == nil,
               "DarkWake of the newer sleep must remain suppressed")
        let nextSchedule = state.wakeDidOccur(source: .system)
        expect(nextSchedule != nil,
               "the newer full wake must schedule the requeued target")
        let nextWork = nextSchedule.flatMap { state.claimRemount($0.token) }
        expect(nextWork?.disks == [target],
               "the newer wake must claim the exact target returned by the canceled worker")
        _ = nextWork.flatMap { state.finishRemount($0.token, canceledDisks: []) }
        expect(!state.hasAutomaticLibraryAppRelaunchOwner,
               "library ownership may end only after the replacement remount finishes")
    }

    private static func testMatchingLidSleepGetsOnlyOneFailedEpisodeRetry() {
        expect(
            SleepLidRetryPolicy.shouldStartPowerRetry(
                priorSucceeded: false,
                isSleepBoundaryTrigger: true,
                retryAlreadyStarted: false,
                hasActiveOperation: false
            ),
            "a failed lid eject must get one retry at its matching recent sleep boundary"
        )
        expect(
            !SleepLidRetryPolicy.shouldStartPowerRetry(
                priorSucceeded: false,
                isSleepBoundaryTrigger: false,
                retryAlreadyStarted: false,
                hasActiveOperation: false
            ),
            "duplicate clamshell notifications must not retry a failed episode"
        )
        expect(
            !SleepLidRetryPolicy.shouldStartPowerRetry(
                priorSucceeded: false,
                isSleepBoundaryTrigger: true,
                retryAlreadyStarted: true,
                hasActiveOperation: false
            ),
            "the late sleep boundary must not start a second retry"
        )
        expect(
            !SleepLidRetryPolicy.shouldStartPowerRetry(
                priorSucceeded: true,
                isSleepBoundaryTrigger: true,
                retryAlreadyStarted: false,
                hasActiveOperation: false
            ),
            "a successful close-time eject must be joined without retry"
        )
        expect(
            !SleepLidRetryPolicy.shouldStartPowerRetry(
                priorSucceeded: false,
                isSleepBoundaryTrigger: true,
                retryAlreadyStarted: false,
                hasActiveOperation: true
            ),
            "a sleep boundary must join an active eject instead of overlapping it"
        )
    }

    private static func testNewCloseGenerationJoinedToActiveWorkRequiresFreshInventory() {
        expect(
            SleepLidInventoryPolicy.needsRefreshAfterJoiningActive(
                previousGeneration: 4,
                requestedGeneration: 5
            ),
            "a new close generation must take a fresh inventory after older active work"
        )
        expect(
            !SleepLidInventoryPolicy.needsRefreshAfterJoiningActive(
                previousGeneration: 5,
                requestedGeneration: 5
            ),
            "duplicate callbacks in the same close generation must only join"
        )
        expect(
            SleepLidInventoryPolicy.needsBoundaryRefresh(
                currentClosedGeneration: 6,
                completedInventoryGeneration: 5,
                generationRefreshPending: false
            ),
            "a newer close generation must keep the power boundary open until its inventory completes"
        )
        expect(
            !SleepLidInventoryPolicy.needsBoundaryRefresh(
                currentClosedGeneration: 6,
                completedInventoryGeneration: 6,
                generationRefreshPending: false
            ),
            "the current close generation may finish after its own inventory completes"
        )
        expect(
            SleepLidInventoryPolicy.needsBoundaryRefresh(
                currentClosedGeneration: 6,
                completedInventoryGeneration: 6,
                generationRefreshPending: true
            ),
            "a mounted-media event must override a completed generation"
        )
    }

    private static func testRepeatedLidJoinPreservesEpisodeForceLedger() {
        expect(
            !SleepLidInventoryPolicy.shouldReplaceForceClaimLedger(
                previousGeneration: 9,
                requestedGeneration: 9,
                hasExistingLedger: true
            ),
            "a repeated WillSleep join must not overwrite the current lid episode force ledger"
        )
        expect(
            SleepLidInventoryPolicy.shouldReplaceForceClaimLedger(
                previousGeneration: 8,
                requestedGeneration: 9,
                hasExistingLedger: true
            ),
            "a new physical close generation must receive a new force ledger"
        )
        expect(
            SleepLidInventoryPolicy.shouldReplaceForceClaimLedger(
                previousGeneration: 9,
                requestedGeneration: 9,
                hasExistingLedger: false
            ),
            "a missing current-generation ledger must be initialized"
        )
    }

    private static func testCurrentLidRefreshPrefersItsEpisodeForceLedger() {
        expect(
            SleepLidInventoryPolicy.shouldPreferExistingForceClaimLedger(
                episodeGeneration: 12,
                requestedGeneration: 12,
                hasExistingLedger: true
            ),
            "a boundary refresh must not overwrite the current close episode ledger"
        )
        expect(
            !SleepLidInventoryPolicy.shouldPreferExistingForceClaimLedger(
                episodeGeneration: 11,
                requestedGeneration: 12,
                hasExistingLedger: true
            ),
            "a stale generation ledger must not bleed into a new close episode"
        )
        expect(
            !SleepLidInventoryPolicy.shouldPreferExistingForceClaimLedger(
                episodeGeneration: 12,
                requestedGeneration: 12,
                hasExistingLedger: false
            ),
            "a missing current-generation ledger must use the supplied or fresh fallback"
        )
    }

    private static func testPowerBoundaryWaitsForRefreshAndRetriesAtMostOnce() {
        expect(
            PowerBoundaryEjectPolicy.nextAction(
                deadlineRemaining: true,
                hasDifferentActiveOperation: true,
                inventoryRefreshPending: true,
                hasRunFreshBoundaryInventory: false,
                lastAttemptSucceeded: true,
                retryAlreadyStarted: false
            ) == .waitForActive,
            "a power boundary must first wait for any newer active eject"
        )
        expect(
            PowerBoundaryEjectPolicy.nextAction(
                deadlineRemaining: true,
                hasDifferentActiveOperation: false,
                inventoryRefreshPending: true,
                hasRunFreshBoundaryInventory: true,
                lastAttemptSucceeded: true,
                retryAlreadyStarted: false
            ) == .refreshInventory,
            "pending media refresh must remain inside the power ACK chain"
        )
        expect(
            PowerBoundaryEjectPolicy.nextAction(
                deadlineRemaining: true,
                hasDifferentActiveOperation: false,
                inventoryRefreshPending: false,
                hasRunFreshBoundaryInventory: false,
                lastAttemptSucceeded: true,
                retryAlreadyStarted: false
            ) == .refreshInventory,
            "joining an older task must still run a fresh power-boundary inventory"
        )
        expect(
            PowerBoundaryEjectPolicy.nextAction(
                deadlineRemaining: true,
                hasDifferentActiveOperation: false,
                inventoryRefreshPending: false,
                hasRunFreshBoundaryInventory: true,
                lastAttemptSucceeded: false,
                retryAlreadyStarted: false
            ) == .retry,
            "one failed fresh boundary attempt may retry within the deadline"
        )
        expect(
            PowerBoundaryEjectPolicy.nextAction(
                deadlineRemaining: true,
                hasDifferentActiveOperation: false,
                inventoryRefreshPending: false,
                hasRunFreshBoundaryInventory: true,
                lastAttemptSucceeded: false,
                retryAlreadyStarted: true
            ) == .finish,
            "a second failed boundary attempt must not start another retry"
        )
        expect(
            PowerBoundaryEjectPolicy.nextAction(
                deadlineRemaining: false,
                hasDifferentActiveOperation: true,
                inventoryRefreshPending: true,
                hasRunFreshBoundaryInventory: false,
                lastAttemptSucceeded: false,
                retryAlreadyStarted: false
            ) == .finish,
            "the absolute power deadline must stop the chain"
        )
    }
}
