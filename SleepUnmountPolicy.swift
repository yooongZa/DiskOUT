import Foundation

/// One-shot evidence latch shared by DA request joiners. A waiter timeout never completes the
/// latch; the first callback/disconnect evidence is sticky and releases every waiter exactly once.
final class StickyAsyncEvidence<Value>: @unchecked Sendable {
    let completion = DispatchGroup()
    private let lock = NSLock()
    private var value: Value?
    private var observers: [(Value) -> Void] = []

    init() {
        completion.enter()
    }

    @discardableResult
    func finishOnce(_ newValue: Value) -> Bool {
        lock.lock()
        guard value == nil else {
            lock.unlock()
            return false
        }
        value = newValue
        let callbacks = observers
        observers.removeAll()
        lock.unlock()
        completion.leave()
        callbacks.forEach { $0(newValue) }
        return true
    }

    func snapshot() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func wait(timeout: TimeInterval) -> Value? {
        if completion.wait(timeout: .now() + max(0, timeout)) == .success {
            return snapshot()
        }
        // Recheck under the latch lock at the timeout/callback boundary.
        return snapshot()
    }

    func observe(_ callback: @escaping (Value) -> Void) {
        lock.lock()
        if let value {
            lock.unlock()
            callback(value)
            return
        }
        observers.append(callback)
        lock.unlock()
    }
}

struct SleepUnmountTarget: Equatable, Sendable {
    let name: String
    let volumePath: String
    let wholeDiskBSD: String?
    /// DAInventory가 이 mount path를 관측한 physical appearance(물리 연결 세대).
    /// BSD 이름은 재연결 뒤 재사용될 수 있으므로 둘을 함께 검증해야 한다.
    let physicalGeneration: UInt64?
    /// Exact IOMedia registry entry captured with the generation.
    let mediaRegistryEntryID: UInt64?
    /// Mounted sibling set captured in the authoritative sleep snapshot. A new sibling appearing
    /// before the whole-disk request invalidates that request and forces a fresh protection pass.
    let mountedVolumeBSDs: Set<String>?
    /// False only for an explicit user-commanded path such as Eject and Sleep.
    let enforceProtectionClosure: Bool

    init(name: String,
         volumePath: String,
         wholeDiskBSD: String?,
         physicalGeneration: UInt64?,
         mediaRegistryEntryID: UInt64?,
         mountedVolumeBSDs: Set<String>? = nil,
         enforceProtectionClosure: Bool = true) {
        self.name = name
        self.volumePath = volumePath
        self.wholeDiskBSD = wholeDiskBSD
        self.physicalGeneration = physicalGeneration
        self.mediaRegistryEntryID = mediaRegistryEntryID
        self.mountedVolumeBSDs = mountedVolumeBSDs
        self.enforceProtectionClosure = enforceProtectionClosure
    }
}

enum SleepUnmountGroupKey: Equatable, Hashable, Sendable {
    case physicalDisk(bsd: String, generation: UInt64, mediaRegistryEntryID: UInt64)
    case unresolvedVolumePath(String)
}

enum SleepUnmountOperation: Equatable, Sendable {
    case wholeNormal
    case wholeForce
}

enum SleepMountedSiblingPolicy {
    static func isSnapshotStillSafe(expectedMountedVolumeBSDs: Set<String>,
                                    currentMountedVolumeBSDs: Set<String>,
                                    allowMissingExpectedSiblings: Bool,
                                    enforceProtectionClosure: Bool,
                                    hasProtectedCurrentSibling: Bool) -> Bool {
        let topologyMatches = allowMissingExpectedSiblings
            ? currentMountedVolumeBSDs.isSubset(of: expectedMountedVolumeBSDs)
            : expectedMountedVolumeBSDs == currentMountedVolumeBSDs
        return topologyMatches
            && (!enforceProtectionClosure || !hasProtectedCurrentSibling)
    }
}

enum SleepMountApprovalDecision: Equatable, Sendable {
    case approve
    case approveAndTrackPending
    case rejectBusy
}

