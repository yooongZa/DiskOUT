import Foundation

enum SettingsShortcutRole: CaseIterable, Equatable, Sendable {
    case eject
    case mount
    case ejectAndSleep
}

struct SettingsShortcutAssignments<Shortcut: Hashable & Sendable>: Equatable, Sendable {
    var eject: Shortcut
    var mount: Shortcut
    var ejectAndSleep: Shortcut?

    func value(for role: SettingsShortcutRole) -> Shortcut? {
        switch role {
        case .eject: return eject
        case .mount: return mount
        case .ejectAndSleep: return ejectAndSleep
        }
    }

    mutating func set(_ value: Shortcut?, for role: SettingsShortcutRole) {
        switch role {
        case .eject:
            if let value { eject = value }
        case .mount:
            if let value { mount = value }
        case .ejectAndSleep:
            ejectAndSleep = value
        }
    }
}

struct SettingsShortcutResolution<Shortcut: Hashable & Sendable>: Equatable, Sendable {
    let assignments: SettingsShortcutAssignments<Shortcut>
    let displacedRoles: [SettingsShortcutRole]
}

enum SettingsShortcutConflictPolicy {
    /// The value the user just chose always wins. Existing assignments keep their value when
    /// possible; only a colliding role moves to the first unused preset.
    static func assigning<Shortcut: Hashable & Sendable>(
        _ chosen: Shortcut,
        to changedRole: SettingsShortcutRole,
        current: SettingsShortcutAssignments<Shortcut>,
        available: [Shortcut]
    ) -> SettingsShortcutResolution<Shortcut> {
        var result = current
        result.set(chosen, for: changedRole)
        var used = Set<Shortcut>([chosen])
        var displaced: [SettingsShortcutRole] = []

        // Reserve every non-conflicting current assignment before selecting replacements. This
        // prevents an early replacement from taking a shortcut that a later, unrelated role owns.
        for role in SettingsShortcutRole.allCases where role != changedRole {
            guard let value = result.value(for: role) else { continue }
            if used.insert(value).inserted { continue }
            displaced.append(role)
        }
        for role in displaced {
            if let replacement = available.first(where: { !used.contains($0) }) {
                result.set(replacement, for: role)
                used.insert(replacement)
            } else if role == .ejectAndSleep {
                result.set(nil, for: role)
            }
        }
        return SettingsShortcutResolution(assignments: result, displacedRoles: displaced)
    }

    /// Startup repair preserves Eject first, then Mount, then the optional Eject and Sleep action.
    static func normalized<Shortcut: Hashable & Sendable>(
        _ current: SettingsShortcutAssignments<Shortcut>,
        available: [Shortcut]
    ) -> SettingsShortcutResolution<Shortcut> {
        var result = current
        var used = Set<Shortcut>()
        var displaced: [SettingsShortcutRole] = []

        for role in SettingsShortcutRole.allCases {
            guard let value = result.value(for: role) else { continue }
            if used.insert(value).inserted { continue }
            displaced.append(role)
            if let replacement = available.first(where: { !used.contains($0) }) {
                result.set(replacement, for: role)
                used.insert(replacement)
            } else if role == .ejectAndSleep {
                result.set(nil, for: role)
            }
        }
        return SettingsShortcutResolution(assignments: result, displacedRoles: displaced)
    }
}

enum SleepEjectSettingsMigration {
    static let sleepKey = "ejectOnSleep"
    static let lidKey = "ejectOnClamshell"
    static let legacyLidKey = "ejectOnLidClose"

    /// Resolves both modern settings in one pass so the result never depends on which getter runs
    /// first. Fresh installs remain unstored and continue to use each setting's default value.
    static func migrate(in defaults: UserDefaults) {
        let storedSleep = defaults.object(forKey: sleepKey) as? Bool
        let storedLid = defaults.object(forKey: lidKey) as? Bool
        let legacyLid = defaults.object(forKey: legacyLidKey) as? Bool

        let inheritedSleep = storedSleep ?? legacyLid
        if storedSleep == nil, let legacyLid {
            defaults.set(legacyLid, forKey: sleepKey)
        }
        if storedLid == nil, let inheritedSleep {
            defaults.set(inheritedSleep, forKey: lidKey)
        }
        if legacyLid != nil {
            defaults.removeObject(forKey: legacyLidKey)
        }
    }
}

