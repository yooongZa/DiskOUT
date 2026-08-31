/// 메뉴바 디스크 활동 표시의 순수 상태 정책.
///
/// 원시 I/O 감지는 polling 경계와 macOS buffering 때문에 한두 구간씩 비어 보일 수 있다.
/// 한 번 활성화된 장치/방향은 연속된 `inactivePollLimit` 회 무활동이 확인될 때까지 유지해
/// 복사 중 블루닷이 깜빡이는 것을 막는다. 현재 장치 집합에서 사라진 디스크는 grace 없이
/// 즉시 제거한다.
struct DiskActivitySnapshot: Equatable {
    let writing: Set<String>
    let reading: Set<String>

    static let inactive = DiskActivitySnapshot(writing: [], reading: [])
}

/// forced sleep 후보의 물리 디스크 활동을 한 polling generation 기준으로 판정한다.
///
/// `DiskIOMonitor`의 직렬 queue 안에서 이 immutable snapshot을 한 번에 복사하면,
/// 후보를 고르는 동안 다음 poll이 진행돼도 서로 다른 generation의 값을 섞지 않는다.
enum ForcedSleepActivityAssessment: Equatable, Sendable {
    case active
    case idle
    case unknown
}

struct ForcedSleepActivitySnapshot: Equatable, Sendable {
    /// 이 활동 표본과 함께 동기화한 authoritative Disk Arbitration inventory generation.
    /// nil 또는 후보 snapshot 세대와 불일치하면 같은 BSD 이름의 교체 매체일 수 있으므로 unknown이다.
    let inventoryRevision: UInt64?
    /// nil이면 마운트된 볼륨에서 물리 디스크로의 매핑 자체를 확정하지 못한 상태다.
    let mountedPhysicalDisks: Set<String>?
    /// 직전 값과 현재 값 사이의 유효한 delta를 한 번 이상 계산한 물리 디스크다.
    let validDeltaSampledDisks: Set<String>
    let writing: Set<String>
    let reading: Set<String>

    func assessment(for backingPhysicalDisks: Set<String>,
                    expectedInventoryRevision: UInt64) -> ForcedSleepActivityAssessment {
        guard inventoryRevision == expectedInventoryRevision,
              !backingPhysicalDisks.isEmpty,
              let mountedPhysicalDisks,
              backingPhysicalDisks.isSubset(of: mountedPhysicalDisks) else {
            return .unknown
        }

        let sampledBackingDisks = backingPhysicalDisks.intersection(validDeltaSampledDisks)
        let activeDisks = writing.union(reading).intersection(sampledBackingDisks)
        if !activeDisks.isEmpty {
            return .active
        }

        guard backingPhysicalDisks.isSubset(of: validDeltaSampledDisks) else {
            return .unknown
        }
        return .idle
    }
}

struct DiskIOValidatedDelta: Equatable, Sendable {
    let read: UInt64
    let write: UInt64
}

struct DiskIOByteCounters: Equatable, Sendable {
    let read: UInt64
    let write: UInt64
}

enum DiskIOCounterAvailabilityPolicy {
    static func counters(read: UInt64?, write: UInt64?) -> DiskIOByteCounters? {
        guard let read, let write else { return nil }
        return DiskIOByteCounters(read: read, write: write)
    }
}

enum DiskActivityInventoryGenerationPolicy {
    static func shouldReset(previousDisks: Set<String>?,
                            newDisks: Set<String>?,
                            previousRevision: UInt64?,
                            newRevision: UInt64?) -> Bool {
        previousDisks != newDisks || previousRevision != newRevision
    }
}

/// A missing baseline, newly appeared disk, or either counter moving backwards cannot prove idle.
enum DiskIOCounterDeltaPolicy {
    static func validatedDelta(previous: (read: UInt64, write: UInt64)?,
                               current: (read: UInt64, write: UInt64))
        -> DiskIOValidatedDelta? {
        guard let previous,
              current.read >= previous.read,
              current.write >= previous.write else { return nil }
        return DiskIOValidatedDelta(read: current.read - previous.read,
                                    write: current.write - previous.write)
    }
}