/// Nestable automatic-sleep mount barrier. Disk Arbitration approval callbacks do not identify
/// the requester, so a race-free snapshot/request boundary rejects new external mounts for the
/// whole eject operation; the enclosing power token remains active from `willSleep` until the
/// matching wake/cancel edge. Exact tokens prevent one scope from clearing another.
struct SleepPowerMountBarrier: Equatable, Sendable {
    private var nextToken: UInt64 = 0
    private(set) var activeTokens = Set<UInt64>()

    mutating func begin() -> UInt64 {
        nextToken &+= 1
        if nextToken == 0 { nextToken = 1 }
        activeTokens.insert(nextToken)
        return nextToken
    }

    mutating func end(token: UInt64) {
        activeTokens.remove(token)
    }

    func blocks(isExternalCandidate: Bool) -> Bool {
        !activeTokens.isEmpty && isExternalCandidate
    }
}

/// Pure policy for the DA mount-approval barrier used by automatic whole-disk unmount.
enum SleepMountApprovalPolicy {
    static func decision(hasActiveUnmountBarrier: Bool,
                         hasPowerSleepBarrier: Bool = false,
                         isExternalCandidate: Bool = true,
                         volumeAlreadyMounted: Bool) -> SleepMountApprovalDecision {
        if hasActiveUnmountBarrier
            || (hasPowerSleepBarrier && isExternalCandidate) {
            return .rejectBusy
        }
        return volumeAlreadyMounted ? .approve : .approveAndTrackPending
    }

    static func canBeginAutomaticUnmount(hasPendingApprovedMount: Bool) -> Bool {
        !hasPendingApprovedMount
    }

    static func pendingApprovalMatchesCapturedMedia(
        pendingMediaRegistryEntryID: UInt64?,
        capturedMediaRegistryEntryID: UInt64
    ) -> Bool {
        pendingMediaRegistryEntryID == nil
            || pendingMediaRegistryEntryID == capturedMediaRegistryEntryID
    }

    static func shouldRetainBarrierAfterNormalTerminal(
        callbackWasDecline: Bool,
        forceContinuationReserved: Bool
    ) -> Bool {
        callbackWasDecline && forceContinuationReserved
    }
}

struct SleepForceContinuationReservationCounter: Equatable, Sendable {
    private(set) var count = 0

    var isReserved: Bool { count > 0 }

    mutating func reserve() {
        count += 1
    }

    mutating func release() {
        guard count > 0 else { return }
        count -= 1
    }
}

struct SleepUnmountRequest: Equatable, Sendable {
    let key: SleepUnmountGroupKey
    /// 기존 설정 의미를 보존한다: 첫 요청은 항상 normal이고, 명시적인 decline 뒤에만 force를 허용한다.
    let allowsForceFallback: Bool
    let targets: [SleepUnmountTarget]

    var wholeDiskBSD: String? {
        guard case let .physicalDisk(bsdName, _, _) = key else { return nil }
        return bsdName
    }

    var physicalGeneration: UInt64? {
        guard case let .physicalDisk(_, generation, _) = key else { return nil }
        return generation
    }

    var mediaRegistryEntryID: UInt64? {
        guard case let .physicalDisk(_, _, entryID) = key else { return nil }
        return entryID
    }

    var mountedVolumeBSDs: Set<String>? {
        targets.first?.mountedVolumeBSDs
    }

    var enforceProtectionClosure: Bool {
        targets.first?.enforceProtectionClosure ?? true
    }

    var representativeVolumePath: String? {
        targets.first?.volumePath
    }
}

enum SleepUnmountPolicy {
    static func requests(
        for targets: [SleepUnmountTarget],
        forceFallback: Bool
    ) -> [SleepUnmountRequest] {
        var groups: [(key: SleepUnmountGroupKey, targets: [SleepUnmountTarget])] = []
        var groupIndexByKey: [SleepUnmountGroupKey: Int] = [:]

        for target in targets {
            let key = groupKey(for: target)
            if let existingIndex = groupIndexByKey[key] {
                groups[existingIndex].targets.append(target)
            } else {
                groupIndexByKey[key] = groups.count
                groups.append((key: key, targets: [target]))
            }
        }

        return groups.map { group in
            SleepUnmountRequest(
                key: group.key,
                allowsForceFallback: forceFallback,
                targets: group.targets
            )
        }
    }

