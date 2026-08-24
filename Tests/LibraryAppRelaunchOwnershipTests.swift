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

private final class BundleResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String]] = []

    func append(_ value: [String]) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@main
private enum LibraryAppRelaunchOwnershipTests {
    static func main() {
        testManualPendingUnmountRetainsItsOnlyOwnerUntilTerminal()
        testManualFinishCannotDrainAutomaticPendingUnmount()
        testAutomaticWakeCannotDrainNewManualAttempt()
        print("LibraryAppRelaunchOwnershipTests: PASS")
    }

    private static func testManualPendingUnmountRetainsItsOnlyOwnerUntilTerminal() {
        let ledger = LibraryAppRelaunchLedger()
        let activity = SleepUnmountActivityTracker()
        let manual = LibraryAppRelaunchOwner(rawValue: "manual-only-pending")
        let results = BundleResultRecorder()

        ledger.retain(manual)
        ledger.record(["Music"])
        activity.begin()
        activity.whenIdle {
            results.append(ledger.finish(manual))
        }
        expect(results.snapshot.isEmpty,
               "manual failure must not relaunch an app while its DA request is still pending")
        activity.finish()
        expect(results.snapshot == [["Music"]],
               "manual ownership must drain exactly once after terminal DA evidence")
    }

    private static func testManualFinishCannotDrainAutomaticPendingUnmount() {
        let ledger = LibraryAppRelaunchLedger()
        let activity = SleepUnmountActivityTracker()
        let manual = LibraryAppRelaunchOwner(rawValue: "manual")
        let automatic = LibraryAppRelaunchOwner(rawValue: "automatic")
        let results = BundleResultRecorder()

        ledger.retain(manual)
        ledger.record(["Music"])
        ledger.retain(automatic)
        activity.begin()
        expect(ledger.finish(manual).isEmpty,
               "manual cancellation must not drain an overlapping automatic owner")

        activity.whenIdle {
            results.append(ledger.finish(automatic))
        }
        expect(results.snapshot.isEmpty,
               "automatic wake must wait while the DA request or late worker is pending")
        activity.finish()
        expect(results.snapshot == [["Music"]],
               "the final automatic terminal result may release the retained app once")
    }

    private static func testAutomaticWakeCannotDrainNewManualAttempt() {
        let ledger = LibraryAppRelaunchLedger()
        let automatic = LibraryAppRelaunchOwner(rawValue: "automatic")
        let manual = LibraryAppRelaunchOwner(rawValue: "manual")

        ledger.retain(automatic)
        ledger.record(["Photos"])
        ledger.retain(manual)
        expect(ledger.finish(automatic).isEmpty,
               "automatic wake must not drain a newly retained manual owner")
        expect(ledger.finish(manual) == ["Photos"],
               "the later manual completion must receive the shared union exactly once")
    }
}
