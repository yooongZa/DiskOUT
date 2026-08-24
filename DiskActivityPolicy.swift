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
