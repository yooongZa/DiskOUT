import Foundation

enum SystemWakeBoundarySourcePolicy {
    /// IOKit and NSWorkspace can deliver the same wake in different orders. Once IOKit is active,
    /// only its ordered HasPoweredOn stream may consume wake-owned transaction state.
    static func workspaceOwnsBoundary(powerObserverIsActive: Bool) -> Bool {
        !powerObserverIsActive
    }
}

/// Typed provenance for an automatic or explicit sleep-eject request.
///
/// Force fallback is authorized only by a trigger whose intent is known. Unknown system sleep
/// remains normal-only so a missing classification cannot silently become destructive.
enum SleepEjectTrigger: Equatable, Sendable {
    case lidClose
    case systemForced
    case systemIdle
    case displaySleep
    case ejectAndSleep
    case unknownSystemSleep

    static func systemSleep(isIdle: Bool?, lidAttributed: Bool) -> SleepEjectTrigger {
        if lidAttributed { return .lidClose }
        guard let isIdle else { return .unknownSystemSleep }
        return isIdle ? .systemIdle : .systemForced
    }

    /// Whether this trigger enters DiskOUT's established automatic/manual eject flow.
    ///
    /// A system sleep explicitly requested outside DiskOUT, or one whose cause cannot be
    /// classified, does not enter that 24-second flow. IOKit-confirmed `systemForced` may instead
    /// use the separate default-off short best-effort experiment. Lid close, idle sleep, the opt-in
    /// display flow, and DiskOUT's own Eject and Sleep remain eligible here.
    var participatesInEjectFlow: Bool {
        switch self {
        case .lidClose, .systemIdle, .displaySleep, .ejectAndSleep:
            return true
        case .systemForced, .unknownSystemSleep:
            return false
        }
    }

    var allowsForceFallback: Bool {
        switch self {
        case .lidClose, .ejectAndSleep:
            return true
        case .systemForced, .systemIdle, .displaySleep, .unknownSystemSleep:
            return false
        }
    }

    func effectiveForceFallback(masterEnabled: Bool) -> Bool {
        masterEnabled && allowsForceFallback
    }

    var logLabel: String {
        switch self {
        case .lidClose: return "lidClose"
        case .systemForced: return "systemForced"
        case .systemIdle: return "systemIdle"
        case .displaySleep: return "displaySleep"
        case .ejectAndSleep: return "ejectAndSleep"
        case .unknownSystemSleep: return "unknownSystemSleep"
        }
    }

    var isDisplaySleep: Bool {
        self == .displaySleep
    }

    var isSystemSleep: Bool {
        switch self {
        case .lidClose, .systemForced, .systemIdle, .unknownSystemSleep:
            return true
        case .displaySleep, .ejectAndSleep:
            return false
        }
    }
}

/// IOKit reports lid-close and external active sleep through the same forced-sleep boundary.
/// Only a recent physical close edge is safe to attribute to DiskOUT's lid workflow; merely being
/// closed is not evidence because clamshell mode may stay awake for hours.
enum SleepLidAttributionPolicy {
    static func updatedCloseTimestamp(previousNanoseconds: UInt64?,
                                      observedAtNanoseconds: UInt64,
                                      isNewPhysicalClose: Bool) -> UInt64? {
        isNewPhysicalClose ? observedAtNanoseconds : previousNanoseconds
    }

    static func isRecentClose(closedAtNanoseconds: UInt64?,
                              nowNanoseconds: UInt64,
                              windowNanoseconds: UInt64) -> Bool {
        guard let closedAtNanoseconds,
              nowNanoseconds >= closedAtNanoseconds else { return false }
        return nowNanoseconds - closedAtNanoseconds < windowNanoseconds
    }
}

struct SleepRemountTarget: Hashable, Sendable, Comparable {
    let wholeDiskBSD: String
    let physicalGeneration: UInt64
    let mediaRegistryEntryID: UInt64

    static func < (lhs: SleepRemountTarget, rhs: SleepRemountTarget) -> Bool {
        if lhs.wholeDiskBSD != rhs.wholeDiskBSD {
            return lhs.wholeDiskBSD < rhs.wholeDiskBSD
        }
        if lhs.physicalGeneration != rhs.physicalGeneration {
            return lhs.physicalGeneration < rhs.physicalGeneration
        }
        return lhs.mediaRegistryEntryID < rhs.mediaRegistryEntryID
    }
}

/// A failed close-time eject may be retried once when its matching recent lid sleep boundary arrives.
enum SleepLidRetryPolicy {
    static func shouldStartPowerRetry(priorSucceeded: Bool?,
                                      isSleepBoundaryTrigger: Bool,
                                      retryAlreadyStarted: Bool,
                                      hasActiveOperation: Bool) -> Bool {
        isSleepBoundaryTrigger
            && priorSucceeded == false
            && !retryAlreadyStarted
            && !hasActiveOperation
    }
}

