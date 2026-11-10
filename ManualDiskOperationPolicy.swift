import Foundation

/// Notification targets belong to one app session and one physical appearance, never a path alone.
struct ManualDiskIdentity: Codable, Equatable, Sendable {
    let session: UUID
    let wholeDiskBSD: String
    let generation: UInt64
    let mediaRegistryEntryID: UInt64

    func matches(_ current: ManualDiskIdentity?) -> Bool { self == current }
}

/// A command owns its reservation through confirmation dialogs and real OS completion.
final class ManualDiskCommandGate: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: UUID?

    func reserve() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil else { return nil }
        let token = UUID()
        owner = token
        return token
    }

    func release(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        if owner == token { owner = nil }
    }

    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return owner != nil
    }
}

enum ManualDiskOutcome: Equatable, Sendable {
    case pending, ejected, forced, mounted, absent, failed

    var title: String {
        switch self {
        case .pending: return String(localized: "Waiting for macOS…")
        case .ejected: return String(localized: "Ejected")
        case .forced: return String(localized: "Ejected with force")
        case .mounted: return String(localized: "Mounted")
        case .absent: return String(localized: "Disk is no longer mounted")
        case .failed: return String(localized: "Disk operation failed")
        }
    }
    var succeeded: Bool { self == .ejected || self == .forced || self == .mounted }
}

/// Late OS evidence may settle a timeout; a stale waiter must never overwrite that evidence.
final class ManualDiskResultLedger: @unchecked Sendable {
    struct Entry: Equatable {
        let name: String
        let outcome: ManualDiskOutcome
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    var onChange: (() -> Void)?

    func record(key: String, name: String, outcome: ManualDiskOutcome) {
        lock.lock()
        if let previous = entries[key],
           (previous.outcome.succeeded && !(previous.outcome == .ejected && outcome == .forced))
            || (outcome == .pending && previous.outcome != .pending) {
            lock.unlock()
            return
        }
        entries[key] = Entry(name: name, outcome: outcome)
        lock.unlock()
        onChange?()
    }

    var snapshot: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries.sorted { $0.key < $1.key }.map(\.value)
    }

    var title: String {
        let outcomes = snapshot.map(\.outcome)
        if outcomes.contains(.pending) { return ManualDiskOutcome.pending.title }
        if outcomes.contains(.failed) {
            return outcomes.contains(where: \.succeeded)
                ? String(localized: "Some disk operations failed") : ManualDiskOutcome.failed.title
        }
        if outcomes.contains(.forced) { return ManualDiskOutcome.forced.title }
        return outcomes.first?.title ?? String(localized: "No disk operation performed")
    }
}
