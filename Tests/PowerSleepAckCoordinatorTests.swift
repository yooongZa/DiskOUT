import Foundation
import IOKit

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private final class AckRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let result: IOReturn
    private var ids: [Int] = []

    init(result: IOReturn = KERN_SUCCESS) {
        self.result = result
    }

    func record(_ id: Int) -> IOReturn {
        lock.lock()
        ids.append(id)
        lock.unlock()
        return result
    }

    var snapshot: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}

@main
private enum PowerSleepAckCoordinatorTests {
    static func main() {
        testCanSystemSleepThenWillSleepIsIdle()
        testWillSleepWithoutIdleCandidateIsForced()
        testAdvanceEpochClearsIdleCandidate()
        testWillSleepDeduplicationAndNotificationIDReuse()
        testCompletionAndDeadlineEachAckOnce()
        testSynchronousBoundaryCommitAcksBeforeGroupCompletion()
        testDuplicateKeyAndDifferentMessageTypes()
        testEpochAllowsNotificationIDReuse()
        testShutdownDrainsPendingAndInvalidatesLateCompletion()
        testCompletionDeadlineRace()
        testAllowErrorDoesNotRetry()
        testDeadlineStartsAtAPICallBeforeQueueBacklog()
        print("PowerSleepAckCoordinatorTests: PASS")
    }

    private static func testCanSystemSleepThenWillSleepIsIdle() {
        var deduplicator = PowerSleepCycleDeduplicator()
        deduplicator.recordCanSystemSleep()

        expect(deduplicator.beginWillSleep(notificationID: 1) == .idle,
               "CanSystemSleep followed by the first unique WillSleep must be classified as idle")
    }

    private static func testWillSleepWithoutIdleCandidateIsForced() {
        var deduplicator = PowerSleepCycleDeduplicator()

        expect(deduplicator.beginWillSleep(notificationID: 2) == .forced,
               "WillSleep without a preceding CanSystemSleep must be classified as forced")
    }

    private static func testAdvanceEpochClearsIdleCandidate() {
        var deduplicator = PowerSleepCycleDeduplicator()
        deduplicator.recordCanSystemSleep()
        deduplicator.advanceEpoch()

        expect(deduplicator.beginWillSleep(notificationID: 3) == .forced,
               "an epoch boundary must discard a stale idle candidate")
    }

    private static func testWillSleepDeduplicationAndNotificationIDReuse() {
        var deduplicator = PowerSleepCycleDeduplicator()
        expect(deduplicator.beginWillSleep(notificationID: 7) == .forced,
               "first willSleep token in an epoch must start the eject chain")
        deduplicator.recordCanSystemSleep()
        expect(deduplicator.beginWillSleep(notificationID: 7) == nil,
               "duplicate willSleep token must not repeat the eject side effect")
        expect(deduplicator.beginWillSleep(notificationID: 8) == .idle,
               "a duplicate willSleep token must not consume the pending idle candidate")
        expect(deduplicator.beginWillSleep(notificationID: 9) == .forced,
               "a distinct willSleep token in the same epoch remains independent")
        deduplicator.advanceEpoch()
        expect(deduplicator.beginWillSleep(notificationID: 7) == .forced,
               "wake/cancel epoch boundary must permit notification ID reuse")
    }

    private static func makeCoordinator(_ recorder: AckRecorder) -> PowerSleepAckCoordinator {
        PowerSleepAckCoordinator(
            allowPowerChange: { recorder.record($0) },
            log: { _ in }
        )
    }

    private static func testCompletionAndDeadlineEachAckOnce() {
        let recorder = AckRecorder()
        let coordinator = makeCoordinator(recorder)

        let completed = DispatchGroup()
        completed.enter()
        coordinator.deferAcknowledgment(messageType: 1,
                                          notificationID: 11,
                                          operationID: "completed",
                                          until: completed,
                                          deadline: 1)
        completed.leave()

        let hung = DispatchGroup()
        hung.enter()
        coordinator.deferAcknowledgment(messageType: 1,
                                          notificationID: 12,
                                          operationID: "deadline",
                                          until: hung,
                                          deadline: 0.01)
        Thread.sleep(forTimeInterval: 0.05)
        hung.leave()
        coordinator.shutdownAndDrain()

        expect(recorder.snapshot.filter { $0 == 11 }.count == 1,
               "group completion must ACK exactly once")
        expect(recorder.snapshot.filter { $0 == 12 }.count == 1,
               "deadline followed by late completion must ACK exactly once")
    }

    private static func testSynchronousBoundaryCommitAcksBeforeGroupCompletion() {
        let recorder = AckRecorder()
        let coordinator = makeCoordinator(recorder)
        let pending = DispatchGroup()
        pending.enter()
        coordinator.deferAcknowledgment(messageType: 1,
                                         notificationID: 13,
                                         operationID: "boundary",
                                         until: pending,
                                         deadline: 1)
        coordinator.finishDeferredNow(messageType: 1,
                                      notificationID: 13,
                                      operationID: "boundary")
        expect(recorder.snapshot.filter { $0 == 13 }.count == 1,
               "synchronous boundary commit must ACK before returning")
        pending.leave()
        coordinator.shutdownAndDrain()
        expect(recorder.snapshot.filter { $0 == 13 }.count == 1,
               "later group completion must not duplicate a boundary ACK")
    }