enum SleepLidInventoryPolicy {
    /// Joining an operation from another close generation is only an ordering barrier; the new
    /// close still needs a fresh inventory after that older operation completes.
    static func needsRefreshAfterJoiningActive(previousGeneration: UInt64?,
                                               requestedGeneration: UInt64) -> Bool {
        previousGeneration != requestedGeneration
    }

    /// Repeated joins for the same close generation must preserve the episode-local force ledger.
    /// A new generation or a missing ledger receives a fresh/requested instance instead.
    static func shouldReplaceForceClaimLedger(previousGeneration: UInt64?,
                                              requestedGeneration: UInt64,
                                              hasExistingLedger: Bool) -> Bool {
        previousGeneration != requestedGeneration || !hasExistingLedger
    }

    /// A fresh inventory for the current lid episode keeps that episode's ledger even when an
    /// older power-boundary chain offers its own ledger as a fallback.
    static func shouldPreferExistingForceClaimLedger(episodeGeneration: UInt64?,
                                                     requestedGeneration: UInt64,
                                                     hasExistingLedger: Bool) -> Bool {
        episodeGeneration == requestedGeneration && hasExistingLedger
    }

    /// Power ACK may finish only after the current closed-lid generation has completed a fresh
    /// inventory. An explicit mounted-media event also keeps the boundary open.
    static func needsBoundaryRefresh(currentClosedGeneration: UInt64?,
                                     completedInventoryGeneration: UInt64?,
                                     explicitRefreshPending: Bool) -> Bool {
        guard let currentClosedGeneration else { return false }
        return explicitRefreshPending
            || completedInventoryGeneration != currentClosedGeneration
    }
}

enum PowerBoundaryEjectAction: Equatable, Sendable {
    case waitForActive
    case refreshInventory
    case retry
    case finish
}

enum PowerBoundaryEjectPolicy {
    static func nextAction(deadlineRemaining: Bool,
                           hasDifferentActiveOperation: Bool,
                           inventoryRefreshPending: Bool,
                           hasRunFreshBoundaryInventory: Bool,
                           lastAttemptSucceeded: Bool,
                           retryAlreadyStarted: Bool) -> PowerBoundaryEjectAction {
        guard deadlineRemaining else { return .finish }
        if hasDifferentActiveOperation { return .waitForActive }
        if inventoryRefreshPending || !hasRunFreshBoundaryInventory {
            return .refreshInventory
        }
        if !lastAttemptSucceeded && !retryAlreadyStarted {
            return .retry
        }
        return .finish
    }
}

/// lid close → clean unmount → lid/wake remount 한 사건의 순서를 보존하는 pure state machine.
/// AppDelegate 는 한 lock 아래에서만 이 값을 변경하고, 지연 작업에는 generation token 을 전달한다.
struct SleepEpisodeCoordinator: Sendable {
    struct RemountToken: Equatable, Hashable, Sendable {
        let lidGeneration: UInt64
        let nonce: UInt64
    }

    struct RemountSchedule: Equatable, Sendable {
        let token: RemountToken
    }

    struct RemountWork: Equatable, Sendable {
        let token: RemountToken
        let disks: Set<SleepRemountTarget>
        let operationID: String
        let reason: String
    }

    enum LidCloseTransition: Equatable, Sendable {
        case newEpisode(UInt64)
        case repeated(UInt64)

        var generation: UInt64 {
            switch self {
            case let .newEpisode(value), let .repeated(value): return value
            }
        }

        var isNewEpisode: Bool {
            if case .newEpisode = self { return true }
            return false
        }
    }

    private(set) var isLidClosed = false
    private(set) var lidGeneration: UInt64 = 0
    private(set) var pendingTargets = Set<SleepRemountTarget>()
    private(set) var operationID: String?
    private(set) var operationReason: String?
    /// A lid/display automatic eject episode owns the shared Music/Photos relaunch ledger until
    /// its matching open/wake edge. A failed manual Eject and Sleep must not drain that ledger.
    private(set) var lidEjectEpisodeActive = false
    private(set) var displayEjectEpisodeActive = false

    private var remountRequested = false
    private var nextRemountNonce: UInt64 = 0
    private var scheduledRemount: RemountToken?
    private var activeRemount: RemountToken?
    /// lid close/new eject가 이미 실행 중인 worker를 무효화한 경우, 그 worker의 최종 canceled
    /// 결과는 한 번만 받아 pending target으로 되돌린다. 임의의 stale token은 state를 못 바꾼다.
    private var invalidatedActiveRemounts = Set<RemountToken>()

    mutating func setInitialLidState(closed: Bool) {
        isLidClosed = closed
        if closed, lidGeneration == 0 {
            lidGeneration = 1
        }
    }

