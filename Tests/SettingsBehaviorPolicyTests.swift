import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private final class CancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock(); values.append(value); lock.unlock()
    }

    var snapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

@main
private enum SettingsBehaviorPolicyTests {
    static func main() {
        testShortcutUserChoiceWins()
        testShortcutStartupNormalization()
        testLegacyMigrationIsOrderIndependent()
        testLibraryLedgerUnionAndDrain()
        testCancelableRegistryBoundaries()
        testOneShotCallbackUnderConcurrency()
        testPremiumMenuPolicy()
        print("SettingsBehaviorPolicyTests: PASS")
    }

    private static func testShortcutUserChoiceWins() {
        let current = SettingsShortcutAssignments(eject: "A", mount: "B", ejectAndSleep: "C")
        let changedEject = SettingsShortcutConflictPolicy.assigning(
            "C", to: .eject, current: current, available: ["A", "B", "C", "D"]
        )
        expect(changedEject.assignments.eject == "C", "new eject choice wins")
        expect(changedEject.assignments.mount == "B", "unrelated mount stays")
        expect(changedEject.assignments.ejectAndSleep == "A", "colliding optional action moves")
        expect(changedEject.displacedRoles == [.ejectAndSleep], "displaced role reported")

        let changedSleep = SettingsShortcutConflictPolicy.assigning(
            "A", to: .ejectAndSleep, current: current, available: ["A", "B", "C", "D"]
        )
        expect(changedSleep.assignments.ejectAndSleep == "A", "new sleep choice wins")
        expect(changedSleep.assignments.eject == "C", "colliding eject moves")
        expect(Set([changedSleep.assignments.eject, changedSleep.assignments.mount,
                    changedSleep.assignments.ejectAndSleep!]).count == 3,
               "all three shortcuts stay distinct")
    }

    private static func testShortcutStartupNormalization() {
        let broken = SettingsShortcutAssignments(eject: "A", mount: "A", ejectAndSleep: "A")
        let fixed = SettingsShortcutConflictPolicy.normalized(broken, available: ["A", "B", "C", "D"])
        expect(fixed.assignments.eject == "A", "startup preserves eject priority")
        expect(fixed.assignments.mount == "B", "startup repairs mount")
        expect(fixed.assignments.ejectAndSleep == "C", "startup repairs optional action")
        expect(fixed.displacedRoles == [.mount, .ejectAndSleep], "startup reports both repairs")
    }

    private static func testLegacyMigrationIsOrderIndependent() {
        for legacy in [false, true] {
            let suite = "com.yongza.diskout.settings-migration.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(legacy, forKey: SleepEjectSettingsMigration.legacyLidKey)
            SleepEjectSettingsMigration.migrate(in: defaults)
            expect(defaults.object(forKey: SleepEjectSettingsMigration.sleepKey) as? Bool == legacy,
                   "legacy value migrates to sleep")
            expect(defaults.object(forKey: SleepEjectSettingsMigration.lidKey) as? Bool == legacy,
                   "legacy value migrates to lid")
            expect(defaults.object(forKey: SleepEjectSettingsMigration.legacyLidKey) == nil,
                   "legacy key removed after both values resolved")
        }

        let suite = "com.yongza.diskout.settings-existing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: SleepEjectSettingsMigration.sleepKey)
        defaults.set(true, forKey: SleepEjectSettingsMigration.lidKey)
        defaults.set(true, forKey: SleepEjectSettingsMigration.legacyLidKey)
        SleepEjectSettingsMigration.migrate(in: defaults)
        expect(defaults.bool(forKey: SleepEjectSettingsMigration.sleepKey) == false,
               "modern sleep value is preserved")
        expect(defaults.bool(forKey: SleepEjectSettingsMigration.lidKey) == true,
               "modern lid value is preserved")
    }

    private static func testLibraryLedgerUnionAndDrain() {
        let ledger = LibraryAppRelaunchLedger()
        ledger.record(["Music", "Photos"])
        ledger.record([])
        ledger.record(["Music"])
        expect(ledger.drain() == ["Music", "Photos"], "overlapping quit results form a union")
        expect(ledger.drain().isEmpty, "drain is exactly once")
    }

    private static func testCancelableRegistryBoundaries() {
        let registry = CancelableOperationRegistry()
        let recorder = CancellationRecorder()
        let first = UUID()
        let second = UUID()
        expect(registry.register(id: first) { recorder.append("first") }, "enabled registry accepts work")
        expect(registry.register(id: second) { recorder.append("second") }, "enabled registry accepts second work")
        registry.finish(id: first)
        registry.setEnabled(false)
        expect(recorder.snapshot == ["second"], "disable cancels only active work")
        expect(!registry.register(id: UUID()) { recorder.append("late") }, "disabled registry rejects queued work")
        registry.setEnabled(true)
        expect(registry.register(id: UUID()) { recorder.append("retry") }, "re-enable accepts new work")
    }

    private static func testOneShotCallbackUnderConcurrency() {
        let recorder = CancellationRecorder()
        let gate = OneShotBooleanCallback { recorder.append($0 ? "true" : "false") }
        let group = DispatchGroup()
        for index in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                gate.call(index.isMultiple(of: 2))
                group.leave()
            }
        }
        group.wait()
        expect(recorder.snapshot.count == 1, "racing URLSession completions publish exactly once")
    }

    private static func testPremiumMenuPolicy() {
        expect(PremiumMenuPolicy.entry(isConfigured: false, hasPremiumAccess: false,
                                       hasInProgressAction: false) == .hidden,
               "unconfigured billing stays hidden")
        expect(PremiumMenuPolicy.entry(isConfigured: true, hasPremiumAccess: false,
                                       hasInProgressAction: false) == .openSettings,
               "free configured build links to Settings")
        expect(PremiumMenuPolicy.entry(isConfigured: true, hasPremiumAccess: true,
                                       hasInProgressAction: false) == .hidden,
               "active Premium needs no menu row")
        expect(PremiumMenuPolicy.entry(isConfigured: true, hasPremiumAccess: true,
                                       hasInProgressAction: true) == .openSettings,
               "in-progress state remains reachable")
    }
}
