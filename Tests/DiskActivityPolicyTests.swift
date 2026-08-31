import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum DiskActivityPolicyTests {
    static func main() {
        testInactiveGraceAndClear()
        testReactivationResetsGrace()
        testLowVolumeIOOnlySustainsExistingActivity()
        testDirectionsAndDisksRemainIndependent()
        testMultipleDisksRemainIndependent()
        testRemovedDiskClearsImmediately()
        testMountedReconciliationClearsOnlyUnmountedDisk()
        testMountedPhysicalDiskAggregation()
        testForcedSleepActivityRequiresCompleteMapping()
        testForcedSleepActivityRequiresValidDeltaSamples()
        testForcedSleepActivityDetectsEitherDirection()
        testForcedSleepActivityProtectsWholePhysicalSet()
        testForcedSleepCounterDeltaValidation()
        testForcedSleepCounterAvailabilityFailsClosed()
        testInventoryRevisionInvalidatesSameBSDCertainty()
        testForcedSleepActivityRequiresMatchingInventoryRevision()
        testForcedSleepPhysicalRequestClosure()
        testForcedSleepPhysicalProtectionUsesTrueBackingClosure()
        testForcedSleepPhysicalRequestUniquenessFailsClosed()
        testIdleRequestOverlappingActiveOrUnknownMultiBackingRequestIsBlocked()
        testForcedSleepRapidRefreshesDoNotConsumeTimeGrace()
        testResetClearsAllState()
        testActivityMediaClassification()
        print("DiskActivityPolicyTests: PASS")
    }

    private static func testInactiveGraceAndClear() {
        var state = DiskActivityState(inactivePollLimit: 3)
        let present: Set<String> = ["disk6"]

        var snapshot = state.update(
            detectedWriting: ["disk6"],
            detectedReading: [],
            observedWriting: ["disk6"],
            observedReading: [],
            presentDisks: present
        )
        expect(snapshot.writing == ["disk6"], "detected write activates immediately")

        snapshot = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        expect(snapshot.writing == ["disk6"], "first inactive poll preserves activity")
        snapshot = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        expect(snapshot.writing == ["disk6"], "second inactive poll preserves activity")
        snapshot = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        expect(snapshot == .inactive, "third inactive poll clears activity")
    }

    private static func testReactivationResetsGrace() {
        var state = DiskActivityState(inactivePollLimit: 3)
        let present: Set<String> = ["disk6"]

        _ = state.update(
            detectedWriting: ["disk6"], detectedReading: [],
            observedWriting: ["disk6"], observedReading: [],
            presentDisks: present
        )
        _ = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        _ = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        _ = state.update(
            detectedWriting: ["disk6"], detectedReading: [],
            observedWriting: ["disk6"], observedReading: [],
            presentDisks: present
        )
        _ = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        let snapshot = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )

        expect(snapshot.writing == ["disk6"], "new activity resets the inactive countdown")
    }

    private static func testLowVolumeIOOnlySustainsExistingActivity() {
        var state = DiskActivityState(inactivePollLimit: 3)
        let present: Set<String> = ["disk6"]

        var snapshot = state.update(
            detectedWriting: [],
            detectedReading: [],
            observedWriting: ["disk6"],
            observedReading: [],
            presentDisks: present
        )
        expect(snapshot == .inactive, "sub-threshold I/O does not activate an idle disk")

        _ = state.update(
            detectedWriting: ["disk6"],
            detectedReading: [],
            observedWriting: ["disk6"],
            observedReading: [],
            presentDisks: present
        )
        _ = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        _ = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        snapshot = state.update(
            detectedWriting: [],
            detectedReading: [],
            observedWriting: ["disk6"],
            observedReading: [],
            presentDisks: present
        )
        expect(snapshot.writing == ["disk6"], "sub-threshold I/O sustains an active disk")

        _ = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        snapshot = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: present
        )
        expect(snapshot.writing == ["disk6"], "sustain signal resets the inactive countdown")
    }

    private static func testDirectionsAndDisksRemainIndependent() {
        var state = DiskActivityState(inactivePollLimit: 3)
        let present: Set<String> = ["disk6", "disk8"]

        _ = state.update(
            detectedWriting: ["disk6"],
            detectedReading: ["disk8"],
            observedWriting: ["disk6"],
            observedReading: ["disk8"],
            presentDisks: present
        )
        _ = state.update(
            detectedWriting: [], detectedReading: ["disk8"],
            observedWriting: [], observedReading: ["disk8"],
            presentDisks: present
        )
        _ = state.update(
            detectedWriting: [], detectedReading: ["disk8"],
            observedWriting: [], observedReading: ["disk8"],
            presentDisks: present
        )
        let snapshot = state.update(
            detectedWriting: [],
            detectedReading: ["disk8"],
            observedWriting: [],
            observedReading: ["disk8"],
            presentDisks: present
        )

        expect(snapshot.writing.isEmpty, "idle writing disk clears independently")
        expect(snapshot.reading == ["disk8"], "active reading disk remains independently")
    }

    private static func testMultipleDisksRemainIndependent() {
        var state = DiskActivityState(inactivePollLimit: 3)
        let present: Set<String> = ["disk6", "disk8"]

        _ = state.update(
            detectedWriting: ["disk6", "disk8"],
            detectedReading: [],
            observedWriting: ["disk6", "disk8"],
            observedReading: [],
            presentDisks: present
        )
        for _ in 0..<3 {
            _ = state.update(
                detectedWriting: [],
                detectedReading: [],
                observedWriting: ["disk6"],
                observedReading: [],
                presentDisks: present
            )
        }
        let snapshot = state.update(
            detectedWriting: [],
            detectedReading: [],
            observedWriting: ["disk6"],
            observedReading: [],
            presentDisks: present
        )

        expect(snapshot.writing == ["disk6"], "one idle disk does not clear another active disk")
    }

    private static func testRemovedDiskClearsImmediately() {
        var state = DiskActivityState(inactivePollLimit: 3)
        _ = state.update(
            detectedWriting: ["disk6"],
            detectedReading: ["disk6"],
            observedWriting: ["disk6"],
            observedReading: ["disk6"],
            presentDisks: ["disk6"]
        )
        let snapshot = state.update(
            detectedWriting: [],
            detectedReading: [],
            observedWriting: [],
            observedReading: [],
            presentDisks: []
        )

        expect(snapshot == .inactive, "removed disk bypasses inactivity grace")
    }

    private static func testMountedReconciliationClearsOnlyUnmountedDisk() {
        var state = DiskActivityState(inactivePollLimit: 3)
        _ = state.update(
            detectedWriting: ["disk6"],
            detectedReading: ["disk8"],
            observedWriting: ["disk6"],
            observedReading: ["disk8"],
            presentDisks: ["disk6", "disk8"]
        )
        _ = state.update(
            detectedWriting: ["disk6"], detectedReading: [],
            observedWriting: ["disk6"], observedReading: [],
            presentDisks: ["disk6", "disk8"]
        )

        var snapshot = state.reconcilePresentDisks(["disk8"])
        expect(snapshot.writing.isEmpty, "unmounted writing disk clears immediately")
        expect(snapshot.reading == ["disk8"], "mounted disk activity remains intact")

        snapshot = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: ["disk8"]
        )
        expect(snapshot.reading == ["disk8"], "reconciliation preserves remaining disk grace")

        snapshot = state.update(
            detectedWriting: [], detectedReading: [],
            observedWriting: [], observedReading: [],
            presentDisks: ["disk8"]
        )
        expect(snapshot == .inactive, "reconciliation does not reset the remaining grace counter")

        _ = state.update(
            detectedWriting: ["disk8"], detectedReading: [],
            observedWriting: ["disk8"], observedReading: [],
            presentDisks: ["disk8"]
        )
        snapshot = state.reconcilePresentDisks([])
        expect(snapshot == .inactive, "empty mounted inventory clears all activity immediately")
    }

    private static func testMountedPhysicalDiskAggregation() {
        let none: [Set<String>?] = []
        expect(MountedPhysicalDiskFilterPolicy.aggregate(none) == Set<String>(),
               "zero mounted volumes resolves to an empty filter")

        let siblings: [Set<String>?] = [["disk6"], ["disk6"]]
        expect(MountedPhysicalDiskFilterPolicy.aggregate(siblings) == ["disk6"],
               "sibling volumes on one physical disk collapse to one filter entry")

        let separate: [Set<String>?] = [["disk6"], ["disk8"]]
        expect(MountedPhysicalDiskFilterPolicy.aggregate(separate) == ["disk6", "disk8"],
               "separate physical disks remain independent")

        let unresolved: [Set<String>?] = [["disk6"], nil]
        expect(MountedPhysicalDiskFilterPolicy.aggregate(unresolved) == nil,
               "one unresolved volume makes the whole filter unresolved")

        let partialEmpty: [Set<String>?] = [["disk6"], []]
        expect(MountedPhysicalDiskFilterPolicy.aggregate(partialEmpty) == nil,
               "an empty partial mapping cannot become a restrictive filter")
    }

    private static func testForcedSleepRapidRefreshesDoNotConsumeTimeGrace() {
        var state = ForcedSleepRecentActivityState(retentionNanoseconds: 4_500)

        var snapshot = state.update(
            observedWriting: ["disk6"],
            observedReading: [],
            presentDisks: ["disk6"],
            nowNanoseconds: 100
        )
        expect(snapshot.writing == ["disk6"], "forced-sleep activity activates immediately")

        for now in [101, 102, 103] as [UInt64] {
            snapshot = state.update(
                observedWriting: [],
                observedReading: [],
                presentDisks: ["disk6"],
                nowNanoseconds: now
            )
        }
        expect(snapshot.writing == ["disk6"],
               "rapid submission refreshes cannot consume a time-based activity grace")

        snapshot = state.update(
            observedWriting: [],
            observedReading: [],
            presentDisks: ["disk6"],
            nowNanoseconds: 4_599
        )
        expect(snapshot.writing == ["disk6"], "activity remains before the retention deadline")

        snapshot = state.update(
            observedWriting: [],
            observedReading: [],
            presentDisks: ["disk6"],
            nowNanoseconds: 4_600
        )
        expect(snapshot == .inactive, "activity clears when real retention time has elapsed")

        _ = state.update(
            observedWriting: [],
            observedReading: ["disk6"],
            presentDisks: ["disk6"],
            nowNanoseconds: 5_000
        )
        snapshot = state.update(
            observedWriting: [],
            observedReading: [],
            presentDisks: [],
            nowNanoseconds: 5_001
        )
        expect(snapshot == .inactive, "a physically absent disk clears without waiting")
    }

    private static func testForcedSleepActivityRequiresCompleteMapping() {
        let unavailable = ForcedSleepActivitySnapshot(
            inventoryRevision: 41,
            mountedPhysicalDisks: nil,
            validDeltaSampledDisks: ["disk6"],
            writing: [],
            reading: []
        )
        expect(unavailable.assessment(for: ["disk6"], expectedInventoryRevision: 41) == .unknown,
               "unavailable physical mapping fails closed")

        let incomplete = ForcedSleepActivitySnapshot(
            inventoryRevision: 41,
            mountedPhysicalDisks: ["disk6"],
            validDeltaSampledDisks: ["disk6", "disk8"],
            writing: [],
            reading: []
        )
        expect(incomplete.assessment(for: ["disk6", "disk8"], expectedInventoryRevision: 41) == .unknown,
               "a backing disk missing from mounted mapping fails closed")
        expect(incomplete.assessment(for: [], expectedInventoryRevision: 41) == .unknown,
               "an empty backing-disk resolution cannot become an idle candidate")
    }

    private static func testForcedSleepActivityRequiresValidDeltaSamples() {
        let baselineOnly = ForcedSleepActivitySnapshot(
            inventoryRevision: 41,
            mountedPhysicalDisks: ["disk6"],
            validDeltaSampledDisks: [],
            writing: [],
            reading: []
        )
        expect(baselineOnly.assessment(for: ["disk6"], expectedInventoryRevision: 41) == .unknown,
               "the first baseline poll has no valid delta and remains unknown")

        let newSibling = ForcedSleepActivitySnapshot(
            inventoryRevision: 41,
            mountedPhysicalDisks: ["disk6", "disk8"],
            validDeltaSampledDisks: ["disk6"],
            writing: [],
            reading: []
        )
        expect(newSibling.assessment(for: ["disk6", "disk8"], expectedInventoryRevision: 41) == .unknown,
               "one newly attached unsampled backing disk protects the whole set")

        let counterReset = ForcedSleepActivitySnapshot(
            inventoryRevision: 41,
            mountedPhysicalDisks: ["disk6"],
            validDeltaSampledDisks: [],
            writing: ["disk6"],
            reading: []
        )
        expect(counterReset.assessment(for: ["disk6"], expectedInventoryRevision: 41) == .unknown,
               "counter reset removes sample certainty even if stale activity remains")

        let validIdle = ForcedSleepActivitySnapshot(
            inventoryRevision: 41,
            mountedPhysicalDisks: ["disk6"],
            validDeltaSampledDisks: ["disk6"],
            writing: [],
            reading: []
        )
        expect(validIdle.assessment(for: ["disk6"], expectedInventoryRevision: 41) == .idle,
               "a fully mapped, validly sampled inactive disk is idle")
    }

    private static func testForcedSleepActivityDetectsEitherDirection() {
        let writing = ForcedSleepActivitySnapshot(
            inventoryRevision: 41,
            mountedPhysicalDisks: ["disk6", "disk8"],
            validDeltaSampledDisks: ["disk6", "disk8"],
            writing: ["disk6"],
            reading: []
        )
        expect(writing.assessment(for: ["disk6"], expectedInventoryRevision: 41) == .active,
               "valid write activity marks its backing disk active")
        expect(writing.assessment(for: ["disk8"], expectedInventoryRevision: 41) == .idle,
               "activity on an unrelated physical disk does not block an idle disk")

        let reading = ForcedSleepActivitySnapshot(
            inventoryRevision: 41,
            mountedPhysicalDisks: ["disk6"],
            validDeltaSampledDisks: ["disk6"],
            writing: [],
            reading: ["disk6"]
        )
        expect(reading.assessment(for: ["disk6"], expectedInventoryRevision: 41) == .active,
               "valid read activity marks its backing disk active")
    }

    private static func testForcedSleepActivityProtectsWholePhysicalSet() {
        let oneActiveSibling = ForcedSleepActivitySnapshot(
            inventoryRevision: 41,
            mountedPhysicalDisks: ["disk6"],
            validDeltaSampledDisks: ["disk6"],
            writing: ["disk6"],
            reading: []
        )
        expect(oneActiveSibling.assessment(for: ["disk6"], expectedInventoryRevision: 41) == .active,
               "sibling volumes sharing one physical BSD inherit its activity")

        let oneActiveBackingDisk = ForcedSleepActivitySnapshot(
            inventoryRevision: 41,
            mountedPhysicalDisks: ["disk6", "disk8"],
            validDeltaSampledDisks: ["disk6"],
            writing: ["disk6"],
            reading: []
        )
        expect(oneActiveBackingDisk.assessment(for: ["disk6", "disk8"], expectedInventoryRevision: 41) == .active,
               "one validly sampled active disk protects a multi-disk backing set")
    }

    private static func testForcedSleepCounterDeltaValidation() {
        expect(DiskIOCounterDeltaPolicy.validatedDelta(
            previous: nil,
            current: (read: 100, write: 200)
        ) == nil, "a baseline-only or new disk sample is uncertain")
        expect(DiskIOCounterDeltaPolicy.validatedDelta(
            previous: (read: 100, write: 200),
            current: (read: 99, write: 201)
        ) == nil, "a read counter reset invalidates the whole disk sample")
        expect(DiskIOCounterDeltaPolicy.validatedDelta(
            previous: (read: 100, write: 200),
            current: (read: 101, write: 199)
        ) == nil, "a write counter reset invalidates the whole disk sample")
        expect(DiskIOCounterDeltaPolicy.validatedDelta(
            previous: (read: 100, write: 200),
            current: (read: 103, write: 205)
        ) == DiskIOValidatedDelta(read: 3, write: 5),
        "monotonic counters produce an exact valid delta")
        expect(DiskIOCounterDeltaPolicy.validatedDelta(
            previous: (read: 100, write: 200),
            current: (read: 100, write: 200)
        ) == DiskIOValidatedDelta(read: 0, write: 0),
        "a valid zero delta can prove inactivity for this interval")
    }

    private static func testForcedSleepCounterAvailabilityFailsClosed() {
        expect(DiskIOCounterAvailabilityPolicy.counters(read: nil, write: nil) == nil,
               "missing read and write counters cannot prove idle")
        expect(DiskIOCounterAvailabilityPolicy.counters(read: 10, write: nil) == nil,
               "a missing write counter cannot be replaced with zero")
        expect(DiskIOCounterAvailabilityPolicy.counters(read: nil, write: 10) == nil,
               "a missing read counter cannot be replaced with zero")
        expect(DiskIOCounterAvailabilityPolicy.counters(read: 10, write: 20)
            == DiskIOByteCounters(read: 10, write: 20),
        "both IORegistry counters are required for a certainty-eligible sample")
    }

    private static func testInventoryRevisionInvalidatesSameBSDCertainty() {
        expect(DiskActivityInventoryGenerationPolicy.shouldReset(
            previousDisks: ["disk6"],
            newDisks: ["disk6"],
            previousRevision: 40,
            newRevision: 41
        ), "same-BSD unplug/replug or topology revision invalidates the old baseline")
        expect(DiskActivityInventoryGenerationPolicy.shouldReset(
            previousDisks: ["disk6"],
            newDisks: ["disk6", "disk8"],
            previousRevision: 41,
            newRevision: 41
        ), "a physical mapping change invalidates the old baseline")
        expect(!DiskActivityInventoryGenerationPolicy.shouldReset(
            previousDisks: ["disk6"],
            newDisks: ["disk6"],
            previousRevision: 41,
            newRevision: 41
        ), "an unchanged exact inventory generation preserves the current sample")
    }

    private static func testForcedSleepActivityRequiresMatchingInventoryRevision() {
        let snapshot = ForcedSleepActivitySnapshot(
            inventoryRevision: 40,
            mountedPhysicalDisks: ["disk6"],
            validDeltaSampledDisks: ["disk6"],
            writing: [],
            reading: []
        )
        expect(snapshot.assessment(
            for: ["disk6"],
            expectedInventoryRevision: 41
        ) == .unknown,
        "an idle sample from a prior DA inventory generation must fail closed")
        expect(snapshot.assessment(
            for: ["disk6"],
            expectedInventoryRevision: 40
        ) == .idle,
        "an exact inventory-generation match may retain a valid idle sample")
    }

    private static func testForcedSleepPhysicalRequestClosure() {
        let snapshot = ForcedSleepActivitySnapshot(
            inventoryRevision: 41,
            mountedPhysicalDisks: ["disk6", "disk8"],
            validDeltaSampledDisks: ["disk6", "disk8"],
            writing: ["disk6"],
            reading: []
        )
        expect(ForcedSleepPhysicalRequestActivityPolicy.assessment(
            backingResolutions: [["disk6"], ["disk6"]],
            snapshot: snapshot,
            expectedInventoryRevision: 41
        ) == .active, "one active sibling volume protects its whole physical SSD")
        expect(ForcedSleepPhysicalRequestActivityPolicy.assessment(
            backingResolutions: [["disk8"], ["disk8"]],
            snapshot: snapshot,
            expectedInventoryRevision: 41
        ) == .idle, "a fully resolved separate idle SSD remains eligible")
        expect(ForcedSleepPhysicalRequestActivityPolicy.assessment(
            backingResolutions: [["disk8"], nil],
            snapshot: snapshot,
            expectedInventoryRevision: 41
        ) == .unknown, "one unresolved sibling protects the entire unmount request")
        expect(ForcedSleepPhysicalRequestActivityPolicy.assessment(
            backingResolutions: [],
            snapshot: snapshot,
            expectedInventoryRevision: 41
        ) == .unknown, "an empty request cannot become an idle candidate")
    }

    private static func testForcedSleepPhysicalProtectionUsesTrueBackingClosure() {
        let sharedSSD = ForcedSleepPhysicalProtectionPolicy.evaluate([
            ForcedSleepPhysicalProtectionCandidate(
                backingPhysicalDisks: ["disk4"],
                isEjectTarget: true,
                isProtected: false
            ),
            ForcedSleepPhysicalProtectionCandidate(
                backingPhysicalDisks: ["disk4"],
                isEjectTarget: true,
                isProtected: true
            ),
            ForcedSleepPhysicalProtectionCandidate(
                backingPhysicalDisks: ["disk8"],
                isEjectTarget: true,
                isProtected: false
            )
        ])
        expect(sharedSSD.allowedTargetIndices == [2],
               "a protected APFS/container volume must block every target on the same backing SSD")
        expect(sharedSSD.blockedTargetIndices == [0],
               "the unprotected sibling on the protected SSD must be reported as blocked")

        let initiallyUnprotected = ForcedSleepPhysicalProtectionPolicy.evaluate([
            ForcedSleepPhysicalProtectionCandidate(
                backingPhysicalDisks: ["disk4"],
                isEjectTarget: true,
                isProtected: false
            ),
            ForcedSleepPhysicalProtectionCandidate(
                backingPhysicalDisks: ["disk4"],
                isEjectTarget: false,
                isProtected: false
            )
        ])
        expect(ForcedSleepProtectionRevalidationPolicy.allowsSubmission(
            requestTargetIndices: [0],
            currentDecision: initiallyUnprotected
        ), "an unchanged unprotected physical closure remains eligible")
        let becameProtected = ForcedSleepPhysicalProtectionPolicy.evaluate([
            ForcedSleepPhysicalProtectionCandidate(
                backingPhysicalDisks: ["disk4"],
                isEjectTarget: true,
                isProtected: false
            ),
            ForcedSleepPhysicalProtectionCandidate(
                backingPhysicalDisks: ["disk4"],
                isEjectTarget: false,
                isProtected: true
            )
        ])
        expect(!ForcedSleepProtectionRevalidationPolicy.allowsSubmission(
            requestTargetIndices: [0],
            currentDecision: becameProtected
        ), "a newly excluded or Time Machine sibling must deny final submission")

        let unresolvedProtected = ForcedSleepPhysicalProtectionPolicy.evaluate([
            ForcedSleepPhysicalProtectionCandidate(
                backingPhysicalDisks: nil,
                isEjectTarget: false,
                isProtected: true
            ),
            ForcedSleepPhysicalProtectionCandidate(
                backingPhysicalDisks: ["disk8"],
                isEjectTarget: true,
                isProtected: false
            )
        ])
        expect(unresolvedProtected.allowedTargetIndices.isEmpty,
               "an unresolved protected volume must fail closed for the entire forced batch")
        expect(unresolvedProtected.blockedTargetIndices == [1],
               "all otherwise eligible targets are blocked when protected backing identity is unknown")

        let unresolvedTarget = ForcedSleepPhysicalProtectionPolicy.evaluate([
            ForcedSleepPhysicalProtectionCandidate(
                backingPhysicalDisks: nil,
                isEjectTarget: true,
                isProtected: false
            ),
            ForcedSleepPhysicalProtectionCandidate(
                backingPhysicalDisks: ["disk8"],
                isEjectTarget: true,
                isProtected: false
            )
        ])
        expect(unresolvedTarget.allowedTargetIndices.isEmpty
            && unresolvedTarget.blockedTargetIndices == [0, 1],
        "an unresolved target must block the whole batch so a Whole request cannot catch it")
    }

    private static func testForcedSleepPhysicalRequestUniquenessFailsClosed() {
        let distinct = ForcedSleepPhysicalRequestUniquenessPolicy.evaluate(
            backingPhysicalDisksByRequest: [["disk4"], ["disk8"]]
        )
        expect(distinct.allowedRequestIndices == [0, 1]
            && distinct.blockedRequestIndices.isEmpty,
        "independent physical disks may each receive one normal request")

        let overlappingContainers = ForcedSleepPhysicalRequestUniquenessPolicy.evaluate(
            backingPhysicalDisksByRequest: [["disk4"], ["disk4"]]
        )
        expect(overlappingContainers.allowedRequestIndices.isEmpty
            && overlappingContainers.blockedRequestIndices == [0, 1],
        "two logical whole-disk requests sharing one SSD must both fail closed")

        let unresolved = ForcedSleepPhysicalRequestUniquenessPolicy.evaluate(
            backingPhysicalDisksByRequest: [["disk4"], nil]
        )
        expect(unresolved.allowedRequestIndices.isEmpty
            && unresolved.blockedRequestIndices == [0, 1],
        "unresolved request ownership must fail closed for the whole forced batch")
    }

    private static func testIdleRequestOverlappingActiveOrUnknownMultiBackingRequestIsBlocked() {
        let activeOverlap = ForcedSleepPhysicalBatchEligibilityPolicy.evaluate(
            backingPhysicalDisksByRequest: [["disk4"], ["disk4", "disk8"]],
            assessments: [.idle, .active]
        )
        expect(activeOverlap.allowedRequestIndices.isEmpty,
               "an active multi-backing request must protect an overlapping idle request")
        expect(activeOverlap.ownershipBlockedRequestIndices == [0, 1],
               "physical overlap is closed across the full batch before activity filtering")

        let unknownOverlap = ForcedSleepPhysicalBatchEligibilityPolicy.evaluate(
            backingPhysicalDisksByRequest: [["disk4"], ["disk4", "disk8"], ["disk10"]],
            assessments: [.idle, .unknown, .idle]
        )
        expect(unknownOverlap.allowedRequestIndices == [2],
               "an unrelated uniquely owned idle disk remains eligible")
        expect(unknownOverlap.ownershipBlockedRequestIndices == [0, 1],
               "an unknown overlapping request protects every member of that physical component")

        let uniqueActivity = ForcedSleepPhysicalBatchEligibilityPolicy.evaluate(
            backingPhysicalDisksByRequest: [["disk4"], ["disk8"], ["disk10"]],
            assessments: [.idle, .active, .unknown]
        )
        expect(uniqueActivity.allowedRequestIndices == [0],
               "only uniquely owned confirmed-idle requests may be submitted")
        expect(uniqueActivity.activityBlockedRequestIndices == [1, 2],
               "active and unknown unique requests remain mounted")
    }

    private static func testResetClearsAllState() {
        var state = DiskActivityState(inactivePollLimit: 3)
        _ = state.update(
            detectedWriting: ["disk6"],
            detectedReading: ["disk8"],
            observedWriting: ["disk6"],
            observedReading: ["disk8"],
            presentDisks: ["disk6", "disk8"]
        )

        expect(state.reset() == .inactive, "explicit reset clears every disk and direction")
    }

    private static func testActivityMediaClassification() {
        expect(DiskActivityMediaPolicy.shouldInclude(
            physicalLocation: "External",
            busProtocol: "USB",
            isRemovable: false,
            isEjectable: false
        ), "external SSD remains included")

        expect(DiskActivityMediaPolicy.shouldInclude(
            physicalLocation: "Internal",
            busProtocol: "Secure Digital",
            isRemovable: true,
            isEjectable: true
        ), "built-in SDXC media is included")

        expect(!DiskActivityMediaPolicy.shouldInclude(
            physicalLocation: "Internal",
            busProtocol: "PCI",
            isRemovable: false,
            isEjectable: false
        ), "internal SSD remains excluded")

        expect(!DiskActivityMediaPolicy.shouldInclude(
            physicalLocation: "File",
            busProtocol: "Virtual Interface",
            isRemovable: true,
            isEjectable: true
        ), "disk image remains excluded")

        expect(!DiskActivityMediaPolicy.shouldInclude(
            physicalLocation: nil,
            busProtocol: "USB",
            isRemovable: true,
            isEjectable: true
        ), "missing location fails closed")
    }
}