    mutating func lidDidClose() -> LidCloseTransition {
        if isLidClosed {
            return .repeated(lidGeneration)
        }
        isLidClosed = true
        lidGeneration &+= 1
        if lidGeneration == 0 { lidGeneration = 1 }
        remountRequested = false
        scheduledRemount = nil
        if let activeRemount {
            invalidatedActiveRemounts.insert(activeRemount)
        }
        activeRemount = nil
        return .newEpisode(lidGeneration)
    }

    mutating func lidDidOpen() -> RemountSchedule? {
        isLidClosed = false
        lidEjectEpisodeActive = false
        remountRequested = true
        return makeScheduleIfNeeded()
    }

    mutating func lidEjectDidStart() {
        guard isLidClosed else { return }
        lidEjectEpisodeActive = true
    }

    mutating func displayEjectDidStart() {
        displayEjectEpisodeActive = true
    }

    mutating func displayDidWake() {
        displayEjectEpisodeActive = false
    }

    /// Whether an automatic episode still owns the shared library-app relaunch boundary. Pending
    /// or in-flight remount work remains an owner after the physical wake/open edge.
    var hasAutomaticLibraryAppRelaunchOwner: Bool {
        lidEjectEpisodeActive
            || displayEjectEpisodeActive
            || !pendingTargets.isEmpty
            || scheduledRemount != nil
            || activeRemount != nil
    }

    /// 새 automatic eject가 시작되면 이전 wake 요청/timer를 무효화한다. 이미 clean-unmounted인
    /// target은 보존해 다음 실제 wake/open에서 다시 처리한다.
    mutating func automaticEjectDidStart(operationID: String, reason: String) {
        self.operationID = operationID
        operationReason = reason
        remountRequested = false
        scheduledRemount = nil
        if let activeRemount {
            invalidatedActiveRemounts.insert(activeRemount)
        }
        activeRemount = nil
    }

    /// Explicit DA clean callback 을 받은 whole BSD만 추가한다. 기존 target 은 덮어쓰지 않는다.
    /// open/wake가 callback보다 먼저 왔다면 이 시점에 지연 remount를 예약한다.
    mutating func recordCleanUnmountTargets(_ disks: Set<SleepRemountTarget>,
                                            operationID: String,
                                            reason: String) -> RemountSchedule? {
        pendingTargets.formUnion(disks)
        self.operationID = operationID
        operationReason = reason
        // wake/open을 이미 소비한 active remount 도중 다른 disk의 clean callback이 늦게 오면,
        // 현재 worker 종료 직후 그 새 target을 위한 follow-up schedule이 필요하다.
        if activeRemount != nil, !isLidClosed {
            remountRequested = true
        }
        return makeScheduleIfNeeded()
    }

    /// system/display wake. lid가 닫혀 있으면 Amphetamine dark-wake 등으로 보고 보류한다.
    mutating func wakeDidOccur() -> RemountSchedule? {
        guard !isLidClosed else { return nil }
        remountRequested = true
        return makeScheduleIfNeeded()
    }

    mutating func claimRemount(_ token: RemountToken) -> RemountWork? {
        guard scheduledRemount == token,
              activeRemount == nil,
              !isLidClosed,
              remountRequested,
              !pendingTargets.isEmpty else { return nil }

        scheduledRemount = nil
        activeRemount = token
        // open/wake eligibility는 이 한 batch가 끝나도 유지한다. 여러 DA callback이 수십 초
        // 간격으로 도착할 수 있어, 마지막 worker 종료 뒤 온 clean target도 즉시 예약해야 한다.
        let disks = pendingTargets
        pendingTargets.removeAll()
        return RemountWork(token: token,
                           disks: disks,
                           operationID: operationID ?? "-",
                           reason: operationReason ?? "-")
    }

    func isRemountAllowed(_ token: RemountToken) -> Bool {
        activeRemount == token && !isLidClosed
    }

    /// lid가 다시 닫혀 중단한 disk만 requeue한다. 성공/사용자 분리/mount 실패는 기존처럼 종료한다.
    mutating func finishRemount(_ token: RemountToken,
                                canceledDisks: Set<SleepRemountTarget>) -> RemountSchedule? {
        let accepted: Bool
        if activeRemount == token {
            activeRemount = nil
            accepted = true
        } else {
            accepted = invalidatedActiveRemounts.remove(token) != nil
        }
        guard accepted else { return nil }
        pendingTargets.formUnion(canceledDisks)
        return makeScheduleIfNeeded()
    }

    private mutating func makeScheduleIfNeeded() -> RemountSchedule? {
        guard remountRequested,
              !isLidClosed,
              !pendingTargets.isEmpty,
              scheduledRemount == nil,
              activeRemount == nil else { return nil }
        nextRemountNonce &+= 1
        if nextRemountNonce == 0 { nextRemountNonce = 1 }
        let token = RemountToken(lidGeneration: lidGeneration,
                                 nonce: nextRemountNonce)
        scheduledRemount = token
        return RemountSchedule(token: token)
    }
}