    private static func testDuplicateKeyAndDifferentMessageTypes() {
        let recorder = AckRecorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.acknowledgeImmediately(messageType: 1,
                                           notificationID: 21,
                                           operationID: "first")
        coordinator.acknowledgeImmediately(messageType: 1,
                                           notificationID: 21,
                                           operationID: "duplicate")
        coordinator.acknowledgeImmediately(messageType: 2,
                                           notificationID: 21,
                                           operationID: "different-type")
        coordinator.shutdownAndDrain()
        expect(recorder.snapshot.filter { $0 == 21 }.count == 2,
               "same key must dedupe while the same ID with another message type remains independent")
    }

    private static func testEpochAllowsNotificationIDReuse() {
        let recorder = AckRecorder()
        let coordinator = makeCoordinator(recorder)
        coordinator.acknowledgeImmediately(messageType: 1,
                                           notificationID: 31,
                                           operationID: "epoch-0")
        coordinator.advanceEpoch()
        coordinator.acknowledgeImmediately(messageType: 1,
                                           notificationID: 31,
                                           operationID: "epoch-1")
        coordinator.shutdownAndDrain()
        expect(recorder.snapshot.filter { $0 == 31 }.count == 2,
               "notification ID reuse after an epoch boundary must ACK again")
    }

    private static func testShutdownDrainsPendingAndInvalidatesLateCompletion() {
        let recorder = AckRecorder()
        let coordinator = makeCoordinator(recorder)
        let operation = DispatchGroup()
        operation.enter()
        coordinator.deferAcknowledgment(messageType: 1,
                                          notificationID: 41,
                                          operationID: "shutdown",
                                          until: operation,
                                          deadline: 1)
        coordinator.shutdownAndDrain()
        operation.leave()
        Thread.sleep(forTimeInterval: 0.02)
        expect(recorder.snapshot.filter { $0 == 41 }.count == 1,
               "shutdown must drain once and ignore later group completion")
    }

    private static func testCompletionDeadlineRace() {
        let recorder = AckRecorder()
        let coordinator = makeCoordinator(recorder)
        let iterations = 100

        for index in 0..<iterations {
            let operation = DispatchGroup()
            operation.enter()
            coordinator.deferAcknowledgment(messageType: 9,
                                              notificationID: 1000 + index,
                                              operationID: "race-\(index)",
                                              until: operation,
                                              deadline: 0.002)
            DispatchQueue.global().asyncAfter(deadline: .now() + (index.isMultiple(of: 2) ? 0.001 : 0.003)) {
                operation.leave()
            }
        }

        Thread.sleep(forTimeInterval: 0.1)
        coordinator.shutdownAndDrain()
        let racedIDs = recorder.snapshot.filter { $0 >= 1000 && $0 < 1000 + iterations }
        expect(racedIDs.count == iterations, "completion/deadline race must resolve every key once")
        expect(Set(racedIDs).count == iterations, "completion/deadline race must not duplicate an ACK")
    }

    private static func testAllowErrorDoesNotRetry() {
        let recorder = AckRecorder(result: kIOReturnError)
        let coordinator = makeCoordinator(recorder)
        coordinator.acknowledgeImmediately(messageType: 7,
                                           notificationID: 51,
                                           operationID: "error")
        coordinator.acknowledgeImmediately(messageType: 7,
                                           notificationID: 51,
                                           operationID: "error-duplicate")
        coordinator.shutdownAndDrain()
        expect(recorder.snapshot.filter { $0 == 51 }.count == 1,
               "IOAllowPowerChange error must remain resolved without unsafe retries")
    }

    private static func testDeadlineStartsAtAPICallBeforeQueueBacklog() {
        let recorder = AckRecorder()
        let logEntered = DispatchSemaphore(value: 0)
        let releaseLog = DispatchSemaphore(value: 0)
        let coordinator = PowerSleepAckCoordinator(
            allowPowerChange: { recorder.record($0) },
            log: { message in
                if message.contains("operation=block-queue")
                    && message.contains("power ack allowed") {
                    logEntered.signal()
                    releaseLog.wait()
                }
            }
        )

        coordinator.acknowledgeImmediately(messageType: 1,
                                           notificationID: 61,
                                           operationID: "block-queue")
        expect(logEntered.wait(timeout: .now() + 1) == .success,
               "test must establish an ACK queue backlog")

        let hung = DispatchGroup()
        hung.enter()
        coordinator.deferAcknowledgment(messageType: 1,
                                         notificationID: 62,
                                         operationID: "absolute-deadline",
                                         until: hung,
                                         deadline: 0.2)
        Thread.sleep(forTimeInterval: 0.3)
        releaseLog.signal()

        let observedDeadline = Date().addingTimeInterval(0.08)
        while !recorder.snapshot.contains(62), Date() < observedDeadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        expect(recorder.snapshot.filter { $0 == 62 }.count == 1,
               "an expired absolute deadline must ACK immediately after queue backlog clears")
        hung.leave()
        coordinator.shutdownAndDrain()
    }
}