/// Every mounted volume participating in one whole-disk unmount request must resolve completely.
/// The union is assessed once, so activity on any sibling/backing member protects the whole request.
enum ForcedSleepPhysicalRequestActivityPolicy {
    static func assessment(
        backingResolutions: [Set<String>?],
        snapshot: ForcedSleepActivitySnapshot,
        expectedInventoryRevision: UInt64
    ) -> ForcedSleepActivityAssessment {
        guard let backingDisks = MountedPhysicalDiskFilterPolicy.aggregate(backingResolutions),
              !backingDisks.isEmpty else { return .unknown }
        return snapshot.assessment(
            for: backingDisks,
            expectedInventoryRevision: expectedInventoryRevision
        )
    }
}

struct ForcedSleepPhysicalProtectionCandidate: Equatable, Sendable {
    let backingPhysicalDisks: Set<String>?
    let isEjectTarget: Bool
    let isProtected: Bool
}

struct ForcedSleepPhysicalProtectionDecision: Equatable, Sendable {
    let allowedTargetIndices: Set<Int>
    let blockedTargetIndices: Set<Int>
    let skippedTargetCount: Int
}

/// Forced sleep protection is closed over the true IOKit backing SSD set, not a synthesized
/// APFS/container `diskN`. One protected volume therefore protects every logical whole disk that
/// intersects the same physical media. Any unresolved protected volume or eject target blocks the
/// entire batch because a resolved sibling request could otherwise unmount it with Whole options.
enum ForcedSleepPhysicalProtectionPolicy {
    static func evaluate(
        _ candidates: [ForcedSleepPhysicalProtectionCandidate]
    ) -> ForcedSleepPhysicalProtectionDecision {
        let unresolvedSafetyRelevantCandidate = candidates.contains {
            ($0.isProtected || $0.isEjectTarget)
                && ($0.backingPhysicalDisks?.isEmpty != false)
        }
        if unresolvedSafetyRelevantCandidate {
            let blocked = Set(candidates.indices.filter {
                candidates[$0].isEjectTarget && !candidates[$0].isProtected
            })
            let targetCount = candidates.filter(\.isEjectTarget).count
            return ForcedSleepPhysicalProtectionDecision(
                allowedTargetIndices: [],
                blockedTargetIndices: blocked,
                skippedTargetCount: targetCount
            )
        }

        let protectedBackings = candidates.reduce(into: Set<String>()) { result, candidate in
            guard candidate.isProtected,
                  let backing = candidate.backingPhysicalDisks else { return }
            result.formUnion(backing)
        }
        var allowed = Set<Int>()
        var blocked = Set<Int>()
        for index in candidates.indices {
            let candidate = candidates[index]
            guard candidate.isEjectTarget, !candidate.isProtected else { continue }
            guard let backing = candidate.backingPhysicalDisks, !backing.isEmpty else {
                blocked.insert(index)
                continue
            }
            if backing.isDisjoint(with: protectedBackings) {
                allowed.insert(index)
            } else {
                blocked.insert(index)
            }
        }
        let targetCount = candidates.filter(\.isEjectTarget).count
        return ForcedSleepPhysicalProtectionDecision(
            allowedTargetIndices: allowed,
            blockedTargetIndices: blocked,
            skippedTargetCount: targetCount - allowed.count
        )
    }
}

enum ForcedSleepProtectionRevalidationPolicy {
    static func allowsSubmission(
        requestTargetIndices: Set<Int>,
        currentDecision: ForcedSleepPhysicalProtectionDecision
    ) -> Bool {
        !requestTargetIndices.isEmpty
            && requestTargetIndices.isSubset(of: currentDecision.allowedTargetIndices)
    }
}

struct ForcedSleepPhysicalRequestDecision: Equatable, Sendable {
    let allowedRequestIndices: Set<Int>
    let blockedRequestIndices: Set<Int>
}

/// A request may own one or more physical backing disks, but no backing disk may belong to two
/// distinct DA requests in the same forced-sleep batch. Overlapping logical whole-disk identities
/// are ambiguous, so all requests in that overlap are left mounted instead of racing each other.
enum ForcedSleepPhysicalRequestUniquenessPolicy {
    static func evaluate(
        backingPhysicalDisksByRequest: [Set<String>?]
    ) -> ForcedSleepPhysicalRequestDecision {
        if backingPhysicalDisksByRequest.contains(where: { $0?.isEmpty != false }) {
            return ForcedSleepPhysicalRequestDecision(
                allowedRequestIndices: [],
                blockedRequestIndices: Set(backingPhysicalDisksByRequest.indices)
            )
        }
        var ownersByDisk: [String: Set<Int>] = [:]
        var blocked = Set<Int>()
        for index in backingPhysicalDisksByRequest.indices {
            guard let disks = backingPhysicalDisksByRequest[index] else { continue }
            for disk in disks {
                ownersByDisk[disk, default: []].insert(index)
            }
        }
        for owners in ownersByDisk.values where owners.count > 1 {
            blocked.formUnion(owners)
        }
        return ForcedSleepPhysicalRequestDecision(
            allowedRequestIndices: Set(backingPhysicalDisksByRequest.indices).subtracting(blocked),
            blockedRequestIndices: blocked
        )
    }
}