    /// DADiskUnmount에는 request cancel API가 없다. 따라서 timeout/disconnect/unavailable 뒤에는
    /// force 요청을 겹치지 않고, normal callback이 명시적으로 거절한 경우에만 순차 fallback한다.
    static func nextOperation(after event: SleepUnmountEvidenceEvent,
                              requestWasForced: Bool = false,
                              forceFallback: Bool) -> SleepUnmountOperation? {
        guard forceFallback,
              event == .callbackFailure,
              !requestWasForced else { return nil }
        return .wholeForce
    }

    private static func groupKey(for target: SleepUnmountTarget) -> SleepUnmountGroupKey {
        if let wholeDiskBSD = target.wholeDiskBSD,
           !wholeDiskBSD.isEmpty,
           let generation = target.physicalGeneration,
           let entryID = target.mediaRegistryEntryID {
            return .physicalDisk(bsd: wholeDiskBSD,
                                 generation: generation,
                                 mediaRegistryEntryID: entryID)
        }
        return .unresolvedVolumePath(target.volumePath)
    }
}

struct SleepProtectionCandidate: Equatable, Sendable {
    let physicalDiskID: String?
    let isEjectTarget: Bool
    let isProtected: Bool
}

struct SleepProtectionDecision: Equatable, Sendable {
    let allowedTargetIndices: Set<Int>
    let blockedTargetIndices: Set<Int>
    let skippedTargetCount: Int
}

enum SleepProtectionPolicy {
    static func evaluate(_ candidates: [SleepProtectionCandidate]) -> SleepProtectionDecision {
        let unresolvedProtected = candidates.contains {
            $0.isProtected && ($0.physicalDiskID?.isEmpty != false)
        }
        if unresolvedProtected {
            let blocked = Set(candidates.indices.filter {
                candidates[$0].isEjectTarget && !candidates[$0].isProtected
            })
            let skipped = candidates.indices.filter {
                candidates[$0].isEjectTarget && candidates[$0].isProtected
            }.count
            return SleepProtectionDecision(allowedTargetIndices: [],
                                           blockedTargetIndices: blocked,
                                           skippedTargetCount: skipped)
        }

        let protectedDisks = Set(candidates.compactMap { candidate in
            candidate.isProtected ? candidate.physicalDiskID : nil
        })
        let allowed = Set(candidates.indices.filter { index in
            let candidate = candidates[index]
            guard candidate.isEjectTarget,
                  !candidate.isProtected else { return false }
            guard let diskID = candidate.physicalDiskID else {
                // Preserve the legacy path-only attempt when no protected sibling has unresolved
                // identity. The sleep path still rejects it later because clean DA proof needs ID.
                return true
            }
            return !protectedDisks.contains(diskID)
        })
        let targetCount = candidates.filter(\.isEjectTarget).count
        return SleepProtectionDecision(allowedTargetIndices: allowed,
                                       blockedTargetIndices: [],
                                       skippedTargetCount: targetCount - allowed.count)
    }
}

enum SleepUnmountFailure: Equatable, Sendable {
    case disconnect
    case unavailable
    case callbackFailure
}

enum SleepUnmountEvidenceState: Equatable, Sendable {
    case pending
    /// caller deadline은 지났지만 취소할 수 없는 DA request는 계속 진행 중이다.
    case pendingAfterTimeout
    case clean
    case failure(SleepUnmountFailure)
}

enum SleepUnmountEvidenceEvent: Equatable, Sendable {
    case callbackSuccess
    case callbackFailure
    case timeout
    case disconnect
    case unavailable
}

enum SleepUnmountEvidenceReducer {
    static func reduce(
        _ state: SleepUnmountEvidenceState,
        event: SleepUnmountEvidenceEvent
    ) -> SleepUnmountEvidenceState {
        guard state == .pending || state == .pendingAfterTimeout else { return state }

        switch event {
        case .callbackSuccess:
            return .clean
        case .callbackFailure:
            return .failure(.callbackFailure)
        case .timeout:
            return .pendingAfterTimeout
        case .disconnect:
            return .failure(.disconnect)
        case .unavailable:
            return .failure(.unavailable)
        }
    }
}
