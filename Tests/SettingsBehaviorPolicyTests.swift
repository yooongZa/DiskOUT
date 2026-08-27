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
        testLibraryLedgerWaitsForEveryExactOwner()
        testLibraryLedgerConcurrentLastOwnerDrainsOnce()
        testCancelableRegistryBoundaries()
        testOneShotCallbackUnderConcurrency()
        testPremiumMenuPolicy()
        testDriveUsageHintPresentation()
        testDriveMenuActionRequiresExactCommandPrimaryClick()
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

    private static func testLibraryLedgerWaitsForEveryExactOwner() {
        let ledger = LibraryAppRelaunchLedger()
        let manual = LibraryAppRelaunchOwner(rawValue: "manual-1")
        let automatic = LibraryAppRelaunchOwner(rawValue: "automatic-1")
        ledger.retain(manual)
        ledger.retain(automatic)
        ledger.record(["Music", "Photos"])
        ledger.record([])
        ledger.record(["Music"])
        expect(ledger.finish(manual).isEmpty,
               "finishing manual work must not drain an overlapping automatic owner")
        expect(ledger.activeOwnerCount == 1 && !ledger.isEmpty,
               "the remaining owner must retain the complete bundle union")
        expect(ledger.finish(automatic) == ["Music", "Photos"],
               "the exact last owner receives the union once")
        expect(ledger.finish(automatic).isEmpty,
               "a duplicate owner completion must never drain a later ledger")
    }

    private static func testLibraryLedgerConcurrentLastOwnerDrainsOnce() {
        let ledger = LibraryAppRelaunchLedger()
        let owners = (0..<128).map {
            LibraryAppRelaunchOwner(rawValue: "owner-\($0)")
        }
        owners.forEach(ledger.retain)
        ledger.record(["Music", "Photos"])

        let winners = CancellationRecorder()
        let group = DispatchGroup()
        for owner in owners {
            group.enter()
            DispatchQueue.global().async {
                let bundleIDs = ledger.finish(owner)
                if !bundleIDs.isEmpty {
                    winners.append(bundleIDs.joined(separator: ","))
                }
                group.leave()
            }
        }
        expect(group.wait(timeout: .now() + 2) == .success,
               "every concurrent owner completion must finish")
        expect(winners.snapshot == ["Music,Photos"],
               "exactly one concurrent last owner may drain the bundle union")
        expect(ledger.activeOwnerCount == 0 && ledger.isEmpty,
               "concurrent completion must leave no owner or duplicate relaunch work")
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

    private static func testDriveUsageHintPresentation() {
        expect(!DriveUsageHintPresentationPolicy.shouldShow(displayedDriveCount: -1),
               "invalid negative drive counts do not show the usage hint")
        expect(!DriveUsageHintPresentationPolicy.shouldShow(displayedDriveCount: 0),
               "an empty drive list does not show an inapplicable usage hint")
        expect(DriveUsageHintPresentationPolicy.shouldShow(displayedDriveCount: 1),
               "one mounted drive shows the shared usage hint")
        expect(DriveUsageHintPresentationPolicy.shouldShow(displayedDriveCount: 8),
               "multiple mounted drives still show only the shared section-level hint")
    }

    private static func testDriveMenuActionRequiresExactCommandPrimaryClick() {
        func action(primary: Bool = true,
                    command: Bool = false,
                    option: Bool = false,
                    control: Bool = false,
                    shift: Bool = false) -> DriveMenuAction {
            DriveMenuActionPolicy.action(
                isPrimaryClick: primary,
                hasCommand: command,
                hasOption: option,
                hasControl: control,
                hasShift: shift
            )
        }

        expect(action() == .openInFinder,
               "a plain primary click opens Finder")
        expect(action(primary: false, command: true) == .openInFinder,
               "keyboard or Accessibility activation cannot eject")
        expect(action(command: true) == .eject,
               "an exact Command primary click ejects")
        expect(action(command: true, option: true) == .openInFinder,
               "Command-Option click fails safe to Finder")
        expect(action(command: true, control: true) == .openInFinder,
               "Command-Control click fails safe to Finder")
        expect(action(command: true, shift: true) == .openInFinder,
               "Command-Shift click fails safe to Finder")

        var openCount = 0
        var ejectCount = 0
        var notificationCount = 0
        DriveMenuActionExecutor.perform(
            action: .openInFinder,
            openInFinder: { openCount += 1; return true },
            eject: { ejectCount += 1 },
            notifyOpenFailure: { notificationCount += 1 }
        )
        expect((openCount, ejectCount, notificationCount) == (1, 0, 0),
               "successful Finder open has no eject or failure notification side effect")

        DriveMenuActionExecutor.perform(
            action: .openInFinder,
            openInFinder: { openCount += 1; return false },
            eject: { ejectCount += 1 },
            notifyOpenFailure: { notificationCount += 1 }
        )
        expect((openCount, ejectCount, notificationCount) == (2, 0, 1),
               "failed Finder open notifies exactly once without ejecting")

        DriveMenuActionExecutor.perform(
            action: .eject,
            openInFinder: { openCount += 1; return false },
            eject: { ejectCount += 1 },
            notifyOpenFailure: { notificationCount += 1 }
        )
        expect((openCount, ejectCount, notificationCount) == (2, 1, 1),
               "eject action preserves the existing eject path without opening Finder")
    }
}