struct ForcedSleepPhysicalBatchDecision: Equatable, Sendable {
    let allowedRequestIndices: Set<Int>
    let ownershipBlockedRequestIndices: Set<Int>
    let activityBlockedRequestIndices: Set<Int>
}

/// Resolve physical ownership across the entire candidate batch before applying activity. This
/// ordering is essential: an active/unknown multi-backing request must still protect an otherwise
/// idle request that overlaps any member of its physical set.
enum ForcedSleepPhysicalBatchEligibilityPolicy {
    static func evaluate(backingPhysicalDisksByRequest: [Set<String>?],
                         assessments: [ForcedSleepActivityAssessment])
        -> ForcedSleepPhysicalBatchDecision {
        guard backingPhysicalDisksByRequest.count == assessments.count else {
            return ForcedSleepPhysicalBatchDecision(
                allowedRequestIndices: [],
                ownershipBlockedRequestIndices: Set(backingPhysicalDisksByRequest.indices),
                activityBlockedRequestIndices: []
            )
        }
        let ownership = ForcedSleepPhysicalRequestUniquenessPolicy.evaluate(
            backingPhysicalDisksByRequest: backingPhysicalDisksByRequest
        )
        let idle = Set(assessments.indices.filter { assessments[$0] == .idle })
        let allowed = ownership.allowedRequestIndices.intersection(idle)
        return ForcedSleepPhysicalBatchDecision(
            allowedRequestIndices: allowed,
            ownershipBlockedRequestIndices: ownership.blockedRequestIndices,
            activityBlockedRequestIndices: ownership.allowedRequestIndices.subtracting(idle)
        )
    }
}

/// 볼륨별 physical BSD 해석 결과를 activity filter 하나로 합친다.
/// 빈 입력은 마운트된 디스크 0개, nil/빈 원소는 부분 매핑이므로 전체 unresolved로 처리한다.
enum MountedPhysicalDiskFilterPolicy {
    static func aggregate(_ resolutions: [Set<String>?]) -> Set<String>? {
        var disks = Set<String>()
        for resolution in resolutions {
            guard let resolution, !resolution.isEmpty else { return nil }
            disks.formUnion(resolution)
        }
        return disks
    }
}

/// Forced-sleep activity grace is time-based so several request authorizers polling within a few
/// milliseconds cannot consume a nominal multi-second grace window. `nowNanoseconds` must come
/// from one monotonic clock (production uses `DispatchTime.uptimeNanoseconds`).
struct ForcedSleepRecentActivityState {
    let retentionNanoseconds: UInt64
    private var writingLastObservedAt: [String: UInt64] = [:]
    private var readingLastObservedAt: [String: UInt64] = [:]

    init(retentionNanoseconds: UInt64) {
        precondition(retentionNanoseconds > 0)
        self.retentionNanoseconds = retentionNanoseconds
    }

    mutating func update(observedWriting: Set<String>,
                         observedReading: Set<String>,
                         presentDisks: Set<String>,
                         nowNanoseconds: UInt64) -> DiskActivitySnapshot {
        writingLastObservedAt = retained(
            writingLastObservedAt,
            presentDisks: presentDisks,
            nowNanoseconds: nowNanoseconds
        )
        readingLastObservedAt = retained(
            readingLastObservedAt,
            presentDisks: presentDisks,
            nowNanoseconds: nowNanoseconds
        )
        for disk in observedWriting.intersection(presentDisks) {
            writingLastObservedAt[disk] = nowNanoseconds
        }
        for disk in observedReading.intersection(presentDisks) {
            readingLastObservedAt[disk] = nowNanoseconds
        }
        return DiskActivitySnapshot(
            writing: Set(writingLastObservedAt.keys),
            reading: Set(readingLastObservedAt.keys)
        )
    }