struct LibraryAppRelaunchOwner: Hashable, Sendable {
    let rawValue: String
}

/// Music/Photos may be asked to quit by overlapping manual, display, lid, and system paths.
/// Accepted quits remain a union, and only the last exact owner to finish may atomically drain it.
final class LibraryAppRelaunchLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var bundleIDs = Set<String>()
    private var owners = Set<LibraryAppRelaunchOwner>()

    func retain(_ owner: LibraryAppRelaunchOwner) {
        lock.lock()
        owners.insert(owner)
        lock.unlock()
    }

    func record(_ newBundleIDs: [String]) {
        lock.lock()
        bundleIDs.formUnion(newBundleIDs)
        lock.unlock()
    }

    /// Finishing an unknown/duplicate owner is a no-op. A known last owner receives the exact
    /// bundle union to relaunch; every overlapping owner keeps the ledger closed.
    func finish(_ owner: LibraryAppRelaunchOwner) -> [String] {
        lock.lock()
        guard owners.remove(owner) != nil, owners.isEmpty else {
            lock.unlock()
            return []
        }
        let result = bundleIDs.sorted()
        bundleIDs.removeAll()
        lock.unlock()
        return result
    }

    var activeOwnerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return owners.count
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return bundleIDs.isEmpty
    }
}

/// Tracks in-flight network work so disabling diagnostics has a hard boundary: queued work cannot
/// start and active tasks receive cancellation. Cancellation callbacks run outside the lock.
final class CancelableOperationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var isEnabled: Bool
    private var cancellations: [UUID: () -> Void] = [:]

    init(enabled: Bool = true) {
        isEnabled = enabled
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        isEnabled = enabled
        let callbacks = enabled ? [] : Array(cancellations.values)
        if !enabled { cancellations.removeAll() }
        lock.unlock()
        callbacks.forEach { $0() }
    }

    func register(id: UUID, cancel: @escaping () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled else { return false }
        cancellations[id] = cancel
        return true
    }

    func finish(id: UUID) {
        lock.lock()
        cancellations.removeValue(forKey: id)
        lock.unlock()
    }

    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellations.count
    }
}

/// URLSession cancellation and completion can race. This gate guarantees that public completion
/// semantics remain exactly once even when a disabled request is canceled before it starts.
final class OneShotBooleanCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Bool) -> Void)?

    init(_ callback: ((Bool) -> Void)?) {
        self.callback = callback
    }

    func call(_ value: Bool) {
        lock.lock()
        let pending = callback
        callback = nil
        lock.unlock()
        pending?(value)
    }
}

enum PremiumMenuEntry: Equatable, Sendable {
    case hidden
    case openSettings
}

enum PremiumMenuPolicy {
    static func entry(isConfigured: Bool,
                      hasPremiumAccess: Bool,
                      hasInProgressAction: Bool) -> PremiumMenuEntry {
        guard isConfigured else { return .hidden }
        return (!hasPremiumAccess || hasInProgressAction) ? .openSettings : .hidden
    }
}

enum DriveMenuAction: Equatable, Sendable {
    case openInFinder
    case eject
}

enum DriveUsageHintPresentationPolicy {
    /// The non-interactive usage hint is useful only when at least one mounted
    /// drive row can perform the described actions.
    static func shouldShow(displayedDriveCount: Int) -> Bool {
        displayedDriveCount > 0
    }
}

enum DriveMenuActionPolicy {
    /// Eject is destructive, so it requires positive proof of an exact Command + primary click.
    /// Keyboard/Accessibility activation, a missing event, or any additional primary modifier
    /// falls back to opening Finder.
    static func action(isPrimaryClick: Bool,
                       hasCommand: Bool,
                       hasOption: Bool,
                       hasControl: Bool,
                       hasShift: Bool) -> DriveMenuAction {
        guard isPrimaryClick,
              hasCommand,
              !hasOption,
              !hasControl,
              !hasShift else {
            return .openInFinder
        }
        return .eject
    }
}

enum DriveMenuActionExecutor {
    static func perform(action: DriveMenuAction,
                        openInFinder: () -> Bool,
                        eject: () -> Void,
                        notifyOpenFailure: () -> Void) {
        switch action {
        case .openInFinder:
            if !openInFinder() {
                notifyOpenFailure()
            }
        case .eject:
            eject()
        }
    }
}
