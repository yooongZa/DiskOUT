import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
private enum ManualDiskOperationPolicyTests {
    static func main() throws {
        let session = UUID()
        let original = ManualDiskIdentity(session: session, wholeDiskBSD: "disk4", generation: 12, mediaRegistryEntryID: 50)
        let decoded = try JSONDecoder().decode(ManualDiskIdentity.self, from: JSONEncoder().encode(original))
        expect(original.matches(decoded), "notification round-trip retains the exact target")
        expect(!original.matches(nil), "a missing target never authorizes retry")
        for replacement in [
            ManualDiskIdentity(session: session, wholeDiskBSD: "disk4", generation: 13, mediaRegistryEntryID: 50),
            ManualDiskIdentity(session: session, wholeDiskBSD: "disk4", generation: 12, mediaRegistryEntryID: 51),
            ManualDiskIdentity(session: UUID(), wholeDiskBSD: "disk4", generation: 12, mediaRegistryEntryID: 50),
            ManualDiskIdentity(session: session, wholeDiskBSD: "disk5", generation: 12, mediaRegistryEntryID: 50)
        ] { expect(!original.matches(replacement), "replug, reused BSD, replacement, and relaunch invalidate old notifications") }

        let gate = ManualDiskCommandGate()
        let owner = gate.reserve()!
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            expect(gate.reserve() == nil, "a confirmation or pending request excludes every other command")
            gate.release(UUID())
        }
        expect(gate.isBusy, "stale completion must not release another command")
        gate.release(owner)
        let next = gate.reserve()!
        gate.release(owner)
        expect(gate.isBusy, "previous command cannot release its successor")
        gate.release(next)
        expect(!gate.isBusy, "real terminal completion releases reservation")

        let results = ManualDiskResultLedger()
        results.record(key: "A", name: "same name", outcome: .pending)
        results.record(key: "B", name: "same name", outcome: .failed)
        expect(results.snapshot.count == 2, "same-named volumes retain separate outcomes")
        expect(results.title == ManualDiskOutcome.pending.title, "a pending disk keeps the batch pending")
        results.record(key: "A", name: "same name", outcome: .forced)
        results.record(key: "A", name: "same name", outcome: .pending)
        results.record(key: "A", name: "same name", outcome: .failed)
        expect(results.snapshot.first?.outcome == .forced, "late waiter/failure cannot erase OS-confirmed forced success")
        results.record(key: "B", name: "same name", outcome: .ejected)
        expect(results.title == ManualDiskOutcome.forced.title, "late normal success settles a mixed forced/normal batch")
        let absent = ManualDiskResultLedger()
        absent.record(key: "gone", name: "gone", outcome: .absent)
        expect(!absent.snapshot[0].outcome.succeeded, "no request performed is not successful eject")
        let mount = ManualDiskResultLedger()
        mount.record(key: "C", name: "C", outcome: .pending)
        mount.record(key: "C", name: "C", outcome: .mounted)
        mount.record(key: "C", name: "C", outcome: .pending)
        expect(mount.title == ManualDiskOutcome.mounted.title, "a deadline racing the mount callback cannot undo completion")
        let overlapping = ManualDiskResultLedger()
        overlapping.record(key: "D", name: "D", outcome: .ejected)
        overlapping.record(key: "D", name: "D", outcome: .forced)
        expect(overlapping.title == ManualDiskOutcome.forced.title, "a late successful force request remains visible even when normal completed first")
        print("ManualDiskOperationPolicyTests: PASS")
    }
}