    mutating func reset() -> DiskActivitySnapshot {
        writingLastObservedAt.removeAll()
        readingLastObservedAt.removeAll()
        return .inactive
    }

    private func retained(_ observations: [String: UInt64],
                          presentDisks: Set<String>,
                          nowNanoseconds: UInt64) -> [String: UInt64] {
        observations.filter { disk, observedAt in
            guard presentDisks.contains(disk) else { return false }
            // A synthetic backward value cannot prove that the retention window elapsed.
            return nowNanoseconds < observedAt
                || nowNanoseconds - observedAt < retentionNanoseconds
        }
    }
}

struct DiskActivityState {
    static let defaultInactivePollLimit = 3

    let inactivePollLimit: Int
    private var writingIdlePolls: [String: Int] = [:]
    private var readingIdlePolls: [String: Int] = [:]

    init(inactivePollLimit: Int = defaultInactivePollLimit) {
        precondition(inactivePollLimit > 0)
        self.inactivePollLimit = inactivePollLimit
    }

    mutating func update(
        detectedWriting: Set<String>,
        detectedReading: Set<String>,
        observedWriting: Set<String>,
        observedReading: Set<String>,
        presentDisks: Set<String>
    ) -> DiskActivitySnapshot {
        writingIdlePolls = Self.nextIdlePolls(
            previous: writingIdlePolls,
            detected: detectedWriting,
            observed: observedWriting,
            presentDisks: presentDisks,
            inactivePollLimit: inactivePollLimit
        )
        readingIdlePolls = Self.nextIdlePolls(
            previous: readingIdlePolls,
            detected: detectedReading,
            observed: observedReading,
            presentDisks: presentDisks,
            inactivePollLimit: inactivePollLimit
        )
        return snapshot
    }

    mutating func reset() -> DiskActivitySnapshot {
        writingIdlePolls = [:]
        readingIdlePolls = [:]
        return .inactive
    }

    /// 마운트된 물리 디스크 집합이 바뀌었을 때, 더 이상 마운트되지 않은 디스크의 활동만
    /// 즉시 제거한다. 남아 있는 디스크의 inactivity grace 카운터는 그대로 보존한다.
    mutating func reconcilePresentDisks(_ presentDisks: Set<String>) -> DiskActivitySnapshot {
        writingIdlePolls = writingIdlePolls.filter { presentDisks.contains($0.key) }
        readingIdlePolls = readingIdlePolls.filter { presentDisks.contains($0.key) }
        return snapshot
    }

    private var snapshot: DiskActivitySnapshot {
        DiskActivitySnapshot(
            writing: Set(writingIdlePolls.keys),
            reading: Set(readingIdlePolls.keys)
        )
    }

    private static func nextIdlePolls(
        previous: [String: Int],
        detected: Set<String>,
        observed: Set<String>,
        presentDisks: Set<String>,
        inactivePollLimit: Int
    ) -> [String: Int] {
        var next: [String: Int] = [:]

        for bsd in detected where presentDisks.contains(bsd) {
            next[bsd] = 0
        }
        for (bsd, idlePolls) in previous where presentDisks.contains(bsd) {
            if observed.contains(bsd) {
                next[bsd] = 0
                continue
            }
            if detected.contains(bsd) {
                continue
            }
            let nextIdlePolls = idlePolls + 1
            if nextIdlePolls < inactivePollLimit {
                next[bsd] = nextIdlePolls
            }
        }
        return next
    }
}

/// IORegistry 저장장치를 앱의 외장 매체 정책에 연결한다.
///
/// 위치가 없거나 File/Virtual처럼 External/Internal 이 아닌 장치는 기존처럼 fail-closed 한다.
/// Internal 은 실제로 분리 가능한 Secure Digital 매체만 `ExternalMediaPolicy`가 허용한다.
enum DiskActivityMediaPolicy {
    static func shouldInclude(
        physicalLocation: String?,
        busProtocol: String?,
        isRemovable: Bool?,
        isEjectable: Bool?
    ) -> Bool {
        guard physicalLocation == "External" || physicalLocation == "Internal" else {
            return false
        }
        return ExternalMediaPolicy.shouldInclude(
            isInternal: physicalLocation == "Internal",
            busProtocol: busProtocol,
            isRemovable: isRemovable,
            isEjectable: isEjectable
        )
    }
}
