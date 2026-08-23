//
//  AppDelegate.swift
//  DiskOUT — 혼자 쓰는 초간단 버전 (구 EjectDrives)
//
//  - 메뉴바 아이콘 + 드라이브 목록 + 모두 추출
//  - 잠자기 진입 시 자동 추출 + wake 시 자동 재마운트 한 쌍
//  - DMG / sparseimage 는 자동 제외 (Chrome.dmg 같은 마운트 보호)
//  - 전역 단축키 ⌥⌘E
//  - 우클릭 = 모두 추출
//  - 추출 결과 알림
//

import Cocoa
import UserNotifications
import Carbon.HIToolbox
import Darwin
import DiskArbitration
import IOKit
import IOKit.pwr_mgt
import os
import ServiceManagement
import Sparkle

/// 통합 로깅 (unified logging) — Console.app 에서 다음 명령으로 확인:
///   log stream --predicate 'subsystem == "com.yongza.ejectdrives"' --info
private let log = Logger(subsystem: "com.yongza.ejectdrives", category: "app")

/// 디자인 토큰 — UI 전반에서 공유하는 시각 상수의 단일 출처.
/// 새 UI 를 만들 때는 여기 값을 먼저 쓰고, 없는 값이 필요하면 여기에 추가한다.
/// 표기 컨벤션 (Title Case · "…" · 이모지 금지 등) 은 CLAUDE.md "UI 컨벤션" 참조.
private enum UI {
    // 간격
    static let spacing: CGFloat = 14          // 표준 stack 간격 (설정/온보딩 공통)
    static let rowSpacing: CGFloat = 10       // 행 내부 요소 간격
    static let windowPadding: CGFloat = 24    // 창 가장자리 콘텐츠 여백

    // 폰트 크기 (메뉴/메뉴바는 ofSize: 0 = 시스템 기본을 그대로 사용)
    static let titleSize: CGFloat = 16        // 창 헤더 타이틀
    static let bodySize: CGFloat = 13         // 본문/카드 타이틀
    static let captionSize: CGFloat = 11      // 보조 설명 — 최소 가독 크기, 더 줄이지 않는다

    // 메뉴바 상태점 (활동/업데이트)
    static let statusCountSize: CGFloat = 9   // Premium 캐릭터 옆 보조 숫자
    static let dotSize: CGFloat = 8           // 색점 글리프 크기
    static let dotBaselineOffset: CGFloat = 2 // 색점을 숫자/텍스트 광학 중심에 맞추는 오프셋
}

private let ioMessageCanSystemSleep: UInt32 = 0xe0000270
private let ioMessageSystemWillSleep: UInt32 = 0xe0000280
private let ioMessageSystemWillNotSleep: UInt32 = 0xe0000290
private let ioMessageSystemHasPoweredOn: UInt32 = 0xe0000300
private let ioPMMessageClamshellStateChange = UInt32(bitPattern: Int32(-536657664))
private let clamshellStateBit = 1 << 0
private let clamshellSleepBit = 1 << 1
/// willSleep 핸들러가 '이 잠자기가 뚜껑 닫음으로 인한 것인지' 판정하는 시간 창.
/// 뚜껑 닫힘 → 시스템 willSleep 은 보통 1~2초 내 도착하므로 넉넉히 15초.
/// 이 안에 직전 뚜껑 닫힘이 있으면 lid-caused 로 보고 LidCloseEject 게이트를, 아니면 SleepEject 게이트를 적용.
private let clamshellSleepAttributionWindow: TimeInterval = 15

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {

    private var statusItem: NSStatusItem!
    private let statusCharacterAnimator = StatusCharacterAnimator()
    private var billingController: PaddleBillingController?
    private var pendingPremiumRefreshCallback = false
    private var isTerminating = false
    private var isPurchaseInProgress = false
    private var isOpeningPurchaseDetails = false
    private var isCheckingPurchaseStatus = false
    private var isRestoringPurchase = false
    private var recoveryCodeClipboardClearWorkItem: DispatchWorkItem?
    private var recoveryCodeClipboardChangeCount: Int?
    /// 진행/결과 symbol 이 Premium animation tick 에 덮이지 않도록 main-thread 에서만 갱신.
    private var isTransientStatusIconVisible = false

    // MARK: - Sparkle (자동 업데이트)
    //
    // 조용한 알림(gentle reminder) 패턴 — 자동 체크에서 새 버전 발견되어도 다이얼로그를
    // 즉시 띄우지 않고 메뉴바 아이콘에 빨간 점 + 메뉴 안 항목으로만 표시.
    // 사용자가 그 항목 클릭하거나 "업데이트 확인…" 메뉴 클릭 시 표준 Sparkle 다이얼로그 띄움.
    //
    // 구성 요소:
    //   updaterController       : Sparkle 표준 컨트롤러 (UI = 시스템 기본 다이얼로그)
    //   pendingUpdate           : 자동 체크에서 발견된 미설치 업데이트.
    //                             nil ↔ 값 변화 시 메뉴바 아이콘(applyCountTitle) 즉시 갱신.
    private var updaterController: SPUStandardUpdaterController!
    private var pendingUpdate: SUAppcastItem? {
        didSet {
            // 메뉴바 빨간 점 표시/제거 — 반드시 main thread.
            DispatchQueue.main.async { [weak self] in
                self?.applyCountTitle()
            }
        }
    }

    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    /// 언어 변경 재시작은 새 인스턴스의 ready 신호를 받은 경우에만 현재 앱을 종료한다.
    /// 모든 callback 은 main queue 에서 token 을 대조해 timeout/늦은 응답 경쟁을 차단한다.
    private var languageRelaunchAttempt = AppLanguageRelaunchAttempt()
    private var acceptedLanguageRelaunchToken: String?
    private var languageRelaunchReadyObserver: NSObjectProtocol?
    private var languageRelaunchTimeoutWorkItem: DispatchWorkItem?
    private var languageRelaunchCandidate: NSRunningApplication?
    private var lastEjectAt: Date = .distantPast
    private var lastMountAt: Date = .distantPast
    /// 마지막 추출 결과 symbol (wake 후 복원용). nil 이면 default ⏏ 표시.
    private var lastResultSymbol: String?
    /// flashIcon 의 지연 reset 이 그 사이 set 된 결과 아이콘을 덮어쓰는 race 방지용.
    /// flashIcon 호출 시 +1, reset 시점에 같은 값이면 그대로 reset, 다르면 skip.
    /// setPersistentIcon / resetIcon 도 +1 해서 진행중인 reset 무효화.
    private var iconFlashGeneration: Int = 0
    /// 자동 추출 / wake remount 관련 state — `sleepEjectQueue` 와 main thread 양쪽에서 접근하므로
    /// 반드시 `autoEjectStateLock` 으로 감싼다. 직접 storage 는 _ prefix, public 접근은 computed
    /// property 로 lock 자동 적용.
    private let autoEjectStateLock = NSLock()
    /// Serializes physical lid transitions with background retry/refresh reservations.
    private let lidTransitionGate = NSLock()
    /// automatic remount의 token 확인→mount command 시작과 새 lid/eject invalidation을 원자화한다.
    /// 새 eject worker는 이미 시작된 mount command가 끝난 뒤 inventory를 잡아야 한다.
    private let automaticRemountCommandGate = NSLock()
    private let automaticRemountCommandGroup = DispatchGroup()
    /// 자동 추출 대상과 lid/remount generation 을 한 lock 아래에서 변경한다.
    /// 수동 추출(단축키/메뉴)은 여기에 들어가지 않아 사용자 의도를 그대로 보존한다.
    private var sleepEpisodeCoordinator = SleepEpisodeCoordinator()
    private var autoEjectedDisks: Set<SleepRemountTarget> {
        autoEjectStateLock.lock()
        defer { autoEjectStateLock.unlock() }
        return sleepEpisodeCoordinator.pendingTargets
    }
    /// 자동 추출부터 wake/remount 까지 같은 사건을 묶는 진단용 ID.
    private var autoEjectOperationID: String? {
        autoEjectStateLock.lock()
        defer { autoEjectStateLock.unlock() }
        return sleepEpisodeCoordinator.operationID
    }
    private var autoEjectOperationReason: String? {
        autoEjectStateLock.lock()
        defer { autoEjectStateLock.unlock() }
        return sleepEpisodeCoordinator.operationReason
    }
    /// `Eject and Sleep` 이 이미 추출한 직후 들어오는 willSleep 중복 자동 추출 방지.
    private var _skipSleepAutoEjectUntil: Date?
    private var skipSleepAutoEjectUntil: Date? {
        get { autoEjectStateLock.lock(); defer { autoEjectStateLock.unlock() }; return _skipSleepAutoEjectUntil }
        set { autoEjectStateLock.lock(); defer { autoEjectStateLock.unlock() }; _skipSleepAutoEjectUntil = newValue }
    }
    /// 마지막으로 뚜껑이 닫힌 시각. willSleep 의 원인(lid-caused) 판정용 — 두 토글 분리의 핵심 상태.
    private var _lastClamshellCloseAt: Date?
    private var lastClamshellCloseAt: Date? {
        get { autoEjectStateLock.lock(); defer { autoEjectStateLock.unlock() }; return _lastClamshellCloseAt }
        set { autoEjectStateLock.lock(); defer { autoEjectStateLock.unlock() }; _lastClamshellCloseAt = newValue }
    }
    private var powerRootPort: io_connect_t = 0
    private var powerNotifyPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var powerSleepAckCoordinator: PowerSleepAckCoordinator?
    private let powerSleepCycleLock = NSLock()
    private var powerSleepCycleDeduplicator = PowerSleepCycleDeduplicator()
    /// DA queue의 global external-mount barrier를 소유한 현재 power cycle token.
    /// Main power callback 경계에서만 변경한다.
    private var powerSleepMountBarrierToken: UInt64?
    private var clamshellRootDomain: io_service_t = 0
    private var clamshellNotifier: io_object_t = 0
    private let sleepEjectQueue = DispatchQueue(label: "com.yongza.ejectdrives.sleep.eject")
    /// Serializes task reservation itself. Lid refresh holds this gate while consuming its pending
    /// flag, so display/workspace triggers cannot slip a different task into that claim→start gap.
    private let sleepEjectStartGate = NSLock()
    private let sleepEjectStateLock = NSLock()
    private typealias SleepEjectTask = (
        operationID: String,
        group: DispatchGroup,
        outcome: SleepEjectOutcomeBox,
        started: Bool,
        reason: String,
        trigger: SleepEjectTrigger,
        forceClaims: SleepEpisodeForceClaimLedger
    )
    private var activeSleepEjectGroup: DispatchGroup?
    private var activeSleepEjectOperationID: String?
    private var activeSleepEjectReason: String?
    private var activeSleepEjectTrigger: SleepEjectTrigger?
    private var activeSleepEjectForceClaims: SleepEpisodeForceClaimLedger?
    private var activeSleepEjectOutcome: SleepEjectOutcomeBox?
    /// lid가 닫혀 있는 동안 해당 close episode의 completed group을 보관해, Amphetamine
    /// session 종료로 늦게 도착한 willSleep이 새 unmount cycle을 만들지 않게 한다.
    private var lidEpisodeGeneration: UInt64?
    private var lidEpisodeGroup: DispatchGroup?
    private var lidEpisodeOperationID: String?
    private var lidEpisodeOutcome: SleepEjectOutcomeBox?
    private var lidEpisodeTrigger: SleepEjectTrigger?
    private var lidEpisodeForceClaims: SleepEpisodeForceClaimLedger?
    /// 현재 close generation에 실제 fresh inventory worker가 끝났다는 positive proof.
    /// Power ACK는 이 값이 current closed generation과 같아질 때까지 refresh를 연쇄한다.
    private var lidEpisodeInventoryCompletedGeneration: UInt64?
    private var lidEpisodePowerRetryStarted = false
    private var lidEpisodeNeedsInventoryRefresh = false
    /// logout/restart/shutdown 전 자동 추출은 현재 제품 가치가 낮아 기본 비활성화.
    private let powerOffAutoEjectEnabled = false
    /// logout/restart/shutdown 직전 자동 추출 상태.
    private var powerOffEjectInProgress = false
    private var powerOffEjectCompleted = false
    private var shouldEjectBeforeTerminate = false
    private var pendingTerminateReplyApp: NSApplication?
    /// 현재 마운트된 외장 저장장치(물리 디바이스) 개수 — 메뉴바에 숫자(텍스트)로 표시.
    /// launch / mount·unmount 노티 / wake 시 갱신. main thread 에서만 접근.
    private var mountedDriveCount: Int = 0
    /// count 아이콘 refresh debounce 토큰 — 다중 파티션 디스크의 연쇄 노티 coalescing.
    private var countIconRefreshToken: Int = 0
    /// 마지막으로 확인한 알림 권한 상태. `getNotificationSettings` 가 비동기라 메뉴에서
    /// 동기 표시할 수 없어 캐싱. launch / menu 열 때 background refresh.
    private var lastKnownNotificationStatus: UNAuthorizationStatus = .notDetermined
    /// 알림 권한을 launch 시가 아니라 "첫 알림 직전"에 1회 요청하기 위한 가드.
    private var didRequestNotificationAuthorization = false
    /// 현재 쓰기/읽기 I/O 가 진행 중인 외장 **물리** whole-disk BSD 집합 (예: ["disk7","disk8"]).
    /// `DiskIOMonitor` 가 갱신. 메뉴에서 각 볼륨의 backing 물리 디스크와 교집합으로 "이 디스크가
    /// 쓰는 중/읽는 중" 을 판정. main thread 에서만 접근.
    private var writingPhysicalBSDs: Set<String> = []
    private var readingPhysicalBSDs: Set<String> = []
    /// 외장 어딘가에 읽기/쓰기가 진행 중인지 — 메뉴바 숫자 옆 systemBlue `●` + tooltip 표시 여부.
    /// (읽기·쓰기 모두 "분리하면 작업 깨짐" 이므로 닷은 동일, 종류 구분은 tooltip 문구로.)
    private var isDiskActive: Bool { !writingPhysicalBSDs.isEmpty || !readingPhysicalBSDs.isEmpty }

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Register before didFinishLaunching so a custom URL that cold-launches this LSUIElement
        // app cannot arrive before the Apple Event handler exists.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handlePremiumRefreshURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Resolve the legacy lid-only preference before any sleep callback or Settings view can
        // read either modern key. Doing both values in one pass removes getter-order dependence.
        SleepEjectSettingsMigration.migrate(in: .standard)
        ReportEndpoint.setReportingEnabled(SettingsStore.crashReportingEnabled)

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // 추출 실패 시 "끄고 재시도" 액션 카테고리 — launch 시 등록해야 첫 알림부터 버튼이 뜬다.
        let retryAction = UNNotificationAction(
            identifier: EjectNotification.retryAction,
            title: String(localized: "Quit apps and retry"),
            options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: EjectNotification.retryCategory,
                                   actions: [retryAction],
                                   intentIdentifiers: [],
                                   options: [])
        ])
        // 알림 권한은 launch 시 요청하지 않는다 — 사용자가 아무것도 안 했는데 팝업이 뜨는 안티패턴.
        // 요청 시점: 온보딩 카드의 "허용" 버튼, 또는 첫 알림 직전 (ensureNotificationAuthorizationRequested).
        // 여기선 메뉴 권한 경고 표시용으로 현재 상태만 읽어 캐싱.
        center.getNotificationSettings { [weak self] settings in
            log.notice("notif settings: authStatus=\(settings.authorizationStatus.rawValue, privacy: .public) alert=\(settings.alertSetting.rawValue, privacy: .public) center=\(settings.notificationCenterSetting.rawValue, privacy: .public)")
            // authStatus: 0=notDetermined 1=denied 2=authorized 3=provisional 4=ephemeral
            DispatchQueue.main.async {
                self?.lastKnownNotificationStatus = settings.authorizationStatus
            }
        }

        setupStatusItem()
        setupPremiumStatusPresentation()
        if pendingPremiumRefreshCallback {
            pendingPremiumRefreshCallback = false
            billingController?.refreshAfterPurchaseCallback()
        }
        setupSparkleUpdater()
        setupSleepObserver()
        setupPowerSleepObserver()
        setupClamshellObserver()
        // DA inventory 가 0.5s 내 ready 되면 DiskMenuSnapshotCache.warm() 가 자동으로
        // DA 경로 사용. 그 전엔 diskutil fallback. 순서 보장 위해 start() 가 warm() 보다 먼저.
        // 메뉴바 숫자 자가 보정: DA 인벤토리 변경 시마다 재계산. start() 보다 먼저 hook 을
        // 걸어야 초기 enumeration 이벤트(기존 디스크들)도 빠짐없이 받는다.
        DAInventory.shared.onInventoryChanged = { [weak self] change in
            // Keep the safety state on the DA event boundary itself. Power ACK calls
            // `flushPendingEvents()`, so a mount observed before that barrier must already have
            // marked the required lid-closed refresh; UI count work can remain on main.
            switch change {
            case .mountedExternal, .safetyRefreshRequired:
                self?.handleExternalMediaMountedWhileLidClosed()
            case .other:
                break
            }
            DispatchQueue.main.async {
                self?.scheduleMountedDriveCountRefresh()
            }
        }
        DAInventory.shared.start()
        // 외장 쓰기 활동 표시 — 모니터 폴링은 updateMountedDriveCount 가 외장 유무로 start/stop.
        DiskIOMonitor.shared.onActivityChanged = { [weak self] writingBSDs, readingBSDs in
            self?.setDiskActivity(writing: writingBSDs, reading: readingBSDs)
        }
        DiskMenuSnapshotCache.warm()
        // launch 시 초기 1회 — DA hook 이 enumeration 중 트리거하지만, DA 가 끝내 ready
        // 안 되는 환경 대비 안전망.
        scheduleMountedDriveCountRefresh(after: 0.7)
        installHotkey()
        log.notice("EjectDrives launched")

        // 크래시 사후 수확 — macOS 가 적어둔 `.ips` 중 새 것만 스캔·스크럽·전송. 절대 launch 를 막지 않음
        // (백그라운드 utility 큐, best-effort, 모든 에러 swallow). crashReportingEnabled OFF 면 전부 no-op.
        CrashReporter.harvestIfEnabled()

        // 권한 온보딩 — 콘텐츠 버전이 올라갔거나 처음이면 1회 표시. 비차단 (앱은 이미 동작 중).
        // 메뉴바 아이콘이 자리잡은 뒤 살짝 지연해서 띄운다.
        let onboardingDone = SettingsStore.onboardingCompletedVersion
        log.notice("onboarding gate: completedVersion=\(onboardingDone, privacy: .public) appVersion=\(OnboardingWindowController.version, privacy: .public)")
        if onboardingDone < OnboardingWindowController.version {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showOnboardingWindow()
            }
        }

        // 언어 변경으로 띄운 새 인스턴스만 고유 token 을 돌려준다. 기존 인스턴스는 이 신호를
        // 받은 뒤에만 종료하므로 open 접수만 성공하고 실제 launch 가 실패하는 경우에도 유지된다.
        if let token = AppLanguageRelaunch.token(in: CommandLine.arguments) {
            DistributedNotificationCenter.default().postNotificationName(
                AppLanguageRelaunch.readyNotification,
                object: nil,
                userInfo: ["token": token],
                deliverImmediately: true
            )
            log.notice("Language relaunch ready: \(token, privacy: .public)")
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isTerminating else { return }
        settingsWindowController?.refreshExternalState()
        billingController?.refreshAfterReturningFromCheckout()
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        isPurchaseInProgress = false
        isOpeningPurchaseDetails = false
        isCheckingPurchaseStatus = false
        isRestoringPurchase = false
        recoveryCodeClipboardClearWorkItem?.cancel()
        recoveryCodeClipboardClearWorkItem = nil
        clearCopiedRecoveryCodeIfUnchanged()
        statusCharacterAnimator.invalidate()
        billingController?.stop()
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        clearLanguageRelaunchAttempt(terminateCandidate: acceptedLanguageRelaunchToken == nil)
        tearDownPowerSleepObserver()
    }

    /// `diskout://premium/refresh` can be invoked by any local process, so it is deliberately a
    /// parameter-free, exact-match hint. It cannot mutate billing state or unlock Premium; it only
    /// starts the normal authenticated request whose Ed25519 response is verified by the controller.
    @objc private func handlePremiumRefreshURL(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard !isTerminating,
              let rawURL = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: rawURL),
              PremiumRefreshCallbackPolicy.accepts(url) else {
            log.error("Rejected malformed Premium refresh callback")
            return
        }

        guard let billingController else {
            pendingPremiumRefreshCallback = true
            return
        }
        log.notice("Accepted Premium refresh callback")
        billingController.refreshAfterPurchaseCallback()
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            applyCountTitle()
            // 좌클릭 + 우클릭 둘 다 button.action 으로 받음.
            // action handler 안에서 NSApp.currentEvent.type 으로 분기.
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // mouse event mask 는 button 과 cell 양쪽에 설정 — NSStatusBarButton 에서
            // 한쪽만 설정하면 무시되는 케이스 보호.
            // .leftMouseDown/.rightMouseDown 으로 down 시점에 발화 (메뉴 표시 timing 일치).
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            (button.cell as? NSButtonCell)?.sendAction(on: [.leftMouseDown, .rightMouseDown])

            // macOS 26 워크어라운드: NSStatusBarWindow 의 height=0 갇힘 방지.
            // WindowServer 에 등록 안 되거나 frame 이 0 으로 갇히는 케이스에서 메뉴바 아이콘이
            // 표시 안 됨. setFrame + orderFrontRegardless 로 강제 등록 + frame 보장.
            // (이 두 줄이 빠지면 일부 환경에서 메뉴바 아이콘 자체가 안 보임 — 자세한 내용은 README 참조)
            if let win = button.window {
                let thickness = NSStatusBar.system.thickness
                win.setFrame(NSRect(x: 0, y: 0, width: 32, height: thickness),
                             display: true, animate: false)
                win.orderFrontRegardless()
            }
        }
    }

    /// Verified Paddle access changes only the status-item presentation. Disk discovery,
    /// eject, mount, sleep, update, and notification behavior stay outside this gate.
    private func setupPremiumStatusPresentation() {
        statusCharacterAnimator.onFrameChanged = { [weak self] in
            self?.updateAnimatedStatusCharacterFrame()
        }

        let controller = PaddleBillingController()
        controller.onAccessChanged = { [weak self] granted in
            guard let self else { return }
            log.info("Premium status presentation access → \(granted, privacy: .public)")
            self.applyCountTitle()
            self.settingsWindowController?.refreshExternalState()
        }
        controller.onPurchasePollingChanged = { [weak self] polling in
            self?.isPurchaseInProgress = polling
            self?.settingsWindowController?.refreshExternalState()
        }
        billingController = controller
        controller.start()
    }

    /// Animation may update only the image portion. The right-side count and activity/update
    /// dots are owned by applyCountTitle(), and transient/result symbols always take priority.
    private func updateAnimatedStatusCharacterFrame() {
        guard Thread.isMainThread,
              !isTransientStatusIconVisible,
              lastResultSymbol == nil,
              hasPremiumStatusPresentationAccess else { return }

        let presentation = StatusItemPresentationPolicy.presentation(
            count: mountedDriveCount,
            premiumState: .verified,
            hasCharacterAsset: statusCharacterAnimator.hasFrames(for:)
        )
        guard case .premiumCharacter(let count) = presentation.visual,
              let image = statusCharacterAnimator.image(for: count) else { return }
        statusItem.button?.image = image
    }

    /// `DISKOUT_PREMIUM_PREVIEW` opens only the character presentation for a local demo build.
    /// Distributable builds omit the flag and continue to require a verified signed lease.
    private var hasPremiumStatusPresentationAccess: Bool {
        PremiumRuntimeMode.hasPresentationAccess(
            verifiedBillingAccess: billingController?.hasPremiumAccess == true
        )
    }

    // MARK: - Sparkle Updater Setup

    /// Sparkle 자동 업데이트 컨트롤러 초기화.
    /// startingUpdater: true → 자체 스케줄 (24h, Info.plist `SUScheduledCheckInterval`) 시작.
    /// userDriverDelegate: gentle reminder 패턴을 위해 self 가 응답.
    private func setupSparkleUpdater() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        log.notice("Sparkle: updater started (auto-check interval=\(self.updaterController.updater.updateCheckInterval, privacy: .public)s, automaticallyChecks=\(self.updaterController.updater.automaticallyChecksForUpdates, privacy: .public))")
    }

    /// 메뉴의 "업데이트 확인…" 항목 — 사용자 직접 트리거.
    /// userInitiated 라서 SPUStandardUserDriverDelegate 가 다이얼로그 가로채지 않음.
    @objc func checkForUpdatesFromMenu(_ sender: Any?) {
        log.notice("Sparkle: user-initiated check")
        updaterController.checkForUpdates(sender)
    }

    /// 자동 체크에서 발견되어 보류 중인 업데이트 다이얼로그 표시.
    /// checkForUpdates 를 다시 호출하면 Sparkle 이 캐시된 업데이트를 즉시 표시함.
    @objc func showPendingUpdate(_ sender: Any?) {
        log.notice("Sparkle: user clicked pending-update menu item")
        updaterController.checkForUpdates(sender)
    }

    @objc private func purchasePremiumStatusIcons(_ sender: Any?) {
        guard canPresentBillingUI,
              !isPurchaseInProgress,
              !isCheckingPurchaseStatus,
              !isRestoringPurchase else { return }
        guard let billingController, let checkoutURL = billingController.checkoutURL else { return }
        guard NSWorkspace.shared.open(checkoutURL) else {
            showBillingBrowserError()
            return
        }
        billingController.startPurchasePolling()
    }

    @objc private func stopPremiumPurchaseCheck(_ sender: Any?) {
        guard canPresentBillingUI,
              isPurchaseInProgress,
              let billingController else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Stop Checking for Purchase?")
        alert.informativeText = String(localized: "This does not cancel an open Paddle checkout. Close that checkout before starting another purchase.")
        alert.addButton(withTitle: String(localized: "Stop Checking"))
        alert.addButton(withTitle: String(localized: "Keep Checking"))
        guard alert.runModal() == .alertFirstButtonReturn,
              canPresentBillingUI else { return }
        billingController.cancelPurchasePolling()
    }

    @objc private func viewPremiumPurchaseDetails(_ sender: Any?) {
        guard canPresentBillingUI,
              !isOpeningPurchaseDetails,
              let billingController else { return }
        isOpeningPurchaseDetails = true
        settingsWindowController?.refreshExternalState()
        billingController.requestPurchaseDetailsURL { [weak self] portalURL in
            guard let self else { return }
            self.isOpeningPurchaseDetails = false
            self.settingsWindowController?.refreshExternalState()
            guard self.canPresentBillingUI else { return }
            guard let portalURL, NSWorkspace.shared.open(portalURL) else {
                self.showBillingBrowserError()
                return
            }
        }
    }

    @objc private func copyPremiumRecoveryCode(_ sender: Any?) {
        guard canPresentBillingUI,
              let recoveryCode = billingController?.recoveryCode else { return }
        recoveryCodeClipboardClearWorkItem?.cancel()
        recoveryCodeClipboardClearWorkItem = nil
        recoveryCodeClipboardChangeCount = nil
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(recoveryCode, forType: .string) else { return }
        recoveryCodeClipboardChangeCount = pasteboard.changeCount
        let clearWorkItem = DispatchWorkItem { [weak self] in
            self?.clearCopiedRecoveryCodeIfUnchanged()
        }
        recoveryCodeClipboardClearWorkItem = clearWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: clearWorkItem)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Recovery Code Copied")
        alert.informativeText = String(localized: "Keep this code private—it can move Premium. The clipboard clears after two minutes, but clipboard managers may retain it.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    private func clearCopiedRecoveryCodeIfUnchanged() {
        defer {
            recoveryCodeClipboardChangeCount = nil
            recoveryCodeClipboardClearWorkItem = nil
        }
        guard let expectedChangeCount = recoveryCodeClipboardChangeCount else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expectedChangeCount else { return }
        pasteboard.clearContents()
    }

    @objc private func restorePremiumPurchase(_ sender: Any?) {
        guard canPresentBillingUI,
              !isPurchaseInProgress,
              !isRestoringPurchase,
              !isCheckingPurchaseStatus,
              let billingController,
              billingController.isConfigured else { return }

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.placeholderString = "DOUT1.…"
        input.setAccessibilityLabel(String(localized: "Restore Purchase"))

        let prompt = NSAlert()
        prompt.alertStyle = .informational
        prompt.messageText = String(localized: "Restore Purchase")
        prompt.informativeText = String(localized: "Paste the recovery code from your previous Mac. Restoring moves Premium to this Mac.")
        prompt.accessoryView = input
        prompt.addButton(withTitle: String(localized: "Restore"))
        prompt.addButton(withTitle: String(localized: "Cancel"))
        prompt.window.initialFirstResponder = input
        guard prompt.runModal() == .alertFirstButtonReturn else { return }

        let recoveryCode = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recoveryCode.isEmpty else { return }
        isRestoringPurchase = true
        settingsWindowController?.refreshExternalState()
        billingController.restorePurchase(using: recoveryCode) { [weak self] success in
            guard let self else { return }
            self.isRestoringPurchase = false
            self.settingsWindowController?.refreshExternalState()
            guard self.canPresentBillingUI else { return }

            let result = NSAlert()
            if success {
                result.alertStyle = .informational
                result.messageText = String(localized: "Premium Was Restored")
                result.informativeText = String(localized: "Premium has moved to this Mac. The previous Mac will lose access when it next checks online.")
            } else {
                result.alertStyle = .warning
                result.messageText = String(localized: "Couldn’t Restore Purchase")
                result.informativeText = String(localized: "Check the recovery code and internet connection, then try again.")
            }
            result.addButton(withTitle: String(localized: "OK"))
            result.runModal()
        }
    }

    /// This checks only the current installation-bound entitlement. Cross-device transfer is a
    /// separate recovery-code flow and still requires a fresh signed entitlement before unlock.
    @objc private func checkPremiumPurchaseStatus(_ sender: Any?) {
        guard canPresentBillingUI,
              !isPurchaseInProgress,
              !isCheckingPurchaseStatus,
              !isRestoringPurchase,
              let billingController,
              billingController.isConfigured else { return }
        isCheckingPurchaseStatus = true
        settingsWindowController?.refreshExternalState()
        billingController.refresh { [weak self] success in
            guard let self else { return }
            self.isCheckingPurchaseStatus = false
            self.settingsWindowController?.refreshExternalState()
            guard self.canPresentBillingUI else { return }
            let hasPremiumAccess = self.billingController?.hasPremiumAccess == true

            let alert = NSAlert()
            if success && hasPremiumAccess {
                alert.alertStyle = .informational
                alert.messageText = String(localized: "Premium is active")
                alert.informativeText = String(localized: "Animated icons are unlocked on this Mac.")
            } else if success {
                alert.alertStyle = .informational
                alert.messageText = String(localized: "No active purchase was found")
                alert.informativeText = String(localized: "This checks purchases linked to this DiskOUT installation.")
            } else {
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Couldn’t check purchase status")
                alert.informativeText = String(localized: "Check your internet connection and try again.")
            }
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
        }
    }

    private func showBillingBrowserError() {
        guard canPresentBillingUI else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn’t open billing")
        alert.informativeText = String(localized: "Check your internet connection and try again.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    private var canPresentBillingUI: Bool {
        !isTerminating && pendingTerminateReplyApp == nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let typeStr: String
        switch event?.type {
        case .leftMouseDown:  typeStr = "leftDown"
        case .leftMouseUp:    typeStr = "leftUp"
        case .rightMouseDown: typeStr = "rightDown"
        case .rightMouseUp:   typeStr = "rightUp"
        case .otherMouseDown: typeStr = "otherDown"
        case .none:           typeStr = "nil"
        default:              typeStr = "other(\(event!.type.rawValue))"
        }
        log.debug("statusItemClicked — currentEvent.type=\(typeStr, privacy: .public)")

        let isRightClick = (event?.type == .rightMouseDown || event?.type == .rightMouseUp)
        // ctrl+좌클릭도 우클릭으로 간주 (macOS 표준)
        let isCtrlLeftClick = (event?.type == .leftMouseDown || event?.type == .leftMouseUp)
            && (event?.modifierFlags.contains(.control) ?? false)

        if isRightClick || isCtrlLeftClick {
            log.info("RIGHTCLICK on status item enabled=\(SettingsStore.rightClickEjectEnabled, privacy: .public)")
            // 사용자가 우클릭=즉시추출을 끈 경우엔 메뉴를 띄운다 (좌클릭과 동일 동작).
            // 실수 우클릭으로 작업 중인 외장이 한꺼번에 빠지는 사고 방지.
            guard SettingsStore.rightClickEjectEnabled else {
                showStatusMenu()
                return
            }
            // 별도 ack 플래시 없음 — ejectAll 이 즉시 진행 플래시(회전 화살표)를 띄운다.
            ejectAll(caller: "rightclick")
            return
        }

        showStatusMenu()
    }

    /// 메뉴바 아이콘 클릭 시 임시 menu 부착 → popup → 닫히면 nil 복원.
    /// (status item 의 menu 를 영구 set 하면 좌클릭 = action handler 가 아닌 menu popup 으로 변해
    ///  우클릭 분기 등 커스텀 처리가 안 됨 — 그래서 임시 부착 패턴 유지.)
    private func showStatusMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        // 권한 상태 background refresh — 결과는 다음번 메뉴 열 때 반영.
        if SettingsStore.notificationsEnabled {
            UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
                DispatchQueue.main.async {
                    self?.lastKnownNotificationStatus = settings.authorizationStatus
                }
            }
        }
        // DA 인벤토리가 떠 있으면 동기 즉시 로드 (<1ms) 로 한 번만 populate.
        // async 경로는 placeholder 행을 그렸다가 메뉴가 열린 채 다시 채우는데, macOS 26 의
        // 메뉴 창은 항목이 줄어도 높이를 반납하지 않아 종료 아래 빈 한 칸이 남는다.
        if let snapshot = DiskMenuSnapshotCache.currentIfInstant() {
            populateMenu(menu, snapshot: snapshot, isRefreshing: false)
            return
        }
        // Cold start (DA 미준비 — diskutil 로드는 느림) fallback: placeholder 를 먼저 보여주고
        // 도착하면 다시 채운다. 이쪽은 메뉴가 커지는 방향이라 빈 칸 잔상이 없다.
        let state = DiskMenuSnapshotCache.currentForMenu { [weak self, weak menu] snapshot in
            DispatchQueue.main.async {
                guard let self, let menu else { return }
                self.populateMenu(menu, snapshot: snapshot, isRefreshing: false)
            }
        }
        populateMenu(menu, snapshot: state.snapshot, isRefreshing: state.isRefreshing)
    }

    /// Accessibility 권한 — global hotkey 동작 필수. prompt 없는 동기 체크.
    private var isAccessibilityTrusted: Bool {
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ] as CFDictionary)
    }

    /// 메뉴 상단에 표시할 권한 경고 항목들. 빈 배열이면 표시 안 함.
    private func permissionWarnings() -> [(title: String, action: Selector)] {
        var warnings: [(String, Selector)] = []
        if !isAccessibilityTrusted {
            warnings.append((String(localized: "Allow Accessibility for global hotkeys"),
                             #selector(openPermissionsFromMenu)))
        }
        if SettingsStore.notificationsEnabled,
           lastKnownNotificationStatus == .denied {
            warnings.append((String(localized: "Allow notifications to see eject results"),
                             #selector(openPermissionsFromMenu)))
        }
        return warnings
    }

    @objc private func openLoginItemSettings() {
        LoginItem.openSystemSettings()
    }

    /// 볼륨의 여유 용량/사용률을 "X free · NN% used" 로 포맷. 값이 없으면 nil.
    /// 전체 용량은 생략 — 여유량+사용률이면 충분하고, "free of 1 TB (77% used)" 식 괄호 중첩이
    /// 메뉴를 텍스트 과밀하게 만든다 (UI 컨벤션: 메타데이터 괄호 금지).
    /// `drive.url`(마운트 포인트) 에서 `URLResourceValues` 로 조회 — 프로세스 스폰 없음.
    /// 메뉴 열 때만 호출되므로 동기 조회 비용 무시 가능 (로컬 외장 디스크 대상).
    private func capacityDetail(forVolumeURL url: URL) -> String? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        guard let available = values.volumeAvailableCapacity else {
            return formatter.string(fromByteCount: Int64(total))
        }
        let freeStr = formatter.string(fromByteCount: Int64(available))
        // 사용률 % — 디스크가 얼마나 찼는지 (df 의 Capacity 열과 같은 관점). 0...100 클램프.
        let usedPct = max(0, min(100, Int((Double(total - available) / Double(total) * 100).rounded())))
        let pctStr = "\(usedPct)%"   // 미리 % 붙여 String 으로 — 포맷 문자열에 리터럴 % 없게.
        return String(localized: "\(freeStr) free · \(pctStr) used")
    }

    /// 읽기/쓰기 활동에 따른 "분리 금지" tooltip 문구. 둘 다 없으면 nil.
    /// 닷(●)은 활동이 있으면 동일하게 띄우고, 읽기/쓰기 구분은 이 문구로만 전달한다.
    private func activityTooltip(writing: Bool, reading: Bool) -> String? {
        switch (writing, reading) {
        case (true, true):   return String(localized: "Reading and writing an external disk — don't disconnect")
        case (true, false):  return String(localized: "Writing to an external disk — don't disconnect")
        case (false, true):  return String(localized: "Reading from an external disk — don't disconnect")
        case (false, false): return nil
        }
    }

    /// 활동/업데이트 표시용 작은 색점(" ●"). menuItemTitle / applyCountTitle 공용 헬퍼.
    /// baselineOffset 으로 본문 텍스트의 광학 중심에 맞춘다 (베이스라인에 그대로 두면 점이 처져 보임).
    private func activityDot(color: NSColor) -> NSAttributedString {
        let dot = NSMutableAttributedString(string: " ")
        dot.append(NSAttributedString(
            string: "●",
            attributes: [.foregroundColor: color,
                         .font: NSFont.systemFont(ofSize: UI.dotSize),
                         .baselineOffset: UI.dotBaselineOffset]))
        return dot
    }

    /// 메뉴 항목 attributedTitle — 1줄 primary(기본 메뉴 폰트). 읽기/쓰기 중이면 systemBlue `●` 부착
    /// (메뉴바 표시와 동일한 시각 언어). secondary 가 있으면 2줄로 작게·dimmed 추가.
    private func menuItemTitle(primary: String, secondary: String?, active: Bool) -> NSAttributedString {
        let attr = NSMutableAttributedString(
            string: primary,
            attributes: [.font: NSFont.menuFont(ofSize: 0)])
        if active {
            attr.append(activityDot(color: .systemBlue))
        }
        if let secondary {
            attr.append(NSAttributedString(
                string: "\n" + secondary,
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]))
        }
        return attr
    }

    /// 볼륨의 backing 물리 whole-disk BSD 집합. IOService plane 에서 볼륨 IOMedia 의 부모 방향으로
    /// 거슬러 올라가 `IOBlockStorageDriver` 를 가진 whole `IOMedia` 들을 수집.
    ///
    /// direct(NTFS disk6 → {disk6}) · APFS synthesized(disk5s1 → 물리 store) · RAID(여러 멤버 →
    /// {disk7,disk8}) 를 모두 균일하게 처리. `DiskIOMonitor` 가 보고하는 물리 BSD 집합과 교집합으로
    /// "이 볼륨이 쓰는 중" 을 판정한다. 메뉴 열 때만 호출 (드라이브당 1회, 바운드된 IORegistry 순회).
    private func physicalWholeDisks(forVolumeURL url: URL) -> Set<String> {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let bsdC = DADiskGetBSDName(disk) else { return [] }
        let startBSD = String(cString: bsdC)
        guard let match = IOBSDNameMatching(kIOMainPortDefault, 0, startBSD) else { return [] }
        let start = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard start != IO_OBJECT_NULL else { return [] }

        var result = Set<String>()
        var visited = Set<UInt64>()
        var queue = [start]   // 각 dequeue 시 1회 release. IOIteratorNext 가 준 retain 을 소비.
        while !queue.isEmpty {
            let e = queue.removeFirst()
            defer { IOObjectRelease(e) }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(e, &id)
            guard visited.insert(id).inserted else { continue }
            if IOObjectConformsTo(e, "IOMedia") != 0,
               (IORegistryEntryCreateCFProperty(e, "Whole" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool) == true,
               Self.hasBlockStorageDriverParent(e),
               let bsd = IORegistryEntryCreateCFProperty(e, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String {
                result.insert(bsd)
            }
            var pit: io_iterator_t = 0
            if IORegistryEntryGetParentIterator(e, kIOServicePlane, &pit) == KERN_SUCCESS {
                var p = IOIteratorNext(pit)
                while p != IO_OBJECT_NULL { queue.append(p); p = IOIteratorNext(pit) }
                IOObjectRelease(pit)
            }
        }
        return result
    }

    /// `entry` 의 직속 부모(provider) 중 `IOBlockStorageDriver` 가 있는지 — whole `IOMedia` 가
    /// 물리 디스크인지(= I/O 카운터 존재) 판별용.
    private static func hasBlockStorageDriverParent(_ entry: io_registry_entry_t) -> Bool {
        var pit: io_iterator_t = 0
        guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &pit) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(pit) }
        var found = false
        var p = IOIteratorNext(pit)
        while p != IO_OBJECT_NULL {
            if IOObjectConformsTo(p, "IOBlockStorageDriver") != 0 { found = true }
            IOObjectRelease(p)
            p = IOIteratorNext(pit)
        }
        return found
    }

    /// 주어진 볼륨의 읽기/쓰기 활동 — backing 물리 디스크와 모니터 보고 집합의 교집합.
    /// 메뉴 표시(닷 + tooltip)용. 닷은 writing||reading, tooltip 은 종류별 문구.
    private func volumeActivity(_ url: URL) -> (writing: Bool, reading: Bool) {
        let wEmpty = writingPhysicalBSDs.isEmpty
        let rEmpty = readingPhysicalBSDs.isEmpty
        guard !wEmpty || !rEmpty else { return (false, false) }
        let disks = physicalWholeDisks(forVolumeURL: url)
        let writing = !wEmpty && !disks.isDisjoint(with: writingPhysicalBSDs)
        let reading = !rEmpty && !disks.isDisjoint(with: readingPhysicalBSDs)
        return (writing, reading)
    }

    /// 주어진 볼륨이 지금 쓰기 중인지 — eject 가드용(쓰기 중 분리는 손상 위험, 읽기는 제외).
    private func isWritingVolume(_ url: URL) -> Bool {
        guard !writingPhysicalBSDs.isEmpty else { return false }
        return !physicalWholeDisks(forVolumeURL: url).isDisjoint(with: writingPhysicalBSDs)
    }

    private func populateMenu(_ menu: NSMenu, snapshot: DiskMenuSnapshot, isRefreshing: Bool) {
        let started = Date()
        // 메뉴 열면 추출 결과 아이콘 reset — 사용자가 결과 확인했다고 간주
        resetIcon()

        menu.removeAllItems()

        // 권한 누락 경고 — 클릭 시 시스템 설정의 해당 페이지로 이동.
        // 자주 보이지 않게 (사용자가 거부했으면 매번 권유하기보다 메뉴 상단에 조용히 표시).
        let warnings = permissionWarnings()
        for warning in warnings {
            let item = NSMenuItem(title: warning.title, action: warning.action, keyEquivalent: "")
            item.target = self
            item.image = menuSymbol("exclamationmark.triangle.fill", fallback: "exclamationmark.triangle")
            menu.addItem(item)
        }
        if !warnings.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        let drives = snapshot.drives

        if isRefreshing {
            let updating = NSMenuItem(title: String(localized: "Updating Disk Status…"),
                                      action: nil, keyEquivalent: "")
            updating.isEnabled = false
            menu.addItem(updating)
            menu.addItem(NSMenuItem.separator())
        } else if snapshot.refreshError != nil {
            let failed = NSMenuItem(title: String(localized: "Disk status update failed"),
                                    action: nil,
                                    keyEquivalent: "")
            failed.isEnabled = false
            failed.toolTip = localizedOperationFailure()
            menu.addItem(failed)
            menu.addItem(NSMenuItem.separator())
        }

        if drives.isEmpty {
            let empty = NSMenuItem(title: String(localized: "No External Drives"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            // Time Machine 디스크 첫 등장 시 자동으로 ExcludedVolumes 에 추가 + 1회 알림.
            // 사용자가 모르는 사이 백업 디스크가 자동 추출되어 백업 사이클 깨지는 사고 방지.
            autoExcludeNewTimeMachineDisks(drives)

            // 섹션 헤더 (macOS 14+) — 시스템 메뉴(Wi-Fi 등)와 같은 작은 회색 헤더.
            // 13 은 헤더 없는 현행 유지 (disabled 행을 추가하면 오히려 행 수만 늘어남).
            if #available(macOS 14.0, *) {
                menu.addItem(NSMenuItem.sectionHeader(title: String(localized: "External Drives")))
            }

            for drive in drives {
                let isExcluded = ExcludedVolumes.isExcluded(drive.volumeUUID)
                // 디스크 상태 라벨 — 한 번에 하나만 (TM 디스크는 자동 제외가 기본이라 TM 우선):
                //   macOS 14+ → 네이티브 badge ("업무백업  Time Machine") — 본문과 분리된 회색 캡션
                //   macOS 13  → 괄호 suffix fallback ("업무백업 (Time Machine)")
                let statusLabel: String? = drive.isTimeMachine
                    ? "Time Machine"
                    : (isExcluded ? String(localized: "auto-eject excluded") : nil)

                let baseTitle: String
                if #available(macOS 14.0, *) {
                    baseTitle = drive.name
                } else {
                    baseTitle = statusLabel.map { "\(drive.name) (\($0))" } ?? drive.name
                }
                let item = NSMenuItem(title: baseTitle,
                                      action: #selector(ejectOne(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = drive.url
                item.isEnabled = !isRefreshing
                item.image = menuSymbol(drive.isTimeMachine ? "clock.arrow.circlepath" : drive.kind.symbolName,
                                        fallback: "externaldrive")
                if #available(macOS 14.0, *), let statusLabel {
                    item.badge = NSMenuItemBadge(string: statusLabel)
                }
                // 용량/여유공간(2번째 줄, dimmed) + 읽기/쓰기 중이면 이름 옆 systemBlue `●`.
                // 둘 다 없으면 단일 줄 plain title 유지 (네트워크/일부 TM 등 용량 nil + 비활성).
                let detail = capacityDetail(forVolumeURL: drive.url)
                let activity = volumeActivity(drive.url)
                let active = activity.writing || activity.reading
                if detail != nil || active {
                    item.attributedTitle = menuItemTitle(primary: baseTitle, secondary: detail, active: active)
                }
                // 읽기/쓰기 종류에 따라 tooltip 문구 구분 (활동 없으면 nil → tooltip 제거).
                item.toolTip = activityTooltip(writing: activity.writing, reading: activity.reading)
                // submenu 폐기 — submenu 가 있으면 macOS 가 클릭 시 action 무시 (추출 안 됨).
                // 자동 추출 제외 토글은 메뉴 하단의 별도 "자동 추출 제외 디스크" submenu 로 이동.
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
            let ejectHotkey = SettingsStore.ejectHotkey
            // 단축키는 keyEquivalent 가 메뉴 우측에 표시 — 제목 안 괄호 중복 표기 금지 (UI 컨벤션).
            let ejectAllItem = NSMenuItem(title: String(localized: "Eject All"),
                                          action: #selector(ejectAllAction(_:)),
                                          keyEquivalent: "e")
            ejectAllItem.keyEquivalentModifierMask = ejectHotkey.flags
            ejectAllItem.target = self
            ejectAllItem.isEnabled = !isRefreshing
            // 우클릭 안내는 tooltip 으로 — 우클릭 즉시 추출을 켠 경우에만 의미가 있다.
            if SettingsStore.rightClickEjectEnabled {
                ejectAllItem.toolTip = String(localized: "Tip: right-clicking the menu bar icon also ejects all drives.")
            }
            menu.addItem(ejectAllItem)

            let ejectAndSleepItem = NSMenuItem(title: String(localized: "Eject and Sleep"),
                                               action: #selector(ejectAndSleepAction(_:)),
                                               keyEquivalent: "")
            ejectAndSleepItem.target = self
            ejectAndSleepItem.isEnabled = !isRefreshing
            menu.addItem(ejectAndSleepItem)
        }

        // Mount 섹션 — 마운트 안 된 외장이 있을 때만 표시.
        // 사용자가 추출 후 다시 쓰고 싶거나, macOS 가 wake 후 자동 mount 못 한 케이스 회복용.
        let unmounted = snapshot.unmounted
        if !unmounted.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let header: NSMenuItem
            if #available(macOS 14.0, *) {
                header = NSMenuItem.sectionHeader(title: String(localized: "Unmounted Drives"))
            } else {
                header = NSMenuItem(title: String(localized: "Unmounted Drives"),
                                    action: nil, keyEquivalent: "")
                header.isEnabled = false
            }
            menu.addItem(header)

            for u in unmounted {
                let item = NSMenuItem(title: u.displayName,
                                      action: #selector(mountOne(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = u.bsdName
                item.isEnabled = !isRefreshing
                item.image = menuSymbol(u.kind.unmountedSymbolName, fallback: "externaldrive.badge.plus")
                item.toolTip = String(localized: "Click to mount.  ⌘+click to also open in Finder.")
                menu.addItem(item)
            }

            if unmounted.count >= 2 {
                let mountHotkey = SettingsStore.mountHotkey
                let mountAllItem = NSMenuItem(title: String(localized: "Mount All"),
                                              action: #selector(mountAllAction(_:)),
                                              keyEquivalent: "e")
                mountAllItem.keyEquivalentModifierMask = mountHotkey.flags
                mountAllItem.target = self
                mountAllItem.isEnabled = !isRefreshing
                menu.addItem(mountAllItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // requiresApproval 인 경우만 메뉴에서 경고 표시 — 사용자가 모르는 사이 로그인 자동 실행이
        // 막혀 있는 상황을 알아챌 수 있도록.
        if LoginItem.status == .requiresApproval {
            let approve = NSMenuItem(title: String(localized: "Login item needs approval"),
                                     action: #selector(openLoginItemSettings),
                                     keyEquivalent: "")
            approve.target = self
            approve.image = menuSymbol("exclamationmark.triangle.fill", fallback: "exclamationmark.triangle")
            approve.toolTip = String(localized: "Approve in System Settings → General → Login Items")
            menu.addItem(approve)
        }

        // 자동 추출 제외 디스크 submenu — 식별 가능한 (UUID 있는) 디스크가 1개 이상일 때만 노출.
        // submenu 안에 디스크 별 토글 — 사용자가 디스크 항목 클릭 = 추출 (1단계) 보장하면서
        // 토글 기능도 남기는 구조.
        let togglableDrives = drives.filter { $0.volumeUUID != nil }
        if !togglableDrives.isEmpty {
            let parent = NSMenuItem(title: String(localized: "Auto-Eject Excluded Disks"),
                                    action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for drive in togglableDrives {
                guard let uuid = drive.volumeUUID else { continue }
                let toggle = NSMenuItem(title: drive.name,
                                        action: #selector(toggleExcludeVolume(_:)),
                                        keyEquivalent: "")
                toggle.target = self
                toggle.representedObject = uuid
                toggle.state = ExcludedVolumes.isExcluded(uuid) ? .on : .off
                sub.addItem(toggle)
            }
            parent.submenu = sub
            menu.addItem(parent)
        }

        if menu.items.last?.isSeparatorItem != true {
            menu.addItem(NSMenuItem.separator())
        }

        // Sparkle 자동 업데이트 — gentle reminder.
        // pendingUpdate 가 있으면 (자동 체크에서 발견된 미설치 업데이트) 메뉴 안에서도 강조 표시.
        // 메뉴바 아이콘 옆 빨간 점과 짝을 이뤄, 사용자가 메뉴 열면 즉시 발견 가능.
        if let pending = pendingUpdate {
            let title = String(localized: "Update to \(pending.displayVersionString)…")
            let pendingItem = NSMenuItem(title: title,
                                         action: #selector(showPendingUpdate(_:)),
                                         keyEquivalent: "")
            pendingItem.target = self
            pendingItem.toolTip = String(localized: "Click to install")
            // 메뉴바의 업데이트 점(systemRed ●)과 같은 시각 언어 — 이모지(🔴) 대신 attributed 색점.
            // 이모지는 시스템 메뉴 어휘(SF Symbol/텍스트)와 톤이 어긋난다 (UI 컨벤션: 이모지 금지).
            let attr = NSMutableAttributedString(
                string: "●",
                attributes: [.foregroundColor: NSColor.systemRed,
                             .font: NSFont.systemFont(ofSize: UI.dotSize),
                             .baselineOffset: UI.dotBaselineOffset])
            attr.append(NSAttributedString(string: "  \(title)",
                                           attributes: [.font: NSFont.menuFont(ofSize: 0)]))
            pendingItem.attributedTitle = attr
            menu.addItem(pendingItem)
        }

        // Billing actions live in Settings so the menu stays focused on drive operations. Keep one
        // entry only while a free/in-progress configured state needs a path to that pane.
        if let billingController,
           PremiumMenuPolicy.entry(isConfigured: billingController.isConfigured,
                                   hasPremiumAccess: billingController.hasPremiumAccess,
                                   hasInProgressAction: isPurchaseInProgress ||
                                       isCheckingPurchaseStatus || isRestoringPurchase) == .openSettings {
            let premiumItem = NSMenuItem(title: String(localized: "Premium…"),
                                         action: #selector(showPremiumSettings(_:)),
                                         keyEquivalent: "")
            premiumItem.target = self
            menu.addItem(premiumItem)
            menu.addItem(NSMenuItem.separator())
        }

        // 유틸리티 행(업데이트/설정/종료)은 아이콘 없이 텍스트만 — 아이콘은 콘텐츠(디스크)와
        // 경고(⚠)에만. 시스템 Wi-Fi/배터리 메뉴와 같은 문법 (UI 컨벤션: 아이콘 정책).
        let checkUpdates = NSMenuItem(title: String(localized: "Check for Updates…"),
                                      action: #selector(checkForUpdatesFromMenu(_:)),
                                      keyEquivalent: "")
        checkUpdates.target = self
        menu.addItem(checkUpdates)

        menu.addItem(NSMenuItem.separator())

        let settings = NSMenuItem(title: String(localized: "Settings…"),
                                  action: #selector(showSettingsWindow(_:)),
                                  keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: String(localized: "Quit DiskOUT"),
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        let elapsed = Date().timeIntervalSince(started)
        log.info("menuWillOpen: built in \(String(format: "%.3f", elapsed), privacy: .public)s drives=\(drives.count, privacy: .public) unmounted=\(unmounted.count, privacy: .public) refreshing=\(isRefreshing, privacy: .public)")
    }

    /// 디스크별 *"자동 추출 제외"* 토글. representedObject = Volume UUID.
    @objc private func toggleExcludeVolume(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        ExcludedVolumes.toggle(uuid)
        log.info("ExcludedVolumes toggled \(uuid, privacy: .public) → excluded=\(ExcludedVolumes.isExcluded(uuid), privacy: .public)")
    }

    @objc private func showSettingsWindow(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(onHotkeyChanged: { [weak self] in
                self?.installHotkey()
            }, onClosed: { [weak self] in
                // 창 닫히면 controller 해제 — 다음번 ⌘, 시 fresh state 로 다시 띄움.
                self?.settingsWindowController = nil
            }, onCheckForUpdates: { [weak self] in
                // About 페인의 "업데이트 확인…" — 메뉴 항목과 같은 경로 (userInitiated).
                self?.checkForUpdatesFromMenu(nil)
            }, premiumState: { [weak self] in
                guard let self, let billing = self.billingController else {
                    return PremiumSettingsState(isConfigured: false,
                                                hasAccess: false,
                                                isPurchaseInProgress: false,
                                                isOpeningDetails: false,
                                                isCheckingStatus: false,
                                                isRestoring: false,
                                                canOpenDetails: false,
                                                hasRecoveryCode: false)
                }
                return PremiumSettingsState(isConfigured: billing.isConfigured,
                                            hasAccess: billing.hasPremiumAccess,
                                            isPurchaseInProgress: self.isPurchaseInProgress,
                                            isOpeningDetails: self.isOpeningPurchaseDetails,
                                            isCheckingStatus: self.isCheckingPurchaseStatus,
                                            isRestoring: self.isRestoringPurchase,
                                            canOpenDetails: billing.canOpenPurchaseDetails,
                                            hasRecoveryCode: billing.recoveryCode != nil)
            }, premiumActions: PremiumSettingsActions(
                purchase: { [weak self] in self?.purchasePremiumStatusIcons(nil) },
                stopPurchaseCheck: { [weak self] in self?.stopPremiumPurchaseCheck(nil) },
                viewDetails: { [weak self] in self?.viewPremiumPurchaseDetails(nil) },
                copyRecoveryCode: { [weak self] in self?.copyPremiumRecoveryCode(nil) },
                checkStatus: { [weak self] in self?.checkPremiumPurchaseStatus(nil) },
                restore: { [weak self] in self?.restorePremiumPurchase(nil) }
            ))
        }
        settingsWindowController?.show()
    }

    @objc private func showPremiumSettings(_ sender: Any?) {
        showSettingsWindow(sender)
        settingsWindowController?.showPremiumPane()
    }

    /// 환경설정의 언어 드롭다운에서 호출 — 새 언어는 다음 launch 의 main.swift 에서 적용된다.
    /// 새 인스턴스가 applicationDidFinishLaunching 까지 도달했다는 token 응답을 확인한 뒤 종료한다.
    /// open 실패/non-zero/timeout 에서는 현재 앱을 유지하고 사용자가 즉시 재시도할 수 있게 한다.
    func relaunchApplicationForLanguageChange() {
        let token = UUID().uuidString
        guard languageRelaunchAttempt.begin(token: token) else {
            log.notice("Language relaunch already in progress")
            return
        }
        acceptedLanguageRelaunchToken = nil

        let bundleURL = Bundle.main.bundleURL
        log.notice("Relaunching for language change: \(bundleURL.path, privacy: .public) token=\(token, privacy: .public)")

        languageRelaunchReadyObserver = DistributedNotificationCenter.default().addObserver(
            forName: AppLanguageRelaunch.readyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let readyToken = notification.userInfo?["token"] as? String else { return }
            self?.completeLanguageRelaunchIfCurrent(token: readyToken)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.arguments = [AppLanguageRelaunch.tokenArgument, token]
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { [weak self] application, error in
            DispatchQueue.main.async {
                self?.handleLanguageRelaunchOpenCompletion(application: application,
                                                           error: error,
                                                           token: token)
            }
        }

        let timeout = DispatchWorkItem { [weak self] in
            self?.failLanguageRelaunchIfCurrent(token: token, reason: "ready timeout")
        }
        languageRelaunchTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private func handleLanguageRelaunchOpenCompletion(application: NSRunningApplication?,
                                                       error: Error?,
                                                       token: String) {
        // ready가 open completion보다 먼저 도착해 이미 성공 처리된 경우 새 앱을 보존한다.
        if acceptedLanguageRelaunchToken == token { return }

        // timeout/실패/새 retry 뒤 늦게 뜬 이전 인스턴스는 즉시 정리해 영구 중복을 막는다.
        guard languageRelaunchAttempt.isCurrent(token: token) else {
            terminateLanguageRelaunchCandidate(application)
            return
        }
        languageRelaunchCandidate = application
        guard error == nil, application != nil else {
            failLanguageRelaunchIfCurrent(token: token,
                                          reason: error?.localizedDescription ?? "no running application")
            return
        }
    }

    private func completeLanguageRelaunchIfCurrent(token: String) {
        guard languageRelaunchAttempt.finishIfCurrent(token: token) else { return }
        log.notice("Language relaunch acknowledged: \(token, privacy: .public)")
        acceptedLanguageRelaunchToken = token
        clearLanguageRelaunchAttempt(terminateCandidate: false)
        NSApp.terminate(nil)
    }

    private func failLanguageRelaunchIfCurrent(token: String, reason: String) {
        guard languageRelaunchAttempt.finishIfCurrent(token: token) else { return }
        log.error("Language relaunch failed; current app remains active: \(reason, privacy: .public)")
        clearLanguageRelaunchAttempt(terminateCandidate: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn’t restart DiskOUT")
        alert.informativeText = String(localized: "DiskOUT is still running. Try again, or restart it later.")
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            DispatchQueue.main.async { [weak self] in
                self?.relaunchApplicationForLanguageChange()
            }
        }
    }

    private func clearLanguageRelaunchAttempt(terminateCandidate: Bool) {
        languageRelaunchTimeoutWorkItem?.cancel()
        languageRelaunchTimeoutWorkItem = nil
        if terminateCandidate {
            terminateLanguageRelaunchCandidate(languageRelaunchCandidate)
        }
        languageRelaunchCandidate = nil
        if let observer = languageRelaunchReadyObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        languageRelaunchReadyObserver = nil
        languageRelaunchAttempt.clear()
    }

    private func terminateLanguageRelaunchCandidate(_ application: NSRunningApplication?) {
        guard let application, !application.isTerminated else { return }
        if !application.terminate() {
            application.forceTerminate()
        }
    }

    /// 권한 온보딩 창 표시 (첫 실행 시 자동, 메뉴 권한 경고행에서 수동). 비차단.
    private func showOnboardingWindow() {
        log.notice("onboarding: showOnboardingWindow() called")
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController(
                onClosed: { [weak self] in self?.onboardingWindowController = nil },
                onAccessibilityGranted: { [weak self] in
                    // 손쉬운 사용 권한이 부여된 순간 — 단축키 모니터 재설치로 재시작 없이 활성화.
                    self?.installHotkey()
                }
            )
        }
        onboardingWindowController?.show()
    }

    @objc private func openPermissionsFromMenu() {
        showOnboardingWindow()
    }

    /// Time Machine 디스크 처음 등장 시 자동으로 ExcludedVolumes 에 등록 + 1회 알림.
    /// 사용자가 명시적으로 토글 OFF 하면 그 의도 존중 (다시 자동 추가 안 함).
    private func autoExcludeNewTimeMachineDisks(_ drives: [ExternalDrive]) {
        for drive in drives where drive.isTimeMachine {
            guard let uuid = drive.volumeUUID else { continue }
            // 이미 한 번이라도 알림 줬으면 (사용자가 OFF 했어도) 다시 자동 추가 안 함
            if TimeMachineNotified.wasNotified(uuid) { continue }
            ExcludedVolumes.add(uuid)
            TimeMachineNotified.markNotified(uuid)
            log.notice("Auto-excluded Time Machine disk: \(drive.name, privacy: .public) uuid=\(uuid, privacy: .public)")
            notify(title: String(localized: "Time Machine drive protected"),
                   body: String(localized: "\"\(drive.name)\" is excluded from auto-eject. Toggle in the menu if you want it ejected on sleep."),
                   archived: true)
        }
    }

    // MARK: - Status Icon Feedback (단축키/추출 시각 피드백)

    /// 아이콘 변경 직전 호출 — 0.15s 페이드 전환으로 상태 교체가 덜컥거리지 않게.
    /// 시스템 "동작 줄이기(Reduce Motion)" 설정 시 즉시 전환.
    private func crossfadeIconChange(_ button: NSStatusBarButton) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.15
        button.wantsLayer = true
        button.layer?.add(fade, forKey: "iconFade")
    }

    /// 메뉴바 아이콘 잠시 다른 심볼로 변경 후 원복 (회전화살표 등 임시 표시용).
    /// 지연 reset 이 그 사이 표시된 결과 아이콘 (setPersistentIcon) 을 덮어쓰지 않도록
    /// generation 토큰으로 보호. 빠른 추출에서 결과 ✓ 가 사라지던 race 방지.
    private func flashIcon(symbol: String, duration: TimeInterval = 0.4) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            guard let newImg = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
                log.error("flashIcon: symbol '\(symbol, privacy: .public)' not found")
                return
            }
            newImg.isTemplate = true
            self.isTransientStatusIconVisible = true
            self.crossfadeIconChange(button)
            button.title = ""        // 숫자 title 제거 — 심볼만 표시
            button.image = newImg
            self.iconFlashGeneration += 1
            let myGen = self.iconFlashGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self = self else { return }
                // 그 사이 다른 flashIcon / setPersistentIcon / resetIcon 호출되었으면 skip.
                guard self.iconFlashGeneration == myGen else { return }
                self.isTransientStatusIconVisible = false
                self.applyCountTitle()
            }
        }
    }

    /// 메뉴바 아이콘을 영구 변경 (메뉴 열 때 또는 다음 추출 시작 시까지 유지).
    /// 추출 결과 표시용 — sleep 중 추출 후 wake 했을 때 사용자가 결과 확인 가능.
    /// lastResultSymbol 에도 저장 — wake 시 macOS 가 view redraw 하면서 reset 되는 것 복원용.
    /// 5분간 메뉴를 열지 않으면 자동으로 default 아이콘으로 복귀 — 결과 아이콘이 며칠씩
    /// 메뉴바에 남아 거슬리는 것 방지.
    private func setPersistentIcon(symbol: String) {
        lastResultSymbol = symbol
        log.info("setPersistentIcon: \(symbol, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
                log.error("setPersistentIcon: symbol '\(symbol, privacy: .public)' not found")
                return
            }
            img.isTemplate = true
            self.isTransientStatusIconVisible = false
            self.crossfadeIconChange(button)
            button.title = ""        // 숫자 title 제거 — 결과 심볼만 표시
            button.image = img
            self.updateStatusButtonAccessibility(
                value: Self.accessibilityValue(forResultSymbol: symbol),
                announceChange: true
            )
            self.iconFlashGeneration += 1   // 진행중인 flashIcon reset 무효화
            let myGen = self.iconFlashGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
                guard let self = self, self.iconFlashGeneration == myGen else { return }
                self.resetIcon()
            }
        }
    }

    /// 메뉴바를 현재 마운트 개수(숫자)로 reset. lastResultSymbol 도 clear.
    private func resetIcon() {
        lastResultSymbol = nil
        isTransientStatusIconVisible = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isTransientStatusIconVisible = false
            self.applyCountTitle()
            self.iconFlashGeneration += 1   // 진행중인 flashIcon reset 무효화
        }
    }

    // MARK: - Mounted Drive Count

    /// 메뉴바 정체성 글리프 — 앱의 "얼굴". 숫자 왼쪽에 항상 표시해 어느 앱의 카운트인지 알 수 있게 한다.
    /// 커스텀 아이콘으로 교체할 일이 생기면 이 함수만 바꾸면 된다 (호출부는 그대로).
    private static func statusGlyph() -> NSImage? {
        let image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "DiskOUT")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        image?.isTemplate = true
        return image
    }

    /// 결과 심볼과 VoiceOver 문구의 단일 매핑. wake 후 결과 아이콘 복원도
    /// `setPersistentIcon` 을 다시 통과하므로 시각 상태와 접근성 상태가 함께 복구된다.
    private static func accessibilityValue(forResultSymbol symbol: String) -> String {
        switch symbol {
        case "checkmark.circle.fill":       return String(localized: "All drives ejected")
        case "xmark.circle.fill":           return String(localized: "Eject failed")
        case "exclamationmark.circle.fill": return String(localized: "Some drives didn't eject")
        case "questionmark.circle.fill":    return String(localized: "No drives to eject")
        default:                             return "DiskOUT"
        }
    }

    /// 메뉴바 버튼의 시각적 상태를 VoiceOver 속성에도 반영한다.
    /// 완료 결과만 즉시 알리고, 자주 바뀌는 I/O 상태는 포커스 시 읽히게만 해 음성 알림 폭주를 막는다.
    private func updateStatusButtonAccessibility(value: String, announceChange: Bool = false) {
        guard let button = statusItem.button else { return }
        let previousValue = button.accessibilityValue() as? String
        button.setAccessibilityLabel("DiskOUT")
        button.setAccessibilityValue(value)
        button.setAccessibilityHelp(String(localized: "Click to open the DiskOUT menu."))
        if announceChange && previousValue != value {
            NSAccessibility.post(element: button, notification: .valueChanged)
        }
    }

    /// 무료 상태는 기존 정체성 글리프(⏏)를 보존한다. 검증된 Premium 상태의 0...12는
    /// `button.image`에 animation frame, `button.attributedTitle`에 오른쪽 숫자를 표시한다.
    /// 13 이상, 미검증/만료, asset 누락은 모두 기존 무료 표시로 fail-closed 한다.
    ///
    /// 색점(●)은 한 번에 하나만 — 읽기/쓰기 활동(systemBlue)이 미설치 업데이트(systemRed)보다
    /// 우선. 업데이트는 메뉴 안 "Update to …" 항목으로도 보이므로 메뉴바에서는 양보한다.
    /// (둘을 같이 붙이면 "2●●" — 점 두 개가 나란히 떠 시각 소음.)
    ///
    /// 반드시 main thread 에서 호출.
    private func applyCountTitle() {
        guard let button = statusItem.button,
              lastResultSymbol == nil,
              !isTransientStatusIconVisible else { return }
        crossfadeIconChange(button)

        let premiumState: PremiumVerificationState
        if hasPremiumStatusPresentationAccess {
            premiumState = .verified
        } else if billingController?.isConfigured == true {
            premiumState = .unverified
        } else {
            premiumState = .free
        }
        let presentation = StatusItemPresentationPolicy.presentation(
            count: mountedDriveCount,
            premiumState: premiumState,
            hasCharacterAsset: statusCharacterAnimator.hasFrames(for:)
        )

        switch presentation.visual {
        case .freeGlyph:
            statusCharacterAnimator.setActive(false)
            button.image = Self.statusGlyph()
        case .premiumCharacter(let count):
            statusCharacterAnimator.setActive(true)
            button.image = statusCharacterAnimator.image(for: count) ?? Self.statusGlyph()
        }
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown

        let menuBarSize = NSFont.menuBarFont(ofSize: 0).pointSize  // 0 = 시스템 기본 메뉴바 크기
        let countFontSize: CGFloat
        switch presentation.visual {
        case .freeGlyph:
            countFontSize = menuBarSize
        case .premiumCharacter:
            countFontSize = UI.statusCountSize
        }
        let countStr = presentation.countTitle

        let attr = NSMutableAttributedString(
            string: countStr,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: countFontSize, weight: .regular)]
        )
        if isDiskActive {
            attr.append(activityDot(color: .systemBlue))
        } else if pendingUpdate != nil {
            attr.append(activityDot(color: .systemRed))
        }
        button.attributedTitle = attr
        let activity = activityTooltip(writing: !writingPhysicalBSDs.isEmpty,
                                       reading: !readingPhysicalBSDs.isEmpty)
        button.toolTip = activity

        let driveState = mountedDriveCount > 0
            ? "\(String(localized: "External Drives")): \(mountedDriveCount)"
            : String(localized: "No external drives connected.")
        let accessibleState: String
        if let activity {
            accessibleState = "\(driveState). \(activity)"
        } else if let pendingUpdate {
            accessibleState = "\(driveState). \(String(localized: "Update to \(pendingUpdate.displayVersionString)…"))"
        } else {
            accessibleState = driveState
        }
        updateStatusButtonAccessibility(value: accessibleState)
    }

    /// 마운트된 외장 "디바이스" 개수 — 물리 디스크(whole-disk BSD) 단위 집계.
    /// 한 디스크에 파티션이 여러 개 마운트돼 있어도 1개로 카운트.
    /// RAID/합성(APFS) 볼륨은 합성 컨테이너의 whole-disk 로 잡혀 자연스럽게 1개.
    /// statfs 가 전부 실패하는 비정상 케이스에선 volume 수로 폴백.
    private static func mountedExternalDeviceCount(drives: [ExternalDrive]) -> Int {
        let devices = Set(drives.compactMap { $0.wholeDiskBSDName })
        return devices.isEmpty ? drives.count : devices.count
    }

    /// 외장 디바이스 개수를 갱신하고 메뉴바 아이콘에 반영. 반드시 main thread 에서 호출.
    /// 결과 아이콘 (setPersistentIcon) 표시 중이면 count 만 저장 — resetIcon 시점에 최신값 반영.
    private func updateMountedDriveCount(_ count: Int) {
        let changed = count != mountedDriveCount
        mountedDriveCount = count
        // I/O 모니터는 외장이 있을 때만 폴링 (배터리 절약). 0 이면 중단 + 쓰기 표시 clear.
        if count > 0 {
            DiskIOMonitor.shared.start()
        } else {
            DiskIOMonitor.shared.stop()
            writingPhysicalBSDs = []
            readingPhysicalBSDs = []
        }
        guard lastResultSymbol == nil, !isTransientStatusIconVisible else {
            if changed {
                log.info("drive count → \(count, privacy: .public) (deferred — status feedback icon showing)")
            }
            return
        }
        applyCountTitle()
        iconFlashGeneration += 1   // 진행중인 flashIcon 지연 reset 무효화
        if changed {
            log.info("drive count → \(count, privacy: .public), menu bar title updated")
        }
    }

    /// `DiskIOMonitor` 콜백 — 쓰는 중/읽는 중 물리 디스크 집합 변화 시 메뉴바 표시 갱신. main thread.
    /// 결과 심볼(↻/✓/✗) 표시 중에는 title 을 건드리지 않음 — resetIcon 시 최신 상태 반영.
    private func setDiskActivity(writing: Set<String>, reading: Set<String>) {
        guard writingPhysicalBSDs != writing || readingPhysicalBSDs != reading else { return }
        writingPhysicalBSDs = writing
        readingPhysicalBSDs = reading
        if lastResultSymbol == nil, !isTransientStatusIconVisible {
            applyCountTitle()
        }
        log.debug("disk activity → writing=\(writing.sorted(), privacy: .public) reading=\(reading.sorted(), privacy: .public)")
    }

    /// 백그라운드에서 마운트 개수를 다시 계산해 메뉴바 숫자에 반영.
    /// 데이터 소스: DA 인벤토리(in-process, 항상 최신) 우선 — DA 콜백 직후 호출되므로
    /// 변경분이 이미 반영돼 있다. DA 미준비(cold start)면 캐시(diskutil 폴백)로.
    private func refreshMountedDriveCountIcon() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let drives: [ExternalDrive]
            if let snap = DAInventory.shared.snapshot() {
                drives = snap.drives
            } else {
                drives = DiskMenuSnapshotCache.current().drives
            }
            let count = AppDelegate.mountedExternalDeviceCount(drives: drives)
            DispatchQueue.main.async {
                // Time Machine 디스크 자동 제외를 '메뉴 열기' 와 분리해 DA 인벤토리 변경(mount /
                // unmount / launch / wake)마다 선제 등록한다. 메뉴를 한 번도 안 열고 슬립해도 TM
                // 보호가 동작 (idempotent — TimeMachineNotified 가 중복 알림/재등록 차단).
                self?.autoExcludeNewTimeMachineDisks(drives)
                self?.updateMountedDriveCount(count)
            }
        }
    }

    /// 메뉴바 숫자 refresh 를 debounce 후 실행.
    /// 트리거: DA 인벤토리 변경(주 경로), NSWorkspace mount/unmount 노티, launch, wake.
    /// RAID 조립·다중 파티션 등으로 변경 이벤트가 연쇄 발생 → 마지막 이벤트 기준 1회로 합침.
    private func scheduleMountedDriveCountRefresh(after delay: TimeInterval = 0.3) {
        countIconRefreshToken += 1
        let myToken = countIconRefreshToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.countIconRefreshToken == myToken else { return }
            self.refreshMountedDriveCountIcon()
        }
    }

    // MARK: - Eject Actions

    /// 메뉴에서 호출되는 wrapper. caller = "menu".
    @objc func ejectAllAction(_ sender: Any?) {
        ejectAll(caller: "menu")
    }

    /// 추출 완료 후 시스템 sleep 진입. 실패가 있으면 sleep 은 시작하지 않는다.
    @objc func ejectAndSleepAction(_ sender: Any?) {
        ejectAndSleep(caller: "menu")
    }

    /// 쓰는 중 디스크를 **수동** 추출할 때 확인 — force fallback(기본 ON)이 복사를 끊어 파일을
    /// 손상시키는 사고 방지. 사용자가 "그래도 추출"을 택하면 true. main thread 전용.
    ///
    /// **사용자 명시 경로 전용**: 메뉴 추출과 "추출하고 잠자기"는 확인할 사람이 있으므로 사용한다.
    /// 자동 lid/forced sleep은 확인 없이 정책상 busy force를 허용하고 idle/display는 force하지 않는다.
    private func confirmEjectWhileWriting(title: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = String(localized: "Ejecting now will interrupt the copy and may corrupt files. Eject anyway?")
        let ejectButton = alert.addButton(withTitle: String(localized: "Eject Anyway"))
        let cancelButton = alert.addButton(withTitle: String(localized: "Cancel"))
        // 위험 동작이 기본(Return) 버튼이 되지 않게 — Cancel 을 기본/강조로.
        ejectButton.keyEquivalent = ""
        cancelButton.keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 개별 드라이브 추출 (메뉴 아이템 클릭).
    @objc private func ejectOne(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let name = sender.title
        let path = url.path
        // 쓰는 중이면 강제 추출 전에 확인 (수동 경로 전용 가드).
        if isWritingVolume(url),
           !confirmEjectWhileWriting(title: String(localized: "\"\(name)\" is being written to")) {
            log.notice("EJECTONE cancelled by user — disk busy (writing): \(name, privacy: .public)")
            return
        }
        log.info("EJECTONE start: \(name, privacy: .public) at \(path, privacy: .public)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.diskutilEject(volumePath: path)
            DiskMenuSnapshotCache.invalidate()
            DiskMenuSnapshotCache.warm()
            log.info("EJECTONE done: \(name, privacy: .public) success=\(result.success, privacy: .public) err=\(result.errorMessage ?? "-", privacy: .public)")
            // 실패 시 점유 앱 중 끌 수 있는 것 계산 — lsof 가 blocking 이라 background 에서 (main 전에).
            var quittableNames: [String] = []
            var quittableBundleIDs: [String] = []
            if !result.success {
                let apps = self.quittableApps(from: LsofInspector.blockingProcesses(forVolumePath: path))
                quittableNames = apps.map { $0.localizedName ?? $0.bundleIdentifier ?? "?" }
                quittableBundleIDs = apps.compactMap { $0.bundleIdentifier }
            }
            DispatchQueue.main.async {
                if result.success {
                    self.notify(title: String(localized: "Ejected"), body: name, kind: .success)
                } else if quittableBundleIDs.isEmpty {
                    // 끌 수 있는 앱 없음 (데몬뿐 / 진단 실패) → 기존 텍스트 알림.
                    self.notify(title: String(localized: "Couldn't eject \(name)"),
                                body: localizedOperationFailure(),
                                archived: true,
                                kind: .failure)
                } else {
                    // 끌 수 있는 앱 있음 → "끄고 재시도" 액션 알림. userInfo 에 대상 박아 둠.
                    let appList = quittableNames.joined(separator: ", ")
                    self.notify(title: String(localized: "Couldn't eject \(name)"),
                                body: String(localized: "\(appList) is using this disk. Quit it and try ejecting again?"),
                                archived: true,
                                kind: .failure,
                                categoryIdentifier: EjectNotification.retryCategory,
                                userInfo: [
                                    EjectNotification.volumePathKey: path,
                                    EjectNotification.appBundleIDsKey: quittableBundleIDs,
                                ])
                }
            }
        }
    }

    /// 모든 외장 드라이브 추출. caller 는 식별용 문자열.
    /// eject 결과(시도/실패/성공 비어있음 여부) → 영구표시 SF Symbol. ejectAll / ejectAndSleep 공용.
    /// 결과 심볼은 전부 `*.circle.fill` 패밀리로 통일 — 같은 자리에 octagon/triangle 이 섞여
    /// 나오면 매번 다른 어휘처럼 읽힌다 (색·기호로 구분, 형태는 동일).
    private static func ejectResultSymbol(attemptedEmpty: Bool, failureEmpty: Bool, successEmpty: Bool) -> String {
        if attemptedEmpty { return "questionmark.circle.fill" }  // 추출할 외장 없음
        if failureEmpty { return "checkmark.circle.fill" }       // 모두 성공
        if successEmpty { return "xmark.circle.fill" }           // 모두 실패
        return "exclamationmark.circle.fill"                     // 일부 성공/실패
    }

    private func ejectAll(caller: String) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastEjectAt)
        if elapsed < 1.5 {
            log.info("EJECT(\(caller, privacy: .public)) DEBOUNCED — last fired \(String(format: "%.2f", elapsed), privacy: .public)s ago")
            flashIcon(symbol: "circle.dashed", duration: 0.3)
            return
        }
        // 외장 중 하나라도 쓰는 중이면 강제 추출 전에 확인 (수동 경로 전용 가드).
        if !writingPhysicalBSDs.isEmpty,
           !confirmEjectWhileWriting(title: String(localized: "An external disk is being written to")) {
            log.notice("EJECT(\(caller, privacy: .public)) cancelled by user — disk(s) busy (writing)")
            return
        }
        lastEjectAt = now
        log.info("EJECT(\(caller, privacy: .public)) START")

        // 이전 결과 아이콘 지우고 진행 표시 (회전 화살표 1초)
        flashIcon(symbol: "arrow.triangle.2.circlepath", duration: 1.0)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.ejectAllSilently()
            log.info("EJECT(\(caller, privacy: .public)) DONE — attempted=\(result.attempted.count) success=\(result.success.count) failure=\(result.failure.count)")
            DispatchQueue.main.async { [weak self] in
                self?.notifyResult(result)
                // 결과 아이콘 영구 표시 — 메뉴 열거나 다음 추출 시작 시까지 유지
                let resultSymbol = AppDelegate.ejectResultSymbol(attemptedEmpty: result.attempted.isEmpty,
                                                                 failureEmpty: result.failure.isEmpty,
                                                                 successEmpty: result.success.isEmpty)
                self?.setPersistentIcon(symbol: resultSymbol)
            }
        }
    }

    private func ejectAndSleep(caller: String) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastEjectAt)
        if elapsed < 1.5 {
            log.info("EJECT_AND_SLEEP(\(caller, privacy: .public)) DEBOUNCED — last fired \(String(format: "%.2f", elapsed), privacy: .public)s ago")
            flashIcon(symbol: "circle.dashed", duration: 0.3)
            return
        }
        // This command is user-present and may force-unmount after a busy callback. Keep the
        // existing write monitor guard and make Cancel the default before any operation starts.
        if !writingPhysicalBSDs.isEmpty,
           !confirmEjectWhileWriting(
               title: String(localized: "An external disk is being written to")
           ) {
            log.notice("EJECT_AND_SLEEP(\(caller, privacy: .public)) cancelled by user — disk(s) busy (writing)")
            return
        }
        lastEjectAt = now
        log.info("EJECT_AND_SLEEP(\(caller, privacy: .public)) START")
        flashIcon(symbol: "moon.zzz.fill", duration: 1.0)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if LibraryAppManagement.enabled {
                LibraryAppHandler.quitLibraryApps()
            }
            let operation = self.newOperationID(reason: "ejectAndSleep")
            self.beginAutomaticEject(operationID: operation, reason: "ejectAndSleep")
            let result = self.ejectAllForSleep(operationID: operation,
                                               applyExcludeFilter: false,
                                               context: "ejectAndSleep",
                                               trigger: .ejectAndSleep,
                                               forceClaims: SleepEpisodeForceClaimLedger())
            log.info("EJECT_AND_SLEEP(\(caller, privacy: .public)) eject done — attempted=\(result.attempted.count, privacy: .public) success=\(result.success.count, privacy: .public) failure=\(result.failure.count, privacy: .public)")

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.notifyResult((attempted: result.attempted,
                                   success: result.success,
                                   failure: result.failure))

                self.recordAutomaticUnmountTargets(result.remountTargets,
                                                   operationID: operation,
                                                   reason: "ejectAndSleep")

                guard result.failure.isEmpty else {
                    log.notice("EJECT_AND_SLEEP(\(caller, privacy: .public)) sleep canceled because eject failed")
                    self.notify(title: String(localized: "Sleep canceled"),
                                body: String(localized: "Some drives didn't eject. Sleep was not started."),
                                archived: true,
                                kind: .failure)
                    self.setPersistentIcon(symbol: AppDelegate.ejectResultSymbol(attemptedEmpty: result.attempted.isEmpty,
                                                                                 failureEmpty: result.failure.isEmpty,
                                                                                 successEmpty: result.success.isEmpty))
                    // Sleep을 취소했으므로 이미 clean-unmount 된 일부 disk와 이전 pending
                    // target을 기다릴 wake가 없다. 현재 열린 상태에서 즉시 remount 흐름으로 돌린다.
                    self.requestAutomaticRemount(trigger: "ejectAndSleepCanceled")
                    return
                }

                self.skipSleepAutoEjectUntil = Date().addingTimeInterval(15)
                log.info("EJECT_AND_SLEEP(\(caller, privacy: .public)) recorded successful BSDs: \(result.remountTargets.sorted(), privacy: .public)")

                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }
                    let sleep = self.requestSystemSleep()
                    guard !sleep.success else { return }
                    DispatchQueue.main.async { [weak self] in
                        self?.skipSleepAutoEjectUntil = nil
                        self?.notify(title: String(localized: "Couldn't start sleep"),
                                     body: localizedOperationFailure(),
                                     archived: true,
                                     kind: .failure)
                        self?.requestAutomaticRemount(trigger: "ejectAndSleepRequestFailed")
                    }
                }
            }
        }
    }

    private func notifyResult(_ result: (attempted: [String], success: [String], failure: [(String, String)])) {
        guard !result.attempted.isEmpty else {
            notify(title: String(localized: "No drives to eject"),
                   body: String(localized: "No external drives connected."))
            return
        }
        let title: String
        let archived: Bool
        let kind: AppNotificationKind
        if result.failure.isEmpty {
            title = String(localized: "All drives ejected")
            archived = false   // 성공 — 결과 아이콘 ✓ 으로 즉시 피드백 충분
            kind = .success
        } else if result.success.isEmpty {
            title = String(localized: "Eject failed")
            archived = true    // 실패 — 어떤 디스크인지 사후 확인 가치
            kind = .failure
        } else {
            title = String(localized: "Some drives didn't eject")
            archived = true
            kind = .failure
        }
        var lines: [String] = []
        if !result.success.isEmpty {
            lines.append(String(localized: "Succeeded: \(result.success.joined(separator: ", "))"))
        }
        if !result.failure.isEmpty {
            lines.append(String(localized: "Failed: \(result.failure.map { $0.0 }.joined(separator: ", "))"))
            lines.append(localizedOperationFailure())
        }
        notify(title: title, body: lines.joined(separator: "\n"), archived: archived, kind: kind)
    }

    private func newOperationID(reason: String) -> String {
        let suffix = UUID().uuidString.prefix(8)
        return "\(reason)-\(suffix)"
    }

    private func elapsedText(since started: Date) -> String {
        String(format: "%.2f", Date().timeIntervalSince(started))
    }

    private func shortLogMessage(_ message: String?, limit: Int = 300) -> String {
        guard let message, !message.isEmpty else { return "-" }
        if message.count <= limit { return message }
        return "\(message.prefix(limit))..."
    }

    private func notificationID(from messageArgument: UnsafeMutableRawPointer?) -> Int {
        Int(bitPattern: messageArgument)
    }

    /// 자동 (sleep / display sleep / power-off) 추출에서 제외할 드라이브를 걸러낸다.
    ///
    /// 추출은 whole-disk(BSD) 단위로 번진다 — sleep 경로가 처음부터
    /// `kDADiskUnmountOptionWhole` 로 물리 디스크 전체를 unmount 한다. 따라서 같은 물리 디스크에
    /// 보호 대상 볼륨(ExcludedVolumes 등록 OR Time Machine)이 하나라도 있으면 그 디스크의 *모든*
    /// 볼륨을 제외해야 보호 볼륨이 sibling 추출에 휩쓸리지 않는다 (예: TM 컨테이너 + Data 컨테이너가
    /// 한 물리 디스크에 공존할 때, Data 추출이 whole-disk 로 번져 TM 볼륨까지 추출되던 사고 차단).
    ///
    /// Time Machine 볼륨은 ExcludedVolumes 등록 여부와 무관하게 isTimeMachine 으로 즉시 보호한다 —
    /// autoExclude/메뉴가 아직 안 돈 첫 마운트 직후 윈도우, diskutil 인벤토리 실패로 volumeUUID 가
    /// nil 인 fallback 경로(둘 다 isTimeMachine 은 파일 마커로 판별 가능)까지 커버한다.
    private struct AutomaticEjectCandidate {
        let drive: ExternalDrive
        let identity: SleepDiskIdentity?
        let isEjectTarget: Bool
    }

    private static func automaticEjectCandidates(_ drives: [ExternalDrive]) -> [AutomaticEjectCandidate] {
        drives.map {
            AutomaticEjectCandidate(drive: $0,
                                    identity: DAInventory.shared.sleepIdentity(at: $0.url.path),
                                    isEjectTarget: true)
        }
    }

    private static func filterAutoEjectExclusions(_ candidates: [AutomaticEjectCandidate]) -> (kept: [AutomaticEjectCandidate], skipped: Int, blocked: [AutomaticEjectCandidate]) {
        func isProtected(_ d: ExternalDrive) -> Bool {
            ExcludedVolumes.isExcluded(d.volumeUUID) || d.isTimeMachine
        }
        let policyInputs = candidates.map { candidate -> SleepProtectionCandidate in
            let physicalID: String?
            if let identity = candidate.identity {
                physicalID = "\(identity.wholeDiskBSD)#\(identity.generation)#\(identity.mediaRegistryEntryID)"
            } else {
                physicalID = candidate.drive.wholeDiskBSDName.flatMap { $0.isEmpty ? nil : $0 }
            }
            return SleepProtectionCandidate(physicalDiskID: physicalID,
                                            isEjectTarget: candidate.isEjectTarget,
                                            isProtected: isProtected(candidate.drive))
        }
        let decision = SleepProtectionPolicy.evaluate(policyInputs)
        if policyInputs.contains(where: { $0.isProtected && $0.physicalDiskID == nil }) {
            log.error("automatic eject skipped all targets because a protected volume has unresolved physical identity")
        }
        let kept = candidates.indices.compactMap {
            decision.allowedTargetIndices.contains($0) ? candidates[$0] : nil
        }
        let blocked = candidates.indices.compactMap {
            decision.blockedTargetIndices.contains($0) ? candidates[$0] : nil
        }
        return (kept, decision.skippedTargetCount, blocked)
    }

    /// 병렬 추출. background thread 에서 호출하라.
    /// - parameter applyExcludeFilter: true 면 자동 추출 제외 규칙 적용 (filterAutoEjectExclusions —
    ///   제외/TM 볼륨이 속한 물리 디스크 전체를 whole-disk 단위로 보호).
    ///   자동 (sleep / display sleep / power-off) path 에서만 true. 사용자 명시 추출은 false (사용자 의도 우선).
    @discardableResult
    private func ejectAllSilently(applyExcludeFilter: Bool = false,
                                  operationID: String? = nil) -> (attempted: [String], success: [String], failure: [(String, String)]) {
        let operation = operationID ?? "-"
        let listStarted = Date()
        var drives = ExternalDrive.list()
        log.info("cycle \(operation, privacy: .public) ejectAll list complete count=\(drives.count, privacy: .public) elapsed=\(self.elapsedText(since: listStarted), privacy: .public)s")
        if applyExcludeFilter {
            let filterStarted = Date()
            let candidates = AppDelegate.automaticEjectCandidates(drives)
            let (kept, skipped, blocked) = AppDelegate.filterAutoEjectExclusions(candidates)
            drives = kept.map(\.drive)
            if skipped > 0 {
                log.info("cycle \(operation, privacy: .public) ejectAll filtered out \(skipped, privacy: .public) excluded/protected disks elapsed=\(self.elapsedText(since: filterStarted), privacy: .public)s")
            }
            if !blocked.isEmpty {
                log.error("cycle \(operation, privacy: .public) ejectAll blocked \(blocked.count, privacy: .public) automatic targets because protected-disk identity was unresolved")
            }
        }
        log.info("cycle \(operation, privacy: .public) ejectAll targets count=\(drives.count, privacy: .public) names=\(drives.map { $0.name }, privacy: .public)")
        guard !drives.isEmpty else { return ([], [], []) }

        let lock = NSLock()
        var success: [String] = []
        var failure: [(String, String)] = []
        let group = DispatchGroup()
        let parallelQueue = DispatchQueue(label: "com.yongza.ejectdrives.parallel", attributes: .concurrent)

        for drive in drives {
            group.enter()
            parallelQueue.async {
                let started = Date()
                log.info("cycle \(operation, privacy: .public) → eject start: \(drive.name, privacy: .public) at \(drive.url.path, privacy: .public)")
                let result = self.diskutilEject(volumePath: drive.url.path, operationID: operationID)
                let elapsed = Date().timeIntervalSince(started)
                if result.success {
                    log.info("cycle \(operation, privacy: .public) ✓ eject OK: \(drive.name, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
                } else {
                    log.error("cycle \(operation, privacy: .public) ✗ eject FAIL: \(drive.name, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s error=\(result.errorMessage ?? "unknown", privacy: .public)")
                }
                lock.lock()
                if result.success {
                    success.append(drive.name)
                } else {
                    failure.append((drive.name, result.errorMessage ?? String(localized: "Unknown error")))
                }
                lock.unlock()
                group.leave()
            }
        }
        let waitStarted = Date()
        group.wait()
        log.info("cycle \(operation, privacy: .public) ejectAll wait complete elapsed=\(self.elapsedText(since: waitStarted), privacy: .public)s success=\(success.count, privacy: .public) failure=\(failure.count, privacy: .public)")
        let snapshotStarted = Date()
        DiskMenuSnapshotCache.invalidate()
        DiskMenuSnapshotCache.warm()
        log.info("cycle \(operation, privacy: .public) ejectAll snapshot warm complete elapsed=\(self.elapsedText(since: snapshotStarted), privacy: .public)s")
        return (drives.map { $0.name }, success, failure)
    }

    @discardableResult
    private func ejectAllForSleep(operationID: String,
                                  applyExcludeFilter: Bool = true,
                                  context: String = "sleep",
                                  trigger: SleepEjectTrigger,
                                  forceClaims: SleepEpisodeForceClaimLedger,
                                  deadline: Date? = nil) -> (attempted: [String],
                                                                 success: [String],
                                                                 failure: [(String, String)],
                                                                 remountTargets: Set<SleepRemountTarget>) {
        let operationDeadline = deadline ?? Date().addingTimeInterval(24)
        // Snapshot 이전부터 모든 whole-disk callback terminal까지 global approval lease를
        // 유지한다. Power willSleep lease와 중첩되므로 exact token으로 각자 해제한다.
        let mountBarrierToken = DAInventory.shared.beginSleepProtectionMountBarrier()
        defer {
            DAInventory.shared.endSleepProtectionMountBarrier(token: mountBarrierToken)
        }
        // close/new eject가 stale remount token을 먼저 무효화한다. 그 전에 이미 command gate를
        // 통과한 mountDisk만 끝날 때까지 기다린 뒤 현재 inventory를 수집한다.
        let inFlightRemountStarted = Date()
        automaticRemountCommandGroup.wait()
        let inFlightRemountWait = Date().timeIntervalSince(inFlightRemountStarted)
        if inFlightRemountWait >= 0.01 {
            log.notice("cycle \(operationID, privacy: .public) \(context, privacy: .public) waited for in-flight automatic remount elapsed=\(String(format: "%.2f", inFlightRemountWait), privacy: .public)s")
        }

        let listStarted = Date()
        // Normal reconciliation is synchronous and returns immediately. The full remaining budget
        // is used only when an external mount has been approved but is not visible yet; returning
        // early there would let a late mount complete after the power ACK.
        let inventoryWait = max(0, operationDeadline.timeIntervalSinceNow)
        guard let sleepSnapshot = DAInventory.shared.automaticSleepVolumeSnapshot(
            waitUntilReady: inventoryWait
        ) else {
            let message = "Disk Arbitration inventory was not ready before the automatic unmount deadline"
            log.error("cycle \(operationID, privacy: .public) \(context, privacy: .public) \(message, privacy: .public)")
            return (["External drives"], [], [("External drives", message)], [])
        }
        var candidates = sleepSnapshot.map {
            AutomaticEjectCandidate(drive: $0.drive,
                                    identity: $0.identity,
                                    isEjectTarget: $0.isEjectTarget)
        }
        log.info("cycle \(operationID, privacy: .public) \(context, privacy: .public) eject list complete source=DA-atomic count=\(candidates.count, privacy: .public) elapsed=\(self.elapsedText(since: listStarted), privacy: .public)s")

        var preflightFailures: [(String, String)] = []
        if applyExcludeFilter {
            let filterStarted = Date()
            let (kept, skipped, blocked) = AppDelegate.filterAutoEjectExclusions(candidates)
            candidates = kept
            preflightFailures = blocked.map {
                ($0.drive.name, "Protected disk identity was unresolved; automatic whole-disk unmount was blocked")
            }
            if skipped > 0 {
                log.info("cycle \(operationID, privacy: .public) \(context, privacy: .public) eject filtered out \(skipped, privacy: .public) excluded/protected disks elapsed=\(self.elapsedText(since: filterStarted), privacy: .public)s")
            }
        } else {
            candidates = candidates.filter(\.isEjectTarget)
        }

        let targets = candidates.map { candidate in
            SleepUnmountTarget(name: candidate.drive.name,
                               volumePath: candidate.drive.url.path,
                               wholeDiskBSD: candidate.identity?.wholeDiskBSD,
                               physicalGeneration: candidate.identity?.generation,
                               mediaRegistryEntryID: candidate.identity?.mediaRegistryEntryID,
                               mountedVolumeBSDs: candidate.identity?.mountedVolumeBSDs,
                               enforceProtectionClosure: applyExcludeFilter)
        }
        let effectiveForceFallback = trigger.effectiveForceFallback(
            masterEnabled: SettingsStore.forceFallbackEnabled
        )
        let requests = SleepUnmountPolicy.requests(
            for: targets,
            forceFallback: effectiveForceFallback
        )
        log.info("cycle \(operationID, privacy: .public) \(context, privacy: .public) eject targets count=\(targets.count, privacy: .public) physicalRequests=\(requests.count, privacy: .public) trigger=\(trigger.logLabel, privacy: .public) forceAllowed=\(effectiveForceFallback, privacy: .public) names=\(targets.map { $0.name }, privacy: .public) bsds=\(targets.compactMap { $0.wholeDiskBSD }.sorted(), privacy: .public)")
        guard !targets.isEmpty else {
            return (preflightFailures.map(\.0), [], preflightFailures, [])
        }

        let lock = NSLock()
        var success: [String] = []
        var failure = preflightFailures
        var remountTargets = Set<SleepRemountTarget>()
        let group = DispatchGroup()
        let parallelQueue = DispatchQueue(label: "com.yongza.ejectdrives.sleep.parallel",
                                          attributes: .concurrent)

        for request in requests {
            group.enter()
            parallelQueue.async {
                defer { group.leave() }
                let started = Date()
                let names = request.targets.map(\.name)
                let volumePath = request.representativeVolumePath ?? "-"
                log.info("cycle \(operationID, privacy: .public) → \(context, privacy: .public) unmount start names=\(names, privacy: .public) at \(volumePath, privacy: .public) bsd=\(request.wholeDiskBSD ?? "-", privacy: .public) generation=\(request.physicalGeneration.map(String.init) ?? "-", privacy: .public) forceFallback=\(request.allowsForceFallback, privacy: .public)")
                let result = self.unmountRequestForSleep(volumePath: volumePath,
                                                         requestKey: request.key,
                                                         wholeDiskBSDName: request.wholeDiskBSD,
                                                         expectedGeneration: request.physicalGeneration,
                                                         expectedMediaRegistryEntryID: request.mediaRegistryEntryID,
                                                         expectedMountedVolumeBSDs: request.mountedVolumeBSDs,
                                                         enforceProtectionClosure: request.enforceProtectionClosure,
                                                         allowForceFallback: request.allowsForceFallback,
                                                         forceClaims: forceClaims,
                                                         operationID: operationID,
                                                         context: context,
                                                         deadline: operationDeadline)
                let elapsed = Date().timeIntervalSince(started)
                lock.lock()
                if result.success {
                    success.append(contentsOf: names)
                    if let bsd = request.wholeDiskBSD,
                       let generation = request.physicalGeneration,
                       let entryID = request.mediaRegistryEntryID {
                        remountTargets.insert(SleepRemountTarget(
                            wholeDiskBSD: bsd,
                            physicalGeneration: generation,
                            mediaRegistryEntryID: entryID
                        ))
                    }
                } else {
                    let message = result.errorMessage ?? String(localized: "Unknown error")
                    failure.append(contentsOf: names.map { ($0, message) })
                }
                lock.unlock()

                if result.success {
                    log.info("cycle \(operationID, privacy: .public) ✓ \(context, privacy: .public) clean unmount OK names=\(names, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
                } else {
                    log.error("cycle \(operationID, privacy: .public) ✗ \(context, privacy: .public) clean unmount FAIL names=\(names, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s error=\(result.errorMessage ?? "unknown", privacy: .public)")
                }
            }
        }

        let waitStarted = Date()
        group.wait()
        log.info("cycle \(operationID, privacy: .public) \(context, privacy: .public) eject wait complete elapsed=\(self.elapsedText(since: waitStarted), privacy: .public)s success=\(success.count, privacy: .public) failure=\(failure.count, privacy: .public) remountTargets=\(remountTargets.sorted(), privacy: .public)")
        DiskMenuSnapshotCache.invalidate()
        log.info("cycle \(operationID, privacy: .public) \(context, privacy: .public) eject snapshot invalidated; warm skipped")
        return (preflightFailures.map(\.0) + targets.map { $0.name },
                success,
                failure,
                remountTargets)
    }

    /// whole disk 의 mountable partition 들을 모두 mount.
    /// App Store/sandbox 포기 경로: helper daemon 없이 `diskutil mountDisk` 직접 실행.
    /// background thread 에서만 호출.
    private func daMountWholeDisk(bsdName: String,
                                  operationID: String? = nil,
                                  timeout: TimeInterval? = nil) -> (success: Bool, errorMessage: String?) {
        let operation = operationID ?? "-"
        let r = runDiskutil(["mountDisk", bsdName],
                            operationID: operationID,
                            timeout: timeout)
        if r.success {
            log.info("cycle \(operation, privacy: .public) diskutil mountDisk: \(bsdName, privacy: .public) OK")
        } else {
            log.notice("cycle \(operation, privacy: .public) diskutil mountDisk: \(bsdName, privacy: .public) failed — \(r.errorMessage ?? "?", privacy: .public)")
        }
        return r
    }

    /// 외장하드 추출 — `diskutil eject` 실패 시 `diskutil unmount force` fallback.
    /// background thread 에서만 호출.
    private func diskutilEject(volumePath: String, operationID: String? = nil) -> (success: Bool, errorMessage: String?) {
        let operation = operationID ?? "-"
        let eject = runDiskutil(["eject", volumePath], operationID: operationID)
        if eject.success {
            return eject
        }
        // `diskutil eject` 는 whole-disk 동작 — 같은 물리 디스크의 다른 볼륨을 병렬 추출하면
        // 먼저 끝난 쪽이 이 볼륨까지 분리해 진 쪽 명령이 실패로 끝난다. 볼륨이 이미 사라졌으면
        // 성공으로 처리 (multi-partition "Eject All" 거짓 실패 알림 방지 — sleep 경로와 같은 가드).
        if !DAInventory.shared.isVolumePresent(at: volumePath) {
            log.notice("cycle \(operation, privacy: .public) volume already gone after eject — treat as success: \(volumePath, privacy: .public)")
            return (true, nil)
        }

        guard SettingsStore.forceFallbackEnabled else {
            log.notice("cycle \(operation, privacy: .public) force fallback disabled for \(volumePath, privacy: .public)")
            // 카테고리만 — 디스크명/경로 절대 포함 안 함.
            ErrorReporter.report(signature: "diskutil_eject_failed_no_fallback")
            return eject
        }
        log.notice("cycle \(operation, privacy: .public) diskutil eject failed for \(volumePath, privacy: .public), fallback to unmount force — \(eject.errorMessage ?? "?", privacy: .public)")
        let force = runDiskutil(["unmount", "force", volumePath], operationID: operationID)
        if force.success {
            log.notice("cycle \(operation, privacy: .public) force fallback succeeded for \(volumePath, privacy: .public)")
            return force
        }
        if !DAInventory.shared.isVolumePresent(at: volumePath) {
            log.notice("cycle \(operation, privacy: .public) volume gone after force fallback — treat as success: \(volumePath, privacy: .public)")
            return (true, nil)
        }

        // 정상 eject + force unmount 둘 다 실패 — 가장 의미 있는 실패 카테고리. 디스크 식별 정보 없음.
        ErrorReporter.report(signature: "diskutil_force_unmount_failed")
        let ejectMessage = eject.errorMessage ?? "diskutil eject failed"
        let forceMessage = force.errorMessage ?? "diskutil unmount force failed"
        var details = [ejectMessage, "force fallback: \(forceMessage)"]
        if let blockers = LsofInspector.diagnosticMessage(forVolumePath: volumePath) {
            details.append(blockers)
        }
        return (false, details.joined(separator: "\n"))
    }

    private func unmountRequestForSleep(volumePath: String,
                                        requestKey: SleepUnmountGroupKey,
                                        wholeDiskBSDName: String?,
                                        expectedGeneration: UInt64?,
                                        expectedMediaRegistryEntryID: UInt64?,
                                        expectedMountedVolumeBSDs: Set<String>?,
                                        enforceProtectionClosure: Bool,
                                        allowForceFallback: Bool,
                                        forceClaims: SleepEpisodeForceClaimLedger,
                                        operationID: String? = nil,
                                        context: String = "sleep",
                                        deadline: Date) -> (success: Bool, errorMessage: String?) {
        // 기존 설정 의미를 보존한다: normal을 먼저 시도하고, callback이 명시적으로 거절한 경우에만
        // force를 순차 실행한다. timeout은 underlying request 취소가 아니므로 절대 force와 겹치지 않는다.
        // IOKit ACK 25초보다 여유를 둔 하나의 total deadline 안에서 두 시도를 나눈다.
        let normalBudget = deadline.timeIntervalSinceNow
        guard normalBudget > 0 else {
            return (false, "Automatic unmount deadline expired before the request could start")
        }
        let normal = diskArbitrationUnmountForSleep(
            volumePath: volumePath,
            wholeDiskBSDName: wholeDiskBSDName,
            expectedGeneration: expectedGeneration,
            expectedMediaRegistryEntryID: expectedMediaRegistryEntryID,
            expectedMountedVolumeBSDs: expectedMountedVolumeBSDs,
            enforceProtectionClosure: enforceProtectionClosure,
            force: false,
            retainBarrierForForceContinuation: allowForceFallback,
            operationID: operationID,
            timeout: normalBudget,
            context: context
        )
        if normal.success {
            return (true, nil)
        }

        // Timeout already releases this waiter's reservation inside DAInventory. Only a real
        // dissenter callback retains a continuation for the caller to release after its decision.
        let shouldReleaseDeclineContinuation = SleepForceContinuationReleasePolicy
            .callerOwnsRelease(forceContinuationReserved: allowForceFallback,
                               requestWasForced: normal.requestWasForced,
                               dissenterStatus: normal.dissenterStatus)
        defer {
            if shouldReleaseDeclineContinuation {
                DAInventory.shared.releaseSleepUnmountForceContinuation(
                    wholeDiskBSDName: wholeDiskBSDName,
                    expectedGeneration: expectedGeneration,
                    expectedMediaRegistryEntryID: expectedMediaRegistryEntryID
                )
            }
        }

        let next = normal.dissenterStatus.flatMap {
            SleepUnmountPolicy.nextOperation(after: .callbackFailure($0),
                                             requestWasForced: normal.requestWasForced,
                                             forceFallback: allowForceFallback)
        }
        guard next == .wholeForce else {
            if normal.dissenterStatus != nil {
                ErrorReporter.report(signature: "sleep_da_unmount_declined")
            }
            return (false, normal.errorMessage)
        }

        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            ErrorReporter.report(signature: "sleep_da_unmount_declined_no_force_budget")
            return (false, normal.errorMessage)
        }
        guard forceClaims.claimForce(for: requestKey) else {
            ErrorReporter.report(signature: "sleep_da_force_unmount_already_claimed")
            log.notice("cycle \(operationID ?? "-", privacy: .public) \(context, privacy: .public) DA force fallback suppressed because this physical request already used its one episode claim")
            return (false, normal.errorMessage)
        }
        log.notice("cycle \(operationID ?? "-", privacy: .public) \(context, privacy: .public) DA normal unmount declined with force-eligible busy status; starting one sequential force fallback remaining=\(String(format: "%.2f", remaining), privacy: .public)s")
        let forced = diskArbitrationUnmountForSleep(
            volumePath: volumePath,
            wholeDiskBSDName: wholeDiskBSDName,
            expectedGeneration: expectedGeneration,
            expectedMediaRegistryEntryID: expectedMediaRegistryEntryID,
            expectedMountedVolumeBSDs: expectedMountedVolumeBSDs,
            enforceProtectionClosure: enforceProtectionClosure,
            force: true,
            retainBarrierForForceContinuation: false,
            operationID: operationID,
            timeout: remaining,
            context: context
        )
        if !forced.success {
            ErrorReporter.report(signature: "sleep_da_force_unmount_failed")
        }
        return (forced.success, forced.errorMessage)
    }

    private func diskArbitrationUnmountForSleep(volumePath: String,
                                                wholeDiskBSDName: String?,
                                                expectedGeneration: UInt64?,
                                                expectedMediaRegistryEntryID: UInt64?,
                                                expectedMountedVolumeBSDs: Set<String>?,
                                                enforceProtectionClosure: Bool,
                                                force: Bool,
                                                retainBarrierForForceContinuation: Bool,
                                                operationID: String? = nil,
                                                timeout: TimeInterval,
                                                context: String = "sleep") -> SleepUnmountAttemptResult {
        let operation = operationID ?? "-"
        let started = Date()
        let result = DAInventory.shared.unmountForSleep(
            volumePath: volumePath,
            wholeDiskBSDName: wholeDiskBSDName,
            expectedGeneration: expectedGeneration,
            expectedMediaRegistryEntryID: expectedMediaRegistryEntryID,
            expectedMountedVolumeBSDs: expectedMountedVolumeBSDs,
            enforceProtectionClosure: enforceProtectionClosure,
            force: force,
            retainBarrierForForceContinuation: retainBarrierForForceContinuation,
            timeout: timeout,
            operationID: operation,
            context: context
        )
        let elapsed = elapsedText(since: started)
        switch result {
        case let .completed(.callbackSuccess, requestWasForced):
            log.notice("cycle \(operation, privacy: .public) \(context, privacy: .public) DA explicit clean callback accepted target=\(wholeDiskBSDName ?? volumePath, privacy: .public) actualMode=\(requestWasForced ? "force" : "normal", privacy: .public) elapsed=\(elapsed, privacy: .public)s")
            return SleepUnmountAttemptResult(success: true,
                                             errorMessage: nil,
                                             dissenterStatus: nil,
                                             requestWasForced: requestWasForced)
        case let .completed(.callbackFailure(status, reason), requestWasForced):
            log.notice("cycle \(operation, privacy: .public) \(context, privacy: .public) DA unmount declined actualMode=\(requestWasForced ? "force" : "normal", privacy: .public) status=0x\(String(status.rawValue, radix: 16, uppercase: true), privacy: .public) forceEligible=\(status.isForceEligible, privacy: .public) elapsed=\(elapsed, privacy: .public)s reason=\(reason, privacy: .public)")
            return SleepUnmountAttemptResult(success: false,
                                             errorMessage: "DA unmount declined: \(reason)",
                                             dissenterStatus: status,
                                             requestWasForced: requestWasForced)
        case let .completed(.disconnectedBeforeCallback, requestWasForced):
            log.error("cycle \(operation, privacy: .public) \(context, privacy: .public) media disconnected before clean callback elapsed=\(elapsed, privacy: .public)s")
            ErrorReporter.report(signature: "sleep_media_removed_before_clean_callback")
            return SleepUnmountAttemptResult(success: false,
                                             errorMessage: "Media disconnected before clean unmount completed",
                                             dissenterStatus: nil,
                                             requestWasForced: requestWasForced)
        case let .timedOutPending(request):
            let lateTarget = SleepRemountTarget(
                wholeDiskBSD: request.token.wholeDiskBSD,
                physicalGeneration: request.token.generation,
                mediaRegistryEntryID: request.token.mediaRegistryEntryID
            )
            request.onLateClean { [weak self] in
                guard let self else { return }
                log.notice("cycle \(operation, privacy: .public) \(context, privacy: .public) late DA clean callback accepted after waiter timeout target=\(lateTarget.wholeDiskBSD, privacy: .public) generation=\(lateTarget.physicalGeneration, privacy: .public)")
                self.recordAutomaticUnmountTargets([lateTarget],
                                                   operationID: operation,
                                                   reason: context)
            }
            log.error("cycle \(operation, privacy: .public) \(context, privacy: .public) DA unmount wait timed out; request remains pending and no fallback will overlap elapsed=\(elapsed, privacy: .public)s")
            ErrorReporter.report(signature: "sleep_da_unmount_timed_out_pending")
            return SleepUnmountAttemptResult(success: false,
                                             errorMessage: "DA unmount timed out while the request remained pending",
                                             dissenterStatus: nil,
                                             requestWasForced: request.force)
        case let .unavailable(reason):
            log.error("cycle \(operation, privacy: .public) \(context, privacy: .public) DA unmount unavailable elapsed=\(elapsed, privacy: .public)s reason=\(reason, privacy: .public)")
            ErrorReporter.report(signature: "sleep_da_unmount_unavailable")
            return SleepUnmountAttemptResult(success: false,
                                             errorMessage: reason,
                                             dissenterStatus: nil,
                                             requestWasForced: force)
        }
    }

    /// diskutil 외부 명령 실행 helper.
    private func runDiskutil(_ args: [String],
                             operationID: String? = nil,
                             timeout: TimeInterval? = nil) -> (success: Bool, errorMessage: String?) {
        let operation = operationID ?? "-"
        let started = Date()
        let result = ProcessRunner.run(executable: "/usr/sbin/diskutil",
                                       arguments: args,
                                       timeout: timeout)
        let elapsed = elapsedText(since: started)
        let command = "diskutil \(args.joined(separator: " "))"
        let exitCode = result.terminationStatus.map(String.init) ?? "-"
        if result.success {
            log.info("cycle \(operation, privacy: .public) command OK: \(command, privacy: .public) elapsed=\(elapsed, privacy: .public)s exit=\(exitCode, privacy: .public)")
            return (true, nil)
        }
        log.notice("cycle \(operation, privacy: .public) command FAIL: \(command, privacy: .public) elapsed=\(elapsed, privacy: .public)s exit=\(exitCode, privacy: .public) timedOut=\(result.timedOut, privacy: .public) error=\(self.shortLogMessage(result.errorMessage), privacy: .public)")
        return (false, result.errorMessage)
    }

    private func requestSystemSleep() -> (success: Bool, errorMessage: String?) {
        let result = ProcessRunner.run(executable: "/usr/bin/pmset",
                                       arguments: ["sleepnow"],
                                       timeout: 5)
        if result.success {
            log.notice("pmset sleepnow requested")
            return (true, nil)
        }
        log.error("pmset sleepnow failed: \(result.errorMessage ?? "unknown", privacy: .public)")
        return (false, result.errorMessage)
    }

    // MARK: - Mount Actions

    /// 메뉴 일괄 마운트 wrapper. caller = "menu".
    @objc func mountAllAction(_ sender: Any?) {
        mountAll(caller: "menu")
    }

    /// 개별 마운트 (메뉴 아이템 클릭). representedObject = whole disk BSD name.
    /// ⌘+클릭이면 마운트 후 Finder 에서 첫 mount path 열기.
    @objc private func mountOne(_ sender: NSMenuItem) {
        guard let bsd = sender.representedObject as? String else { return }
        let displayName = sender.title
        let openInFinder = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        log.info("MOUNTONE start: \(displayName, privacy: .public) bsd=\(bsd, privacy: .public) openInFinder=\(openInFinder, privacy: .public)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let r = self.daMountWholeDisk(bsdName: bsd)
            DiskMenuSnapshotCache.invalidate()
            DiskMenuSnapshotCache.warm()
            log.info("MOUNTONE done: \(displayName, privacy: .public) success=\(r.success, privacy: .public)")
            DispatchQueue.main.async {
                if r.success {
                    self.notify(title: String(localized: "Mounted"), body: displayName, kind: .success)
                    if openInFinder {
                        // mount path 가 보통 /Volumes/<volumeName>. 충돌 시 (2) suffix 가능,
                        // 그 케이스는 silent 처리 (열기 실패해도 mount 자체는 성공).
                        let url = URL(fileURLWithPath: "/Volumes/\(displayName)")
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.open(url)
                        } else {
                            log.notice("openInFinder: /Volumes/\(displayName, privacy: .public) not found")
                        }
                    }
                } else {
                    self.notify(title: String(localized: "Couldn't mount \(displayName)"),
                                body: localizedOperationFailure(),
                                archived: true,
                                kind: .failure)
                }
            }
        }
    }

    /// 모든 마운트 안 된 외장 일괄 마운트. 디바운스 1.5s.
    private func mountAll(caller: String) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastMountAt)
        if elapsed < 1.5 {
            log.info("MOUNT(\(caller, privacy: .public)) DEBOUNCED — last fired \(String(format: "%.2f", elapsed), privacy: .public)s ago")
            flashIcon(symbol: "circle.dashed", duration: 0.3)
            return
        }
        lastMountAt = now
        log.info("MOUNT(\(caller, privacy: .public)) START")
        flashIcon(symbol: "arrow.down.circle", duration: 0.6)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let unmounted = UnmountedExternal.list()
            guard !unmounted.isEmpty else {
                log.info("MOUNT(\(caller, privacy: .public)) — no candidates")
                DispatchQueue.main.async { [weak self] in
                    self?.notify(title: String(localized: "Nothing to mount"),
                                 body: String(localized: "No unmounted external drives connected."))
                }
                return
            }

            let lock = NSLock()
            var success: [String] = []
            var failure: [(String, String)] = []
            let group = DispatchGroup()
            let pq = DispatchQueue(label: "com.yongza.ejectdrives.mountall", attributes: .concurrent)

            for u in unmounted {
                group.enter()
                pq.async {
                    let r = self.daMountWholeDisk(bsdName: u.bsdName)
                    if r.success {
                        log.info("✓ mount OK:    \(u.displayName, privacy: .public) (\(u.bsdName, privacy: .public))")
                    } else {
                        log.error("✗ mount FAIL:  \(u.displayName, privacy: .public) — \(r.errorMessage ?? "?", privacy: .public)")
                    }
                    lock.lock()
                    if r.success { success.append(u.displayName) }
                    else { failure.append((u.displayName, r.errorMessage ?? String(localized: "Unknown error"))) }
                    lock.unlock()
                    group.leave()
                }
            }
            group.wait()
            DiskMenuSnapshotCache.invalidate()
            DiskMenuSnapshotCache.warm()
            log.info("MOUNT(\(caller, privacy: .public)) DONE — success=\(success.count, privacy: .public) failure=\(failure.count, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                self?.notifyMountResult(success: success, failure: failure)
            }
        }
    }

    private func notifyMountResult(success: [String], failure: [(String, String)]) {
        if failure.isEmpty {
            // 모두 성공 — 성공이 본인 trigger 결과이므로 banner 만 (archived 안 함).
            notify(title: String(localized: "All drives mounted"),
                   body: success.joined(separator: ", "),
                   kind: .success)
            return
        }
        let title: String
        if success.isEmpty { title = String(localized: "Mount failed") }
        else { title = String(localized: "Some drives didn't mount") }
        var lines: [String] = []
        if !success.isEmpty {
            lines.append(String(localized: "Succeeded: \(success.joined(separator: ", "))"))
        }
        lines.append(String(localized: "Failed: \(failure.map { $0.0 }.joined(separator: ", "))"))
        notify(title: title, body: lines.joined(separator: "\n"), archived: true, kind: .failure)
    }

    // MARK: - Sleep

    private func setupSleepObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(systemWillSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(systemDidWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
        // Display sleep — 화면만 꺼지는 시점. system sleep 과 별개 노티.
        // `pmset sleep = 0` 환경 (데스크탑/항상-켬) 에서 보호 갭을 메우는 용도.
        nc.addObserver(self, selector: #selector(screensDidSleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(screensDidWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(systemWillPowerOff),
                       name: NSWorkspace.willPowerOffNotification, object: nil)
        nc.addObserver(self, selector: #selector(sessionDidBecomeActive),
                       name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesDidChange(_:)),
                       name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesDidChange(_:)),
                       name: NSWorkspace.didUnmountNotification, object: nil)
    }

    private func setupPowerSleepObserver() {
        var notifyPort: IONotificationPortRef?
        var notifier: io_object_t = 0
        let rootPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(),
                                                &notifyPort,
                                                { refcon, _, messageType, messageArgument in
                                                    guard let refcon else { return }
                                                    let app = Unmanaged<AppDelegate>
                                                        .fromOpaque(refcon)
                                                        .takeUnretainedValue()
                                                    app.handlePowerMessage(messageType: messageType,
                                                                           messageArgument: messageArgument)
                                                },
                                                &notifier)

        guard rootPort != 0, let notifyPort else {
            log.error("IORegisterForSystemPower failed; falling back to NSWorkspace willSleep")
            return
        }

        guard let source = IONotificationPortGetRunLoopSource(notifyPort)?.takeUnretainedValue() else {
            IONotificationPortDestroy(notifyPort)
            IOServiceClose(rootPort)
            log.error("IORegisterForSystemPower run loop source missing; falling back to NSWorkspace willSleep")
            return
        }

        powerRootPort = rootPort
        powerNotifyPort = notifyPort
        powerNotifier = notifier
        powerSleepAckCoordinator = PowerSleepAckCoordinator(rootPort: rootPort) { message in
            log.notice("\(message, privacy: .public)")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        log.notice("IOKit power sleep observer registered rootPort=\(rootPort, privacy: .public) notifier=\(notifier, privacy: .public)")
    }

    private func setupClamshellObserver() {
        guard let notifyPort = powerNotifyPort else {
            log.notice("IOKit clamshell observer skipped — power notify port unavailable")
            return
        }
        guard let matching = IOServiceMatching("IOPMrootDomain") else {
            log.error("IOServiceMatching(IOPMrootDomain) failed")
            return
        }

        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard rootDomain != 0 else {
            log.error("IOPMrootDomain service not found; clamshell pre-eject unavailable")
            return
        }

        var notifier: io_object_t = 0
        let result = IOServiceAddInterestNotification(notifyPort,
                                                      rootDomain,
                                                      kIOGeneralInterest,
                                                      { refcon, _, messageType, messageArgument in
                                                          guard let refcon else { return }
                                                          let app = Unmanaged<AppDelegate>
                                                              .fromOpaque(refcon)
                                                              .takeUnretainedValue()
                                                          app.handleClamshellMessage(messageType: messageType,
                                                                                     messageArgument: messageArgument)
                                                      },
                                                      Unmanaged.passUnretained(self).toOpaque(),
                                                      &notifier)

        guard result == KERN_SUCCESS else {
            IOObjectRelease(rootDomain)
            log.error("IOServiceAddInterestNotification clamshell failed result=0x\(String(result, radix: 16), privacy: .public)")
            return
        }

        clamshellRootDomain = rootDomain
        clamshellNotifier = notifier
        let state = currentClamshellState(rootDomain: rootDomain)
        if let closed = state.closed {
            autoEjectStateLock.lock()
            sleepEpisodeCoordinator.setInitialLidState(closed: closed)
            autoEjectStateLock.unlock()
        }
        log.notice("IOKit clamshell observer registered notifier=\(notifier, privacy: .public) closed=\(self.boolText(state.closed), privacy: .public) causesSleep=\(self.boolText(state.causesSleep), privacy: .public)")
    }

    private func tearDownPowerSleepObserver() {
        endPowerSleepMountBarrierIfNeeded()
        // ACK coordinator 가 열린 rootPort 를 마지막으로 사용한 뒤에만 observer/port 를 닫는다.
        // completion/deadline/termination 경쟁에서도 closed port 로 IOAllowPowerChange 하지 않게 한다.
        powerSleepAckCoordinator?.shutdownAndDrain()
        powerSleepAckCoordinator = nil
        if clamshellNotifier != 0 {
            IOObjectRelease(clamshellNotifier)
            clamshellNotifier = 0
        }
        if clamshellRootDomain != 0 {
            IOObjectRelease(clamshellRootDomain)
            clamshellRootDomain = 0
        }
        if powerNotifier != 0 {
            var notifier = powerNotifier
            let result = IODeregisterForSystemPower(&notifier)
            log.info("IODeregisterForSystemPower result=0x\(String(result, radix: 16), privacy: .public)")
            powerNotifier = 0
        }
        if let notifyPort = powerNotifyPort {
            IONotificationPortDestroy(notifyPort)
            powerNotifyPort = nil
        }
        if powerRootPort != 0 {
            IOServiceClose(powerRootPort)
            powerRootPort = 0
        }
    }

    private func handlePowerMessage(messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
        let notificationID = notificationID(from: messageArgument)
        switch messageType {
        case ioMessageCanSystemSleep:
            powerSleepCycleLock.lock()
            powerSleepCycleDeduplicator.recordCanSystemSleep()
            powerSleepCycleLock.unlock()
            log.notice("IOKit canSystemSleep received notificationID=\(notificationID, privacy: .public); allowing idle sleep")
            powerSleepAckCoordinator?.acknowledgeImmediately(
                messageType: messageType,
                notificationID: notificationID,
                operationID: "-"
            )
        case ioMessageSystemWillSleep:
            handlePowerSystemWillSleep(notificationID: notificationID)
        case ioMessageSystemWillNotSleep:
            // CanSystemSleep attempt가 취소된 경계다. 이 message 자체에는 ACK하지 않지만,
            // 다음 idle-sleep attempt가 notification ID를 재사용할 수 있어 epoch은 갱신한다.
            powerSleepCycleLock.lock()
            powerSleepCycleDeduplicator.advanceEpoch()
            powerSleepCycleLock.unlock()
            powerSleepAckCoordinator?.advanceEpoch()
            endPowerSleepMountBarrierIfNeeded()
            log.notice("IOKit systemWillNotSleep received notificationID=\(notificationID, privacy: .public)")
        case ioMessageSystemHasPoweredOn:
            powerSleepCycleLock.lock()
            powerSleepCycleDeduplicator.advanceEpoch()
            powerSleepCycleLock.unlock()
            powerSleepAckCoordinator?.advanceEpoch()
            endPowerSleepMountBarrierIfNeeded()
            log.notice("IOKit systemHasPoweredOn received notificationID=\(notificationID, privacy: .public)")
            requestAutomaticRemount(trigger: "IOKitPoweredOn")
        default:
            log.debug("IOKit power message ignored type=0x\(String(messageType, radix: 16), privacy: .public) notificationID=\(notificationID, privacy: .public)")
        }
    }

    private func handleClamshellMessage(messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
        guard messageType == ioPMMessageClamshellStateChange else {
            log.debug("IOKit clamshell observer ignored message type=0x\(String(messageType, radix: 16), privacy: .public)")
            return
        }

        let bits = Int(bitPattern: messageArgument)
        let closed = (bits & clamshellStateBit) != 0
        let causesSleep = (bits & clamshellSleepBit) != 0
        log.notice("IOKit clamshell state changed closed=\(closed, privacy: .public) causesSleep=\(causesSleep, privacy: .public) bits=0x\(String(bits, radix: 16), privacy: .public)")

        lidTransitionGate.lock()
        defer { lidTransitionGate.unlock() }

        guard closed else {
            // 뚜껑 열림 → lid-caused 추적 초기화 (오래된 닫힘 시각이 이후 idle 잠자기를 오인하지 않도록).
            lastClamshellCloseAt = nil
            autoEjectStateLock.lock()
            let remountSchedule = sleepEpisodeCoordinator.lidDidOpen()
            autoEjectStateLock.unlock()
            sleepEjectStateLock.lock()
            lidEpisodeGeneration = nil
            lidEpisodeGroup = nil
            lidEpisodeOperationID = nil
            lidEpisodeOutcome = nil
            lidEpisodeTrigger = nil
            lidEpisodeForceClaims = nil
            lidEpisodeInventoryCompletedGeneration = nil
            lidEpisodePowerRetryStarted = false
            lidEpisodeNeedsInventoryRefresh = false
            sleepEjectStateLock.unlock()
            if let remountSchedule {
                scheduleAutomaticRemount(remountSchedule, trigger: "clamshellOpen")
            } else {
                requestAutomaticRemount(trigger: "clamshellOpen")
            }
            return
        }
        // 뚜껑 닫힌 시각 기록 — willSleep 핸들러가 '이 잠자기가 뚜껑 때문인지' 판정하는 데 사용.
        lastClamshellCloseAt = Date()
        automaticRemountCommandGate.lock()
        autoEjectStateLock.lock()
        let lidTransition = sleepEpisodeCoordinator.lidDidClose()
        autoEjectStateLock.unlock()
        automaticRemountCommandGate.unlock()
        if !causesSleep {
            log.notice("IOKit clamshell pre-eject continuing although lid close does not report sleep")
        }
        guard LidCloseEject.enabled else {
            log.info("IOKit clamshell pre-eject skipped — LidCloseEject disabled")
            return
        }

        let task = startSleepEjectIfNeeded(reason: "clamshell",
                                           trigger: .lidClose,
                                           lidGeneration: lidTransition.generation)
        log.notice("cycle \(task.operationID, privacy: .public) clamshell close pre-eject \((task.started ? "started" : "joined"), privacy: .public) generation=\(lidTransition.generation, privacy: .public) newEpisode=\(lidTransition.isNewEpisode, privacy: .public)")
    }

    private func handlePowerSystemWillSleep(notificationID: Int) {
        powerSleepCycleLock.lock()
        let origin = powerSleepCycleDeduplicator.beginWillSleep(
            notificationID: notificationID
        )
        powerSleepCycleLock.unlock()

        guard let origin else {
            // IOKit이 같은 token을 재전달해도 ACK coordinator와 eject side effect 모두 1회다.
            // 최초 callback의 registration은 main run-loop 순서상 이 registration보다 먼저
            // ACK queue에 들어가므로, coordinator가 같은 key를 안전하게 dedupe한다.
            log.notice("IOKit duplicate systemWillSleep ignored notificationID=\(notificationID, privacy: .public)")
            powerSleepAckCoordinator?.deferAcknowledgment(
                messageType: ioMessageSystemWillSleep,
                notificationID: notificationID,
                operationID: "duplicate-willSleep",
                until: DispatchGroup(),
                deadline: 25
            )
            return
        }

        beginPowerSleepMountBarrierIfNeeded()
        let lidGeneration = currentClosedLidGeneration()
        let trigger = attributedSystemSleepTrigger(isIdle: origin == .idle,
                                                   lidGeneration: lidGeneration)
        let boundaryForceClaims = lidGeneration.flatMap {
            currentLidEpisodeForceClaims(generation: $0)
        } ?? SleepEpisodeForceClaimLedger()
        // ACK는 25초에 hard-stop하고, eject/retry는 callback 시점 기준 24초 안에서 끝낸다.
        let operationDeadline = Date().addingTimeInterval(24)
        let task = startSleepEjectIfNeeded(reason: "powerSleep",
                                           trigger: trigger,
                                           lidGeneration: lidGeneration,
                                           forceClaims: boundaryForceClaims,
                                           deadline: operationDeadline)
        let acknowledgmentGroup = DispatchGroup()
        acknowledgmentGroup.enter()
        continuePowerBoundaryEjectChain(task: task,
                                        deadline: operationDeadline,
                                        hasRunFreshBoundaryInventory: isPowerBoundaryReason(task.reason),
                                        retryAlreadyStarted: false,
                                        completion: acknowledgmentGroup,
                                        boundaryTrigger: trigger,
                                        boundaryForceClaims: boundaryForceClaims,
                                        powerNotificationID: notificationID)
        log.notice("cycle \(task.operationID, privacy: .public) IOKit systemWillSleep received; async defer notificationID=\(notificationID, privacy: .public) origin=\(origin == .idle ? "idle" : "forced", privacy: .public) trigger=\(trigger.logLabel, privacy: .public) ejectStarted=\(task.started, privacy: .public)")
        powerSleepAckCoordinator?.deferAcknowledgment(
            messageType: ioMessageSystemWillSleep,
            notificationID: notificationID,
            operationID: task.operationID,
            until: acknowledgmentGroup,
            deadline: 25
        )
    }

    private func continuePowerBoundaryEjectChain(task: SleepEjectTask,
                                                  deadline: Date,
                                                  hasRunFreshBoundaryInventory: Bool,
                                                  retryAlreadyStarted: Bool,
                                                  completion: DispatchGroup,
                                                  boundaryTrigger: SleepEjectTrigger,
                                                  boundaryForceClaims: SleepEpisodeForceClaimLedger,
                                                  powerNotificationID: Int? = nil) {
        // Policy decision을 main queue에 직렬화해 IOKit clamshell callback과 ordering을 공유한다.
        // 이미 전달된 새 close edge가 final ACK 검사 사이에 끼어드는 race를 막는다.
        task.group.notify(queue: .main) { [weak self] in
            guard let self else {
                completion.leave()
                return
            }

            // Drain all DA events queued before this decision. A mountedExternal event that arrived
            // after the prior task's snapshot must become a refresh inside this ACK chain.
            DAInventory.shared.flushPendingEvents()
            let differentActive = self.currentSleepEjectTask().flatMap {
                $0.operationID == task.operationID ? nil : $0
            }
            let currentLidGeneration = self.currentClosedLidGeneration()
            let lidBoundaryState: (refreshPending: Bool, latestOutcome: Bool?) = {
                guard currentLidGeneration != nil else { return (false, nil) }
                self.sleepEjectStateLock.lock()
                defer { self.sleepEjectStateLock.unlock() }
                let refreshPending = SleepLidInventoryPolicy.needsBoundaryRefresh(
                    currentClosedGeneration: currentLidGeneration,
                    completedInventoryGeneration: self.lidEpisodeInventoryCompletedGeneration,
                    explicitRefreshPending: self.lidEpisodeNeedsInventoryRefresh
                )
                let latestOutcome: Bool?
                if self.lidEpisodeInventoryCompletedGeneration == currentLidGeneration {
                    latestOutcome = self.lidEpisodeOutcome?.succeeded
                } else {
                    latestOutcome = nil
                }
                return (refreshPending, latestOutcome)
            }()
            // A newer close generation can start and finish between recursive chain callbacks.
            // Use that generation's retained outcome, not the older task's success, for retry policy.
            let succeeded = lidBoundaryState.latestOutcome
                ?? task.outcome.succeeded
                ?? false
            let action = PowerBoundaryEjectPolicy.nextAction(
                deadlineRemaining: deadline.timeIntervalSinceNow > 0,
                hasDifferentActiveOperation: differentActive != nil,
                inventoryRefreshPending: lidBoundaryState.refreshPending,
                hasRunFreshBoundaryInventory: hasRunFreshBoundaryInventory,
                lastAttemptSucceeded: succeeded,
                retryAlreadyStarted: retryAlreadyStarted
            )

            switch action {
            case .waitForActive:
                guard let differentActive else {
                    self.finishPowerBoundaryEjectChain(
                        completion: completion,
                        notificationID: powerNotificationID,
                        operationID: task.operationID
                    )
                    return
                }
                self.continuePowerBoundaryEjectChain(
                    task: differentActive,
                    deadline: deadline,
                    hasRunFreshBoundaryInventory: hasRunFreshBoundaryInventory
                        || self.isPowerBoundaryReason(differentActive.reason),
                    retryAlreadyStarted: retryAlreadyStarted,
                    completion: completion,
                    boundaryTrigger: boundaryTrigger,
                    boundaryForceClaims: boundaryForceClaims,
                    powerNotificationID: powerNotificationID
                )

            case .refreshInventory:
                let next: SleepEjectTask
                if let currentLidGeneration,
                   let lidTask = self.startLidInventoryRefreshIfNeeded(
                    generation: currentLidGeneration,
                    forceRefresh: true,
                    reason: "powerSleepRefresh",
                    forceClaims: boundaryForceClaims,
                    deadline: deadline
                   ) {
                    next = lidTask
                } else {
                    next = self.startSleepEjectIfNeeded(reason: "powerSleepRefresh",
                                                        trigger: boundaryTrigger,
                                                        forceClaims: boundaryForceClaims,
                                                        deadline: deadline)
                }
                guard next.operationID != task.operationID else {
                    self.finishPowerBoundaryEjectChain(
                        completion: completion,
                        notificationID: powerNotificationID,
                        operationID: task.operationID
                    )
                    return
                }
                self.continuePowerBoundaryEjectChain(
                    task: next,
                    deadline: deadline,
                    hasRunFreshBoundaryInventory: hasRunFreshBoundaryInventory
                        || self.isPowerBoundaryReason(next.reason),
                    retryAlreadyStarted: retryAlreadyStarted
                        || (!succeeded && !hasRunFreshBoundaryInventory),
                    completion: completion,
                    boundaryTrigger: boundaryTrigger,
                    boundaryForceClaims: boundaryForceClaims,
                    powerNotificationID: powerNotificationID
                )

            case .retry:
                let next: SleepEjectTask?
                if let currentLidGeneration {
                    next = self.startSleepEjectIfCurrentLidMatches(
                        reason: "powerSleepRetry",
                        generation: currentLidGeneration,
                        trigger: boundaryTrigger,
                        forceClaims: boundaryForceClaims,
                        deadline: deadline
                    )
                } else {
                    next = self.startSleepEjectIfNeeded(reason: "powerSleepRetry",
                                                        trigger: boundaryTrigger,
                                                        forceClaims: boundaryForceClaims,
                                                        deadline: deadline)
                }
                guard let next, next.operationID != task.operationID else {
                    self.finishPowerBoundaryEjectChain(
                        completion: completion,
                        notificationID: powerNotificationID,
                        operationID: task.operationID
                    )
                    return
                }
                self.continuePowerBoundaryEjectChain(
                    task: next,
                    deadline: deadline,
                    hasRunFreshBoundaryInventory: true,
                    retryAlreadyStarted: true,
                    completion: completion,
                    boundaryTrigger: boundaryTrigger,
                    boundaryForceClaims: boundaryForceClaims,
                    powerNotificationID: powerNotificationID
                )

            case .finish:
                self.finishPowerBoundaryEjectChain(
                    completion: completion,
                    notificationID: powerNotificationID,
                    operationID: task.operationID
                )
            }
        }
    }

    /// Called on main by the boundary chain. `leave()` makes the DispatchGroup eligible, then the
    /// synchronous coordinator commit drains that notification on its ACK queue before main can
    /// process a newer clamshell edge. Group notify/deadline races still converge in finishOnce.
    private func finishPowerBoundaryEjectChain(completion: DispatchGroup,
                                               notificationID: Int?,
                                               operationID: String) {
        completion.leave()
        guard let notificationID else { return }
        powerSleepAckCoordinator?.finishDeferredNow(
            messageType: ioMessageSystemWillSleep,
            notificationID: notificationID,
            operationID: operationID
        )
    }

    private func isPowerBoundaryReason(_ reason: String) -> Bool {
        reason == "powerSleep"
            || reason == "powerSleepRefresh"
            || reason == "powerSleepRetry"
            || reason == "clamshellMediaMounted"
            || reason == "workspaceSleep"
    }

    private func beginPowerSleepMountBarrierIfNeeded() {
        guard powerSleepMountBarrierToken == nil else { return }
        let token = DAInventory.shared.beginSleepProtectionMountBarrier()
        powerSleepMountBarrierToken = token
        log.notice("power sleep external-mount barrier began token=\(token, privacy: .public)")
    }

    private func endPowerSleepMountBarrierIfNeeded() {
        guard let token = powerSleepMountBarrierToken else { return }
        powerSleepMountBarrierToken = nil
        DAInventory.shared.endSleepProtectionMountBarrier(token: token)
        log.notice("power sleep external-mount barrier ended token=\(token, privacy: .public)")
    }

    private func startSleepEjectIfCurrentLidMatches(reason: String,
                                                    generation: UInt64,
                                                    trigger: SleepEjectTrigger,
                                                    forceClaims: SleepEpisodeForceClaimLedger,
                                                    deadline: Date) -> SleepEjectTask? {
        lidTransitionGate.lock()
        defer { lidTransitionGate.unlock() }
        guard currentClosedLidGeneration() == generation else { return nil }
        return startSleepEjectIfNeeded(reason: reason,
                                       trigger: trigger,
                                       lidGeneration: generation,
                                       forceClaims: forceClaims,
                                       deadline: deadline)
    }

    private func currentSleepEjectTask() -> SleepEjectTask? {
        sleepEjectStateLock.lock()
        defer { sleepEjectStateLock.unlock() }
        guard let operationID = activeSleepEjectOperationID,
              let group = activeSleepEjectGroup,
              let outcome = activeSleepEjectOutcome,
              let trigger = activeSleepEjectTrigger,
              let forceClaims = activeSleepEjectForceClaims
        else { return nil }
        return (operationID,
                group,
                outcome,
                false,
                activeSleepEjectReason ?? "-",
                trigger,
                forceClaims)
    }

    private func currentClosedLidGeneration() -> UInt64? {
        autoEjectStateLock.lock()
        defer { autoEjectStateLock.unlock() }
        guard sleepEpisodeCoordinator.isLidClosed else { return nil }
        return sleepEpisodeCoordinator.lidGeneration
    }

    private func currentLidEpisodeForceClaims(
        generation: UInt64
    ) -> SleepEpisodeForceClaimLedger? {
        sleepEjectStateLock.lock()
        defer { sleepEjectStateLock.unlock() }
        guard lidEpisodeGeneration == generation else { return nil }
        return lidEpisodeForceClaims
    }

    /// Power and clamshell notifications can cross on the main run loop. Preserve the existing
    /// short attribution window so a real lid-close episode keeps the lid setting and force policy.
    private func attributedSystemSleepTrigger(isIdle: Bool?,
                                              lidGeneration: UInt64?) -> SleepEjectTrigger {
        let recentlyClosed = lastClamshellCloseAt.map {
            Date().timeIntervalSince($0) < clamshellSleepAttributionWindow
        } ?? false
        let lidAttributed = lidGeneration != nil
            || currentClosedLidGeneration() != nil
            || recentlyClosed
        return SleepEjectTrigger.systemSleep(isIdle: isIdle,
                                             lidAttributed: lidAttributed)
    }

    /// Amphetamine CDM처럼 lid가 닫힌 채 awake인 동안 새 external volume이 mount되면 기존
    /// completed lid group을 재사용하지 않고, 현재 active cycle 직후 새 inventory cycle을 만든다.
    private func handleExternalMediaMountedWhileLidClosed() {
        lidTransitionGate.lock()
        guard LidCloseEject.enabled,
              let generation = currentClosedLidGeneration() else {
            lidTransitionGate.unlock()
            return
        }

        sleepEjectStateLock.lock()
        let wasAlreadyPending = lidEpisodeNeedsInventoryRefresh
        lidEpisodeNeedsInventoryRefresh = true
        let activeGroup = activeSleepEjectGroup
        sleepEjectStateLock.unlock()
        lidTransitionGate.unlock()
        guard !wasAlreadyPending else { return }

        if let activeGroup {
            activeGroup.notify(queue: .global(qos: .userInitiated)) { [weak self] in
                self?.scheduleLidInventoryRefresh(generation: generation)
            }
        } else {
            scheduleLidInventoryRefresh(generation: generation)
        }
    }

    private func scheduleLidInventoryRefresh(generation: UInt64) {
        guard let task = startLidInventoryRefreshIfNeeded(generation: generation) else { return }
        if !task.started {
            task.group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
                self?.scheduleLidInventoryRefresh(generation: generation)
            }
        }
    }

    @discardableResult
    private func startLidInventoryRefreshIfNeeded(generation: UInt64,
                                                  forceRefresh: Bool = false,
                                                  reason: String = "clamshellMediaMounted",
                                                  forceClaims: SleepEpisodeForceClaimLedger? = nil,
                                                  deadline: Date? = nil) -> SleepEjectTask? {
        lidTransitionGate.lock()
        defer { lidTransitionGate.unlock() }
        guard LidCloseEject.enabled,
              currentClosedLidGeneration() == generation else { return nil }

        sleepEjectStartGate.lock()
        defer { sleepEjectStartGate.unlock() }
        sleepEjectStateLock.lock()
        guard forceRefresh || lidEpisodeNeedsInventoryRefresh else {
            sleepEjectStateLock.unlock()
            return nil
        }
        if let operationID = activeSleepEjectOperationID,
           let activeGroup = activeSleepEjectGroup,
           let outcome = activeSleepEjectOutcome,
           let activeTrigger = activeSleepEjectTrigger,
           let activeForceClaims = activeSleepEjectForceClaims {
            let activeReason = activeSleepEjectReason ?? "-"
            sleepEjectStateLock.unlock()
            return (operationID,
                    activeGroup,
                    outcome,
                    false,
                    activeReason,
                    activeTrigger,
                    activeForceClaims)
        }
        let episodeForceClaims: SleepEpisodeForceClaimLedger
        if SleepLidInventoryPolicy.shouldPreferExistingForceClaimLedger(
            episodeGeneration: lidEpisodeGeneration,
            requestedGeneration: generation,
            hasExistingLedger: lidEpisodeForceClaims != nil
        ), let existing = lidEpisodeForceClaims {
            episodeForceClaims = existing
        } else {
            episodeForceClaims = forceClaims ?? SleepEpisodeForceClaimLedger()
        }
        lidEpisodeNeedsInventoryRefresh = false
        lidEpisodeGeneration = generation
        lidEpisodeGroup = nil
        lidEpisodeOperationID = nil
        lidEpisodeOutcome = nil
        lidEpisodeTrigger = nil
        lidEpisodeForceClaims = episodeForceClaims
        sleepEjectStateLock.unlock()

        let task = startSleepEjectWithStartGateHeld(reason: reason,
                                                    trigger: .lidClose,
                                                    lidGeneration: generation,
                                                    forceClaims: episodeForceClaims,
                                                    deadline: deadline)
        log.notice("cycle \(task.operationID, privacy: .public) lid-closed mounted media refresh \((task.started ? "started" : "joined"), privacy: .public) generation=\(generation, privacy: .public)")
        return task
    }

    private func recordAutomaticUnmountTargets(_ disks: Set<SleepRemountTarget>,
                                               operationID: String,
                                               reason: String) {
        autoEjectStateLock.lock()
        let remountSchedule = sleepEpisodeCoordinator.recordCleanUnmountTargets(
            disks,
            operationID: operationID,
            reason: reason
        )
        let storedTargets = sleepEpisodeCoordinator.pendingTargets
        autoEjectStateLock.unlock()
        log.info("cycle \(operationID, privacy: .public) automatic clean targets unioned reason=\(reason, privacy: .public) added=\(disks.sorted(), privacy: .public) stored=\(storedTargets.sorted(), privacy: .public)")
        if let remountSchedule {
            scheduleAutomaticRemount(remountSchedule, trigger: "lateCleanCallback")
        }
    }

    private func beginAutomaticEject(operationID: String, reason: String) {
        automaticRemountCommandGate.lock()
        autoEjectStateLock.lock()
        sleepEpisodeCoordinator.automaticEjectDidStart(operationID: operationID,
                                                       reason: reason)
        autoEjectStateLock.unlock()
        automaticRemountCommandGate.unlock()
    }

    private func startSleepEjectIfNeeded(reason: String,
                                         trigger: SleepEjectTrigger,
                                         lidGeneration: UInt64? = nil,
                                         forceClaims: SleepEpisodeForceClaimLedger? = nil,
                                         deadline: Date? = nil) -> SleepEjectTask {
        sleepEjectStartGate.lock()
        defer { sleepEjectStartGate.unlock() }
        return startSleepEjectWithStartGateHeld(reason: reason,
                                                trigger: trigger,
                                                lidGeneration: lidGeneration,
                                                forceClaims: forceClaims,
                                                deadline: deadline)
    }

    /// Caller owns `sleepEjectStartGate`.
    private func startSleepEjectWithStartGateHeld(reason: String,
                                                  trigger: SleepEjectTrigger,
                                                  lidGeneration: UInt64? = nil,
                                                  forceClaims: SleepEpisodeForceClaimLedger? = nil,
                                                  deadline: Date? = nil) -> SleepEjectTask {
        let requestedAt = Date()
        let operationDeadline = deadline ?? requestedAt.addingTimeInterval(24)
        let isPowerRetryTrigger = reason == "powerSleep"
            || reason == "powerSleepRetry"
            || reason == "workspaceSleep"
        sleepEjectStateLock.lock()
        if let operationID = activeSleepEjectOperationID,
           let group = activeSleepEjectGroup,
           let outcome = activeSleepEjectOutcome,
           let activeTrigger = activeSleepEjectTrigger,
           let activeForceClaims = activeSleepEjectForceClaims {
            let activeReason = activeSleepEjectReason ?? "-"
            var refreshGeneration: UInt64?
            if let lidGeneration {
                let previousEpisodeGeneration = self.lidEpisodeGeneration
                let existingEpisodeForceClaims = previousEpisodeGeneration == lidGeneration
                    ? lidEpisodeForceClaims
                    : nil
                let needsNewGenerationRefresh = SleepLidInventoryPolicy.needsRefreshAfterJoiningActive(
                    previousGeneration: previousEpisodeGeneration,
                    requestedGeneration: lidGeneration
                )
                if needsNewGenerationRefresh {
                    lidEpisodePowerRetryStarted = false
                    // A new physical close edge must not be fully consumed by an older worker
                    // that may already have taken its inventory snapshot. Join it for ordering,
                    // then run one fresh inventory cycle for this lid generation.
                    lidEpisodeNeedsInventoryRefresh = true
                    refreshGeneration = lidGeneration
                }
                self.lidEpisodeGeneration = lidGeneration
                lidEpisodeOperationID = operationID
                lidEpisodeGroup = group
                lidEpisodeOutcome = outcome
                // A new close edge is a new destructive-I/O episode even when it must first wait
                // for an older active task. Give its later fresh inventory an independent claim.
                lidEpisodeTrigger = .lidClose
                lidEpisodeForceClaims = SleepLidInventoryPolicy.shouldReplaceForceClaimLedger(
                    previousGeneration: previousEpisodeGeneration,
                    requestedGeneration: lidGeneration,
                    hasExistingLedger: existingEpisodeForceClaims != nil
                )
                    ? (forceClaims ?? SleepEpisodeForceClaimLedger())
                    : existingEpisodeForceClaims
            }
            sleepEjectStateLock.unlock()
            if let refreshGeneration {
                group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
                    self?.scheduleLidInventoryRefresh(generation: refreshGeneration)
                }
            }
            log.notice("cycle \(operationID, privacy: .public) sleep eject already active; join reason=\(reason, privacy: .public) activeReason=\(activeReason, privacy: .public)")
            return (operationID,
                    group,
                    outcome,
                    false,
                    activeReason,
                    activeTrigger,
                    activeForceClaims)
        }

        if let lidGeneration,
           self.lidEpisodeGeneration == lidGeneration,
           let operationID = lidEpisodeOperationID,
           let group = lidEpisodeGroup,
           let outcome = lidEpisodeOutcome,
           let episodeTrigger = lidEpisodeTrigger,
           let episodeForceClaims = lidEpisodeForceClaims {
            let canStartPowerRetry = SleepLidRetryPolicy.shouldStartPowerRetry(
                priorSucceeded: outcome.succeeded,
                isSleepBoundaryTrigger: isPowerRetryTrigger,
                retryAlreadyStarted: lidEpisodePowerRetryStarted,
                hasActiveOperation: false
            )
            if canStartPowerRetry {
                lidEpisodePowerRetryStarted = true
                log.notice("cycle \(operationID, privacy: .public) failed lid episode will use one bounded power-sleep retry generation=\(lidGeneration, privacy: .public)")
            } else {
                sleepEjectStateLock.unlock()
                log.notice("cycle \(operationID, privacy: .public) lid episode eject already started/completed; join reason=\(reason, privacy: .public) generation=\(lidGeneration, privacy: .public)")
                return (operationID,
                        group,
                        outcome,
                        false,
                        "lidEpisode",
                        episodeTrigger,
                        episodeForceClaims)
            }
        }

        let selectedForceClaims: SleepEpisodeForceClaimLedger = {
            if let lidGeneration,
               self.lidEpisodeGeneration == lidGeneration,
               let episodeForceClaims = self.lidEpisodeForceClaims {
                return episodeForceClaims
            }
            return forceClaims ?? SleepEpisodeForceClaimLedger()
        }()
        let operation = newOperationID(reason: "sleep")
        let group = DispatchGroup()
        let outcome = SleepEjectOutcomeBox()
        group.enter()
        activeSleepEjectGroup = group
        activeSleepEjectOperationID = operation
        activeSleepEjectReason = reason
        activeSleepEjectTrigger = trigger
        activeSleepEjectForceClaims = selectedForceClaims
        activeSleepEjectOutcome = outcome
        if let lidGeneration {
            if self.lidEpisodeGeneration != lidGeneration {
                lidEpisodePowerRetryStarted = false
                lidEpisodeInventoryCompletedGeneration = nil
                lidEpisodeForceClaims = nil
            }
            self.lidEpisodeGeneration = lidGeneration
            lidEpisodeOperationID = operation
            lidEpisodeGroup = group
            lidEpisodeOutcome = outcome
            lidEpisodeTrigger = trigger
            lidEpisodeForceClaims = selectedForceClaims
        }
        sleepEjectStateLock.unlock()

        beginAutomaticEject(operationID: operation, reason: reason)

        sleepEjectQueue.async { [weak self] in
            guard let self else {
                outcome.finish(false)
                group.leave()
                return
            }
            log.info("cycle \(operation, privacy: .public) automatic eject worker started reason=\(reason, privacy: .public) trigger=\(trigger.logLabel, privacy: .public) forceAllowed=\(trigger.effectiveForceFallback(masterEnabled: SettingsStore.forceFallbackEnabled), privacy: .public) dispatchLatency=\(self.elapsedText(since: requestedAt), privacy: .public)s")
            let attemptSucceeded: Bool
            if trigger.isDisplaySleep {
                attemptSucceeded = self.performDisplaySleepEject(operation: operation,
                                                                 totalStarted: requestedAt,
                                                                 forceClaims: selectedForceClaims,
                                                                 deadline: operationDeadline)
            } else {
                attemptSucceeded = self.performSystemSleepEject(operation: operation,
                                                                totalStarted: requestedAt,
                                                                reason: reason,
                                                                trigger: trigger,
                                                                forceClaims: selectedForceClaims,
                                                                deadline: operationDeadline)
            }
            self.sleepEjectStateLock.lock()
            outcome.finish(attemptSucceeded)
            if let lidGeneration,
               self.lidEpisodeGeneration == lidGeneration {
                self.lidEpisodeInventoryCompletedGeneration = lidGeneration
            }
            if self.activeSleepEjectOperationID == operation {
                self.activeSleepEjectGroup = nil
                self.activeSleepEjectOperationID = nil
                self.activeSleepEjectReason = nil
                self.activeSleepEjectTrigger = nil
                self.activeSleepEjectForceClaims = nil
                self.activeSleepEjectOutcome = nil
            }
            self.sleepEjectStateLock.unlock()
            group.leave()
        }

        return (operation,
                group,
                outcome,
                true,
                reason,
                trigger,
                selectedForceClaims)
    }

    private func currentClamshellState(rootDomain: io_registry_entry_t) -> (closed: Bool?, causesSleep: Bool?) {
        (boolProperty("AppleClamshellState", rootDomain: rootDomain),
         boolProperty("AppleClamshellCausesSleep", rootDomain: rootDomain))
    }

    private func boolProperty(_ key: String, rootDomain: io_registry_entry_t) -> Bool? {
        guard let value = IORegistryEntryCreateCFProperty(rootDomain,
                                                         key as CFString,
                                                         kCFAllocatorDefault,
                                                         0)?.takeRetainedValue()
        else { return nil }
        return value as? Bool
    }

    private func boolText(_ value: Bool?) -> String {
        guard let value else { return "unknown" }
        return value ? "true" : "false"
    }

    @objc private func volumesDidChange(_ notification: Notification) {
        log.info("volume changed: \(notification.name.rawValue, privacy: .public)")
        DiskMenuSnapshotCache.invalidate()
        DiskMenuSnapshotCache.warm()
        scheduleMountedDriveCountRefresh()
    }

    /// wake 직후:
    /// 1. macOS 가 status bar view 를 redraw 하면서 button.image 가 reset 되는 케이스 보호 —
    ///    마지막 결과 symbol 다시 set.
    /// 2. 자동(lid-close) 추출된 디스크들 자동 재마운트 시도 — 사용자 무감각 UX.
    @objc private func systemDidWake() {
        if powerRootPort == 0 {
            // NSWorkspace fallback에는 IOKit HasPoweredOn이 없으므로 여기서 lease를 끝낸다.
            endPowerSleepMountBarrierIfNeeded()
        }
        let operation = autoEjectOperationID ?? "-"
        let reason = autoEjectOperationReason ?? "-"
        log.info("cycle \(operation, privacy: .public) didWake notification received reason=\(reason, privacy: .public) storedTargets=\(self.autoEjectedDisks.sorted(), privacy: .public)")

        // 1) 아이콘 복원
        if lastResultSymbol != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, let symbol = self.lastResultSymbol else { return }
                log.info("cycle \(operation, privacy: .public) didWake → restore icon: \(symbol, privacy: .public)")
                self.setPersistentIcon(symbol: symbol)
            }
        }
        // sleep 중 디바이스가 빠지거나 wake 시 재마운트될 수 있음 → count 아이콘 재반영.
        // 결과 아이콘 표시 중이면 updateMountedDriveCount 가 알아서 defer (count 만 저장).
        scheduleMountedDriveCountRefresh(after: 1.0)

        // 2) 자동 추출된 디스크 재마운트. 실제 target claim 은 2초 뒤 token 을 다시 검증해
        // 그 사이 lid가 재차 닫힌 경우 stale timer가 mount하지 못하게 한다.
        requestAutomaticRemount(trigger: "systemDidWake")
    }

    @objc private func systemWillSleep() {
        guard powerRootPort == 0 else {
            log.info("NSWorkspace willSleep skipped — IOKit power observer active")
            return
        }

        // NSWorkspace notification 에는 async completion handshake 가 없다. Main thread 를
        // 기다리게 하면 DA approver callback 과 자기 교착하므로 작업만 시작하고 즉시 반환한다.
        beginPowerSleepMountBarrierIfNeeded()
        let lidGeneration = currentClosedLidGeneration()
        let trigger = attributedSystemSleepTrigger(isIdle: nil,
                                                   lidGeneration: lidGeneration)
        let boundaryForceClaims = lidGeneration.flatMap {
            currentLidEpisodeForceClaims(generation: $0)
        } ?? SleepEpisodeForceClaimLedger()
        let operationDeadline = Date().addingTimeInterval(24)
        let task = startSleepEjectIfNeeded(reason: "workspaceSleep",
                                           trigger: trigger,
                                           lidGeneration: lidGeneration,
                                           forceClaims: boundaryForceClaims,
                                           deadline: operationDeadline)
        let completion = DispatchGroup()
        completion.enter()
        continuePowerBoundaryEjectChain(
            task: task,
            deadline: operationDeadline,
            hasRunFreshBoundaryInventory: isPowerBoundaryReason(task.reason),
            retryAlreadyStarted: false,
            completion: completion,
            boundaryTrigger: trigger,
            boundaryForceClaims: boundaryForceClaims
        )
        log.notice("cycle \(task.operationID, privacy: .public) NSWorkspace willSleep fallback received; trigger=\(trigger.logLabel, privacy: .public) async eject \((task.started ? "started" : "joined"), privacy: .public)")
    }

    private func performSystemSleepEject(operation: String,
                                         totalStarted: Date,
                                         reason: String,
                                         trigger: SleepEjectTrigger,
                                         forceClaims: SleepEpisodeForceClaimLedger,
                                         deadline: Date) -> Bool {
        log.notice("cycle \(operation, privacy: .public) willSleep handler settings source=\(reason, privacy: .public) trigger=\(trigger.logLabel, privacy: .public) sleepEject=\(SleepEject.enabled, privacy: .public) displaySleepEject=\(DisplaySleepEject.enabled, privacy: .public) forceFallback=\(SettingsStore.forceFallbackEnabled, privacy: .public) effectiveForce=\(trigger.effectiveForceFallback(masterEnabled: SettingsStore.forceFallbackEnabled), privacy: .public) libraryMgmt=\(LibraryAppManagement.enabled, privacy: .public)")
        if let until = skipSleepAutoEjectUntil, Date() < until {
            skipSleepAutoEjectUntil = nil
            log.info("cycle \(operation, privacy: .public) EJECT(sleep) SKIPPED — already handled by Eject and Sleep")
            return true
        }
        skipSleepAutoEjectUntil = nil

        // Lid close keeps its dedicated opt-in. Idle and forced non-lid sleep share the existing
        // SleepEject switch; only their force-fallback authorization differs.
        let lidCaused = trigger == .lidClose
        guard (lidCaused ? LidCloseEject.enabled : SleepEject.enabled) else {
            log.info("cycle \(operation, privacy: .public) EJECT(sleep) SKIPPED — \(lidCaused ? "LidCloseEject" : "SleepEject", privacy: .public) disabled lidCaused=\(lidCaused, privacy: .public)")
            return true
        }
        log.info("cycle \(operation, privacy: .public) EJECT(sleep) START")

        // 외장 라이브러리 앱 자동 종료 (Music / Photos) — 옵션 ON 시 추출 직전.
        if LibraryAppManagement.enabled {
            let quitStarted = Date()
            LibraryAppHandler.quitLibraryApps()
            log.info("cycle \(operation, privacy: .public) EJECT(sleep) library apps quit complete elapsed=\(self.elapsedText(since: quitStarted), privacy: .public)s")
        }

        let ejectStarted = Date()
        let r = ejectAllForSleep(operationID: operation,
                                 trigger: trigger,
                                 forceClaims: forceClaims,
                                 deadline: deadline)
        recordAutomaticUnmountTargets(r.remountTargets,
                                      operationID: operation,
                                      reason: reason)
        log.info("cycle \(operation, privacy: .public) EJECT(sleep) recorded successful BSDs: \(self.autoEjectedDisks.sorted(), privacy: .public)")
        log.notice("cycle \(operation, privacy: .public) EJECT(sleep) DONE — success=\(r.success.count, privacy: .public) failure=\(r.failure.count, privacy: .public) remountTargets=\(r.remountTargets.sorted(), privacy: .public) ejectElapsed=\(self.elapsedText(since: ejectStarted), privacy: .public)s totalElapsed=\(self.elapsedText(since: totalStarted), privacy: .public)s")

        // Sleep 추출 실패는 부재 중 발생한 negative event → 알림 센터에 보관.
        // unmount 안 된 채 sleep 진입했으니 dock 분리 시 file system 손상 위험.
        // sleep 진입 직전이지만 UNUserNotificationCenter 는 OS-level 이라 등록만 되면 OS 가 처리.
        if !r.failure.isEmpty {
            let failedNames = r.failure.map { $0.0 }.joined(separator: ", ")
            notify(title: String(localized: "\(r.failure.count) drive(s) didn't eject before sleep"),
                   body: String(localized: "\(failedNames)\nDisks went to sleep still mounted. Disconnect risk. Eject manually after wake."),
                   archived: true,
                   kind: .failure)
        }
        return r.failure.isEmpty
    }

    @objc private func systemWillPowerOff() {
        log.notice("willPowerOff notification received")
        guard powerOffAutoEjectEnabled else {
            log.info("EJECT(poweroff) SKIPPED — power-off auto eject disabled")
            return
        }
        shouldEjectBeforeTerminate = true
        startPowerOffEjectIfNeeded()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard powerOffAutoEjectEnabled else {
            return .terminateNow
        }
        guard shouldEjectBeforeTerminate || powerOffEjectInProgress else {
            return .terminateNow
        }

        if powerOffEjectCompleted {
            return .terminateNow
        }

        pendingTerminateReplyApp = sender
        startPowerOffEjectIfNeeded()
        return .terminateLater
    }

    private func startPowerOffEjectIfNeeded() {
        guard !powerOffEjectCompleted, !powerOffEjectInProgress else { return }
        powerOffEjectInProgress = true
        log.notice("EJECT(poweroff) START")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if LibraryAppManagement.enabled {
                LibraryAppHandler.quitLibraryApps()
            }

            let r = self.ejectAllSilently(applyExcludeFilter: true)
            log.notice("EJECT(poweroff) DONE — success=\(r.success.count, privacy: .public) failure=\(r.failure.count, privacy: .public)")

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.powerOffEjectCompleted = true
                self.powerOffEjectInProgress = false

                if !r.failure.isEmpty {
                    let failedNames = r.failure.map { $0.0 }.joined(separator: ", ")
                    self.notify(title: String(localized: "\(r.failure.count) drive(s) didn't eject before power off"),
                                body: String(localized: "\(failedNames)\nLogout, restart, or shutdown is continuing. Eject manually if you stay logged in."),
                                archived: true,
                                kind: .failure)
                }

                if let app = self.pendingTerminateReplyApp {
                    self.pendingTerminateReplyApp = nil
                    app.reply(toApplicationShouldTerminate: true)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    self?.resetPowerOffEjectStateIfStillRunning()
                }
            }
        }
    }

    @objc private func sessionDidBecomeActive() {
        log.info("sessionDidBecomeActive notification received")
        resetPowerOffEjectStateIfStillRunning()
    }

    private func resetPowerOffEjectStateIfStillRunning() {
        guard pendingTerminateReplyApp == nil else { return }
        if shouldEjectBeforeTerminate || powerOffEjectInProgress || powerOffEjectCompleted {
            log.info("reset power-off eject state")
        }
        shouldEjectBeforeTerminate = false
        powerOffEjectInProgress = false
        powerOffEjectCompleted = false
    }

    // MARK: - Display Sleep (`pmset sleep = 0` 환경 보호용)

    /// 화면이 꺼질 때 자동 추출. system sleep 과 독립.
    ///
    /// **왜?** `pmset sleep = 0` (데스크탑/항상-켬) 사용자는 화면이 꺼져도 system 은 awake 상태.
    /// 그 상태에서 도킹/외장 분리 시 ungraceful disconnect (`danglingVolumeList` 등록).
    /// system sleep 만 처리하던 v0.2.x 의 갭. Jettison 1.9.1 도 동일 시나리오 대응.
    ///
    /// **트레이드오프**: 자리 잠깐 비우면 (디스플레이 sleep) 추출 → 돌아와서 (디스플레이 wake)
    /// 재마운트 사이클 빈번 발생 가능. 그래서 default = false, 명시적 opt-in.
    @objc private func screensDidSleep() {
        log.notice("screensDidSleep notification received settings sleepEject=\(SleepEject.enabled, privacy: .public) displaySleepEject=\(DisplaySleepEject.enabled, privacy: .public) forceFallback=\(SettingsStore.forceFallbackEnabled, privacy: .public) libraryMgmt=\(LibraryAppManagement.enabled, privacy: .public) existingTargets=\(self.autoEjectedDisks.sorted(), privacy: .public)")
        guard DisplaySleepEject.enabled else {
            log.info("EJECT(displaysleep) SKIPPED — DisplaySleepEject disabled")
            return
        }
        let task = startSleepEjectIfNeeded(reason: "displaySleep",
                                           trigger: .displaySleep)
        log.notice("cycle \(task.operationID, privacy: .public) screensDidSleep async eject \((task.started ? "started" : "joined"), privacy: .public)")
    }

    private func performDisplaySleepEject(operation: String,
                                          totalStarted: Date,
                                          forceClaims: SleepEpisodeForceClaimLedger,
                                          deadline: Date) -> Bool {
        guard DisplaySleepEject.enabled else {
            log.info("cycle \(operation, privacy: .public) EJECT(displaysleep) SKIPPED — DisplaySleepEject disabled before execution")
            return true
        }
        guard autoEjectedDisks.isEmpty else {
            log.info("cycle \(operation, privacy: .public) EJECT(displaysleep) SKIPPED — clean targets already stored")
            return true
        }
        log.info("cycle \(operation, privacy: .public) EJECT(displaysleep) START")

        // 외장 라이브러리 앱 자동 종료 (옵션 ON 시).
        if LibraryAppManagement.enabled {
            let quitStarted = Date()
            LibraryAppHandler.quitLibraryApps()
            log.info("cycle \(operation, privacy: .public) EJECT(displaysleep) library apps quit complete elapsed=\(self.elapsedText(since: quitStarted), privacy: .public)s")
        }

        let ejectStarted = Date()
        let r = ejectAllForSleep(operationID: operation,
                                 applyExcludeFilter: true,
                                 context: "displaySleep",
                                 trigger: .displaySleep,
                                 forceClaims: forceClaims,
                                 deadline: deadline)
        recordAutomaticUnmountTargets(r.remountTargets,
                                      operationID: operation,
                                      reason: "displaySleep")
        log.info("cycle \(operation, privacy: .public) EJECT(displaysleep) recorded successful BSDs: \(self.autoEjectedDisks.sorted(), privacy: .public)")
        log.notice("cycle \(operation, privacy: .public) EJECT(displaysleep) DONE — success=\(r.success.count, privacy: .public) failure=\(r.failure.count, privacy: .public) remountTargets=\(r.remountTargets.sorted(), privacy: .public) ejectElapsed=\(self.elapsedText(since: ejectStarted), privacy: .public)s totalElapsed=\(self.elapsedText(since: totalStarted), privacy: .public)s")

        if !r.failure.isEmpty {
            let failedNames = r.failure.map { $0.0 }.joined(separator: ", ")
            DispatchQueue.main.async { [weak self] in
                self?.notify(title: String(localized: "\(r.failure.count) drive(s) didn't eject at display sleep"),
                             body: String(localized: "\(failedNames)\nDisks still mounted. Disconnect risk. Wake screen and eject manually."),
                             archived: true,
                             kind: .failure)
            }
        }
        return r.failure.isEmpty
    }

    /// 화면 다시 켜질 때 재마운트. systemDidWake 와 같은 coordinator 를 사용하므로 두
    /// notification 이 함께 와도 disk당 하나의 generation token만 예약된다.
    @objc private func screensDidWake() {
        let operation = autoEjectOperationID ?? "-"
        let reason = autoEjectOperationReason ?? "-"
        log.info("cycle \(operation, privacy: .public) screensDidWake notification received reason=\(reason, privacy: .public) storedTargets=\(self.autoEjectedDisks.sorted(), privacy: .public)")
        requestAutomaticRemount(trigger: "screensDidWake")
    }

    private func requestAutomaticRemount(trigger: String) {
        autoEjectStateLock.lock()
        let schedule = sleepEpisodeCoordinator.wakeDidOccur()
        let lidClosed = sleepEpisodeCoordinator.isLidClosed
        let targets = sleepEpisodeCoordinator.pendingTargets
        let operation = sleepEpisodeCoordinator.operationID ?? "-"
        autoEjectStateLock.unlock()

        if let schedule {
            scheduleAutomaticRemount(schedule, trigger: trigger)
            return
        }
        if lidClosed {
            log.info("cycle \(operation, privacy: .public) \(trigger, privacy: .public) remount suppressed — lid is closed targets=\(targets.sorted(), privacy: .public)")
        } else if targets.isEmpty {
            if let task = currentSleepEjectTask() {
                log.info("cycle \(task.operationID, privacy: .public) \(trigger, privacy: .public) no target yet; defer wake handling until active eject completes")
                task.group.notify(queue: .main) { [weak self] in
                    self?.requestAutomaticRemount(trigger: "\(trigger)AfterEject")
                }
                return
            }
            log.info("cycle \(operation, privacy: .public) \(trigger, privacy: .public) → no remount target")
            LibraryAppHandler.relaunchQuitApps()
        } else {
            log.info("cycle \(operation, privacy: .public) \(trigger, privacy: .public) remount already scheduled/active targets=\(targets.sorted(), privacy: .public)")
        }
    }

    private func scheduleAutomaticRemount(_ schedule: SleepEpisodeCoordinator.RemountSchedule,
                                          trigger: String) {
        log.notice("automatic remount scheduled after 2.0s trigger=\(trigger, privacy: .public) generation=\(schedule.token.lidGeneration, privacy: .public) nonce=\(schedule.token.nonce, privacy: .public)")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.autoEjectStateLock.lock()
            let work = self.sleepEpisodeCoordinator.claimRemount(schedule.token)
            self.autoEjectStateLock.unlock()
            guard let work else {
                log.info("automatic remount stale schedule ignored trigger=\(trigger, privacy: .public) generation=\(schedule.token.lidGeneration, privacy: .public) nonce=\(schedule.token.nonce, privacy: .public)")
                return
            }

            let canceled = self.remountWithBackoff(
                disks: work.disks,
                operationID: work.operationID,
                shouldContinue: { [weak self] in
                    guard let self else { return false }
                    self.autoEjectStateLock.lock()
                    defer { self.autoEjectStateLock.unlock() }
                    return self.sleepEpisodeCoordinator.isRemountAllowed(work.token)
                }
            )

            self.autoEjectStateLock.lock()
            let mayRelaunchLibraryApps = self.sleepEpisodeCoordinator.isRemountAllowed(work.token)
            let nextSchedule = self.sleepEpisodeCoordinator.finishRemount(
                work.token,
                canceledDisks: canceled
            )
            self.autoEjectStateLock.unlock()

            if mayRelaunchLibraryApps {
                LibraryAppHandler.relaunchQuitApps()
            }
            if let nextSchedule {
                self.scheduleAutomaticRemount(nextSchedule, trigger: "remountRetryAfterReopen")
            }
        }
    }

    // MARK: - Remount (wake 후 자동 재마운트)

    /// 재마운트 결과.
    /// - success: 정상 재마운트
    /// - userDisconnected: 디스크가 끝까지 USB enumerate 안 됨 — 사용자가 케이블 분리한 것으로 간주, 알림 X
    /// - mountFailed: 디스크는 인식되는데 mount 실패 — file system 문제 가능, 알림 O
    private enum RemountOutcome {
        case success
        case userDisconnected
        case mountFailed(String)
        case canceled
    }

    /// 여러 디스크를 병렬로 backoff 재시도. mount 실패 디스크만 알림.
    /// 사용자 분리 (USB 케이블 뽑힌 케이스) 는 silent.
    private func remountWithBackoff(disks: Set<SleepRemountTarget>,
                                    operationID: String? = nil,
                                    shouldContinue: @escaping () -> Bool = { true }) -> Set<SleepRemountTarget> {
        let operation = operationID ?? "-"
        let totalStarted = Date()
        log.notice("cycle \(operation, privacy: .public) remount START targets=\(disks.sorted(), privacy: .public)")
        let lock = NSLock()
        var mountFailed: [String] = []
        var canceled = Set<SleepRemountTarget>()
        let group = DispatchGroup()
        let parallel = DispatchQueue(label: "com.yongza.ejectdrives.remount", attributes: .concurrent)

        for target in disks {
            group.enter()
            parallel.async { [weak self] in
                defer { group.leave() }
                guard let self = self else { return }
                let bsd = target.wholeDiskBSD
                let diskStarted = Date()
                switch self.tryRemount(target: target,
                                       delays: [0, 1, 3, 7],
                                       operationID: operationID,
                                       shouldContinue: shouldContinue) {
                case .success:
                    log.info("cycle \(operation, privacy: .public) remount disk handled: \(bsd, privacy: .public) outcome=success elapsed=\(self.elapsedText(since: diskStarted), privacy: .public)s")
                    break
                case .userDisconnected:
                    log.info("cycle \(operation, privacy: .public) remount disk handled: \(bsd, privacy: .public) outcome=userDisconnected elapsed=\(self.elapsedText(since: diskStarted), privacy: .public)s")
                case .mountFailed:
                    log.notice("cycle \(operation, privacy: .public) remount disk handled: \(bsd, privacy: .public) outcome=mountFailed elapsed=\(self.elapsedText(since: diskStarted), privacy: .public)s")
                    lock.lock(); mountFailed.append(bsd); lock.unlock()
                case .canceled:
                    log.info("cycle \(operation, privacy: .public) remount disk handled: \(bsd, privacy: .public) outcome=canceledByLid elapsed=\(self.elapsedText(since: diskStarted), privacy: .public)s")
                    lock.lock(); canceled.insert(target); lock.unlock()
                }
            }
        }
        group.wait()

        guard !mountFailed.isEmpty else {
            log.notice("cycle \(operation, privacy: .public) remount DONE all disks handled canceled=\(canceled.sorted(), privacy: .public) elapsed=\(self.elapsedText(since: totalStarted), privacy: .public)s")
            return canceled
        }
        let list = mountFailed.sorted().joined(separator: ", ")
        log.error("cycle \(operation, privacy: .public) remount DONE mount FAILED = \(list, privacy: .public) elapsed=\(self.elapsedText(since: totalStarted), privacy: .public)s")
        DispatchQueue.main.async { [weak self] in
            self?.notify(title: String(localized: "Remount failed"),
                         body: String(localized: "\(list)\nDisks detected but won't mount. Try Disk Utility."),
                         archived: true,
                         kind: .failure)
        }
        return canceled
    }

    /// 한 BSD 디스크에 대해 지정된 delays(초) 간격으로 mountDisk 재시도.
    /// 각 시도마다 IORegistry 직접 enumerate 검사 — 분리 의도 감지 + `diskutil info` 호출 회피
    /// (info 호출당 수백 ms 소요 → wake 직후 사용자 체감 지연 누적).
    /// 첫 시도 delay=0 즉시. 이후 1, 3, 7s 백오프 (USB 재인식 시간 확보).
    /// 이미 마운트된 디스크에 호출되면 idempotent (no-op success).
    private func tryRemount(target: SleepRemountTarget,
                            delays: [Int],
                            operationID: String? = nil,
                            shouldContinue: () -> Bool = { true }) -> RemountOutcome {
        let operation = operationID ?? "-"
        let bsd = target.wholeDiskBSD
        var everEnumerated = false
        var lastMountError: String?

        for (i, delay) in delays.enumerated() {
            guard shouldContinue() else { return .canceled }
            if delay > 0 {
                log.info("cycle \(operation, privacy: .public) remount attempt \(i + 1, privacy: .public)/\(delays.count, privacy: .public): \(bsd, privacy: .public) waiting \(delay, privacy: .public)s before retry")
                let deadline = Date().addingTimeInterval(TimeInterval(delay))
                while Date() < deadline {
                    guard shouldContinue() else { return .canceled }
                    Thread.sleep(forTimeInterval: max(0, min(0.1, deadline.timeIntervalSinceNow)))
                }
            }

            guard shouldContinue() else { return .canceled }

            guard DAInventory.shared.isCurrentPhysicalGeneration(target) else {
                log.notice("cycle \(operation, privacy: .public) remount stopped: \(bsd, privacy: .public) physical generation \(target.physicalGeneration, privacy: .public) is no longer present")
                return .userDisconnected
            }

            // 1) 디스크가 시스템에 보이나? — IORegistry 직접 검사 (process spawn 없음).
            guard ioRegistryHasBSDDisk(bsd) else {
                log.notice("cycle \(operation, privacy: .public) remount attempt \(i + 1, privacy: .public)/\(delays.count, privacy: .public): \(bsd, privacy: .public) not enumerated — wait for re-detection")
                continue
            }
            everEnumerated = true

            // 2) token 확인→mount command 시작을 lid close/new eject invalidation과 같은 gate로
            // 직렬화한다. 먼저 시작한 command는 새 eject가 inventory를 잡기 전에 group으로 join한다.
            automaticRemountCommandGate.lock()
            guard shouldContinue() else {
                automaticRemountCommandGate.unlock()
                return .canceled
            }
            automaticRemountCommandGroup.enter()
            automaticRemountCommandGate.unlock()
            // Public DA callback이 실제 mount terminal을 증명할 때만 command barrier를 푼다.
            // Waiter의 4초 UX timeout은 underlying request를 취소하거나 barrier를 해제하지 않는다.
            let commandGroup = automaticRemountCommandGroup
            let mount = DAInventory.shared.mountForWake(
                target: target,
                timeout: 4,
                operationID: operation,
                onTerminal: { commandGroup.leave() }
            )

            // command 실행 중 lid가 닫힌 경우 success로 소비하지 않는다. 새 close worker가 방금
            // mount된 디스크까지 다시 inventory/unmount하고, 이 target은 다음 open용으로 requeue한다.
            guard shouldContinue() else { return .canceled }
            switch mount {
            case .completed(.callbackSuccess):
                log.info("cycle \(operation, privacy: .public) ✓ remount OK: \(bsd, privacy: .public) (attempt \(i + 1, privacy: .public)/\(delays.count, privacy: .public))")
                return .success
            case let .completed(.callbackFailure(error)):
                lastMountError = error
            case .completed(.identityChangedBeforeCallback):
                log.info("cycle \(operation, privacy: .public) remount stopped: \(bsd, privacy: .public) exact physical media changed during mount")
                return .userDisconnected
            case .timedOutPending:
                let error = "Disk Arbitration mount is still pending after 4 seconds"
                log.notice("cycle \(operation, privacy: .public) remount wait timed out without starting an overlapping retry: \(bsd, privacy: .public)")
                return .mountFailed(error)
            case let .unavailable(error):
                lastMountError = error
            }
            log.notice("cycle \(operation, privacy: .public) remount attempt \(i + 1, privacy: .public) mount failed: \(bsd, privacy: .public) — \(lastMountError ?? "?", privacy: .public)")
        }

        if !everEnumerated {
            log.info("cycle \(operation, privacy: .public) ✗ \(bsd, privacy: .public) never enumerated across \(delays.count, privacy: .public) attempts — user disconnect")
            return .userDisconnected
        }
        log.error("cycle \(operation, privacy: .public) ✗ remount FAIL: \(bsd, privacy: .public) — enumerate OK but mount failed all \(delays.count, privacy: .public) attempts")
        return .mountFailed(lastMountError ?? "unknown")
    }

    /// IORegistry 에 주어진 BSD name 의 IOMedia 가 enumerate 되어 있는지. `diskutil info`
    /// process spawn 보다 1~2 자릿수 빠르다.
    private func ioRegistryHasBSDDisk(_ bsd: String) -> Bool {
        guard let matching = IOServiceMatching("IOMedia") else { return false }
        let dict = matching as NSMutableDictionary
        dict["BSD Name"] = bsd
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iter) }
        let svc = IOIteratorNext(iter)
        if svc != 0 { IOObjectRelease(svc); return true }
        return false
    }

    // MARK: - Notifications

    /// 알림 권한을 맥락 기반으로 1회 요청 — 첫 알림을 보낼 때. launch 시 무조건 요청하는 안티패턴 대체.
    /// `requestAuthorization` 은 최초 1회만 실제 프롬프트, 이후엔 결정값만 반환 (재호출 안전).
    private func ensureNotificationAuthorizationRequested() {
        guard !didRequestNotificationAuthorization else { return }
        didRequestNotificationAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            log.notice("contextual notification auth: granted=\(granted, privacy: .public) error=\(error?.localizedDescription ?? "nil", privacy: .public)")
        }
    }

    /// archived=true 면 알림 센터에 보관 (사후 확인 가치 있는 negative event 등),
    /// false 면 banner 만 잠깐 표시되고 사라짐 (즉시 인지 가능한 positive event 등).
    /// userInfo 에 flag 를 박아 willPresent 콜백에서 옵션 분기.
    private func notify(title: String, body: String, archived: Bool = false, kind: AppNotificationKind = .info,
                        categoryIdentifier: String? = nil, userInfo extraUserInfo: [String: Any] = [:]) {
        guard SettingsStore.notificationsEnabled else {
            log.info("notification skipped: notifications disabled")
            return
        }
        switch kind {
        case .info:
            break
        case .success:
            guard SettingsStore.successNotificationsEnabled else {
                log.info("notification skipped: success notifications disabled")
                return
            }
        case .failure:
            guard SettingsStore.failureNotificationsEnabled else {
                log.info("notification skipped: failure notifications disabled")
                return
            }
        }
        // 첫 알림을 보내는 시점에 권한을 맥락 기반으로 요청 (launch 시 무조건 요청 대체).
        ensureNotificationAuthorizationRequested()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        var userInfo: [String: Any] = ["archived": archived]
        userInfo.merge(extraUserInfo) { _, new in new }
        content.userInfo = userInfo
        if let categoryIdentifier { content.categoryIdentifier = categoryIdentifier }
        // sound 의도적으로 설정 안 함 — 도서관 등 조용한 환경 고려
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        let archived = (notification.request.content.userInfo["archived"] as? Bool) ?? false
        // archived 만 .list (알림 센터 보관). sound 는 항상 제외 — 무음 정책.
        completionHandler(archived ? [.banner, .list] : [.banner])
    }

    /// 알림 액션 응답 — "끄고 재시도" 버튼. main thread 에서 호출되므로 completionHandler 는 즉시
    /// 호출하고(수신 확인), 실제 종료+재시도는 background 로 (terminate polling 이 blocking).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard response.actionIdentifier == EjectNotification.retryAction else { return }
        let userInfo = response.notification.request.content.userInfo
        guard let volumePath = userInfo[EjectNotification.volumePathKey] as? String else { return }
        let bundleIDs = userInfo[EjectNotification.appBundleIDsKey] as? [String] ?? []
        log.notice("eject retry action: volume=\(volumePath, privacy: .public) apps=\(bundleIDs, privacy: .public)")
        handleQuitAndRetry(volumePath: volumePath, appBundleIDs: bundleIDs)
    }

    /// 점유 프로세스 중 "사용자가 끌 수 있는 일반 GUI 앱"만 추려 반환.
    /// 시스템 데몬(mds/backupd 등, .regular 아님) + Finder · Dock 등 시스템 GUI + 자기 자신 제외.
    /// background/main 어디서든 호출 가능 (NSRunningApplication 읽기는 thread-safe).
    private func quittableApps(from blockers: [BlockingProcess]) -> [NSRunningApplication] {
        let denylist: Set<String> = [
            Bundle.main.bundleIdentifier ?? "com.yongza.ejectdrives",
            "com.apple.finder",
            "com.apple.dock",
            "com.apple.loginwindow",
            "com.apple.systemuiserver",
        ]
        var seen = Set<String>()
        var apps: [NSRunningApplication] = []
        for blocker in blockers {
            guard let app = NSRunningApplication(processIdentifier: blocker.pid),
                  app.activationPolicy == .regular,
                  let bid = app.bundleIdentifier,
                  !denylist.contains(bid),
                  seen.insert(bid).inserted
            else { continue }
            apps.append(app)
        }
        return apps
    }

    /// "끄고 재시도" 버튼 핸들러 — 대상 앱 graceful 종료 → 추출 **1회만** 재시도 → 결과 알림.
    /// 끈 앱은 재실행하지 않는다 (사용자가 추출하려고 끈 것 — 다시 띄우면 볼륨 재잠금).
    /// pid 는 stale 일 수 있어 bundle ID 로 현재 실행 중인 앱을 다시 찾는다.
    private func handleQuitAndRetry(volumePath: String, appBundleIDs: [String]) {
        let name = (volumePath as NSString).lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let targets = NSWorkspace.shared.runningApplications.filter {
                guard let bid = $0.bundleIdentifier else { return false }
                return appBundleIDs.contains(bid)
            }
            if !targets.isEmpty {
                LibraryAppHandler.terminate(apps: targets, timeout: 3.0)
            }
            // 재시도 1회 — 루프 금지. 재시도도 수동 gentle 경로(diskutilEject) 사용 (force 사다리 X).
            let result = self.diskutilEject(volumePath: volumePath)
            DiskMenuSnapshotCache.invalidate()
            DiskMenuSnapshotCache.warm()
            log.info("eject retry done: \(name, privacy: .public) success=\(result.success, privacy: .public) err=\(result.errorMessage ?? "-", privacy: .public)")
            DispatchQueue.main.async {
                if result.success {
                    self.notify(title: String(localized: "Ejected"), body: name, kind: .success)
                } else {
                    // graceful terminate 라 미저장 문서 앱은 종료 거부 가능 → 솔직히 실패 알림.
                    self.notify(title: String(localized: "Still couldn't eject \(name)"),
                                body: localizedOperationFailure(),
                                archived: true,
                                kind: .failure)
                }
            }
        }
    }

    // MARK: - Global Hotkey (설정된 E 기반 preset)
    // NSEvent.addGlobalMonitorForEvents 만 사용. Accessibility 권한 필요.
    // 우클릭 monitor 는 제거 — false positive 위험. 우클릭은 button.sendAction 으로 받음.

    private func installHotkey() {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }

        // 손쉬운 사용 프롬프트는 여기서 띄우지 않는다 — 온보딩 창의 "허용" 버튼이 1회 담당.
        // 무프롬프트 체크만: 권한 없으면 global monitor 는 등록돼도 이벤트를 못 받고,
        // 권한 부여 시 OnboardingWindowController 가 installHotkey() 를 재호출해 활성화한다.
        let trusted = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ] as CFDictionary)
        log.notice("Accessibility trusted = \(trusted, privacy: .public)")

        // Repair all three assignments together. Eject keeps startup priority, then Mount, then
        // the optional Eject and Sleep shortcut; no action can become unreachable.
        let normalized = SettingsShortcutConflictPolicy.normalized(
            SettingsStore.shortcutAssignments,
            available: SettingsHotkeyPreset.allCases
        )
        if !normalized.displacedRoles.isEmpty {
            SettingsStore.shortcutAssignments = normalized.assignments
            log.notice("hotkey conflicts repaired at startup: displaced=\(String(describing: normalized.displacedRoles), privacy: .public)")
        }

        let ejectHotkey = SettingsStore.ejectHotkey
        let mountHotkey = SettingsStore.mountHotkey
        log.notice("hotkeys: eject=\(ejectHotkey.title, privacy: .public) mount=\(mountHotkey.title, privacy: .public)")

        // GLOBAL monitor — 다른 앱이 활성일 때 잡음 (Accessibility 권한 필요)
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handleHotkey(event, scope: "GLOBAL")
        }
        log.notice("globalKeyMonitor = \(self.globalKeyMonitor != nil ? "REGISTERED" : "NIL — failed!", privacy: .public)")

        // LOCAL monitor — 우리 앱 활성일 때
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleHotkey(event, scope: "LOCAL") ? nil : event
        }
    }

    private func handleHotkey(_ event: NSEvent, scope: String) -> Bool {
        guard event.keyCode == SettingsStore.ejectHotkey.keyCode else { return false }
        // 키 누름 유지로 인한 자동 반복 이벤트 무시 — 디바운스 1.5s 가 있긴 하지만 첫 한두 번이
        // 통과해 결과 알림이 두 번 뜨는 경우 방지. 사용자 의도는 한 번 누름 = 한 번 실행.
        guard !event.isARepeat else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .help, .capsLock])

        // 별도 ack 플래시 없음 — 각 동작 함수가 곧바로 자기 진행 플래시를 띄운다
        // (ejectAll=회전 화살표, mountAll=arrow.down.circle, ejectAndSleep=moon.zzz.fill).
        // ack 0.3s + 진행 1.0s 가 연달아 깜빡이면 같은 자리에서 심볼이 두 번 바뀌어 어수선.
        if flags == SettingsStore.ejectHotkey.flags {
            log.info("HOTKEY \(scope, privacy: .public) eject fired")
            DispatchQueue.main.async { [weak self] in self?.ejectAll(caller: "hotkey-\(scope.lowercased())") }
            return true
        }

        if flags == SettingsStore.mountHotkey.flags {
            log.info("HOTKEY \(scope, privacy: .public) mount fired")
            DispatchQueue.main.async { [weak self] in self?.mountAll(caller: "hotkey-\(scope.lowercased())") }
            return true
        }

        if let preset = SettingsStore.ejectAndSleepHotkey, flags == preset.flags {
            log.info("HOTKEY \(scope, privacy: .public) eject-and-sleep fired")
            DispatchQueue.main.async { [weak self] in self?.ejectAndSleep(caller: "hotkey-\(scope.lowercased())") }
            return true
        }

        return false
    }
}

private enum AppNotificationKind {
    case info
    case success
    case failure
}

/// 추출 실패 알림의 "끄고 재시도" 액션 관련 식별자 + userInfo 키.
/// 카테고리는 launch 시 1회 등록 (지연 등록 시 첫 알림에 버튼이 안 뜸).
private enum EjectNotification {
    static let retryCategory = "diskout.eject.retry"
    static let retryAction = "diskout.eject.retry.action"
    static let volumePathKey = "diskout.volumePath"
    /// 끌 대상 앱 bundle ID 목록 — 탭 시점에 pid 는 stale 일 수 있어 bundle ID 로 재해석.
    static let appBundleIDsKey = "diskout.appBundleIDs"
}

private struct SleepDAPhysicalToken: Hashable {
    let wholeDiskBSD: String
    let generation: UInt64
    let mediaRegistryEntryID: UInt64
}

private struct SleepDiskIdentity: Equatable {
    let wholeDiskBSD: String
    let generation: UInt64
    let mediaRegistryEntryID: UInt64
    let mountedVolumeBSDs: Set<String>

    init(wholeDiskBSD: String,
         generation: UInt64,
         mediaRegistryEntryID: UInt64,
         mountedVolumeBSDs: Set<String> = []) {
        self.wholeDiskBSD = wholeDiskBSD
        self.generation = generation
        self.mediaRegistryEntryID = mediaRegistryEntryID
        self.mountedVolumeBSDs = mountedVolumeBSDs
    }
}

private struct SleepAutomaticVolumeSnapshot {
    let drive: ExternalDrive
    let identity: SleepDiskIdentity
    /// Hidden/system helper volumes participate in protected-sibling closure but are not targets.
    let isEjectTarget: Bool
}

private struct SleepUnmountAttemptResult {
    let success: Bool
    let errorMessage: String?
    /// Present only when Disk Arbitration supplied an explicit dissenter callback.
    let dissenterStatus: SleepUnmountDissenterStatus?
    /// A normal caller can join an already-pending force request. Preserve the actual mode so its
    /// failure can never be interpreted as permission to submit another force operation.
    let requestWasForced: Bool
}

private final class SleepEjectOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func finish(_ succeeded: Bool) {
        lock.lock()
        value = succeeded
        lock.unlock()
    }

    var succeeded: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private enum SleepDAUnmountEvidence {
    case callbackSuccess
    case callbackFailure(SleepUnmountDissenterStatus, String)
    case disconnectedBeforeCallback
}

private enum SleepDAUnmountWaitResult {
    case completed(SleepDAUnmountEvidence, requestWasForced: Bool)
    /// 호출자의 wait deadline 만 끝난 상태다. 실제 DA 요청은 계속 진행 중이므로
    /// 이 결과 뒤에 다른 unmount/eject fallback 을 시작하면 안 된다.
    case timedOutPending(PendingSleepDAUnmount)
    case unavailable(String)
}

private enum SleepDAMountEvidence {
    case callbackSuccess
    case callbackFailure(String)
    case identityChangedBeforeCallback
}

private enum SleepDAMountWaitResult {
    case completed(SleepDAMountEvidence)
    /// Waiter deadline only. The underlying public DA request has no cancellation API and the
    /// close-side command barrier remains entered until its real callback/disconnect terminal.
    case timedOutPending
    case unavailable(String)
}

private final class PendingSleepDAMount {
    let session: DASession
    let disk: DADisk
    let token: SleepDAPhysicalToken
    weak var inventory: DAInventory?

    private let evidenceLatch = StickyAsyncEvidence<SleepDAMountEvidence>()

    init(session: DASession,
         disk: DADisk,
         token: SleepDAPhysicalToken,
         inventory: DAInventory) {
        self.session = session
        self.disk = disk
        self.token = token
        self.inventory = inventory
    }

    @discardableResult
    func finishOnce(_ evidence: SleepDAMountEvidence) -> Bool {
        evidenceLatch.finishOnce(evidence)
    }

    func wait(timeout: TimeInterval) -> SleepDAMountWaitResult {
        guard let evidence = evidenceLatch.wait(timeout: timeout) else {
            return .timedOutPending
        }
        return .completed(evidence)
    }

    func onTerminal(_ handler: @escaping () -> Void) {
        evidenceLatch.observe { _ in handler() }
    }
}

/// Persistent DA session(지속 Disk Arbitration 세션)의 whole-disk 요청 한 건.
/// 여러 sleep trigger 는 같은 request 를 join 하고, callback/disappear 중 먼저 도착한
/// terminal evidence(종료 증거)만 보존한다.
private final class PendingSleepDAUnmount {
    let session: DASession
    let disk: DADisk
    let token: SleepDAPhysicalToken
    let target: String
    let force: Bool
    let modeLabel: String
    weak var inventory: DAInventory?

    private let evidenceLatch = StickyAsyncEvidence<SleepDAUnmountEvidence>()

    init(session: DASession,
         disk: DADisk,
         token: SleepDAPhysicalToken,
         target: String,
         force: Bool,
         modeLabel: String,
         inventory: DAInventory) {
        self.session = session
        self.disk = disk
        self.token = token
        self.target = target
        self.force = force
        self.modeLabel = modeLabel
        self.inventory = inventory
    }

    @discardableResult
    func finishOnce(_ newEvidence: SleepDAUnmountEvidence) -> Bool {
        evidenceLatch.finishOnce(newEvidence)
    }

    func snapshot() -> SleepDAUnmountEvidence? {
        evidenceLatch.snapshot()
    }

    func wait(timeout: TimeInterval) -> SleepDAUnmountWaitResult {
        if let evidence = evidenceLatch.wait(timeout: timeout) {
            return .completed(evidence, requestWasForced: force)
        }
        return .timedOutPending(self)
    }

    /// waiter timeout 직후 callback 과의 경계를 lock 하나로 직렬화한다. 이미 clean callback이
    /// 왔으면 즉시 실행하고, 아직 pending이면 최초 terminal callback까지 보관한다.
    func onLateClean(_ handler: @escaping () -> Void) {
        evidenceLatch.observe { evidence in
            if case .callbackSuccess = evidence {
                handler()
            }
        }
    }
}

private func daDissenterStatusText(_ status: DAReturn) -> String {
    switch UInt32(bitPattern: status) {
    case 0xF8DA0001: return "internal error"
    case 0xF8DA0002: return "disk is busy"
    case 0xF8DA0003: return "bad argument"
    case 0xF8DA0004: return "exclusive access"
    case 0xF8DA0005: return "no resources"
    case 0xF8DA0006: return "not found"
    case 0xF8DA0007: return "not mounted"
    case 0xF8DA0008: return "not permitted"
    case 0xF8DA0009: return "not privileged"
    case 0xF8DA000A: return "not ready"
    case 0xF8DA000B: return "not writable"
    case 0xF8DA000C: return "unsupported"
    default: return "DA status 0x\(String(UInt32(bitPattern: status), radix: 16, uppercase: true))"
    }
}

private enum SettingsHotkeyPreset: String, CaseIterable {
    case optionCommandE
    case optionShiftCommandE
    case controlCommandE
    case controlOptionE

    var title: String {
        switch self {
        case .optionCommandE: return "⌥⌘E"
        case .optionShiftCommandE: return "⌥⇧⌘E"
        case .controlCommandE: return "⌃⌘E"
        case .controlOptionE: return "⌃⌥E"
        }
    }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .optionCommandE: return [.option, .command]
        case .optionShiftCommandE: return [.option, .shift, .command]
        case .controlCommandE: return [.control, .command]
        case .controlOptionE: return [.control, .option]
        }
    }

    var keyCode: UInt16 { UInt16(kVK_ANSI_E) }
}

private enum SettingsStore {
    private enum Key {
        static let notificationsEnabled = "settings.notifications.enabled"
        static let successNotificationsEnabled = "settings.notifications.success.enabled"
        static let failureNotificationsEnabled = "settings.notifications.failure.enabled"
        static let forceFallbackEnabled = "settings.eject.forceFallback.enabled"
        static let ejectHotkey = "settings.hotkey.eject"
        static let mountHotkey = "settings.hotkey.mount"
        static let ejectAndSleepHotkey = "settings.hotkey.ejectAndSleep"
        static let rightClickEjectEnabled = "settings.statusItem.rightClickEject.enabled"
        static let onboardingCompletedVersion = "settings.onboarding.completedVersion"
        static let crashReportingEnabled = "settings.crashReporting.enabled"
    }

    private static func bool(for key: String, default defaultValue: Bool) -> Bool {
        if let value = UserDefaults.standard.object(forKey: key) as? Bool { return value }
        return defaultValue
    }

    private static func int(for key: String, default defaultValue: Int) -> Int {
        if let value = UserDefaults.standard.object(forKey: key) as? Int { return value }
        return defaultValue
    }

    /// 사용자가 마지막으로 완료(또는 닫은) 권한 온보딩 콘텐츠 버전. 0 = 한 번도 안 봄.
    /// `OnboardingWindowController.version` 보다 작으면 launch 시 1회 표시.
    static var onboardingCompletedVersion: Int {
        get { int(for: Key.onboardingCompletedVersion, default: 0) }
        set { UserDefaults.standard.set(newValue, forKey: Key.onboardingCompletedVersion) }
    }

    static var notificationsEnabled: Bool {
        get { bool(for: Key.notificationsEnabled, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.notificationsEnabled) }
    }

    static var successNotificationsEnabled: Bool {
        get { bool(for: Key.successNotificationsEnabled, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.successNotificationsEnabled) }
    }

    static var failureNotificationsEnabled: Bool {
        get { bool(for: Key.failureNotificationsEnabled, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.failureNotificationsEnabled) }
    }

    static var forceFallbackEnabled: Bool {
        get { bool(for: Key.forceFallbackEnabled, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.forceFallbackEnabled) }
    }

    /// 메뉴바 아이콘 우클릭(또는 ctrl+좌클릭) 시 즉시 모두 추출. default ON (기존 동작 유지).
    /// OFF 면 우클릭도 메뉴를 띄움 — 실수로 작업 중인 외장이 빠지는 사고 방지용 opt-out.
    static var rightClickEjectEnabled: Bool {
        get { bool(for: Key.rightClickEjectEnabled, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.rightClickEjectEnabled) }
    }

    /// 익명 크래시/에러 리포트 전송. default ON (기존 익명 텔레메트리 철학과 일관).
    /// OFF 면 `.ips` 수확·전송과 핸들드 에러 카테고리 전송이 모두 중단된다.
    /// 전송 내용은 예외 타입 + 백트레이스 프레임(스크럽됨) / 에러 카테고리뿐 —
    /// 디스크명·볼륨명·경로·유저명·원본 IP 는 절대 나가지 않는다.
    static var crashReportingEnabled: Bool {
        get { bool(for: Key.crashReportingEnabled, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.crashReportingEnabled) }
    }

    /// popup 선택값. "system" 은 저장하지 않으며 key 없음 자체가 시스템 추종을 뜻한다.
    /// 명시 언어만 저장하므로 popup 표시와 실제 상태가 어긋나지 않고 손상값도 자동 정리된다.
    ///
    /// 적용 시점: main.swift 에서 NSApplication 생성 *전에* AppleLanguages 키를 set/remove.
    /// 변경 후에는 반드시 앱 재시작 필요 (NSBundle 의 localized resource 가 launch 시점에 캐시).
    static var appLanguage: String {
        get { AppLanguagePolicy.settingsSelection(in: .standard) }
        set { AppLanguagePolicy.setSettingsSelection(newValue, in: .standard) }
    }

    static var ejectHotkey: SettingsHotkeyPreset {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.ejectHotkey),
                  let value = SettingsHotkeyPreset(rawValue: raw) else {
                return .optionCommandE
            }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.ejectHotkey) }
    }

    static var mountHotkey: SettingsHotkeyPreset {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.mountHotkey),
                  let value = SettingsHotkeyPreset(rawValue: raw) else {
                return .controlCommandE
            }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.mountHotkey) }
    }

    /// "추출하고 잠자기" 전역 단축키. nil 이면 단축키 없음 (메뉴에서만 호출).
    /// 충돌 위험 + 사용 빈도 미상이라 default = nil.
    static var ejectAndSleepHotkey: SettingsHotkeyPreset? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.ejectAndSleepHotkey) else {
                return nil
            }
            return SettingsHotkeyPreset(rawValue: raw)
        }
        set {
            if let preset = newValue {
                UserDefaults.standard.set(preset.rawValue, forKey: Key.ejectAndSleepHotkey)
            } else {
                UserDefaults.standard.removeObject(forKey: Key.ejectAndSleepHotkey)
            }
        }
    }

    static var shortcutAssignments: SettingsShortcutAssignments<SettingsHotkeyPreset> {
        get {
            SettingsShortcutAssignments(eject: ejectHotkey,
                                        mount: mountHotkey,
                                        ejectAndSleep: ejectAndSleepHotkey)
        }
        set {
            ejectHotkey = newValue.eject
            mountHotkey = newValue.mount
            ejectAndSleepHotkey = newValue.ejectAndSleep
        }
    }
}

private struct PremiumSettingsState {
    let isConfigured: Bool
    let hasAccess: Bool
    let isPurchaseInProgress: Bool
    let isOpeningDetails: Bool
    let isCheckingStatus: Bool
    let isRestoring: Bool
    let canOpenDetails: Bool
    let hasRecoveryCode: Bool
}

private struct PremiumSettingsActions {
    let purchase: () -> Void
    let stopPurchaseCheck: () -> Void
    let viewDetails: () -> Void
    let copyRecoveryCode: () -> Void
    let checkStatus: () -> Void
    let restore: () -> Void
}

private final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private let onHotkeyChanged: () -> Void
    private let onClosed: () -> Void
    private let onCheckForUpdates: () -> Void
    private let premiumState: () -> PremiumSettingsState
    private let premiumActions: PremiumSettingsActions

    private var loginToggle: NSButton!
    private var sleepToggle: NSButton!
    private var lidCloseToggle: NSButton!
    private var displaySleepToggle: NSButton!
    private var libraryAppToggle: NSButton!
    private var notificationsToggle: NSButton!
    private var successNotificationsToggle: NSButton!
    private var failureNotificationsToggle: NSButton!
    private var notificationPermissionHint: NSTextField!
    private var notificationSettingsButton: NSButton!
    private var forceFallbackToggle: NSButton!
    private var rightClickEjectToggle: NSButton!
    private var crashReportingToggle: NSButton!
    private var ejectHotkeyPopup: NSPopUpButton!
    private var mountHotkeyPopup: NSPopUpButton!
    private var ejectAndSleepHotkeyPopup: NSPopUpButton!
    private var languagePopup: NSPopUpButton!
    private var premiumStatusLabel: NSTextField!
    private var premiumPurchaseButton: NSButton!
    private var premiumStopButton: NSButton!
    private var premiumDetailsButton: NSButton!
    private var premiumRecoveryButton: NSButton!
    private var premiumCheckButton: NSButton!
    private var premiumRestoreButton: NSButton!

    /// 설정 페인 — 시스템 설정과 같은 툴바 스타일 (아이콘+라벨 탭, 페인별 높이, 창 제목 = 페인 이름).
    private enum Pane: String, CaseIterable {
        case general, eject, notifications, hotkeys, premium, about

        var identifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier(rawValue) }

        var label: String {
            switch self {
            case .general: return String(localized: "General")
            case .eject: return String(localized: "Eject Behavior")
            case .notifications: return String(localized: "Notifications")
            case .hotkeys: return String(localized: "Hotkeys")
            case .premium: return String(localized: "Premium")
            case .about: return String(localized: "About")
            }
        }

        var symbolName: String {
            switch self {
            case .general: return "gearshape"
            case .eject: return "eject"
            case .notifications: return "bell"
            case .hotkeys: return "keyboard"
            case .premium: return "star.circle"
            case .about: return "info.circle"
            }
        }
    }

    /// 페인 콘텐츠 고정폭 — 설명 라벨 줄바꿈 기준이자 창 폭.
    private static let paneWidth: CGFloat = 540
    /// 체크박스 글리프+간격 폭 — 설명 줄을 체크박스 *텍스트* 시작선에 맞추는 들여쓰기.
    private static let checkboxTextIndent: CGFloat = 18

    private var paneViews: [Pane: NSView] = [:]

    init(onHotkeyChanged: @escaping () -> Void,
         onClosed: @escaping () -> Void,
         onCheckForUpdates: @escaping () -> Void,
         premiumState: @escaping () -> PremiumSettingsState,
         premiumActions: PremiumSettingsActions) {
        self.onHotkeyChanged = onHotkeyChanged
        self.onClosed = onClosed
        self.onCheckForUpdates = onCheckForUpdates
        self.premiumState = premiumState
        self.premiumActions = premiumActions
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.paneWidth, height: 320),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        paneViews = [
            .general: makeGeneralPane(),
            .eject: makeEjectPane(),
            .notifications: makeNotificationsPane(),
            .hotkeys: makeHotkeysPane(),
            .premium: makePremiumPane(),
            .about: makeAboutPane(),
        ]
        showPane(.general, animated: false)
        window.center()
        refreshControls()
    }

    func windowWillClose(_ notification: Notification) {
        onClosed()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        refreshControls()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshExternalState() {
        guard isWindowLoaded else { return }
        refreshControls()
    }

    func showPremiumPane() {
        refreshControls()
        showPane(.premium, animated: window?.isVisible == true)
    }

    // MARK: Toolbar (페인 전환)

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.identifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.identifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.identifier)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = Pane(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.label
        item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.label)
        item.target = self
        item.action = #selector(paneToolbarItemClicked(_:))
        item.autovalidates = false   // 항상 활성 — validate 경유로 비활성화되는 것 방지
        return item
    }

    @objc private func paneToolbarItemClicked(_ sender: NSToolbarItem) {
        guard let pane = Pane(rawValue: sender.itemIdentifier.rawValue) else { return }
        showPane(pane, animated: true)
    }

    /// 페인 전환 — 창 제목 갱신 + 페인 fittingSize 에 맞춰 높이 전환 (상단 모서리 고정).
    /// 페인 컨테이너의 bottom 제약이 priority 999 라 전환 애니메이션 중 프레임 불일치를
    /// 조용히 흡수한다 (required 면 일시적 unsatisfiable 로그).
    private func showPane(_ pane: Pane, animated: Bool) {
        guard let window, let view = paneViews[pane] else { return }
        window.toolbar?.selectedItemIdentifier = pane.identifier
        window.title = pane.label

        view.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.paneWidth, height: view.fittingSize.height)
        let contentFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var frame = window.frame
        frame.origin.y += frame.height - contentFrame.height
        frame.size = contentFrame.size

        window.contentView = view
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }

    // MARK: Pane builders

    private func makeGeneralPane() -> NSView {
        loginToggle = checkbox(title: String(localized: "Launch at login"), action: #selector(toggleLoginItem(_:)))

        // 언어 셀렉터 — "system" / "en" / "ko" / "ja" / "zh-Hans". 변경 시 재시작 다이얼로그.
        // System default 다음 구분선, 그 아래 명시 언어는 native name 사전순 (macOS Settings convention).
        // 정렬은 사용자 OS locale 따라가도록 localizedStandardCompare 사용.
        languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        languagePopup.addItem(withTitle: String(localized: "System default"))
        languagePopup.lastItem?.representedObject = "system"
        languagePopup.menu?.addItem(NSMenuItem.separator())
        let supportedLangs: [(code: String, native: String)] = [
            ("en", "English"),
            ("ko", "한국어"),
            ("ja", "日本語"),
            ("zh-Hans", "中文 (简体)"),
        ]
        let sortedLangs = supportedLangs.sorted {
            $0.native.localizedStandardCompare($1.native) == .orderedAscending
        }
        for (code, native) in sortedLangs {
            languagePopup.addItem(withTitle: native)
            languagePopup.lastItem?.representedObject = code
        }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))
        languagePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        crashReportingToggle = checkbox(title: String(localized: "Send anonymous crash & error reports"),
                                        action: #selector(toggleCrashReporting(_:)))

        return pane([
            settingRow(loginToggle, description: String(localized: "Auto-start DiskOUT when you log in")),
            formGrid(rows: [(String(localized: "Language"), languagePopup)]),
            settingRow(crashReportingToggle,
                       description: String(localized: "Sends only crash type, anonymized stack traces, and error categories. Never disk names, file paths, or your identity.")),
        ])
    }

    /// 추출 동작 — 잠자기 연동 3종 + 추출 전략 + 우클릭. (이전엔 General/Eject Behavior 에
    /// 흩어져 있던 것을 "추출이 언제·어떻게 일어나는가" 기준으로 한 페인에 모음.)
    private func makeEjectPane() -> NSView {
        sleepToggle = checkbox(title: String(localized: "Eject on sleep"), action: #selector(toggleSleepEject(_:)))
        lidCloseToggle = checkbox(title: String(localized: "Eject on lid close"), action: #selector(toggleLidCloseEject(_:)))
        displaySleepToggle = checkbox(title: String(localized: "Eject on display sleep (experimental)"), action: #selector(toggleDisplaySleepEject(_:)))
        libraryAppToggle = checkbox(title: String(localized: "Quit Music/Photos before sleep"), action: #selector(toggleLibraryAppManagement(_:)))
        forceFallbackToggle = checkbox(title: String(localized: "Allow Force Unmount"), action: #selector(toggleForceFallback(_:)))
        rightClickEjectToggle = checkbox(title: String(localized: "Right-click menu bar icon to eject all"),
                                         action: #selector(toggleRightClickEject(_:)))

        return pane([
            settingRow(sleepToggle, description: String(localized: "Eject all external drives right before the Mac sleeps.")),
            settingRow(lidCloseToggle, description: String(localized: "Eject all external drives the moment you close the lid.")),
            settingRow(displaySleepToggle, description: String(localized: "Also eject when only the display goes to sleep — for Macs set to never sleep.")),
            settingRow(libraryAppToggle, description: String(localized: "Auto-quit Music and Photos before sleep, relaunch on wake. Useful when libraries are on external drives.")),
            settingRow(forceFallbackToggle, description: String(localized: "If a normal eject fails, manual eject may fall back to a force unmount. Eject and Sleep, lid close, and immediate system sleep (Apple menu, power key, or similar causes) try it once only when the disk is busy. Idle and display sleep never use it.")),
            settingRow(rightClickEjectToggle, description: String(localized: "When off, right-click (and ctrl+click) opens the menu instead of ejecting all drives.")),
        ])
    }

    private func makeNotificationsPane() -> NSView {
        notificationsToggle = checkbox(title: String(localized: "Notifications"), action: #selector(toggleNotifications(_:)))
        successNotificationsToggle = checkbox(title: String(localized: "Success notifications"), action: #selector(toggleSuccessNotifications(_:)))
        failureNotificationsToggle = checkbox(title: String(localized: "Failure notifications"), action: #selector(toggleFailureNotifications(_:)))

        notificationPermissionHint = NSTextField(wrappingLabelWithString:
            String(localized: "Notifications are blocked in System Settings."))
        notificationPermissionHint.font = .systemFont(ofSize: UI.captionSize)
        notificationPermissionHint.textColor = .systemOrange
        notificationPermissionHint.preferredMaxLayoutWidth = Self.paneWidth - UI.windowPadding * 2
        notificationSettingsButton = NSButton(title: String(localized: "Open Notification Settings…"),
                                              target: self,
                                              action: #selector(openNotificationSettings))
        notificationSettingsButton.bezelStyle = .rounded

        // 무음 설계 안내 — 알림 동작에 대한 설명이므로 이 페인에 (이전엔 About 에 잘못 배치).
        let hint = NSTextField(wrappingLabelWithString:
            String(localized: "Notifications are silent by design — no sound. Look for the menu bar icon for results."))
        hint.font = .systemFont(ofSize: UI.captionSize)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = Self.paneWidth - UI.windowPadding * 2

        return pane([
            notificationsToggle,
            indented(successNotificationsToggle),
            indented(failureNotificationsToggle),
            notificationPermissionHint,
            notificationSettingsButton,
            hint,
        ])
    }

    private func makeHotkeysPane() -> NSView {
        ejectHotkeyPopup = hotkeyPopup(action: #selector(ejectHotkeyChanged(_:)))
        mountHotkeyPopup = hotkeyPopup(action: #selector(mountHotkeyChanged(_:)))
        ejectAndSleepHotkeyPopup = optionalHotkeyPopup(action: #selector(ejectAndSleepHotkeyChanged(_:)))
        return pane([
            formGrid(rows: [
                (String(localized: "Eject all"), ejectHotkeyPopup),
                (String(localized: "Mount all"), mountHotkeyPopup),
                (String(localized: "Eject and Sleep"), ejectAndSleepHotkeyPopup),
            ]),
        ])
    }

    private func makePremiumPane() -> NSView {
        premiumStatusLabel = NSTextField(wrappingLabelWithString: "")
        premiumStatusLabel.font = .systemFont(ofSize: UI.bodySize, weight: .medium)
        premiumPurchaseButton = actionButton(String(localized: "Unlock Animated Icons — USD 4.99 One-Time…"),
                                             #selector(premiumPurchaseClicked))
        premiumStopButton = actionButton(String(localized: "Stop Checking Purchase…"),
                                         #selector(premiumStopClicked))
        premiumDetailsButton = actionButton(String(localized: "View Purchase Details…"),
                                            #selector(premiumDetailsClicked))
        premiumRecoveryButton = actionButton(String(localized: "Copy Recovery Code…"),
                                             #selector(premiumRecoveryClicked))
        premiumCheckButton = actionButton(String(localized: "Check Purchase Status…"),
                                          #selector(premiumCheckClicked))
        premiumRestoreButton = actionButton(String(localized: "Restore Purchase…"),
                                            #selector(premiumRestoreClicked))
        return pane([
            premiumStatusLabel,
            premiumPurchaseButton,
            premiumStopButton,
            premiumDetailsButton,
            premiumRecoveryButton,
            premiumCheckButton,
            premiumRestoreButton,
        ])
    }

    private func makeAboutPane() -> NSView {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        let copyright = (info?["NSHumanReadableCopyright"] as? String) ?? "DiskOUT by LIMOD"

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let name = NSTextField(labelWithString: "DiskOUT")
        name.font = .systemFont(ofSize: UI.titleSize, weight: .semibold)

        let versionLabel = NSTextField(labelWithString: String(localized: "Version \(version) (build \(build))"))
        versionLabel.font = .systemFont(ofSize: UI.captionSize)
        versionLabel.textColor = .secondaryLabelColor

        let copyrightLabel = NSTextField(labelWithString: copyright)
        copyrightLabel.font = .systemFont(ofSize: UI.captionSize)
        copyrightLabel.textColor = .secondaryLabelColor

        let updateButton = NSButton(title: String(localized: "Check for Updates…"),
                                    target: self, action: #selector(checkForUpdatesClicked))
        updateButton.bezelStyle = .rounded

        let links = NSStackView(views: [
            linkButton(title: "GitHub", urlString: "https://github.com/yooongZa/DiskOUT"),
            linkButton(title: String(localized: "Release Notes"),
                       urlString: "https://github.com/yooongZa/DiskOUT/releases"),
        ])
        links.orientation = .horizontal
        links.spacing = UI.spacing

        let stack = NSStackView(views: [icon, name, versionLabel, copyrightLabel, updateButton, links])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(UI.rowSpacing, after: icon)
        stack.setCustomSpacing(UI.spacing, after: copyrightLabel)
        stack.setCustomSpacing(UI.rowSpacing, after: updateButton)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // About 는 중앙 정렬 — pane() 의 leading 정렬 대신 자체 컨테이너.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        let bottom = stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -UI.windowPadding)
        bottom.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.paneWidth),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: UI.windowPadding),
            bottom,
        ])
        return container
    }

    // MARK: Pane layout helpers

    /// 페인 공통 컨테이너 — 고정폭, 24pt 여백, leading 정렬 세로 stack.
    /// bottom 제약 priority 999: showPane 높이 전환 애니메이션 중 일시 프레임 불일치 흡수.
    private func pane(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = UI.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        let bottom = stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -UI.windowPadding)
        bottom.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.paneWidth),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: UI.windowPadding),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -UI.windowPadding),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: UI.windowPadding),
            bottom,
        ])
        return container
    }

    /// 체크박스 + 아래 보조 설명(11pt secondary) 한 묶음.
    /// 설명은 체크박스 *텍스트* 시작선에 맞춰 들여쓰기 — 시스템 설정과 같은 문법.
    private func settingRow(_ checkbox: NSButton, description: String) -> NSView {
        let desc = NSTextField(wrappingLabelWithString: description)
        desc.font = .systemFont(ofSize: UI.captionSize)
        desc.textColor = .secondaryLabelColor
        desc.preferredMaxLayoutWidth = Self.paneWidth - UI.windowPadding * 2 - Self.checkboxTextIndent

        let stack = NSStackView(views: [checkbox, indented(desc)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return stack
    }

    /// 체크박스 텍스트 시작선만큼 들여쓴 행 — 종속 토글/설명 줄 공용.
    private func indented(_ view: NSView) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: Self.checkboxTextIndent).isActive = true
        let row = NSStackView(views: [spacer, view])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 0
        return row
    }

    /// 우측 정렬 라벨 + 컨트롤의 2열 폼 — 고정 라벨폭 대신 자연 폭 (언어별 라벨 길이 자동 대응).
    private func formGrid(rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { label, control in
            let text = NSTextField(labelWithString: label)
            return [text, control]
        })
        grid.rowSpacing = UI.rowSpacing
        grid.columnSpacing = UI.spacing
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        return grid
    }

    private func linkButton(title: String, urlString: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(linkClicked(_:)))
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: NSColor.linkColor,
                         .font: NSFont.systemFont(ofSize: UI.captionSize + 1)])
        button.identifier = NSUserInterfaceItemIdentifier(urlString)
        return button
    }

    @objc private func linkClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func checkForUpdatesClicked() {
        onCheckForUpdates()
    }

    private func checkbox(title: String, action: Selector) -> NSButton {
        NSButton(checkboxWithTitle: title, target: self, action: action)
    }

    private func actionButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func hotkeyPopup(action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for preset in SettingsHotkeyPreset.allCases {
            popup.addItem(withTitle: preset.title)
        }
        popup.target = self
        popup.action = action
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return popup
    }

    /// "Off" 옵션이 첫 번째 항목으로 들어간 popup. index 0 = nil (단축키 없음),
    /// index 1+ = SettingsHotkeyPreset.allCases[i-1].
    private func optionalHotkeyPopup(action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItem(withTitle: String(localized: "Off"))
        for preset in SettingsHotkeyPreset.allCases {
            popup.addItem(withTitle: preset.title)
        }
        popup.target = self
        popup.action = action
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return popup
    }

    private func refreshControls() {
        let loginStatus = LoginItem.status
        loginToggle.title = loginStatus == .requiresApproval
            ? String(localized: "Launch at login (needs approval)")
            : String(localized: "Launch at login")
        loginToggle.allowsMixedState = loginStatus == .requiresApproval
        loginToggle.state = loginStatus == .requiresApproval
            ? .mixed
            : (loginStatus == .enabled ? .on : .off)
        sleepToggle.state = SleepEject.enabled ? .on : .off
        lidCloseToggle.state = LidCloseEject.enabled ? .on : .off
        displaySleepToggle.state = DisplaySleepEject.enabled ? .on : .off
        libraryAppToggle.state = LibraryAppManagement.enabled ? .on : .off
        notificationsToggle.state = SettingsStore.notificationsEnabled ? .on : .off
        successNotificationsToggle.state = SettingsStore.successNotificationsEnabled ? .on : .off
        failureNotificationsToggle.state = SettingsStore.failureNotificationsEnabled ? .on : .off
        forceFallbackToggle.state = SettingsStore.forceFallbackEnabled ? .on : .off
        rightClickEjectToggle.state = SettingsStore.rightClickEjectEnabled ? .on : .off
        crashReportingToggle.state = SettingsStore.crashReportingEnabled ? .on : .off
        selectHotkey(SettingsStore.ejectHotkey, in: ejectHotkeyPopup)
        selectHotkey(SettingsStore.mountHotkey, in: mountHotkeyPopup)
        selectOptionalHotkey(SettingsStore.ejectAndSleepHotkey, in: ejectAndSleepHotkeyPopup)
        selectLanguage(SettingsStore.appLanguage, in: languagePopup)
        refreshNotificationControlState()
        refreshNotificationPermissionState()
        refreshPremiumControls()
    }

    private func refreshPremiumControls() {
        let state = premiumState()
        premiumStatusLabel.stringValue = !state.isConfigured
            ? String(localized: "Premium is unavailable in this build")
            : (state.hasAccess
                ? String(localized: "Premium is active")
                : String(localized: "No active purchase was found"))
        let busy = state.isPurchaseInProgress || state.isCheckingStatus || state.isRestoring
        premiumPurchaseButton.isHidden = !state.isConfigured || state.hasAccess || state.isPurchaseInProgress
        premiumPurchaseButton.isEnabled = !busy
        premiumStopButton.isHidden = !state.isPurchaseInProgress
        premiumDetailsButton.isHidden = !state.hasAccess
        premiumDetailsButton.isEnabled = state.canOpenDetails && !state.isOpeningDetails
        premiumRecoveryButton.isHidden = !state.hasAccess
        premiumRecoveryButton.isEnabled = state.hasRecoveryCode
        premiumCheckButton.isHidden = !state.isConfigured || state.hasAccess || state.isPurchaseInProgress
        premiumCheckButton.isEnabled = !busy
        premiumRestoreButton.isHidden = !state.isConfigured || state.hasAccess || state.isPurchaseInProgress
        premiumRestoreButton.isEnabled = !busy
    }

    @objc private func premiumPurchaseClicked() { premiumActions.purchase(); refreshPremiumControls() }
    @objc private func premiumStopClicked() { premiumActions.stopPurchaseCheck(); refreshPremiumControls() }
    @objc private func premiumDetailsClicked() { premiumActions.viewDetails(); refreshPremiumControls() }
    @objc private func premiumRecoveryClicked() { premiumActions.copyRecoveryCode(); refreshPremiumControls() }
    @objc private func premiumCheckClicked() { premiumActions.checkStatus(); refreshPremiumControls() }
    @objc private func premiumRestoreClicked() { premiumActions.restore(); refreshPremiumControls() }

    /// representedObject 가 lang 코드 ("system" / "en" / "ko" / "ja" / "zh-Hans") 인 항목을 popup 에서 선택.
    private func selectLanguage(_ lang: String, in popup: NSPopUpButton) {
        for (i, item) in popup.itemArray.enumerated() {
            if (item.representedObject as? String) == lang {
                popup.selectItem(at: i)
                return
            }
        }
        // 매칭 항목 없으면 "system" 으로 fallback (첫 번째 항목)
        popup.selectItem(at: 0)
    }

    private func refreshNotificationControlState() {
        let enabled = SettingsStore.notificationsEnabled
        successNotificationsToggle.isEnabled = enabled
        failureNotificationsToggle.isEnabled = enabled
    }

    private func refreshNotificationPermissionState() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                let denied = settings.authorizationStatus == .denied
                self.notificationPermissionHint.isHidden = !denied
                self.notificationSettingsButton.isHidden = !denied
            }
        }
    }

    private func selectHotkey(_ preset: SettingsHotkeyPreset, in popup: NSPopUpButton) {
        if let index = SettingsHotkeyPreset.allCases.firstIndex(of: preset) {
            popup.selectItem(at: index)
        }
    }

    private func selectOptionalHotkey(_ preset: SettingsHotkeyPreset?, in popup: NSPopUpButton) {
        guard let preset, let index = SettingsHotkeyPreset.allCases.firstIndex(of: preset) else {
            popup.selectItem(at: 0)   // "Off"
            return
        }
        popup.selectItem(at: index + 1)
    }

    @objc private func toggleLoginItem(_ sender: NSButton) {
        let before = LoginItem.status
        if before == .requiresApproval {
            LoginItem.openSystemSettings()
            refreshControls()
            return
        }

        do {
            if before == .enabled {
                try LoginItem.unregister()
            } else {
                try LoginItem.register()
                if LoginItem.status == .requiresApproval {
                    LoginItem.openSystemSettings()
                }
            }
        } catch {
            log.error("Settings login item update failed: \(error.localizedDescription, privacy: .public)")
            showError(localizedLoginItemUpdateFailure())
        }
        refreshControls()
    }

    @objc private func toggleSleepEject(_ sender: NSButton) {
        SleepEject.enabled = sender.state == .on
    }

    @objc private func toggleLidCloseEject(_ sender: NSButton) {
        LidCloseEject.enabled = sender.state == .on
    }

    @objc private func toggleDisplaySleepEject(_ sender: NSButton) {
        DisplaySleepEject.enabled = sender.state == .on
    }

    @objc private func toggleLibraryAppManagement(_ sender: NSButton) {
        LibraryAppManagement.enabled = sender.state == .on
    }

    @objc private func toggleNotifications(_ sender: NSButton) {
        SettingsStore.notificationsEnabled = sender.state == .on
        if SettingsStore.notificationsEnabled {
            requestNotificationAuthorization()
        }
        refreshNotificationControlState()
        refreshNotificationPermissionState()
    }

    @objc private func toggleSuccessNotifications(_ sender: NSButton) {
        SettingsStore.successNotificationsEnabled = sender.state == .on
    }

    @objc private func toggleFailureNotifications(_ sender: NSButton) {
        SettingsStore.failureNotificationsEnabled = sender.state == .on
    }

    @objc private func toggleForceFallback(_ sender: NSButton) {
        SettingsStore.forceFallbackEnabled = sender.state == .on
    }

    @objc private func toggleRightClickEject(_ sender: NSButton) {
        SettingsStore.rightClickEjectEnabled = sender.state == .on
    }

    @objc private func toggleCrashReporting(_ sender: NSButton) {
        SettingsStore.crashReportingEnabled = sender.state == .on
        ReportEndpoint.setReportingEnabled(SettingsStore.crashReportingEnabled)
        if SettingsStore.crashReportingEnabled {
            CrashReporter.harvestIfEnabled()
        }
    }

    /// 환경설정의 언어 popup 변경. 새 값이 기존과 다르면 SettingsStore 갱신 + 재시작 다이얼로그.
    /// 사용자가 "지금 재시작" 누르면 AppDelegate 가 helper 로 새 인스턴스 띄우고 종료.
    /// "나중에" 누르면 다음 자연 launch 부터 새 언어 적용.
    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let newLang = sender.selectedItem?.representedObject as? String else { return }
        let prevLang = SettingsStore.appLanguage
        guard newLang != prevLang else { return }
        SettingsStore.appLanguage = newLang
        log.notice("Language changed: \(prevLang, privacy: .public) → \(newLang, privacy: .public)")

        let alert = NSAlert()
        alert.messageText = String(localized: "Language changed")
        alert.informativeText = String(localized: "DiskOUT needs to restart to apply the new language.")
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            (NSApp.delegate as? AppDelegate)?.relaunchApplicationForLanguageChange()
        }
    }

    @objc private func ejectHotkeyChanged(_ sender: NSPopUpButton) {
        let chosen = SettingsHotkeyPreset.allCases[sender.indexOfSelectedItem]
        applyHotkeyChoice(chosen, to: .eject)
    }

    @objc private func mountHotkeyChanged(_ sender: NSPopUpButton) {
        let chosen = SettingsHotkeyPreset.allCases[sender.indexOfSelectedItem]
        applyHotkeyChoice(chosen, to: .mount)
    }

    @objc private func ejectAndSleepHotkeyChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if index == 0 {
            SettingsStore.ejectAndSleepHotkey = nil
            onHotkeyChanged()
            return
        }
        let chosen = SettingsHotkeyPreset.allCases[index - 1]
        applyHotkeyChoice(chosen, to: .ejectAndSleep)
    }

    private func applyHotkeyChoice(_ chosen: SettingsHotkeyPreset, to role: SettingsShortcutRole) {
        let resolution = SettingsShortcutConflictPolicy.assigning(
            chosen,
            to: role,
            current: SettingsStore.shortcutAssignments,
            available: SettingsHotkeyPreset.allCases
        )
        SettingsStore.shortcutAssignments = resolution.assignments
        selectHotkey(resolution.assignments.eject, in: ejectHotkeyPopup)
        selectHotkey(resolution.assignments.mount, in: mountHotkeyPopup)
        selectOptionalHotkey(resolution.assignments.ejectAndSleep, in: ejectAndSleepHotkeyPopup)
        onHotkeyChanged()
        guard !resolution.displacedRoles.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Hotkey conflict")
        alert.informativeText = String(localized: "The shortcut you chose is now assigned to this action. Conflicting actions were moved to unused shortcuts.")
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, error in
            log.notice("settings requestAuthorization: granted=\(granted, privacy: .public) error=\(error?.localizedDescription ?? "nil", privacy: .public)")
            DispatchQueue.main.async { self?.refreshNotificationPermissionState() }
        }
    }

    @objc private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Settings update failed")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - First-Run Permission Onboarding

/// 첫 실행 시 1회 표시하는 권한 온보딩 창. 메뉴 권한 경고행에서도 다시 열 수 있다.
///
/// **비차단 설계**: DiskOUT 핵심 기능(sleep 자동 추출)은 권한 0개로 동작 → 이 창은 앱을 막지 않는다.
/// 닫거나 무시해도 앱은 정상. 권한은 *부가 기능*을 켜는 것:
/// - 손쉬운 사용 → 전역 단축키 (macOS 자동 프롬프트 없음 → 여기서 1회 유도)
/// - 알림 → 추출 결과 피드백
/// - 로그인 항목 → 자동 실행 (순수 선택 → 체크박스, 자동 요청 안 함)
///
/// 창이 열린 동안 0.5s 타이머로 권한 상태를 폴링해 카드 상태점을 실시간 갱신
/// (손쉬운 사용은 변경 알림 API 가 없어 폴링이 정석). 닫히면 타이머 중지 +
/// `SettingsStore.onboardingCompletedVersion` 기록 → 재노출 안 함.
/// `SettingsWindowController` 와 같은 패턴 (순수 AppKit, 프로그래밍 방식 NSWindow).
private final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    /// 온보딩 콘텐츠 버전. 권한이 추가되면 올려서 기존 사용자에게 1회 재노출.
    static let version = 1
    private static let minimumContentSize = NSSize(width: 460, height: 456)

    private let onClosed: () -> Void
    private let onAccessibilityGranted: () -> Void

    private var accessibilityDot: NSImageView!
    private var accessibilityButton: NSButton!
    private var notificationsDot: NSImageView!
    private var notificationsButton: NSButton!
    private var loginToggle: NSButton!
    private var loginHint: NSTextField!

    private var pollTimer: Timer?
    private var lastAccessibilityTrusted = false
    private var notificationStatus: UNAuthorizationStatus = .notDetermined
    /// 사용자가 직접 닫았는지 (Done 버튼 / X 버튼). 앱 종료로 인한 닫힘과 구분.
    private var userDismissed = false

    init(onClosed: @escaping () -> Void, onAccessibilityGranted: @escaping () -> Void) {
        self.onClosed = onClosed
        self.onAccessibilityGranted = onAccessibilityGranted
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.minimumContentSize),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = String(localized: "DiskOUT Permissions")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let content = makeContentView()
        window.contentView = content.view
        window.contentMinSize = Self.minimumContentSize
        window.setContentSize(NSSize(width: Self.minimumContentSize.width,
                                     height: max(Self.minimumContentSize.height, content.preferredHeight)))
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { log.notice("onboarding: deinit") }

    /// 창 표시 + 폴링 시작. `.accessory` 앱이지만 SettingsWindowController 와 동일하게
    /// makeKeyAndOrderFront + NSApp.activate 로 포커스 확보 (이미 검증된 경로).
    func show() {
        lastAccessibilityTrusted = AXIsProcessTrusted()
        refreshAll()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPolling()
        log.notice("onboarding: window shown")
    }

    /// X 버튼 닫기 — 사용자가 직접 닫은 것으로 표시.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        userDismissed = true
        return true
    }

    func windowWillClose(_ notification: Notification) {
        log.notice("onboarding: windowWillClose userDismissed=\(self.userDismissed, privacy: .public)")
        stopPolling()
        // 사용자가 직접 닫았을 때만 완료로 기록 — 앱 종료 등으로 창이 닫히는 건 "봤음" 으로 안 침.
        if userDismissed {
            SettingsStore.onboardingCompletedVersion = OnboardingWindowController.version
        }
        onClosed()
    }

    // MARK: Layout

    private func makeContentView() -> (view: NSView, preferredHeight: CGFloat) {
        let appIcon = NSImageView()
        appIcon.image = NSApp.applicationIconImage
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.setAccessibilityElement(false)
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        appIcon.widthAnchor.constraint(equalToConstant: 52).isActive = true
        appIcon.heightAnchor.constraint(equalToConstant: 52).isActive = true

        let headerTitle = NSTextField(wrappingLabelWithString: String(localized: "DiskOUT Permissions"))
        headerTitle.font = .boldSystemFont(ofSize: 16)
        headerTitle.maximumNumberOfLines = 0
        headerTitle.lineBreakMode = .byWordWrapping
        let headerSubtitle = NSTextField(wrappingLabelWithString:
            String(localized: "DiskOUT's core features work without any permissions. The ones below are optional — turn on what you want."))
        headerSubtitle.font = .systemFont(ofSize: 11)
        headerSubtitle.textColor = .secondaryLabelColor
        headerSubtitle.maximumNumberOfLines = 0
        headerSubtitle.lineBreakMode = .byWordWrapping
        headerSubtitle.preferredMaxLayoutWidth = 336
        let headerText = NSStackView(views: [headerTitle, headerSubtitle])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 3
        headerText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [appIcon, headerText])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        let accessibilityCard = makeAccessibilityCard()
        let notificationsCard = makeNotificationsCard()
        let loginCard = makeLoginCard()

        let hint = NSTextField(wrappingLabelWithString:
            String(localized: "You can reopen this anytime from the menu bar icon's menu."))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 0
        hint.lineBreakMode = .byWordWrapping
        hint.preferredMaxLayoutWidth = 320
        hint.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let doneButton = NSButton(title: String(localized: "Done"), target: self, action: #selector(closeWindow))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        let footer = NSStackView(views: [hint, doneButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12

        let children: [NSView] = [header, makeSeparator(),
                                  accessibilityCard, makeSeparator(),
                                  notificationsCard, makeSeparator(),
                                  loginCard, makeSeparator(),
                                  footer]
        let stack = NSStackView(views: children)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -22)
        ]
        for child in children {
            constraints.append(child.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        // 460pt 폭에서 먼저 실제 줄바꿈 높이를 계산한다. 기본 번역은 기존 456pt 높이를
        // 유지하고, 긴 번역/큰 글자는 필요한 만큼 창을 늘려 하단 버튼이 잘리지 않게 한다.
        container.frame = NSRect(origin: .zero, size: Self.minimumContentSize)
        container.layoutSubtreeIfNeeded()
        return (container, stack.fittingSize.height + 44)
    }

    private func makeAccessibilityCard() -> NSView {
        accessibilityDot = makeStatusDot(accessibilityLabel: String(localized: "Global hotkey"))
        accessibilityButton = NSButton(title: String(localized: "Allow"),
                                       target: self, action: #selector(accessibilityButtonClicked))
        accessibilityButton.bezelStyle = .rounded
        // trailing 은 [버튼, 상태점] 순 — 상태점이 항상 우측 끝 고정폭 칸에 와서
        // 버튼 폭이 행마다 달라도 점들이 세로로 정렬된다.
        return makeRow(symbol: "keyboard",
                       title: String(localized: "Global hotkey"),
                       detail: String(localized: "Eject all drives anywhere with ⌥⌘E"),
                       trailing: [accessibilityButton, accessibilityDot])
    }

    private func makeNotificationsCard() -> NSView {
        notificationsDot = makeStatusDot(accessibilityLabel: String(localized: "Notifications"))
        notificationsButton = NSButton(title: String(localized: "Allow"),
                                       target: self, action: #selector(notificationsButtonClicked))
        notificationsButton.bezelStyle = .rounded
        return makeRow(symbol: "bell",
                       title: String(localized: "Notifications"),
                       detail: String(localized: "See eject results at a glance"),
                       trailing: [notificationsButton, notificationsDot])
    }

    private func makeLoginCard() -> NSView {
        loginToggle = NSButton(checkboxWithTitle: "", target: self, action: #selector(loginToggleClicked(_:)))
        loginHint = NSTextField(wrappingLabelWithString: String(localized: "Needs approval in System Settings"))
        loginHint.font = .systemFont(ofSize: UI.captionSize)
        loginHint.textColor = .systemOrange
        loginHint.maximumNumberOfLines = 0
        loginHint.lineBreakMode = .byWordWrapping
        // isHidden 대신 alphaValue — 각주가 나타나고 사라질 때 카드 높이가 출렁이지 않게
        // 자리는 항상 유지한다 (레이아웃 점프 방지).
        loginHint.alphaValue = 0
        return makeRow(symbol: "power",
                       title: String(localized: "Launch at login"),
                       detail: String(localized: "Auto-start DiskOUT when you log in"),
                       footnote: loginHint,
                       trailing: [loginToggle])
    }

    /// 권한 행 한 줄: [아이콘  제목/설명(+각주)  ⟨여백⟩  trailing…].
    private func makeRow(symbol: String, title: String, detail: String,
                         footnote: NSTextField? = nil, trailing: [NSView]) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true

        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.maximumNumberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var textViews: [NSView] = [titleLabel, detailLabel]
        if let footnote { textViews.append(footnote) }
        let textStack = NSStackView(views: textViews)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let row = NSStackView(views: [icon, textStack, spacer] + trailing)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 10
        return row
    }

    private func makeStatusDot(accessibilityLabel: String) -> NSImageView {
        let dot = NSImageView()
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        dot.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        dot.contentTintColor = .tertiaryLabelColor
        dot.setAccessibilityElement(true)
        dot.setAccessibilityRole(.staticText)
        dot.setAccessibilityLabel(accessibilityLabel)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 13).isActive = true
        return dot
    }

    private func makeSeparator() -> NSBox {
        let sep = NSBox()
        sep.boxType = .separator
        return sep
    }

    // MARK: Actions

    @objc private func accessibilityButtonClicked() {
        // macOS 1회성 프롬프트 + 시스템 설정 딥링크 — 둘 다 함께 (research 권장).
        _ = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func notificationsButtonClicked() {
        if notificationStatus == .denied {
            // 거부 후엔 앱이 다시 프롬프트 못 띄움 → 시스템 설정으로 안내.
            openSystemSettings("x-apple.systempreferences:com.apple.preference.notifications")
        } else {
            SettingsStore.notificationsEnabled = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
                log.notice("onboarding notification auth: granted=\(granted, privacy: .public) error=\(error?.localizedDescription ?? "nil", privacy: .public)")
            }
        }
    }

    @objc private func loginToggleClicked(_ sender: NSButton) {
        let before = LoginItem.status
        if before == .requiresApproval {
            LoginItem.openSystemSettings()
            refreshAll()
            return
        }
        do {
            if before == .enabled {
                try LoginItem.unregister()
            } else {
                try LoginItem.register()
                if LoginItem.status == .requiresApproval {
                    LoginItem.openSystemSettings()
                }
            }
        } catch {
            log.error("Onboarding login item update failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn't update login item")
            alert.informativeText = localizedLoginItemUpdateFailure()
            alert.alertStyle = .warning
            alert.runModal()
        }
        refreshAll()
    }

    @objc private func closeWindow() {
        log.notice("onboarding: Done clicked")
        userDismissed = true
        window?.close()
    }

    private func openSystemSettings(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Live status (polling)

    private func startPolling() {
        pollTimer?.invalidate()
        // 창이 열린 동안만 0.5s 폴링. 닫히면 stopPolling — 타이머 누수 방지.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refreshAll() {
        // 손쉬운 사용 — 변경 알림 API 가 없어 폴링으로 감지.
        let axTrusted = AXIsProcessTrusted()
        accessibilityDot.contentTintColor = axTrusted ? .systemGreen : .tertiaryLabelColor
        accessibilityDot.setAccessibilityValue(axTrusted
            ? String(localized: "Eject all drives anywhere with ⌥⌘E")
            : String(localized: "Allow Accessibility for global hotkeys"))
        accessibilityDot.setAccessibilityHelp(axTrusted ? nil : String(localized: "Allow"))
        accessibilityButton.isHidden = axTrusted
        if axTrusted && !lastAccessibilityTrusted {
            lastAccessibilityTrusted = true
            onAccessibilityGranted()   // 단축키 모니터 재설치 → 재시작 없이 즉시 활성화
        } else if !axTrusted {
            lastAccessibilityTrusted = false
        }

        // 로그인 항목 — 각주는 alphaValue 토글 (자리 유지, 레이아웃 점프 방지)
        let loginStatus = LoginItem.status
        loginToggle.state = (loginStatus == .enabled || loginStatus == .requiresApproval) ? .on : .off
        loginHint.alphaValue = (loginStatus == .requiresApproval) ? 1 : 0
        loginHint.setAccessibilityElement(loginStatus == .requiresApproval)

        // 알림 — getNotificationSettings 는 비동기.
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.notificationStatus = settings.authorizationStatus
                self.refreshNotificationCard()
            }
        }
    }

    private func refreshNotificationCard() {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationsDot.contentTintColor = .systemGreen
            notificationsDot.setAccessibilityValue(String(localized: "See eject results at a glance"))
            notificationsDot.setAccessibilityHelp(nil)
            notificationsButton.isHidden = true
        case .denied:
            notificationsDot.contentTintColor = .systemRed
            notificationsDot.setAccessibilityValue(String(localized: "Open System Settings"))
            notificationsDot.setAccessibilityHelp(String(localized: "Allow notifications to see eject results"))
            notificationsButton.isHidden = false
            notificationsButton.title = String(localized: "Open System Settings")
        case .notDetermined:
            notificationsDot.contentTintColor = .tertiaryLabelColor
            notificationsDot.setAccessibilityValue(String(localized: "Allow notifications to see eject results"))
            notificationsDot.setAccessibilityHelp(String(localized: "Allow"))
            notificationsButton.isHidden = false
            notificationsButton.title = String(localized: "Allow")
        @unknown default:
            notificationsDot.contentTintColor = .tertiaryLabelColor
            notificationsDot.setAccessibilityValue(String(localized: "Allow notifications to see eject results"))
            notificationsDot.setAccessibilityHelp(String(localized: "Allow"))
            notificationsButton.isHidden = false
            notificationsButton.title = String(localized: "Allow")
        }
    }
}

private func menuSymbol(_ name: String, fallback: String) -> NSImage? {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)
    image?.isTemplate = true
    return image
}

/// External tools and Disk Arbitration return diagnostic text in the system language.
/// Keep that detail in unified logging, and expose only this app-localized summary in UI.
private func localizedOperationFailure() -> String {
    String(localized: "The operation couldn't be completed. Please try again.")
}

/// Login item framework errors are diagnostic text outside DiskOUT's localization policy.
/// Keep the original detail in unified logging and show one actionable app-localized message.
private func localizedLoginItemUpdateFailure() -> String {
    String(localized: "DiskOUT couldn’t update the login item. Check System Settings → General → Login Items, then try again.")
}

// MARK: - Process / Disk Utilities

private struct ProcessResult {
    let success: Bool
    let stdout: Data
    let errorMessage: String?
    let timedOut: Bool
    let terminationStatus: Int32?

    init(success: Bool,
         stdout: Data,
         errorMessage: String?,
         timedOut: Bool = false,
         terminationStatus: Int32? = nil) {
        self.success = success
        self.stdout = stdout
        self.errorMessage = errorMessage
        self.timedOut = timedOut
        self.terminationStatus = terminationStatus
    }
}

private enum ProcessRunner {
    static func run(executable: String, arguments: [String], timeout: TimeInterval? = nil) -> ProcessResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        let lock = NSLock()
        var stdout = Data()
        var stderr = Data()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            lock.lock()
            stdout.append(data)
            lock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            lock.lock()
            stderr.append(data)
            lock.unlock()
        }

        do {
            try task.run()

            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                task.waitUntilExit()
                finished.signal()
            }

            var didTimeout = false
            if let timeout {
                didTimeout = finished.wait(timeout: .now() + timeout) == .timedOut
                if didTimeout {
                    task.terminate()
                    if finished.wait(timeout: .now() + 0.5) == .timedOut {
                        kill(task.processIdentifier, SIGKILL)
                        _ = finished.wait(timeout: .now() + 1.0)
                    }
                }
            } else {
                finished.wait()
            }

            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            // timeout 후 SIGKILL 된 child 가 grandchild 를 남겨 둔 경우 (예: hdiutil fork)
            // pipe fd 가 즉시 닫히지 않아 readDataToEndOfFile 가 무한 대기할 수 있다.
            // timeout 시엔 readabilityHandler 가 모은 데이터만 사용하고 추가 read 는 생략.
            let finalStdout: Data
            let finalStderr: Data
            if didTimeout {
                lock.lock()
                finalStdout = stdout
                finalStderr = stderr
                lock.unlock()
            } else {
                let remainingStdout = outPipe.fileHandleForReading.readDataToEndOfFile()
                let remainingStderr = errPipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                stdout.append(remainingStdout)
                stderr.append(remainingStderr)
                finalStdout = stdout
                finalStderr = stderr
                lock.unlock()
            }

            let executableName = URL(fileURLWithPath: executable).lastPathComponent
            if didTimeout {
                // SIGKILL 후에도 child 가 살아 있을 수 있다 (디스크 I/O 행 — uninterruptible sleep).
                // 그 상태에서 terminationStatus 를 읽으면 NSInvalidArgumentException 크래시.
                let status: Int32? = task.isRunning ? nil : task.terminationStatus
                return ProcessResult(success: false,
                                     stdout: finalStdout,
                                     errorMessage: "\(executableName) timed out",
                                     timedOut: true,
                                     terminationStatus: status)
            }

            let stderrText = String(data: finalStderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if task.terminationStatus == 0 {
                return ProcessResult(success: true,
                                     stdout: finalStdout,
                                     errorMessage: nil,
                                     terminationStatus: task.terminationStatus)
            }

            let message = stderrText.isEmpty ? "\(executableName) exit code \(task.terminationStatus)" : stderrText
            return ProcessResult(success: false,
                                 stdout: finalStdout,
                                 errorMessage: message,
                                 terminationStatus: task.terminationStatus)
        } catch {
            return ProcessResult(success: false, stdout: Data(), errorMessage: error.localizedDescription)
        }
    }
}

private struct BlockingProcess {
    let pid: pid_t
    let command: String
    let openFiles: [String]

    var displayName: String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? command
    }

    var processSummary: String {
        "\(displayName)(\(pid))"
    }
}

private enum LsofInspector {
    private static let maxProcesses = 5
    private static let maxFiles = 5

    static func diagnosticMessage(forVolumePath volumePath: String) -> String? {
        let result = ProcessRunner.run(executable: "/usr/sbin/lsof",
                                       arguments: ["-nP", "-w", "-Fpcfn", "--", volumePath],
                                       timeout: 3.0)
        if result.timedOut {
            return String(localized: "lsof timed out")
        }

        let processes = parse(result.stdout, volumePath: volumePath)
        if !processes.isEmpty {
            let processText = processes
                .prefix(maxProcesses)
                .map { $0.processSummary }
                .joined(separator: ", ")
            var lines = [String(localized: "Blocking processes: \(processText)")]

            let files = uniqueFiles(from: processes, volumePath: volumePath)
                .prefix(maxFiles)
                .joined(separator: ", ")
            if !files.isEmpty {
                lines.append(String(localized: "Open files: \(files)"))
            }
            return lines.joined(separator: "\n")
        }

        if result.success || isNoMatchResult(result) {
            return String(localized: "No blocking process found")
        }

        return "\(String(localized: "Could not inspect blocking processes"))\n\(String(localized: "Full Disk Access may be needed"))"
    }

    /// 점유 프로세스를 구조화된 `[BlockingProcess]`(pid 포함)로 반환 — 능동 복구(앱 끄고 재시도)
    /// 판단용. `diagnosticMessage` 와 동일한 lsof 호출이지만 텍스트 대신 pid 목록을 돌려준다.
    /// timeout / FDA 부재 등으로 조회 실패하면 빈 배열 (호출자는 기존 텍스트 알림으로 fallback).
    static func blockingProcesses(forVolumePath volumePath: String) -> [BlockingProcess] {
        let result = ProcessRunner.run(executable: "/usr/sbin/lsof",
                                       arguments: ["-nP", "-w", "-Fpcfn", "--", volumePath],
                                       timeout: 3.0)
        guard !result.timedOut else { return [] }
        return parse(result.stdout, volumePath: volumePath)
    }

    private static func parse(_ data: Data, volumePath: String) -> [BlockingProcess] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var currentPID: pid_t?
        var currentCommand = ""
        var commands: [pid_t: String] = [:]
        var pathsByPID: [pid_t: [String]] = [:]

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let key = line.first else { continue }
            let value = String(line.dropFirst())

            switch key {
            case "p":
                currentPID = pid_t(value) ?? 0
                currentCommand = commands[currentPID ?? 0] ?? ""
            case "c":
                guard let pid = currentPID else { continue }
                currentCommand = value
                commands[pid] = value
            case "n":
                guard let pid = currentPID, isRelevant(path: value, volumePath: volumePath) else { continue }
                var paths = pathsByPID[pid] ?? []
                if !paths.contains(value) {
                    paths.append(value)
                }
                pathsByPID[pid] = paths
                if commands[pid] == nil {
                    commands[pid] = currentCommand
                }
            default:
                continue
            }
        }

        return pathsByPID
            .map { pid, paths in
                BlockingProcess(pid: pid,
                                command: commands[pid]?.isEmpty == false ? commands[pid]! : "pid \(pid)",
                                openFiles: paths)
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private static func isRelevant(path: String, volumePath: String) -> Bool {
        path == volumePath || path.hasPrefix(volumePath + "/") || path.contains(volumePath)
    }

    private static func uniqueFiles(from processes: [BlockingProcess], volumePath: String) -> [String] {
        var seen = Set<String>()
        var files: [String] = []

        for process in processes {
            for path in process.openFiles {
                let display = displayPath(path, volumePath: volumePath)
                guard !seen.contains(display) else { continue }
                seen.insert(display)
                files.append(display)
            }
        }
        return files
    }

    private static func displayPath(_ path: String, volumePath: String) -> String {
        if path == volumePath { return "/" }
        if path.hasPrefix(volumePath + "/") {
            return String(path.dropFirst(volumePath.count + 1))
        }
        return path
    }

    private static func isNoMatchResult(_ result: ProcessResult) -> Bool {
        result.stdout.isEmpty && (result.errorMessage?.contains("exit code 1") ?? false)
    }
}

private enum DiskUtilInfo {
    static func plist(for argument: String, timeout: TimeInterval? = 3.0) -> [String: Any]? {
        let result = ProcessRunner.run(executable: "/usr/sbin/diskutil",
                                       arguments: ["info", "-plist", argument],
                                       timeout: timeout)
        guard result.success else {
            log.debug("diskutil info failed for \(argument, privacy: .public): \(result.errorMessage ?? "?", privacy: .public)")
            return nil
        }
        return try? PropertyListSerialization
            .propertyList(from: result.stdout, format: nil) as? [String: Any]
    }

    static func busProtocol(in info: [String: Any]?) -> String? {
        info?["BusProtocol"] as? String
    }

    static func shouldIncludeAsExternalMedia(_ info: [String: Any]?, isInternal: Bool) -> Bool {
        let removable = (info?["RemovableMedia"] as? Bool) ?? (info?["Removable"] as? Bool)
        return ExternalMediaPolicy.shouldInclude(
            isInternal: isInternal,
            busProtocol: busProtocol(in: info),
            isRemovable: removable,
            isEjectable: info?["Ejectable"] as? Bool
        )
    }
}

/// 마운트된 DMG/sparseimage/CoreSimulator 같은 disk image 는 외장 디스크처럼 보일 수 있음.
/// 잘못 처리 시 "Chrome 설치 중인데 DMG 가 빠짐" 같은 사고 발생.
private enum DiskImages {
    static func mountedPathsOrNil(timeout: TimeInterval? = 1.0) -> Set<String>? {
        let result = ProcessRunner.run(executable: "/usr/bin/hdiutil",
                                       arguments: ["info", "-plist"],
                                       timeout: timeout)
        guard result.success else {
            log.error("hdiutil info failed: \(result.errorMessage ?? "?", privacy: .public)")
            return nil
        }
        guard let plist = try? PropertyListSerialization
                .propertyList(from: result.stdout, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]]
        else { return [] }

        var paths: Set<String> = []
        for image in images {
            guard let entities = image["system-entities"] as? [[String: Any]] else { continue }
            for entity in entities {
                if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                    paths.insert(mountPoint)
                }
            }
        }
        return paths
    }

    static func isKnownDiskImageMountPath(_ path: String) -> Bool {
        path.hasPrefix("/Library/Developer/CoreSimulator/Volumes/")
    }
}

private struct DiskUtilExternalVolume {
    let name: String
    let mountPoint: String?
    let volumeUUID: String?
}

/// 시스템/비-사용자 볼륨 판별용 공유 denylist. DiskUtilExternalList 와 DAInventory 공용.
private enum SystemVolumeFilter {
    static let contents: Set<String> = [
        "EFI", "Microsoft Reserved", "Apple_Boot",
        "Apple_KernelCoreDump", "Recovery",
        "Apple_RAID", "Apple_RAID_Offline"
    ]
    static let names: Set<String> = ["EFI", "Boot OS X", "Recovery", "Recovery HD"]
}

/// BSD 디바이스명 유틸.
private enum BSDName {
    /// 파티션 BSD("disk2s1") → whole-disk BSD("disk2"). 매칭 실패 시 nil.
    static func wholeDisk(from bsd: String) -> String? {
        guard let match = bsd.range(of: #"^disk\d+"#, options: .regularExpression) else { return nil }
        return String(bsd[match])
    }
}

private struct DiskUtilExternalList {
    let entries: [[String: Any]]

    static func load(timeout: TimeInterval? = 5.0) -> DiskUtilExternalList? {
        let result = ProcessRunner.run(executable: "/usr/sbin/diskutil",
                                       arguments: ["list", "-plist", "external"],
                                       timeout: timeout)
        guard result.success else {
            log.error("diskutil list -plist external failed: \(result.errorMessage ?? "?", privacy: .public)")
            return nil
        }
        guard let plist = try? PropertyListSerialization
                .propertyList(from: result.stdout, format: nil) as? [String: Any],
              let entries = plist["AllDisksAndPartitions"] as? [[String: Any]]
        else { return nil }
        return DiskUtilExternalList(entries: entries)
    }

    static func userVolumes(in entry: [String: Any]) -> [DiskUtilExternalVolume] {
        var volumes: [DiskUtilExternalVolume] = []
        appendVolume(from: entry, to: &volumes)

        if let parts = entry["Partitions"] as? [[String: Any]] {
            for part in parts {
                appendVolume(from: part, to: &volumes)
            }
        }

        if let apfsVolumes = entry["APFSVolumes"] as? [[String: Any]] {
            for volume in apfsVolumes {
                appendVolume(from: volume, to: &volumes)
            }
        }

        return volumes
    }

    static func info(for bsd: String,
                     cache: inout [String: [String: Any]],
                     timeout: TimeInterval? = 3.0) -> [String: Any]? {
        if let cached = cache[bsd] { return cached }
        guard let info = DiskUtilInfo.plist(for: bsd, timeout: timeout) else { return nil }
        cache[bsd] = info
        return info
    }

    static func isDiskImage(entry: [String: Any],
                            cache: inout [String: [String: Any]],
                            timeout: TimeInterval? = 1.0) -> Bool {
        guard let bsd = entry["DeviceIdentifier"] as? String,
              let info = info(for: bsd, cache: &cache, timeout: timeout)
        else { return false }
        return DiskUtilInfo.busProtocol(in: info) == "Disk Image"
    }

    private static func appendVolume(from dict: [String: Any], to volumes: inout [DiskUtilExternalVolume]) {
        if let content = dict["Content"] as? String, SystemVolumeFilter.contents.contains(content) { return }
        guard let name = dict["VolumeName"] as? String,
              !name.isEmpty,
              !SystemVolumeFilter.names.contains(name)
        else { return }

        volumes.append(DiskUtilExternalVolume(name: name,
                                              mountPoint: dict["MountPoint"] as? String,
                                              volumeUUID: dict["VolumeUUID"] as? String))
    }
}

private struct DiskMenuSnapshot {
    let drives: [ExternalDrive]
    let unmounted: [UnmountedExternal]
    let createdAt: Date
    let refreshError: String?

    /// DA 인벤토리 경로 — 준비돼 있으면 즉시 (<1ms, in-memory 복사) 반환, 미준비면 nil.
    /// menuWillOpen 의 동기 즉시 로드 경로가 직접 호출 (placeholder 행 생략용 — 그쪽 주석 참조).
    static func loadFromDA() -> DiskMenuSnapshot? {
        guard let inv = DAInventory.shared.snapshot() else { return nil }
        log.info("DiskMenuSnapshot.load: DA drives=\(inv.drives.map { $0.name }, privacy: .public) unmounted=\(inv.unmounted.map { $0.displayName }, privacy: .public)")
        return DiskMenuSnapshot(drives: sortedForMenu(inv.drives),
                                unmounted: sortedForMenu(inv.unmounted),
                                createdAt: Date(),
                                refreshError: nil)
    }

    static func load() -> DiskMenuSnapshot {
        let started = Date()

        // 1) 가장 빠르고 안정적: DA 이벤트 기반 인벤토리 (in-process, 외부 daemon 비의존).
        //    SD 카드 삽입 등으로 storagekitd 가 막혀도 영향 없음.
        if let snapshot = loadFromDA() {
            return snapshot
        }

        // 2) DA 인벤토리 미준비 (cold start) → 기존 diskutil 경로로 fallback.
        let diskList = DiskUtilExternalList.load()
        let drives: [ExternalDrive]
        let unmounted: [UnmountedExternal]
        let refreshError: String?

        if let diskList {
            let mounted = ExternalDrive.list(fromExternalDiskList: diskList)
            drives = mounted.drives
            unmounted = UnmountedExternal.list(fromExternalDiskList: diskList,
                                               knownMountedBSDs: mounted.mountedWholeDiskBSDs)
            refreshError = nil
        } else {
            // 3) diskutil 도 timeout → mountedVolumeURLs 만으로 최선 표시.
            drives = ExternalDrive.listFromMountedVolumes()
            unmounted = []
            refreshError = drives.isEmpty ? "diskutil list -plist external failed or timed out" : nil
            if !drives.isEmpty {
                log.notice("DiskMenuSnapshot.load: diskutil external list failed; using mounted volume fallback drives=\(drives.map { $0.name }, privacy: .public)")
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        log.info("DiskMenuSnapshot.load: diskutil \(String(format: "%.3f", elapsed), privacy: .public)s drives=\(drives.map { $0.name }, privacy: .public) unmounted=\(unmounted.map { $0.displayName }, privacy: .public) refreshError=\(refreshError ?? "-", privacy: .public)")
        return DiskMenuSnapshot(drives: sortedForMenu(drives),
                                unmounted: sortedForMenu(unmounted),
                                createdAt: Date(),
                                refreshError: refreshError)
    }

    /// 메뉴 표시 순서 — 이름 기준 정렬로 통일. DA 인벤토리는 Dictionary 기반이라 순서가
    /// 비결정적이어서 메뉴를 열 때마다 항목이 뒤섞일 수 있고, cold start 의 diskutil 경로와도
    /// 순서가 어긋난다 (DA ready 전환 시 항목 점프). 양쪽 모두 여기서 정렬.
    private static func sortedForMenu(_ drives: [ExternalDrive]) -> [ExternalDrive] {
        drives.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func sortedForMenu(_ unmounted: [UnmountedExternal]) -> [UnmountedExternal] {
        unmounted.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

private struct DiskMenuSnapshotCacheState {
    let snapshot: DiskMenuSnapshot
    let isRefreshing: Bool
}

private enum DiskMenuSnapshotCache {
    private static let lock = NSLock()
    private static var cached: DiskMenuSnapshot?
    private static var refreshing = false
    private static var refreshRequested = false
    private static var refreshCompletions: [(DiskMenuSnapshot) -> Void] = []
    private static let maxAge: TimeInterval = 5.0

    static func currentForMenu(onRefresh: @escaping (DiskMenuSnapshot) -> Void) -> DiskMenuSnapshotCacheState {
        lock.lock()
        if let snapshot = cached {
            let stale = refreshRequested || Date().timeIntervalSince(snapshot.createdAt) > maxAge
            guard stale else {
                lock.unlock()
                return DiskMenuSnapshotCacheState(snapshot: snapshot, isRefreshing: false)
            }

            refreshCompletions.append(onRefresh)
            let shouldRefresh = !refreshing
            if shouldRefresh {
                refreshing = true
                refreshRequested = false
            }
            lock.unlock()

            if shouldRefresh {
                refreshAsyncAlreadyMarked()
            }
            return DiskMenuSnapshotCacheState(snapshot: snapshot, isRefreshing: true)
        }

        refreshCompletions.append(onRefresh)
        let shouldRefresh = !refreshing
        if shouldRefresh {
            refreshing = true
            refreshRequested = false
        }
        lock.unlock()

        if shouldRefresh {
            refreshAsyncAlreadyMarked()
        }
        return DiskMenuSnapshotCacheState(snapshot: DiskMenuSnapshot(drives: [],
                                                                     unmounted: [],
                                                                     createdAt: Date(),
                                                                     refreshError: nil),
                                          isRefreshing: true)
    }

    /// menuWillOpen 전용 동기 즉시 경로. fresh 캐시 또는 DA 인벤토리 (즉시 로드 가능) 가 있으면
    /// snapshot 을 반환하고, 둘 다 없으면 (cold start — diskutil 로드는 느림) nil → async 경로로.
    ///
    /// 존재 이유: async 경로는 "Updating Disk Status…" placeholder 행을 먼저 그리고 refresh
    /// 완료 후 열려 있는 메뉴를 다시 채우는데, macOS 26 의 메뉴 창은 열린 채 항목이 줄어도
    /// 높이를 반납하지 않아 마지막 항목 아래 placeholder 한 칸이 빈 공간으로 남는다.
    /// DA 로드는 <1ms 라 placeholder 가 애초에 불필요 — 한 번만 populate 해서 잔상을 없앤다.
    static func currentIfInstant() -> DiskMenuSnapshot? {
        lock.lock()
        if let snapshot = cached,
           !refreshRequested,
           Date().timeIntervalSince(snapshot.createdAt) <= maxAge {
            lock.unlock()
            return snapshot
        }
        // claim 의미론은 async 경로와 동일 — load *시작* 전에 clear 해야 load 도중 도착한
        // invalidate 가 살아남는다 (아래 `refreshRequested` 주석 참조).
        let wasRequested = refreshRequested
        refreshRequested = false
        lock.unlock()

        guard let fresh = DiskMenuSnapshot.loadFromDA() else {
            // DA 미준비 → 로드 안 했으니 claim 반납. OR 누적 — 그 사이 도착한 invalidate 를
            // 덮어쓰지 않도록 켜는 방향으로만 복원.
            lock.lock()
            refreshRequested = refreshRequested || wasRequested
            lock.unlock()
            return nil
        }
        lock.lock()
        cached = fresh
        lock.unlock()
        return fresh
    }

    /// `refreshRequested` 는 "마지막 refresh 가 *시작*된 이후 invalidate 됐다" 는 뜻 —
    /// refresh 를 시작(claim)하는 시점에만 clear 하고 완료 시점엔 건드리지 않는다.
    /// 완료 시점에 clear 하면 load 도중 도착한 invalidate (eject/mount 직후) 가 지워져,
    /// 방금 추출한 디스크가 든 낡은 스냅샷이 최대 maxAge 동안 fresh 로 오인된다.
    static func current() -> DiskMenuSnapshot {
        lock.lock()
        if let snapshot = cached {
            let stale = refreshRequested || Date().timeIntervalSince(snapshot.createdAt) > maxAge
            guard stale else {
                lock.unlock()
                return snapshot
            }

            let ownsRefresh = !refreshing
            if ownsRefresh {
                refreshing = true
                refreshRequested = false
            }
            lock.unlock()

            log.info("DiskMenuSnapshotCache.current: cached snapshot stale, refreshing synchronously")
            let fresh = DiskMenuSnapshot.load()
            var completions: [(DiskMenuSnapshot) -> Void] = []
            lock.lock()
            cached = fresh
            if ownsRefresh {
                refreshing = false
                // refresh 를 우리가 소유한 동안 쌓인 메뉴 콜백도 우리가 해소 — 남겨 두면
                // 비동기 refresh 가 없어 메뉴가 "Updating Disk Status…" 에 갇힌다.
                completions = refreshCompletions
                refreshCompletions = []
            }
            lock.unlock()
            for completion in completions {
                DispatchQueue.main.async { completion(fresh) }
            }
            return fresh
        }

        if refreshing {
            lock.unlock()
            log.info("DiskMenuSnapshotCache.current: initial refresh in progress, loading synchronously")
            let fresh = DiskMenuSnapshot.load()
            lock.lock()
            cached = fresh
            lock.unlock()
            return fresh
        }
        refreshing = true
        refreshRequested = false
        lock.unlock()

        let snapshot = DiskMenuSnapshot.load()
        lock.lock()
        cached = snapshot
        refreshing = false
        let completions = refreshCompletions
        refreshCompletions = []
        lock.unlock()
        for completion in completions {
            DispatchQueue.main.async { completion(snapshot) }
        }
        return snapshot
    }

    static func warm() {
        lock.lock()
        guard !refreshing else {
            lock.unlock()
            return
        }
        refreshing = true
        refreshRequested = false   // claim 시점 clear — current() 와 같은 규약
        lock.unlock()
        refreshAsyncAlreadyMarked()
    }

    static func invalidate() {
        lock.lock()
        refreshRequested = true
        lock.unlock()
    }

    private static func refreshAsyncAlreadyMarked() {
        DispatchQueue.global(qos: .utility).async {
            let snapshot = DiskMenuSnapshot.load()
            let completions: [(DiskMenuSnapshot) -> Void]
            lock.lock()
            if snapshot.refreshError == nil || cached == nil {
                cached = snapshot
            } else if let existing = cached {
                cached = DiskMenuSnapshot(drives: existing.drives,
                                          unmounted: existing.unmounted,
                                          createdAt: Date(),
                                          refreshError: snapshot.refreshError)
            }
            refreshing = false
            // refreshRequested 는 여기서 clear 하지 않는다 — load 도중 invalidate 가 도착했으면
            // true 로 남아 다음 접근에서 다시 refresh 된다 (claim 시점 clear 규약).
            completions = refreshCompletions
            refreshCompletions = []
            let callbackSnapshot = cached ?? snapshot
            lock.unlock()
            for completion in completions {
                DispatchQueue.main.async {
                    completion(callbackSnapshot)
                }
            }
        }
    }
}

// MARK: - External Drive Detection

enum ExternalDeviceKind {
    case disk

    var symbolName: String {
        "externaldrive"
    }

    var unmountedSymbolName: String {
        "externaldrive.badge.plus"
    }
}

private struct MountedExternalDrives {
    let drives: [ExternalDrive]
    let mountedWholeDiskBSDs: Set<String>
}

struct ExternalDrive {
    let name: String
    let url: URL
    let kind: ExternalDeviceKind
    /// Volume UUID — Per-disk 설정 (ExcludedVolumes 등) 의 안정적 식별자.
    /// BSD/이름은 케이블/슬롯 변경에 따라 변하지만 UUID 는 디스크 파일시스템에 박혀있음.
    let volumeUUID: String?
    /// Time Machine 백업 디스크인지 여부. 자동 추출 default 제외 대상.
    let isTimeMachine: Bool

    fileprivate static func list(fromExternalDiskList diskList: DiskUtilExternalList) -> MountedExternalDrives {
        let fm = FileManager.default
        let diskImageMountPaths = DiskImages.mountedPathsOrNil()
        var infoCache: [String: [String: Any]] = [:]
        var drives: [ExternalDrive] = []
        var mountedWholeDiskBSDs = Set<String>()

        for entry in diskList.entries {
            guard let bsd = entry["DeviceIdentifier"] as? String else { continue }
            let isInternal = entry["OSInternal"] as? Bool ?? false
            if isInternal {
                let info = DiskUtilExternalList.info(for: bsd, cache: &infoCache)
                guard DiskUtilInfo.shouldIncludeAsExternalMedia(info, isInternal: true) else { continue }
            }
            if diskImageMountPaths == nil,
               DiskUtilExternalList.isDiskImage(entry: entry, cache: &infoCache) {
                log.debug("filter: disk image entry excluded bsd=\(bsd, privacy: .public)")
                continue
            }

            for volume in DiskUtilExternalList.userVolumes(in: entry) {
                guard let mountPoint = volume.mountPoint, !mountPoint.isEmpty else { continue }
                guard !(diskImageMountPaths?.contains(mountPoint) ?? false),
                      !DiskImages.isKnownDiskImageMountPath(mountPoint)
                else {
                    log.debug("filter: disk image mount excluded \(mountPoint, privacy: .public)")
                    continue
                }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: mountPoint, isDirectory: &isDir), isDir.boolValue else { continue }

                let url = URL(fileURLWithPath: mountPoint)
                drives.append(ExternalDrive(name: volume.name,
                                            url: url,
                                            kind: .disk,
                                            volumeUUID: volume.volumeUUID,
                                            isTimeMachine: isTimeMachineDisk(volumeURL: url)))
                mountedWholeDiskBSDs.insert(bsd)
            }
        }

        // `diskutil list -plist external` 은 built-in SDXC reader(내장 SDXC 리더)를
        // Internal 로 분류해 결과에서 제외한다. mountedVolumeURLs 에서 Secure Digital 이며
        // removable/ejectable 인 볼륨만 보충해 내장 SSD 제외 동작은 그대로 보존한다.
        var knownPaths = Set(drives.map { $0.url.standardizedFileURL.path })
        for drive in listInternalSecureDigitalFromMountedVolumes() {
            let path = drive.url.standardizedFileURL.path
            guard knownPaths.insert(path).inserted else { continue }
            drives.append(drive)
            if let bsd = drive.wholeDiskBSDName {
                mountedWholeDiskBSDs.insert(bsd)
            }
        }

        return MountedExternalDrives(drives: drives, mountedWholeDiskBSDs: mountedWholeDiskBSDs)
    }

    static func list() -> [ExternalDrive] {
        if let diskList = DiskUtilExternalList.load() {
            return list(fromExternalDiskList: diskList).drives
        }

        return listFromMountedVolumes()
    }

    fileprivate static func listFromMountedVolumes() -> [ExternalDrive] {
        let dmgPaths = DiskImages.mountedPathsOrNil()
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeUUIDStringKey,
            .volumeIsInternalKey,
            .volumeIsBrowsableKey,
            .volumeIsLocalKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [] }

        var drives: [ExternalDrive] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let isInternal  = v.volumeIsInternal  ?? false
            let isBrowsable = v.volumeIsBrowsable ?? false
            let isLocal     = v.volumeIsLocal     ?? false
            guard isBrowsable, isLocal else { continue }
            if isInternal, !isSupportedInternalSecureDigitalVolume(at: url) { continue }
            // DMG / sparseimage 제외 — Chrome.dmg 같은 마운트된 디스크 이미지가 같이 빠지면 사고
            guard !(dmgPaths?.contains(url.path) ?? false),
                  !DiskImages.isKnownDiskImageMountPath(url.path)
            else {
                log.debug("filter: DMG excluded \(url.path, privacy: .public)")
                continue
            }
            if dmgPaths == nil,
               DiskUtilInfo.busProtocol(in: DiskUtilInfo.plist(for: url.path, timeout: 1.0)) == "Disk Image" {
                log.debug("filter: disk image fallback excluded \(url.path, privacy: .public)")
                continue
            }
            let name = v.volumeName ?? url.lastPathComponent
            let isTM = isTimeMachineDisk(volumeURL: url)
            // diskutil 인벤토리 실패 fallback 에서도 Volume UUID 를 채워 ExcludedVolumes 매칭 /
            // autoExclude 영속화가 동작하게 한다 (예전엔 nil → 제외 무효화로 TM 오추출 위험).
            drives.append(ExternalDrive(name: name, url: url,
                                        kind: .disk,
                                        volumeUUID: v.volumeUUIDString,
                                        isTimeMachine: isTM))
        }
        return drives
    }

    /// `diskutil list -plist external` 에 나오지 않는 내장 SDXC reader 매체만 보충한다.
    /// Secure Digital + removable/ejectable 조건을 모두 통과해야 하므로 내장 SSD/시스템 볼륨은 제외된다.
    private static func listInternalSecureDigitalFromMountedVolumes() -> [ExternalDrive] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeUUIDStringKey,
            .volumeIsInternalKey,
            .volumeIsBrowsableKey,
            .volumeIsLocalKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [] }

        var drives: [ExternalDrive] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsInternal == true,
                  values.volumeIsBrowsable == true,
                  values.volumeIsLocal == true
            else { continue }
            guard isSupportedInternalSecureDigitalVolume(at: url) else { continue }

            drives.append(ExternalDrive(
                name: values.volumeName ?? url.lastPathComponent,
                url: url,
                kind: .disk,
                volumeUUID: values.volumeUUIDString,
                isTimeMachine: isTimeMachineDisk(volumeURL: url)
            ))
        }
        return drives
    }

    /// DA inventory(인벤토리)가 준비됐으면 외부 daemon 호출 없이 판정한다.
    /// 아직 준비 전이거나 삽입 race(경쟁 상태)로 경로가 없을 때만 diskutil fallback 을 쓴다.
    private static func isSupportedInternalSecureDigitalVolume(at url: URL) -> Bool {
        if let decision = DAInventory.shared.shouldIncludeMountedInternalMedia(at: url.path) {
            return decision
        }
        let info = DiskUtilInfo.plist(for: url.path, timeout: 1.0)
        return DiskUtilInfo.shouldIncludeAsExternalMedia(info, isInternal: true)
    }

    /// Time Machine 백업 디스크 식별 — file 존재 검사만.
    /// - APFS Time Machine: 루트의 `.com.apple.timemachine.donotpresent` 파일
    /// - Legacy HFS+: `Backups.backupdb/` 디렉토리
    fileprivate static func isTimeMachineDisk(volumeURL: URL) -> Bool {
        let fm = FileManager.default
        let marker1 = volumeURL.appendingPathComponent(".com.apple.timemachine.donotpresent")
        if fm.fileExists(atPath: marker1.path) { return true }

        let marker2 = volumeURL.appendingPathComponent("Backups.backupdb")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: marker2.path, isDirectory: &isDir), isDir.boolValue {
            return true
        }
        return false
    }

    /// volume URL → whole disk BSD name. 예: /Volumes/SYSJO → "disk2"
    ///
    /// 재마운트용 식별자. statfs 의 `f_mntfromname` (예: "/dev/disk2s1") 에서
    /// partition suffix 제거해 whole disk 만 추출. `diskutil mountDisk <bsd>` 로
    /// 해당 디스크의 모든 마운트 가능한 partition 을 한 번에 mount 가능.
    var wholeDiskBSDName: String? {
        var stat = statfs()
        guard statfs(url.path, &stat) == 0 else { return nil }
        let dev = withUnsafeBytes(of: &stat.f_mntfromname) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        // "/dev/disk2s1" → "disk2"
        guard dev.hasPrefix("/dev/") else { return nil }
        let bsd = String(dev.dropFirst("/dev/".count))
        return BSDName.wholeDisk(from: bsd)
    }
}

// MARK: - Unmounted External Detection

/// 꽂혀있는데 마운트 안 된 외장 디스크.
/// 사용자가 추출 후 케이블 그대로 두거나, macOS 가 wake 후 자동 mount 못 한 경우.
struct UnmountedExternal {
    /// whole disk BSD name. 예: "disk2"
    let bsdName: String
    /// 표시용 이름. VolumeName 이 있으면 그것, 없으면 BSD.
    let displayName: String
    let kind: ExternalDeviceKind

    /// `diskutil list -plist external` + `ExternalDrive.list()` 비교로 unmounted 외장 검출.
    ///
    /// **로직**:
    /// 1. 현재 마운트된 외장의 whole disk BSD set 수집 (`ExternalDrive.list()` 의 wholeDiskBSDName)
    /// 2. `diskutil list -plist external` 의 모든 OSInternal=false whole disk entry 검사
    /// 3. mountedBSDs 에 없는 entry 중 mountable sub-volume(VolumeName 있는 partition/APFSVolume) 가
    ///    하나라도 있는 것만 후보. RAID 멤버 디스크 같은 건 자동 제외.
    static func list(knownMountedBSDs: Set<String>? = nil) -> [UnmountedExternal] {
        let mountedBSDs: Set<String>
        if let knownMountedBSDs {
            mountedBSDs = knownMountedBSDs
        } else {
            mountedBSDs = Set(ExternalDrive.list().compactMap { $0.wholeDiskBSDName })
        }

        guard let diskList = DiskUtilExternalList.load() else { return [] }
        return list(fromExternalDiskList: diskList, knownMountedBSDs: mountedBSDs)
    }

    fileprivate static func list(fromExternalDiskList diskList: DiskUtilExternalList,
                                 knownMountedBSDs mountedBSDs: Set<String>) -> [UnmountedExternal] {
        var unmounted: [UnmountedExternal] = []
        for entry in diskList.entries {
            guard let bsd = entry["DeviceIdentifier"] as? String else { continue }
            if let internalFlag = entry["OSInternal"] as? Bool, internalFlag { continue }
            if mountedBSDs.contains(bsd) { continue }

            let volumes = DiskUtilExternalList.userVolumes(in: entry)
            guard !volumes.contains(where: { ($0.mountPoint ?? "").isEmpty == false }),
                  let volume = volumes.first
            else { continue }

            unmounted.append(UnmountedExternal(bsdName: bsd, displayName: volume.name, kind: .disk))
        }
        log.info("UnmountedExternal.list: found \(unmounted.count, privacy: .public) candidates = \(unmounted.map { "\($0.displayName)(\($0.bsdName))" }, privacy: .public)")
        return unmounted
    }

}

// MARK: - DA-Event-Driven Disk Inventory

/// 외장 디스크 인벤토리 — DiskArbitration 콜백으로 실시간 갱신하는 in-process 캐시.
///
/// **목적**: `diskutil list -plist external` shellout 제거. SD 카드 등 새 디스크 삽입 직후
/// macOS 의 `storagekitd` 가 프로빙으로 바빠 `diskutil` 호출이 3초 timeout 나는 문제 회피.
/// DA 콜백은 외부 daemon 의존성 없이 in-process 로 도착해 SD 인덱싱과 무관하게 즉시 반영.
///
/// 사용:
/// - 앱 launch 시 `start()` 1회 호출 (DA 세션 등록 + 기존 디스크 enumeration).
/// - `snapshot()` — mounted/unmounted 외장 목록. ready 전엔 nil → 호출자가 diskutil fallback.
/// - `isVolumePresent(at:)` — legacy manual eject 의 중복 volume 결과 보정용 조회.
private enum DAInventoryChange {
    case mountedExternal
    /// Request-time authoritative reconciliation found a topology/protection change before the
    /// normal DA callback could advertise it. Lid-closed safety must schedule a fresh inventory.
    case safetyRefreshRequired
    case other
}

private final class DAInventory {
    static let shared = DAInventory()

    private struct PendingApprovedMount {
        let wholeDiskBSD: String
        let mediaRegistryEntryID: UInt64?
        let volumeRegistryEntryID: UInt64?
        let isExternalCandidate: Bool
    }

    private struct DiskInfo {
        let bsd: String
        let wholeDiskBSD: String
        let mediaRegistryEntryID: UInt64?
        let isWholeDisk: Bool
        let isInternal: Bool
        let isRemovable: Bool?
        let isEjectable: Bool?
        let busProtocol: String?
        let mountPath: String?
        let volumeName: String?
        let volumeUUID: String?
        let mediaContent: String?
    }

    private let lock = NSLock()
    private var disks: [String: DiskInfo] = [:]
    private var ready = false
    private var session: DASession?
    private let queue = DispatchQueue(label: "com.yongza.ejectdrives.da-inventory", qos: .utility)
    /// DA queue 전용 상태. BSD 이름은 재연결 시 재사용될 수 있으므로 appearance generation 과
    /// 함께 식별하고, 같은 physical generation 에는 unmount 요청을 하나만 둔다.
    private var nextPhysicalGeneration: UInt64 = 0
    private var physicalGenerations: [String: UInt64] = [:]
    private var physicalRegistryEntryIDs: [String: UInt64] = [:]
    private var pendingSleepUnmounts: [SleepDAPhysicalToken: PendingSleepDAUnmount] = [:]
    private var pendingWakeMounts: [SleepDAPhysicalToken: PendingSleepDAMount] = [:]
    /// Same normal request를 join한 waiter별 force-continuation reservation. A single waiter
    /// timeout must not cancel another waiter's sequential force handoff.
    private var forceContinuationReservations: [SleepDAPhysicalToken: SleepForceContinuationReservationCounter] = [:]
    /// Automatic whole-disk unmount의 보호 snapshot과 실제 request 사이에 sibling mount가
    /// 끼어들지 못하게 하는 DA approval barrier. Queue-confined state이다.
    private var blockedSleepUnmountMounts: [String: SleepDAPhysicalToken] = [:]
    /// Mount approval은 끝났지만 mounted description callback은 아직 오지 않은 볼륨.
    /// 이 창의 snapshot은 incomplete일 수 있으므로 automatic unmount를 fail closed한다.
    private var pendingApprovedMounts: [String: PendingApprovedMount] = [:]
    private let pendingApprovedMountCondition = NSCondition()
    private var pendingApprovedMountSequence: UInt64 = 0
    /// `willSleep`부터 matching wake/cancel까지 새 external mount가 snapshot/ACK 경계를
    /// 추월하지 못하게 한다. DA serial queue에서만 변경한다.
    private var powerSleepMountBarrier = SleepPowerMountBarrier()

    /// 인벤토리의 마운트 상태가 바뀔 때마다 호출 (디스크 appeared/disappeared/mount 경로 변경).
    /// **DA 큐에서 호출됨** — consumer 가 main hop + debounce 처리할 것.
    /// count 와 무관한 description 변경에는 호출 안 함 (mount 경로 변화만 트리거).
    var onInventoryChanged: ((DAInventoryChange) -> Void)?

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func flushPendingEvents() {
        queue.sync {}
    }

    func beginSleepProtectionMountBarrier() -> UInt64 {
        var token: UInt64 = 0
        queue.sync {
            token = powerSleepMountBarrier.begin()
        }
        return token
    }

    func endSleepProtectionMountBarrier(token: UInt64) {
        queue.sync {
            powerSleepMountBarrier.end(token: token)
        }
    }

    private func startOnQueue() {
        guard session == nil else { return }
        guard let s = DASessionCreate(kCFAllocatorDefault) else {
            log.error("DAInventory: DASessionCreate failed")
            return
        }
        session = s

        let ctx = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(s, nil, { (disk, ctx) in
            guard let ctx else { return }
            let inv = Unmanaged<DAInventory>.fromOpaque(ctx).takeUnretainedValue()
            inv.handleAppearedOrChanged(disk: disk, kind: "appeared")
        }, ctx)

        DARegisterDiskDisappearedCallback(s, nil, { (disk, ctx) in
            guard let ctx else { return }
            let inv = Unmanaged<DAInventory>.fromOpaque(ctx).takeUnretainedValue()
            inv.handleDisappeared(disk: disk)
        }, ctx)

        DARegisterDiskDescriptionChangedCallback(s, nil, nil, { (disk, _, ctx) in
            guard let ctx else { return }
            let inv = Unmanaged<DAInventory>.fromOpaque(ctx).takeUnretainedValue()
            inv.handleAppearedOrChanged(disk: disk, kind: "changed")
        }, ctx)

        DARegisterDiskMountApprovalCallback(s, nil, { (disk, ctx) -> Unmanaged<DADissenter>? in
            guard let ctx else { return nil }
            let inv = Unmanaged<DAInventory>.fromOpaque(ctx).takeUnretainedValue()
            guard let dissenter = inv.handleMountApproval(disk: disk) else { return nil }
            return Unmanaged.passRetained(dissenter)
        }, ctx)

        // Register every observer/approver before scheduling the session. Scheduling first leaves
        // a startup window where an approval can pass without entering the pending ledger.
        DASessionSetDispatchQueue(s, queue)

        // DA 는 등록 직후 모든 기존 disk 에 대해 appeared 이벤트를 즉시 보낸다.
        // 0.5s 후 ready 마킹 — 그 전엔 snapshot() 이 nil 반환해 호출자가 diskutil fallback 으로.
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.markReady()
        }
        log.notice("DAInventory: started")
    }

    private func markReady() {
        lock.lock()
        let count = disks.count
        let mounted = disks.values.filter { $0.mountPath != nil }.count
        ready = true
        lock.unlock()
        log.notice("DAInventory: ready disks=\(count, privacy: .public) mounted=\(mounted, privacy: .public)")
    }

    private func handleAppearedOrChanged(disk: DADisk, kind: String) {
        guard let info = parseDescription(disk: disk) else { return }
        if info.mountPath != nil {
            if let pending = pendingApprovedMounts[info.bsd],
               pending.volumeRegistryEntryID == nil
                    || pending.volumeRegistryEntryID == info.mediaRegistryEntryID {
                pendingApprovedMounts.removeValue(forKey: info.bsd)
                signalPendingApprovedMountChange()
            }
        }
        lock.lock()
        let prevMount = disks[info.bsd]?.mountPath
        disks[info.bsd] = info
        lock.unlock()
        _ = bindCurrentPhysicalIdentityOnQueue(info.wholeDiskBSD)
        if prevMount != info.mountPath {
            log.info("DAInventory: \(kind, privacy: .public) bsd=\(info.bsd, privacy: .public) name=\(info.volumeName ?? "-", privacy: .public) mount=\(info.mountPath ?? "-", privacy: .public) was=\(prevMount ?? "-", privacy: .public) protocol=\(info.busProtocol ?? "-", privacy: .public) internal=\(info.isInternal, privacy: .public)")
            let mountedExternal = prevMount == nil
                && info.mountPath != nil
                && ExternalMediaPolicy.shouldInclude(
                    isInternal: info.isInternal,
                    busProtocol: info.busProtocol,
                    isRemovable: info.isRemovable,
                    isEjectable: info.isEjectable
                )
                && info.busProtocol != "Disk Image"
                && info.busProtocol != "Virtual Interface"
            onInventoryChanged?(mountedExternal ? .mountedExternal : .other)
        } else {
            log.debug("DAInventory: \(kind, privacy: .public) bsd=\(info.bsd, privacy: .public) name=\(info.volumeName ?? "-", privacy: .public) mount=\(info.mountPath ?? "-", privacy: .public)")
        }
    }

    /// Disk Arbitration mount approval callback. A whole-disk automatic unmount owns an exact
    /// physical token until its real callback/disconnect terminal; while owned, a sibling mount
    /// would invalidate the protection closure and is rejected before it can change the topology.
    private func handleMountApproval(disk: DADisk) -> DADissenter? {
        guard let bsdPointer = DADiskGetBSDName(disk) else { return nil }
        let bsd = String(cString: bsdPointer)
        let info = parseDescription(disk: disk)
        let wholeBSD = info?.wholeDiskBSD ?? BSDName.wholeDisk(from: bsd) ?? bsd
        let isExternalCandidate = info.map { diskInfo in
            ExternalMediaPolicy.shouldInclude(
                isInternal: diskInfo.isInternal,
                busProtocol: diskInfo.busProtocol,
                isRemovable: diskInfo.isRemovable,
                isEjectable: diskInfo.isEjectable
            )
                && diskInfo.busProtocol != "Disk Image"
                && diskInfo.busProtocol != "Virtual Interface"
        } ?? true

        // A reused diskN must not inherit the old media's barrier. Bind the current exact whole
        // IOMedia first; replacement binding invalidates the old token and its request.
        _ = bindCurrentPhysicalIdentityOnQueue(wholeBSD)

        let blocked = blockedSleepUnmountMounts[wholeBSD]
        let powerBlocked = info?.mountPath == nil
            && powerSleepMountBarrier.blocks(isExternalCandidate: isExternalCandidate)
        switch SleepMountApprovalPolicy.decision(
            hasActiveUnmountBarrier: blocked != nil,
            hasPowerSleepBarrier: powerBlocked,
            isExternalCandidate: isExternalCandidate,
            mediaContent: info?.mediaContent,
            volumeAlreadyMounted: info?.mountPath != nil
        ) {
        case .rejectBusy:
            if let blocked {
                log.error("DAInventory: mount approval rejected during automatic unmount bsd=\(bsd, privacy: .public) whole=\(wholeBSD, privacy: .public) generation=\(blocked.generation, privacy: .public)")
            } else {
                log.error("DAInventory: external mount approval rejected across power-sleep boundary bsd=\(bsd, privacy: .public) whole=\(wholeBSD, privacy: .public)")
            }
            return DADissenterCreate(
                kCFAllocatorDefault,
                DAReturn(kDAReturnBusy),
                "DiskOUT automatic sleep protection in progress" as CFString
            )
        case .approveAndTrackPending:
            pendingApprovedMounts[bsd] = PendingApprovedMount(
                wholeDiskBSD: wholeBSD,
                mediaRegistryEntryID: currentWholeMediaRegistryEntryIDOnQueue(wholeBSD),
                volumeRegistryEntryID: info?.mediaRegistryEntryID,
                isExternalCandidate: isExternalCandidate
            )
            signalPendingApprovedMountChange()
            if isExternalCandidate {
                // The approval itself is the earliest topology-change edge. Waiting for the later
                // mounted description leaves a snapshot→ACK race in Amphetamine closed-awake mode.
                onInventoryChanged?(.safetyRefreshRequired)
            }
            log.debug("DAInventory: mount approval pending bsd=\(bsd, privacy: .public) whole=\(wholeBSD, privacy: .public)")
            return nil
        case .approve:
            if info?.mountPath == nil,
               isExternalCandidate,
               info?.mediaContent == "EFI" {
                log.info("DAInventory: mount approval approved without pending bsd=\(bsd, privacy: .public) whole=\(wholeBSD, privacy: .public) reason=external-efi")
            }
            // A mounted volume cannot add an unseen sibling. External EFI is already excluded from
            // eject targets and may receive approval without a later mounted callback.
            return nil
        }
    }

    private func signalPendingApprovedMountChange() {
        pendingApprovedMountCondition.lock()
        pendingApprovedMountSequence &+= 1
        pendingApprovedMountCondition.broadcast()
        pendingApprovedMountCondition.unlock()
    }

    private func pendingApprovedMountSequenceSnapshot() -> UInt64 {
        pendingApprovedMountCondition.lock()
        defer { pendingApprovedMountCondition.unlock() }
        return pendingApprovedMountSequence
    }

    private func waitForPendingApprovedMountChange(after sequence: UInt64,
                                                   timeout: TimeInterval) {
        pendingApprovedMountCondition.lock()
        if pendingApprovedMountSequence == sequence, timeout > 0 {
            _ = pendingApprovedMountCondition.wait(
                until: Date().addingTimeInterval(timeout)
            )
        }
        pendingApprovedMountCondition.unlock()
    }

    private func handleDisappeared(disk: DADisk) {
        guard let bsdC = DADiskGetBSDName(disk) else { return }
        let bsd = String(cString: bsdC)
        let disappearedVolumeEntryID = mediaRegistryEntryID(for: disk)
        lock.lock()
        let removed = disks.removeValue(forKey: bsd)
        let wholeBSD = removed?.wholeDiskBSD ?? BSDName.wholeDisk(from: bsd) ?? bsd
        let physicalStillPresent = disks.values.contains { $0.wholeDiskBSD == wholeBSD }
        lock.unlock()
        let terminalVolumeEntryID = disappearedVolumeEntryID ?? removed?.mediaRegistryEntryID
        if let pending = pendingApprovedMounts[bsd],
           pending.volumeRegistryEntryID == nil
                || pending.volumeRegistryEntryID == terminalVolumeEntryID {
            pendingApprovedMounts.removeValue(forKey: bsd)
            signalPendingApprovedMountChange()
        }
        if let generation = physicalGenerations[wholeBSD],
           let entryID = physicalRegistryEntryIDs[wholeBSD] {
            let token = SleepDAPhysicalToken(wholeDiskBSD: wholeBSD,
                                             generation: generation,
                                             mediaRegistryEntryID: entryID)
            if let request = pendingSleepUnmounts[token],
               request.finishOnce(.disconnectedBeforeCallback) {
                forceContinuationReservations.removeValue(forKey: token)
                log.error("DAInventory: sleep unmount physical media disappeared before callback target=\(request.target, privacy: .public) generation=\(generation, privacy: .public)")
            }
            if !physicalStillPresent {
                // DA callback context 가 request 를 retain 한다. Dictionary 에서는 제거해
                // 재연결된 새 generation 이 이전 요청에 합류하지 않게 한다.
                pendingSleepUnmounts.removeValue(forKey: token)
                forceContinuationReservations.removeValue(forKey: token)
                if blockedSleepUnmountMounts[wholeBSD] == token {
                    blockedSleepUnmountMounts.removeValue(forKey: wholeBSD)
                }
            }
            if !physicalStillPresent,
               let mountRequest = pendingWakeMounts[token],
               mountRequest.finishOnce(.identityChangedBeforeCallback) {
                pendingWakeMounts.removeValue(forKey: token)
                log.error("DAInventory: wake mount physical media disappeared before callback whole=\(wholeBSD, privacy: .public) generation=\(generation, privacy: .public)")
            }
        }
        if !physicalStillPresent {
            physicalGenerations.removeValue(forKey: wholeBSD)
            physicalRegistryEntryIDs.removeValue(forKey: wholeBSD)
            let pendingCount = pendingApprovedMounts.count
            pendingApprovedMounts = pendingApprovedMounts.filter {
                $0.value.wholeDiskBSD != wholeBSD
            }
            if pendingApprovedMounts.count != pendingCount {
                signalPendingApprovedMountChange()
            }
        }
        if let removed {
            log.info("DAInventory: disappeared bsd=\(bsd, privacy: .public) name=\(removed.volumeName ?? "-", privacy: .public)")
            onInventoryChanged?(.other)   // 디스크 사라짐 → consumer 가 count 재계산
        } else {
            log.debug("DAInventory: disappeared untracked bsd=\(bsd, privacy: .public) whole=\(wholeBSD, privacy: .public)")
        }
    }

    /// Sleep/lid 자동 보호 전용 unmount. Persistent serial DA session 을 사용해 callback 과
    /// disappeared 사건의 순서를 한 큐에서 판정한다. timeout 은 DA 요청 취소가 아니므로
    /// 요청은 pending 으로 남고, 같은 physical generation 의 다음 caller 는 이를 join 한다.
    func unmountForSleep(volumePath: String,
                         wholeDiskBSDName: String?,
                         expectedGeneration: UInt64?,
                         expectedMediaRegistryEntryID: UInt64?,
                         expectedMountedVolumeBSDs: Set<String>?,
                         enforceProtectionClosure: Bool,
                         force: Bool,
                         retainBarrierForForceContinuation: Bool,
                         timeout: TimeInterval,
                         operationID: String,
                         context: String) -> SleepDAUnmountWaitResult {
        var request: PendingSleepDAUnmount?
        var unavailableReason: String?

        queue.sync {
            if session == nil {
                startOnQueue()
            }
            guard let session else {
                unavailableReason = "DASession unavailable"
                return
            }

            guard let wholeBSD = wholeDiskBSDName,
                  !wholeBSD.isEmpty,
                  let expectedGeneration,
                  let expectedMediaRegistryEntryID,
                  let expectedMountedVolumeBSDs else {
                unavailableReason = "stable whole-disk identity unavailable"
                return
            }

            guard physicalGenerations[wholeBSD] == expectedGeneration,
                  currentIOMediaRegistryEntryID(bsd: wholeBSD)
                    == expectedMediaRegistryEntryID else {
                unavailableReason = "physical media identity changed before unmount"
                return
            }
            let generation = expectedGeneration
            let token = SleepDAPhysicalToken(wholeDiskBSD: wholeBSD,
                                             generation: generation,
                                             mediaRegistryEntryID: expectedMediaRegistryEntryID)

            if let existing = pendingSleepUnmounts[token] {
                blockedSleepUnmountMounts[wholeBSD] = token
                if retainBarrierForForceContinuation, !existing.force {
                    reserveForceContinuationOnQueue(token)
                }
                request = existing
                log.notice("cycle \(operationID, privacy: .public) \(context, privacy: .public) DA unmount joined pending target=\(wholeBSD, privacy: .public) generation=\(generation, privacy: .public) requestedMode=\(force ? "force" : "normal", privacy: .public) activeMode=\(existing.modeLabel, privacy: .public)")
                return
            }

            guard SleepMountApprovalPolicy.canBeginAutomaticUnmount(
                hasPendingApprovedMount: pendingApprovedMounts.values.contains { pending in
                    pending.wholeDiskBSD == wholeBSD
                        && SleepMountApprovalPolicy.pendingApprovalMatchesCapturedMedia(
                            pendingMediaRegistryEntryID: pending.mediaRegistryEntryID,
                            capturedMediaRegistryEntryID: expectedMediaRegistryEntryID
                        )
                }
            ) else {
                unavailableReason = "a mount was approved but is not yet visible in the protection snapshot"
                onInventoryChanged?(.safetyRefreshRequired)
                return
            }

            // Install the approval barrier before the final mount-table reconciliation. Mount
            // approvals queued after this point run on this same DA queue and are rejected.
            blockedSleepUnmountMounts[wholeBSD] = token
            var keepMountBarrier = false
            defer {
                if !keepMountBarrier,
                   blockedSleepUnmountMounts[wholeBSD] == token {
                    blockedSleepUnmountMounts.removeValue(forKey: wholeBSD)
                }
            }

            // Whole-disk protection closure must remain valid through request issuance. Reconcile
            // the authoritative OS mount table on this same DA queue immediately before creating
            // the request; a newly mounted sibling (protected or otherwise) invalidates the old
            // snapshot and is handled only by a fresh cycle.
            guard let mountedNow = currentMountedDiskInfosOnQueue() else {
                unavailableReason = "mounted-volume inventory could not be revalidated"
                return
            }
            let currentGroup = mountedNow.values.filter {
                $0.wholeDiskBSD == wholeBSD && $0.mountPath?.isEmpty == false
            }
            let currentMountedVolumeBSDs = Set(currentGroup.map(\.bsd))
            let protectedSiblingAppeared = currentGroup.contains { info in
                guard let path = info.mountPath else { return false }
                return ExcludedVolumes.isExcluded(info.volumeUUID)
                    || ExternalDrive.isTimeMachineDisk(volumeURL: URL(fileURLWithPath: path))
            }
            guard SleepMountedSiblingPolicy.isSnapshotStillSafe(
                expectedMountedVolumeBSDs: expectedMountedVolumeBSDs,
                currentMountedVolumeBSDs: currentMountedVolumeBSDs,
                allowMissingExpectedSiblings: force,
                enforceProtectionClosure: enforceProtectionClosure,
                hasProtectedCurrentSibling: protectedSiblingAppeared
            ) else {
                unavailableReason = currentMountedVolumeBSDs == expectedMountedVolumeBSDs
                    ? "a protected sibling is mounted on the target whole disk"
                    : "mounted sibling set changed after the protection snapshot"
                // Reconciliation has already populated `disks`, so the later DA changed callback
                // may see prevMount == mountPath and suppress `.mountedExternal`. Emit an explicit
                // safety edge now so Amphetamine CDM (no later willSleep) still runs a fresh cycle.
                onInventoryChanged?(.safetyRefreshRequired)
                return
            }

            if !force {
                // Normal request must still originate from the representative mounted volume.
                // Snapshot 이후 같은 경로에 replacement media가 붙은 경우에도 captured token과
                // 섞이지 않게 한다. Force continuation은 normal Whole이 이 representative를 이미
                // unmount한 partial-decline 경로가 있으므로 exact physical token만 검증한다.
                guard let volumeDisk = DADiskCreateFromVolumePath(
                    kCFAllocatorDefault,
                    session,
                    URL(fileURLWithPath: volumePath) as CFURL
                ),
                let currentVolume = parseDescription(disk: volumeDisk),
                currentVolume.mountPath == volumePath,
                currentVolume.wholeDiskBSD == wholeBSD else {
                    unavailableReason = "volume path no longer matches the captured whole disk"
                    return
                }
            }
            guard physicalGenerations[wholeBSD] == expectedGeneration else {
                unavailableReason = "physical disk generation changed before unmount"
                return
            }
            guard currentIOMediaRegistryEntryID(bsd: wholeBSD)
                    == expectedMediaRegistryEntryID else {
                unavailableReason = "physical media identity changed before unmount"
                return
            }

            // BSD lookup 뒤 replacement가 같은 diskN을 재사용하는 TOCTOU를 없앤다. Snapshot에서
            // 잡은 exact registry entry 자체로 DADisk를 만들고 BSD도 다시 대조한다.
            guard let matching = IORegistryEntryIDMatching(expectedMediaRegistryEntryID) else {
                unavailableReason = "IOMedia identity lookup unavailable for \(wholeBSD)"
                return
            }
            let mediaService = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            guard mediaService != 0 else {
                unavailableReason = "captured physical media is no longer present"
                return
            }
            defer { IOObjectRelease(mediaService) }
            guard let disk = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, mediaService),
                  let diskBSDPointer = DADiskGetBSDName(disk),
                  String(cString: diskBSDPointer) == wholeBSD,
                  mediaRegistryEntryID(for: disk) == expectedMediaRegistryEntryID else {
                unavailableReason = "captured physical media no longer matches \(wholeBSD)"
                return
            }

            let modeLabel = force ? "force" : "normal"
            let pending = PendingSleepDAUnmount(session: session,
                                                disk: disk,
                                                token: token,
                                                target: wholeBSD,
                                                force: force,
                                                modeLabel: modeLabel,
                                                inventory: self)
            pendingSleepUnmounts[token] = pending
            if retainBarrierForForceContinuation, !force {
                reserveForceContinuationOnQueue(token)
            }
            request = pending
            keepMountBarrier = true

            let base = force ? kDADiskUnmountOptionForce : kDADiskUnmountOptionDefault
            let options = DADiskUnmountOptions(base | kDADiskUnmountOptionWhole)
            let contextPointer = Unmanaged.passRetained(pending).toOpaque()
            log.notice("cycle \(operationID, privacy: .public) \(context, privacy: .public) DA \(modeLabel, privacy: .public) unmount start target=\(wholeBSD, privacy: .public) generation=\(generation, privacy: .public) timeout=\(String(format: "%.1f", timeout), privacy: .public)s")
            DADiskUnmount(disk, options, { (_, dissenter, contextPointer) in
                guard let contextPointer else { return }
                let pending = Unmanaged<PendingSleepDAUnmount>
                    .fromOpaque(contextPointer)
                    .takeRetainedValue()
                guard let inventory = pending.inventory else {
                    _ = pending.finishOnce(.callbackFailure(.other(0),
                                                             "DA inventory unavailable"))
                    return
                }
                inventory.finishSleepUnmountOnQueue(pending, dissenter: dissenter)
            }, contextPointer)
        }

        guard let request else {
            return .unavailable(unavailableReason ?? "DA unmount request unavailable")
        }
        let result = request.wait(timeout: timeout)
        if case .timedOutPending = result,
           retainBarrierForForceContinuation,
           !request.force {
            queue.sync {
                releaseForceContinuationReservationOnQueue(request.token)
                // Callback may have won immediately after the waiter timeout and retained the
                // barrier before this queue turn. If so, no request remains to own it.
                if pendingSleepUnmounts[request.token] !== request,
                   forceContinuationReservations[request.token] == nil,
                   blockedSleepUnmountMounts[request.token.wholeDiskBSD] == request.token {
                    blockedSleepUnmountMounts.removeValue(forKey: request.token.wholeDiskBSD)
                }
            }
        }
        return result
    }

    /// DADiskUnmount callback 은 inventory 와 같은 serial DA queue 에서 실행된다.
    private func finishSleepUnmountOnQueue(_ request: PendingSleepDAUnmount,
                                           dissenter: DADissenter?) {
        let evidence: SleepDAUnmountEvidence
        if let dissenter {
            let status = DADissenterGetStatus(dissenter)
            let typedStatus = SleepUnmountDissenterStatus(
                rawValue: UInt32(bitPattern: status)
            )
            let reason = (DADissenterGetStatusString(dissenter) as String?)
                ?? daDissenterStatusText(status)
            evidence = .callbackFailure(typedStatus, reason)
        } else if physicalGenerations[request.token.wholeDiskBSD] == request.token.generation,
                  currentIOMediaRegistryEntryID(bsd: request.token.wholeDiskBSD)
                    == request.token.mediaRegistryEntryID {
            // A nil dissenter is positive clean proof only while the exact captured media is
            // still present. A cable pull can make Disk Arbitration report a late nil callback;
            // IORegistry lets us reject that callback even if DA's disappeared event is queued later.
            evidence = .callbackSuccess
        } else {
            evidence = .disconnectedBeforeCallback
        }

        let accepted = request.finishOnce(evidence)
        let wasCurrentRequest = pendingSleepUnmounts[request.token] === request
        if wasCurrentRequest {
            pendingSleepUnmounts.removeValue(forKey: request.token)
        }
        let retainsForForce: Bool
        let callbackWasDecline: Bool
        if case .callbackFailure = evidence { callbackWasDecline = true }
        else { callbackWasDecline = false }
        retainsForForce = accepted
            && SleepMountApprovalPolicy.shouldRetainBarrierAfterNormalTerminal(
                callbackWasDecline: callbackWasDecline,
                forceContinuationReserved: forceContinuationReservations[request.token]?.isReserved == true
            )
        if wasCurrentRequest && (!callbackWasDecline || !accepted) {
            forceContinuationReservations.removeValue(forKey: request.token)
        }
        if !retainsForForce,
           blockedSleepUnmountMounts[request.token.wholeDiskBSD] == request.token {
            blockedSleepUnmountMounts.removeValue(forKey: request.token.wholeDiskBSD)
        }
        if accepted {
            let clean: Bool
            if case .callbackSuccess = evidence { clean = true } else { clean = false }
            log.notice("DAInventory: sleep unmount callback accepted target=\(request.target, privacy: .public) generation=\(request.token.generation, privacy: .public) mode=\(request.modeLabel, privacy: .public) clean=\(clean, privacy: .public)")
        } else {
            log.error("DAInventory: sleep unmount late callback ignored target=\(request.target, privacy: .public) generation=\(request.token.generation, privacy: .public) mode=\(request.modeLabel, privacy: .public)")
        }
    }

    /// Normal decline가 force launch 전에 유지한 barrier를 정리한다. Force request가 실제
    /// pending이면 callback/disconnect terminal까지 그 request가 계속 소유한다.
    func releaseSleepUnmountForceContinuation(wholeDiskBSDName: String?,
                                              expectedGeneration: UInt64?,
                                              expectedMediaRegistryEntryID: UInt64?) {
        guard let wholeDiskBSDName,
              let expectedGeneration,
              let expectedMediaRegistryEntryID else { return }
        let token = SleepDAPhysicalToken(
            wholeDiskBSD: wholeDiskBSDName,
            generation: expectedGeneration,
            mediaRegistryEntryID: expectedMediaRegistryEntryID
        )
        queue.sync {
            releaseForceContinuationReservationOnQueue(token)
            guard forceContinuationReservations[token] == nil,
                  pendingSleepUnmounts[token] == nil,
                  blockedSleepUnmountMounts[wholeDiskBSDName] == token else { return }
            blockedSleepUnmountMounts.removeValue(forKey: wholeDiskBSDName)
        }
    }

    private func releaseForceContinuationReservationOnQueue(_ token: SleepDAPhysicalToken) {
        guard var counter = forceContinuationReservations[token] else { return }
        counter.release()
        if counter.isReserved {
            forceContinuationReservations[token] = counter
        } else {
            forceContinuationReservations.removeValue(forKey: token)
        }
    }

    private func reserveForceContinuationOnQueue(_ token: SleepDAPhysicalToken) {
        var counter = forceContinuationReservations[token]
            ?? SleepForceContinuationReservationCounter()
        counter.reserve()
        forceContinuationReservations[token] = counter
    }

    /// Wake remount 전용 whole-disk mount. `diskutil` process timeout과 달리 public DA callback이
    /// 실제 terminal을 증명할 때까지 `onTerminal`을 보류하므로, 그 사이 새 lid close가 오면
    /// close-side inventory가 late mount보다 먼저 진행하지 않는다.
    func mountForWake(target: SleepRemountTarget,
                      timeout: TimeInterval,
                      operationID: String,
                      onTerminal: @escaping () -> Void) -> SleepDAMountWaitResult {
        var request: PendingSleepDAMount?
        var unavailableReason: String?

        queue.sync {
            if session == nil {
                startOnQueue()
            }
            guard let session else {
                unavailableReason = "DASession unavailable"
                return
            }

            let token = SleepDAPhysicalToken(
                wholeDiskBSD: target.wholeDiskBSD,
                generation: target.physicalGeneration,
                mediaRegistryEntryID: target.mediaRegistryEntryID
            )
            guard physicalGenerations[target.wholeDiskBSD] == target.physicalGeneration,
                  physicalRegistryEntryIDs[target.wholeDiskBSD] == target.mediaRegistryEntryID,
                  currentIOMediaRegistryEntryID(bsd: target.wholeDiskBSD)
                    == target.mediaRegistryEntryID else {
                unavailableReason = "physical disk generation changed before mount"
                return
            }

            if let existing = pendingWakeMounts[token] {
                request = existing
                log.notice("cycle \(operationID, privacy: .public) DA wake mount joined pending whole=\(target.wholeDiskBSD, privacy: .public) generation=\(target.physicalGeneration, privacy: .public)")
                return
            }

            guard let matching = IORegistryEntryIDMatching(target.mediaRegistryEntryID) else {
                unavailableReason = "IOMedia identity lookup unavailable"
                return
            }
            let mediaService = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            guard mediaService != 0 else {
                unavailableReason = "captured physical media is no longer present"
                return
            }
            defer { IOObjectRelease(mediaService) }
            guard let disk = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, mediaService),
                  let bsdPointer = DADiskGetBSDName(disk),
                  String(cString: bsdPointer) == target.wholeDiskBSD,
                  mediaRegistryEntryID(for: disk) == target.mediaRegistryEntryID else {
                unavailableReason = "captured physical media no longer matches the mount target"
                return
            }

            let pending = PendingSleepDAMount(session: session,
                                              disk: disk,
                                              token: token,
                                              inventory: self)
            pendingWakeMounts[token] = pending
            request = pending
            let contextPointer = Unmanaged.passRetained(pending).toOpaque()
            log.notice("cycle \(operationID, privacy: .public) DA wake mount start whole=\(target.wholeDiskBSD, privacy: .public) generation=\(target.physicalGeneration, privacy: .public) timeout=\(String(format: "%.1f", timeout), privacy: .public)s")
            DADiskMount(disk,
                        nil,
                        DADiskMountOptions(kDADiskMountOptionWhole),
                        { (_, dissenter, contextPointer) in
                            guard let contextPointer else { return }
                            let pending = Unmanaged<PendingSleepDAMount>
                                .fromOpaque(contextPointer)
                                .takeRetainedValue()
                            guard let inventory = pending.inventory else {
                                _ = pending.finishOnce(.callbackFailure("DA inventory unavailable"))
                                return
                            }
                            inventory.finishWakeMountOnQueue(pending, dissenter: dissenter)
                        },
                        contextPointer)
        }

        guard let request else {
            onTerminal()
            return .unavailable(unavailableReason ?? "DA mount request unavailable")
        }
        request.onTerminal(onTerminal)
        return request.wait(timeout: timeout)
    }

    private func finishWakeMountOnQueue(_ request: PendingSleepDAMount,
                                        dissenter: DADissenter?) {
        let evidence: SleepDAMountEvidence
        if let dissenter {
            let status = DADissenterGetStatus(dissenter)
            let reason = (DADissenterGetStatusString(dissenter) as String?)
                ?? daDissenterStatusText(status)
            evidence = .callbackFailure(reason)
        } else if physicalGenerations[request.token.wholeDiskBSD] == request.token.generation,
                  physicalRegistryEntryIDs[request.token.wholeDiskBSD]
                    == request.token.mediaRegistryEntryID,
                  currentIOMediaRegistryEntryID(bsd: request.token.wholeDiskBSD)
                    == request.token.mediaRegistryEntryID {
            evidence = .callbackSuccess
        } else {
            evidence = .identityChangedBeforeCallback
        }

        let accepted = request.finishOnce(evidence)
        if pendingWakeMounts[request.token] === request {
            pendingWakeMounts.removeValue(forKey: request.token)
        }
        if accepted {
            log.notice("DAInventory: wake mount callback accepted whole=\(request.token.wholeDiskBSD, privacy: .public) generation=\(request.token.generation, privacy: .public)")
        } else {
            log.error("DAInventory: wake mount callback late-ignored whole=\(request.token.wholeDiskBSD, privacy: .public) generation=\(request.token.generation, privacy: .public)")
        }
    }

    private func currentWholeMediaRegistryEntryIDOnQueue(_ bsd: String) -> UInt64? {
        currentIOMediaRegistryEntryID(bsd: bsd)
    }

    private func currentIOMediaRegistryEntryID(bsd: String) -> UInt64? {
        guard let matching = IOServiceMatching("IOMedia") else { return nil }
        (matching as NSMutableDictionary)["BSD Name"] = bsd
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else {
            return nil
        }
        return entryID
    }

    private func mediaRegistryEntryID(for disk: DADisk) -> UInt64? {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &entryID) == KERN_SUCCESS else {
            return nil
        }
        return entryID
    }

    /// `wholeBSD`의 현재 exact IOMedia를 appearance generation에 결합한다.
    /// 같은 diskN에 다른 registry entry가 나타나면 이전 pending request는 unsafe terminal로
    /// 고정하고 새 generation을 발급한다. DA serial queue에서만 호출한다.
    @discardableResult
    private func bindCurrentPhysicalIdentityOnQueue(_ wholeBSD: String) -> SleepDiskIdentity? {
        guard let currentEntryID = currentWholeMediaRegistryEntryIDOnQueue(wholeBSD) else {
            return nil
        }

        let previousGeneration = physicalGenerations[wholeBSD]
        let previousEntryID = physicalRegistryEntryIDs[wholeBSD]
        if previousGeneration == nil || previousEntryID != currentEntryID {
            if let previousGeneration, let previousEntryID {
                let oldToken = SleepDAPhysicalToken(
                    wholeDiskBSD: wholeBSD,
                    generation: previousGeneration,
                    mediaRegistryEntryID: previousEntryID
                )
                if let oldRequest = pendingSleepUnmounts[oldToken] {
                    _ = oldRequest.finishOnce(.disconnectedBeforeCallback)
                    pendingSleepUnmounts.removeValue(forKey: oldRequest.token)
                }
                forceContinuationReservations.removeValue(forKey: oldToken)
                if blockedSleepUnmountMounts[wholeBSD] == oldToken {
                    blockedSleepUnmountMounts.removeValue(forKey: wholeBSD)
                }
                let pendingCount = pendingApprovedMounts.count
                pendingApprovedMounts = pendingApprovedMounts.filter { pending in
                    pending.value.wholeDiskBSD != wholeBSD
                        || pending.value.mediaRegistryEntryID == nil
                        || pending.value.mediaRegistryEntryID != previousEntryID
                }
                if pendingApprovedMounts.count != pendingCount {
                    signalPendingApprovedMountChange()
                }
            }
            nextPhysicalGeneration &+= 1
            if nextPhysicalGeneration == 0 { nextPhysicalGeneration = 1 }
            physicalGenerations[wholeBSD] = nextPhysicalGeneration
            physicalRegistryEntryIDs[wholeBSD] = currentEntryID
            log.info("DAInventory: physical generation bound whole=\(wholeBSD, privacy: .public) generation=\(self.nextPhysicalGeneration, privacy: .public) registryEntryID=\(currentEntryID, privacy: .public)")
        }

        guard let generation = physicalGenerations[wholeBSD],
              physicalRegistryEntryIDs[wholeBSD] == currentEntryID else {
            return nil
        }
        return SleepDiskIdentity(wholeDiskBSD: wholeBSD,
                                 generation: generation,
                                 mediaRegistryEntryID: currentEntryID)
    }

    /// OS mount table을 authoritative source(권위 원본)로 사용해 현재 마운트된 모든
    /// `/dev/disk*` volume을 persistent DA session에 동기 reconcile한다. Initial appeared
    /// callback의 도착 시간을 completeness barrier로 오인하지 않는다.
    private func currentMountedDiskInfosOnQueue() -> [String: DiskInfo]? {
        guard let session else { return nil }
        var mountBuffer: UnsafeMutablePointer<statfs>?
        let mountCount = getmntinfo(&mountBuffer, MNT_NOWAIT)
        guard mountCount >= 0, mountCount == 0 || mountBuffer != nil else { return nil }

        var mounted: [String: DiskInfo] = [:]
        if mountCount > 0, let mountBuffer {
            for index in 0..<Int(mountCount) {
                var entry = mountBuffer[index]
                let source = withUnsafePointer(to: &entry.f_mntfromname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
                        String(cString: $0)
                    }
                }
                guard source.hasPrefix("/dev/disk") else { continue }
                let path = withUnsafePointer(to: &entry.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
                        String(cString: $0)
                    }
                }
                guard let disk = DADiskCreateFromVolumePath(
                    kCFAllocatorDefault,
                    session,
                    URL(fileURLWithPath: path) as CFURL
                ),
                let info = parseDescription(disk: disk),
                info.mountPath == path,
                bindCurrentPhysicalIdentityOnQueue(info.wholeDiskBSD) != nil else {
                    log.error("DAInventory: authoritative mounted volume could not be resolved source=\(source, privacy: .public) path=\(path, privacy: .public)")
                    return nil
                }
                mounted[info.bsd] = info
            }
        }

        lock.lock()
        for info in mounted.values {
            disks[info.bsd] = info
        }
        ready = true
        lock.unlock()
        var resolvedPendingApproval = false
        for info in mounted.values {
            guard let pending = pendingApprovedMounts[info.bsd],
                  pending.volumeRegistryEntryID == nil
                    || pending.volumeRegistryEntryID == info.mediaRegistryEntryID else { continue }
            pendingApprovedMounts.removeValue(forKey: info.bsd)
            resolvedPendingApproval = true
        }
        if resolvedPendingApproval {
            signalPendingApprovedMountChange()
        }
        return mounted
    }

    private func parseDescription(disk: DADisk) -> DiskInfo? {
        guard let bsdC = DADiskGetBSDName(disk) else { return nil }
        let bsd = String(cString: bsdC)
        guard let descCF = DADiskCopyDescription(disk) else { return nil }
        let dict = descCF as NSDictionary

        let isWhole = (dict[kDADiskDescriptionMediaWholeKey] as? NSNumber)?.boolValue ?? false
        let isInternal = (dict[kDADiskDescriptionDeviceInternalKey] as? NSNumber)?.boolValue ?? false
        let isRemovable = (dict[kDADiskDescriptionMediaRemovableKey] as? NSNumber)?.boolValue
        let isEjectable = (dict[kDADiskDescriptionMediaEjectableKey] as? NSNumber)?.boolValue
        let busProtocol = dict[kDADiskDescriptionDeviceProtocolKey] as? String
        let mediaContent = dict[kDADiskDescriptionMediaContentKey] as? String
        let volumeName = dict[kDADiskDescriptionVolumeNameKey] as? String
        let mountPath = (dict[kDADiskDescriptionVolumePathKey] as? URL)?.path
        let mediaRegistryEntryID = mediaRegistryEntryID(for: disk)

        var volumeUUID: String? = nil
        if let uuidObj = dict[kDADiskDescriptionVolumeUUIDKey] {
            // CFUUID — toll-free bridging 안 되므로 명시적 캐스트 후 string 화.
            let cfUUID = uuidObj as! CFUUID
            volumeUUID = CFUUIDCreateString(kCFAllocatorDefault, cfUUID) as String?
        }

        let wholeDiskBSD: String
        if isWhole {
            wholeDiskBSD = bsd
        } else {
            wholeDiskBSD = BSDName.wholeDisk(from: bsd) ?? bsd
        }

        return DiskInfo(
            bsd: bsd,
            wholeDiskBSD: wholeDiskBSD,
            mediaRegistryEntryID: mediaRegistryEntryID,
            isWholeDisk: isWhole,
            isInternal: isInternal,
            isRemovable: isRemovable,
            isEjectable: isEjectable,
            busProtocol: busProtocol,
            mountPath: mountPath,
            volumeName: volumeName,
            volumeUUID: volumeUUID,
            mediaContent: mediaContent
        )
    }

    /// 자동 sleep unmount target을 BSD 이름뿐 아니라 현재 DA appearance generation에 묶는다.
    /// path가 사라지거나 같은 diskN이 replacement media에 재사용되면 nil/다른 generation이 된다.
    func sleepIdentity(at volumePath: String) -> SleepDiskIdentity? {
        var identity: SleepDiskIdentity?
        queue.sync {
            if session == nil {
                startOnQueue()
            }
            lock.lock()
            let wholeBSD = disks.values.first { $0.mountPath == volumePath }?.wholeDiskBSD
            lock.unlock()
            if let wholeBSD,
               let generation = physicalGenerations[wholeBSD],
               let entryID = physicalRegistryEntryIDs[wholeBSD]
                    ?? currentWholeMediaRegistryEntryIDOnQueue(wholeBSD) {
                physicalRegistryEntryIDs[wholeBSD] = entryID
                identity = SleepDiskIdentity(wholeDiskBSD: wholeBSD,
                                             generation: generation,
                                             mediaRegistryEntryID: entryID)
                return
            }

            // Initial enumeration이 늦어도 현재 mounted path로 public DA object를 동기 해석한다.
            // diskutil fallback이 SSD를 찾았는데 inventory callback만 늦은 cold-start 창을 보호한다.
            guard let session,
                  let disk = DADiskCreateFromVolumePath(
                    kCFAllocatorDefault,
                    session,
                    URL(fileURLWithPath: volumePath) as CFURL
                  ),
                  let info = parseDescription(disk: disk),
                  info.mountPath == volumePath else { return }

            lock.lock()
            disks[info.bsd] = info
            lock.unlock()
            if physicalGenerations[info.wholeDiskBSD] == nil {
                nextPhysicalGeneration &+= 1
                if nextPhysicalGeneration == 0 { nextPhysicalGeneration = 1 }
                physicalGenerations[info.wholeDiskBSD] = nextPhysicalGeneration
            }
            if physicalRegistryEntryIDs[info.wholeDiskBSD] == nil,
               let entryID = currentWholeMediaRegistryEntryIDOnQueue(info.wholeDiskBSD) {
                physicalRegistryEntryIDs[info.wholeDiskBSD] = entryID
            }
            guard let generation = physicalGenerations[info.wholeDiskBSD],
                  let entryID = physicalRegistryEntryIDs[info.wholeDiskBSD] else { return }
            identity = SleepDiskIdentity(wholeDiskBSD: info.wholeDiskBSD,
                                         generation: generation,
                                         mediaRegistryEntryID: entryID)
            log.notice("DAInventory: synchronously resolved sleep identity path=\(volumePath, privacy: .public) whole=\(info.wholeDiskBSD, privacy: .public) generation=\(generation, privacy: .public)")
        }
        return identity
    }

    /// wake remount가 clean-unmount했던 바로 그 physical appearance에만 적용되게 한다.
    func isCurrentPhysicalGeneration(_ target: SleepRemountTarget) -> Bool {
        var matches = false
        queue.sync {
            guard physicalGenerations[target.wholeDiskBSD] == target.physicalGeneration,
                  physicalRegistryEntryIDs[target.wholeDiskBSD] == target.mediaRegistryEntryID,
                  currentIOMediaRegistryEntryID(bsd: target.wholeDiskBSD)
                    == target.mediaRegistryEntryID else {
                return
            }
            lock.lock()
            matches = disks.values.contains { $0.wholeDiskBSD == target.wholeDiskBSD }
            lock.unlock()
        }
        return matches
    }

    /// Sleep protection inventory. Unlike the menu snapshot, this includes every mounted sibling
    /// (including hidden/non-browsable helper volumes) so an excluded or Time Machine sibling can
    /// protect the whole physical disk. Drive metadata and physical identity are captured together.
    func automaticSleepVolumeSnapshot(waitUntilReady timeout: TimeInterval) -> [SleepAutomaticVolumeSnapshot]? {
        start()
        var snap: [String: DiskInfo] = [:]
        var generations: [String: UInt64] = [:]
        var entryIDs: [String: UInt64] = [:]
        var pendingMounts: [PendingApprovedMount] = []
        let pendingWaitDeadline = Date().addingTimeInterval(max(0, timeout))

        while true {
            let observedSequence = pendingApprovedMountSequenceSnapshot()
            snap.removeAll(keepingCapacity: true)
            generations.removeAll(keepingCapacity: true)
            entryIDs.removeAll(keepingCapacity: true)
            pendingMounts.removeAll(keepingCapacity: true)
            queue.sync {
                if session == nil {
                    startOnQueue()
                }
                guard let mounted = currentMountedDiskInfosOnQueue() else { return }
                snap = mounted
                let wholeBSDs = Set(snap.values.map(\.wholeDiskBSD))
                for wholeBSD in wholeBSDs {
                    _ = bindCurrentPhysicalIdentityOnQueue(wholeBSD)
                }
                generations = physicalGenerations
                entryIDs = physicalRegistryEntryIDs
                pendingMounts = Array(pendingApprovedMounts.values)
            }

            let hasPendingExternalMount = pendingMounts.contains(where: \.isExternalCandidate)
            guard hasPendingExternalMount else { break }
            let remaining = pendingWaitDeadline.timeIntervalSinceNow
            guard remaining > 0 else {
                log.error("DAInventory: automatic snapshot deadline reached with approved external mount still not visible")
                return nil
            }
            log.notice("DAInventory: waiting for approved external mount terminal before automatic snapshot remaining=\(String(format: "%.2f", remaining), privacy: .public)s")
            waitForPendingApprovedMountChange(after: observedSequence,
                                              timeout: remaining)
        }
        guard !snap.isEmpty else {
            // 정상 macOS에는 root `/dev/disk*` mount가 항상 있다. Empty는 initial-enumeration
            // 누락을 "외장 없음" 성공으로 바꾸지 않도록 fail closed한다.
            log.error("DAInventory: authoritative mounted-volume snapshot was empty")
            return nil
        }

        var groups: [String: [DiskInfo]] = [:]
        for info in snap.values {
            groups[info.wholeDiskBSD, default: []].append(info)
        }

        var result: [SleepAutomaticVolumeSnapshot] = []
        for (wholeBSD, group) in groups {
            let probe = group.first { $0.isWholeDisk } ?? group[0]
            guard ExternalMediaPolicy.shouldInclude(
                isInternal: probe.isInternal,
                busProtocol: probe.busProtocol,
                isRemovable: probe.isRemovable,
                isEjectable: probe.isEjectable
            ) else { continue }
            if let protocolName = probe.busProtocol,
               protocolName == "Disk Image" || protocolName == "Virtual Interface" {
                continue
            }
            guard !pendingMounts.contains(where: { pending in
                pending.wholeDiskBSD == wholeBSD
                    && entryIDs[wholeBSD].map { entryID in
                        SleepMountApprovalPolicy.pendingApprovalMatchesCapturedMedia(
                            pendingMediaRegistryEntryID: pending.mediaRegistryEntryID,
                            capturedMediaRegistryEntryID: entryID
                        )
                    } == true
            }) else {
                log.error("DAInventory: automatic snapshot blocked by approved mount not yet visible whole=\(wholeBSD, privacy: .public)")
                return nil
            }
            guard let generation = generations[wholeBSD],
                  let entryID = entryIDs[wholeBSD] else {
                if group.contains(where: { $0.mountPath?.isEmpty == false }) {
                    log.error("DAInventory: mounted external group lacks stable physical identity whole=\(wholeBSD, privacy: .public)")
                    return nil
                }
                continue
            }

            let mountedVolumeBSDs = Set(group.compactMap { info in
                info.mountPath?.isEmpty == false ? info.bsd : nil
            })
            let identity = SleepDiskIdentity(wholeDiskBSD: wholeBSD,
                                             generation: generation,
                                             mediaRegistryEntryID: entryID,
                                             mountedVolumeBSDs: mountedVolumeBSDs)
            for volume in group {
                guard let path = volume.mountPath, !path.isEmpty else { continue }
                let url = URL(fileURLWithPath: path)
                let name = volume.volumeName.flatMap { $0.isEmpty ? nil : $0 }
                    ?? url.lastPathComponent
                let isSystemHelper = SystemVolumeFilter.names.contains(name)
                    || volume.mediaContent.map(SystemVolumeFilter.contents.contains) == true
                    || DiskImages.isKnownDiskImageMountPath(path)
                let drive = ExternalDrive(
                    name: name,
                    url: url,
                    kind: .disk,
                    volumeUUID: volume.volumeUUID,
                    isTimeMachine: ExternalDrive.isTimeMachineDisk(volumeURL: url)
                )
                result.append(SleepAutomaticVolumeSnapshot(drive: drive,
                                                           identity: identity,
                                                           isEjectTarget: !isSystemHelper))
            }
        }
        return result.sorted { $0.drive.url.path < $1.drive.url.path }
    }

    /// nil 반환 = 인벤토리 아직 ready 아님 → 호출자가 diskutil fallback 으로.
    func snapshot() -> (drives: [ExternalDrive], unmounted: [UnmountedExternal])? {
        lock.lock()
        guard ready else { lock.unlock(); return nil }
        let snap = disks
        lock.unlock()

        // wholeDisk BSD 별 그룹핑
        var groups: [String: [DiskInfo]] = [:]
        for info in snap.values {
            groups[info.wholeDiskBSD, default: []].append(info)
        }

        var drives: [ExternalDrive] = []
        var mountedWholeDiskBSDs = Set<String>()

        for (wholeBSD, group) in groups {
            // whole-disk 엔트리에서 internal/protocol 판단 (없으면 group 의 첫 항목)
            let probe = group.first { $0.isWholeDisk } ?? group.first!
            if !ExternalMediaPolicy.shouldInclude(
                isInternal: probe.isInternal,
                busProtocol: probe.busProtocol,
                isRemovable: probe.isRemovable,
                isEjectable: probe.isEjectable
            ) { continue }
            if let p = probe.busProtocol, p == "Disk Image" || p == "Virtual Interface" { continue }

            for vol in group {
                guard let path = vol.mountPath, !path.isEmpty else { continue }
                guard let name = vol.volumeName, !name.isEmpty else { continue }
                if SystemVolumeFilter.names.contains(name) { continue }
                if let content = vol.mediaContent, SystemVolumeFilter.contents.contains(content) { continue }
                if DiskImages.isKnownDiskImageMountPath(path) { continue }

                let url = URL(fileURLWithPath: path)
                drives.append(ExternalDrive(
                    name: name,
                    url: url,
                    kind: .disk,
                    volumeUUID: vol.volumeUUID,
                    isTimeMachine: ExternalDrive.isTimeMachineDisk(volumeURL: url)
                ))
                mountedWholeDiskBSDs.insert(wholeBSD)
            }
        }

        // unmounted 후보 — whole-disk 그룹 중 mount 된 sub-volume 0개 + name 있는 후보 1개+
        var unmounted: [UnmountedExternal] = []
        for (wholeBSD, group) in groups {
            if mountedWholeDiskBSDs.contains(wholeBSD) { continue }
            let probe = group.first { $0.isWholeDisk } ?? group.first!
            if !ExternalMediaPolicy.shouldInclude(
                isInternal: probe.isInternal,
                busProtocol: probe.busProtocol,
                isRemovable: probe.isRemovable,
                isEjectable: probe.isEjectable
            ) { continue }
            if let p = probe.busProtocol, p == "Disk Image" || p == "Virtual Interface" { continue }

            let firstNamed = group.first { vol in
                guard let n = vol.volumeName, !n.isEmpty,
                      !SystemVolumeFilter.names.contains(n) else { return false }
                if let c = vol.mediaContent, SystemVolumeFilter.contents.contains(c) { return false }
                return true
            }
            guard let candidate = firstNamed else { continue }
            unmounted.append(UnmountedExternal(
                bsdName: wholeBSD,
                displayName: candidate.volumeName ?? wholeBSD,
                kind: .disk
            ))
        }

        return (drives, unmounted)
    }

    /// mountedVolumeURLs fallback 에서 internal media(내장 매체)를 판정할 때 쓰는 read-only 조회.
    /// nil 은 inventory 미준비 또는 삽입/제거 race 로 해당 mount path 를 아직 모른다는 뜻이다.
    fileprivate func shouldIncludeMountedInternalMedia(at path: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard ready,
              let volume = disks.values.first(where: { $0.mountPath == path })
        else { return nil }

        let probe = disks[volume.wholeDiskBSD] ?? volume
        return ExternalMediaPolicy.shouldInclude(
            isInternal: probe.isInternal,
            busProtocol: probe.busProtocol,
            isRemovable: probe.isRemovable,
            isEjectable: probe.isEjectable
        )
    }

    /// `false` 만 반환할 때 호출자가 안전하게 skip 가능 — ready 전이거나 mounted 면 항상 true.
    /// (즉 "확실히 사라졌다" 는 강한 신호일 때만 false.)
    func isVolumePresent(at path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !ready { return true }  // uncertain → assume present
        for info in disks.values where info.mountPath == path {
            return true
        }
        return false
    }
}

// MARK: - Sleep Eject Toggle (UserDefaults)

/// 잠자기 진입 시 자동 추출 여부.
/// 노트북 / 데스크탑 / sleep 종류 무관 — 모든 sleep 에서 추출. wake 시 자동 재마운트로 짝.
///
/// Legacy preference migration runs once at launch before either modern value is read.
enum SleepEject {
    private static let key = "ejectOnSleep"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// 노트북 뚜껑(클램쉘)을 닫을 때 자동 추출 여부. `SleepEject`(잠자기 시) 와 별개 토글.
/// 담당 경로: ① 뚜껑 닫힘 선(先)추출(clamshell pre-eject), ② '뚜껑 닫음이 일으킨 잠자기' 경로.
/// **default = true** — 노트북 사용자의 가장 흔한 시나리오(자리 뜰 때 뚜껑 닫음).
/// Legacy values are resolved centrally at launch so the result cannot depend on getter order.
enum LidCloseEject {
    private static let key = "ejectOnClamshell"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// 화면 꺼질 때 자동 추출 여부. system sleep 과 별개 토글.
/// `pmset sleep = 0` (자동 sleep 비활성) 환경의 도킹 분리 사고 보호용.
/// **default = false** — 빈번한 추출/재마운트 위험 때문에 명시적 opt-in.
enum DisplaySleepEject {
    private static let key = "ejectOnDisplaySleep"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// MARK: - Per-disk 자동 추출 제외 (Volume UUID 기반)

/// 사용자가 *"이 디스크는 자동 추출 안 함"* 으로 마크한 Volume UUID set.
/// 자동 (sleep / display sleep) path 에서만 적용 — 명시적 추출 (메뉴 클릭 / 단축키) 은 영향 없음.
/// Volume UUID 가 BSD/이름보다 안정적 (케이블 슬롯 변경에도 유지).
enum ExcludedVolumes {
    private static let key = "excludedVolumeUUIDs"

    static var uuids: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: key) }
    }

    static func toggle(_ uuid: String) {
        var s = uuids
        if s.contains(uuid) { s.remove(uuid) } else { s.insert(uuid) }
        uuids = s
    }

    static func add(_ uuid: String) {
        var s = uuids
        s.insert(uuid)
        uuids = s
    }

    static func isExcluded(_ uuid: String?) -> Bool {
        guard let uuid else { return false }
        return uuids.contains(uuid)
    }
}

/// Time Machine 디스크 자동 등록 알림 1회 처리용 — 같은 UUID 에 알림 반복 방지.
enum TimeMachineNotified {
    private static let key = "tmAutoExcludeNotified"
    static var uuids: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: key) }
    }
    static func markNotified(_ uuid: String) {
        var s = uuids; s.insert(uuid); uuids = s
    }
    static func wasNotified(_ uuid: String) -> Bool { uuids.contains(uuid) }
}

// MARK: - 외장 라이브러리 앱 자동 종료 토글 (Music / Photos)

/// 자동 추출 직전에 Music.app / Photos.app 자동 quit, wake 후 자동 relaunch.
/// 외장 디스크에 라이브러리 둔 사용자 보호.
/// **default = false** — `NSRunningApplication.terminate()` 가 다른 앱을 죽이는 동작이라
/// 사용자 명시 opt-in 필요.
enum LibraryAppManagement {
    private static let key = "manageLibraryApps"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// MARK: - Library App Handler (Music / Photos quit & relaunch)

/// 외장 디스크 라이브러리 lock 풀기 위해 sleep 직전 Music/Photos 종료, wake 후 재실행.
/// `LibraryAppManagement.enabled` 가 true 일 때만 호출됨.
///
/// **sandbox 호환성**: `NSRunningApplication.terminate()` 는 graceful terminate 로,
/// App Store sandbox 안에서도 동작 (Jettison 도 같은 패턴). 사용자가 명시 opt-in 했으니 의도 명확.
/// 만약 macOS 정책 변경으로 막히면 AppleScript fallback (`scripting-targets` entitlement) 검토.
enum LibraryAppHandler {
    private static let bundleIDs = ["com.apple.Music", "com.apple.Photos"]
    /// Overlapping display/system sleep requests can finish in either order. Union every accepted
    /// graceful quit until one valid wake/cancel path atomically drains the relaunch ledger.
    private static let relaunchLedger = LibraryAppRelaunchLedger()

    /// 실행 중인 Music / Photos 종료. 받아들여진 bundle 들은 relaunch ledger에 합쳐 기록.
    /// background thread 또는 main thread 어디서든 호출 가능 (NSWorkspace 는 thread-safe).
    /// terminate() 는 비동기라, 라이브러리 lock 이 풀릴 때까지 짧은 polling 으로 기다린다 —
    /// 그렇지 않으면 직후 추출이 lock 에 걸려 실패할 수 있다.
    static func quitLibraryApps() {
        let workspace = NSWorkspace.shared
        let targets = workspace.runningApplications.filter {
            guard let bid = $0.bundleIdentifier else { return false }
            return bundleIDs.contains(bid)
        }
        // wake 시 relaunch 하려고 종료한 bundle 기록 — overlapping calls must not overwrite it.
        let accepted = terminate(apps: targets, timeout: 3.0)
        relaunchLedger.record(accepted)
        log.info("LibraryAppHandler: quit \(accepted.count, privacy: .public) apps = \(accepted, privacy: .public)")
    }

    /// graceful terminate + 종료 완료 polling. 재사용 코어 — sleep 라이브러리 종료와 능동 복구
    /// (점유 앱 끄고 재시도) 가 공유. `forceTerminate()` 는 **절대 안 씀** (미저장 데이터 손실 방지).
    ///
    /// - 동작: 각 앱에 `terminate()` 요청 → 받아들여진 앱들에 대해 최대 `timeout` 초 종료 대기.
    ///   graceful 이라 보통 100~500ms 에 끝남. 앱이 미저장 문서로 종료 거부하면 timeout 후 진행.
    /// - polling 이 blocking(`Thread.sleep`) 이므로 **background 큐에서 호출**할 것 (main thread X).
    /// - 반환: 종료 요청이 받아들여진 앱들의 bundle ID. (state 변경 없음 — caller 가 보관 여부 결정.)
    @discardableResult
    static func terminate(apps: [NSRunningApplication], timeout: TimeInterval) -> [String] {
        var accepted: [NSRunningApplication] = []
        var acceptedIDs: [String] = []
        for app in apps {
            let bid = app.bundleIdentifier ?? "?"
            log.notice("LibraryAppHandler: terminating \(bid, privacy: .public)")
            // graceful terminate — 앱이 정리 시간 가짐 (write cache flush 등).
            if app.terminate() {
                accepted.append(app)
                if let realBID = app.bundleIdentifier { acceptedIDs.append(realBID) }
            } else {
                log.error("LibraryAppHandler: terminate denied for \(bid, privacy: .public)")
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        for target in accepted {
            while !target.isTerminated && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if !target.isTerminated {
                log.notice("LibraryAppHandler: \(target.bundleIdentifier ?? "?", privacy: .public) still running after \(Int(timeout), privacy: .public)s — proceeding anyway")
            }
        }
        return acceptedIDs
    }

    /// 앞서 종료한 앱들 재실행. 없으면 no-op.
    /// 사용자가 wake 후 즉시 화면 보지 못해도 백그라운드로 라이브러리 다시 마운트되어 있도록.
    static func relaunchQuitApps() {
        let toLaunch = relaunchLedger.drain()
        guard !toLaunch.isEmpty else { return }
        let workspace = NSWorkspace.shared
        for bid in toLaunch {
            guard let url = workspace.urlForApplication(withBundleIdentifier: bid) else {
                log.error("LibraryAppHandler: app URL not found for \(bid, privacy: .public)")
                continue
            }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false   // 사용자 작업 방해 안 함, 백그라운드 실행
            cfg.hides = true        // dock 클릭 전엔 가려두기
            workspace.openApplication(at: url, configuration: cfg) { _, error in
                if let error = error {
                    log.error("LibraryAppHandler: relaunch failed \(bid, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                } else {
                    log.info("LibraryAppHandler: relaunched \(bid, privacy: .public)")
                }
            }
        }
    }
}

// MARK: - Disk I/O Monitor (외장 읽기/쓰기 활동 감지)

/// 외장 물리 디스크의 I/O 를 폴링해 "최근 어떤 디스크가 읽기/쓰기 중" 을 감지 — 사용자가 활동
/// 도중 분리하지 않도록 메뉴바 + 메뉴에 표시하기 위한 신호.
///
/// **왜 물리 디스크 레벨인가**: APFS synthesized 볼륨(disk5 등)·virtual 컨테이너(disk4)는
/// `IOBlockStorageDriver` 가 없어 byte 카운터가 없다. 카운터는 물리 디바이스에만 있으므로
/// `IOBlockStorageDriver` 를 직접 열거하고 `DiskActivityMediaPolicy` 로 외장 장치와 분리 가능한
/// 내장 SDXC 만 포함한다 (내장 disk0 / 디스크 이미지[loc=File] 자동 제외).
///
/// 디스크별 누적 `Bytes (Read)`·`Bytes (Write)` 를 폴 간격마다 비교한다. threshold 이상이면
/// 활동을 시작하고, 이후 작은 I/O 도 상태를 유지하며, 3회 연속 완전한 무활동 뒤 해제한다.
/// 쓰는 중/읽는 중 **물리 whole-disk BSD** 집합(예: ["disk7","disk8"])을 보고한다. 볼륨→물리
/// 매핑은 메뉴 쪽(`physicalWholeDisks(forVolumeURL:)`)이 담당 — 여기선 물리 단위로만 본다.
/// spawn 0 (순수 IORegistry).
final class DiskIOMonitor {
    static let shared = DiskIOMonitor()

    /// 폴링 간격 — 반응성 vs 배터리. 대상 매체가 있을 때만 (AppDelegate 가 start/stop) 돈다.
    private let interval: TimeInterval = 1.5
    /// 폴 간 write 델타가 이 값 이상이면 "쓰는 중" — 작은 metadata flush 오탐 방지.
    private let writeThreshold: UInt64 = 256 * 1024   // 256 KB
    /// 폴 간 read 델타가 이 값 이상이면 "읽는 중". 읽기는 background(Spotlight 인덱싱·QuickLook
    /// 썸네일·Time Machine 스캔) 읽기가 잦아 오탐이 흔하다 — write 보다 훨씬 높게 잡는다.
    /// 16MB/폴(≈10.7MB/s): 관측된 Spotlight 첫 인덱싱(~10MB/s burst)은 거르고, 일반 복사
    /// (외장 보통 수십 MB/s↑)는 잡힌다. 느린 읽기를 놓치면 닷만 안 뜰 뿐(읽기 중 분리는
    /// 쓰기보다 위험 낮음). 거슬리거나 느린 복사를 놓치면 이 값만 조정.
    private let readThreshold: UInt64 = 16 * 1024 * 1024   // 16 MB

    private let queue = DispatchQueue(label: "com.yongza.ejectdrives.io-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// 물리 whole-disk BSD → 직전 폴의 누적 (read, write) 바이트.
    private var lastIOByDisk: [String: (read: UInt64, write: UInt64)] = [:]
    private var hasBaseline = false
    /// macOS buffering 으로 polling 한두 구간의 물리 I/O 가 비어도 활동 표시를 유지한다.
    private var activityState = DiskActivityState()
    /// 직전에 보고한 "쓰는 중"/"읽는 중" 물리 BSD 집합 — 변화 감지용.
    private var lastWritingSet: Set<String> = []
    private var lastReadingSet: Set<String> = []

    /// 쓰는 중/읽는 중 물리 whole-disk BSD 집합이 변할 때 main thread 에서 호출.
    /// (writing, reading) 둘 다 빈 집합이면 비활성. 닷은 둘 중 하나라도 있으면 표시.
    var onActivityChanged: ((_ writing: Set<String>, _ reading: Set<String>) -> Void)?

    /// 대상 매체가 마운트됐을 때 호출. idempotent.
    func start() {
        queue.async { [weak self] in
            guard let self = self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 0.2, repeating: self.interval)
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            self.timer = t
            log.notice("DiskIOMonitor: started")
        }
    }

    /// 대상 매체가 모두 사라졌을 때 호출. idempotent. 상태 리셋 + (켜져 있었으면) 비활성 통지.
    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let wasRunning = self.timer != nil
            self.timer?.cancel()
            self.timer = nil
            self.hasBaseline = false
            self.lastIOByDisk = [:]
            let cleared = self.activityState.reset()
            self.setActive(writing: cleared.writing, reading: cleared.reading)
            if wasRunning {
                log.notice("DiskIOMonitor: stopped")
            }
        }
    }

    private func poll() {
        let (io, hasEligibleMedia) = Self.externalIOByDisk()
        // 대상 매체가 없으면 baseline + grace 상태를 즉시 리셋한다.
        guard hasEligibleMedia else {
            hasBaseline = false
            lastIOByDisk = [:]
            let cleared = activityState.reset()
            setActive(writing: cleared.writing, reading: cleared.reading)
            return
        }
        // 첫 폴은 baseline 만 기록 (직전 누적값을 모르므로 델타 계산 불가).
        guard hasBaseline else {
            lastIOByDisk = io
            hasBaseline = true
            return
        }
        var detectedWriting = Set<String>()
        var detectedReading = Set<String>()
        var observedWriting = Set<String>()
        var observedReading = Set<String>()
        for (bsd, cur) in io {
            // 새로 꽂힌 디스크는 last == cur 로 둬 첫 폴 오탐 방지 (다음 폴부터 델타 유효).
            let last = lastIOByDisk[bsd] ?? cur
            let wDelta = cur.write >= last.write ? cur.write - last.write : 0
            let rDelta = cur.read  >= last.read  ? cur.read  - last.read  : 0
            if wDelta > 0 { observedWriting.insert(bsd) }
            if rDelta > 0 { observedReading.insert(bsd) }
            if wDelta >= writeThreshold { detectedWriting.insert(bsd) }
            if rDelta >= readThreshold  { detectedReading.insert(bsd) }
        }
        lastIOByDisk = io
        let activity = activityState.update(
            detectedWriting: detectedWriting,
            detectedReading: detectedReading,
            observedWriting: observedWriting,
            observedReading: observedReading,
            presentDisks: Set(io.keys)
        )
        setActive(writing: activity.writing, reading: activity.reading)
    }

    private func setActive(writing: Set<String>, reading: Set<String>) {
        guard writing != lastWritingSet || reading != lastReadingSet else { return }
        lastWritingSet = writing
        lastReadingSet = reading
        log.debug("DiskIOMonitor: writing=\(writing.sorted(), privacy: .public) reading=\(reading.sorted(), privacy: .public)")
        DispatchQueue.main.async { [weak self] in self?.onActivityChanged?(writing, reading) }
    }

    /// 대상 물리 디스크별 누적 (read, write) 바이트 (whole-disk BSD → bytes) + 대상 매체 존재 여부.
    /// IORegistry 만 사용.
    private static func externalIOByDisk() -> (
        io: [String: (read: UInt64, write: UInt64)],
        hasEligibleMedia: Bool
    ) {
        let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iter) == KERN_SUCCESS else {
            return ([:], false)
        }
        defer { IOObjectRelease(iter) }

        var io: [String: (read: UInt64, write: UInt64)] = [:]
        var hasEligibleMedia = false
        var svc = IOIteratorNext(iter)
        while svc != IO_OBJECT_NULL {
            if let pc = IORegistryEntrySearchCFProperty(svc, kIOServicePlane,
                                                        "Protocol Characteristics" as CFString,
                                                        kCFAllocatorDefault, opts) as? [String: Any],
               let media = wholeDiskMedia(forDriver: svc),
               DiskActivityMediaPolicy.shouldInclude(
                   physicalLocation: pc["Physical Interconnect Location"] as? String,
                   busProtocol: pc["Physical Interconnect"] as? String,
                   isRemovable: media.isRemovable,
                   isEjectable: media.isEjectable
               ) {
                hasEligibleMedia = true
                if let stats = IORegistryEntryCreateCFProperty(svc, "Statistics" as CFString,
                                                               kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] {
                    let w = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                    let r = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                    io[media.bsd] = (read: r, write: w)
                }
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iter)
        }
        return (io, hasEligibleMedia)
    }

    private struct WholeDiskMedia {
        let bsd: String
        let isRemovable: Bool?
        let isEjectable: Bool?
    }

    /// `IOBlockStorageDriver` 의 자식 whole `IOMedia` 속성. BSD name 은 I/O 카운터 귀속에,
    /// removable/ejectable 은 내장 SDXC 와 내장 SSD 구분에 사용한다.
    private static func wholeDiskMedia(forDriver driver: io_service_t) -> WholeDiskMedia? {
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var found: WholeDiskMedia?
        var child = IOIteratorNext(it)
        while child != IO_OBJECT_NULL {
            if found == nil,
               IOObjectConformsTo(child, "IOMedia") != 0,
               (IORegistryEntryCreateCFProperty(child, "Whole" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool) == true,
               let bsd = IORegistryEntryCreateCFProperty(
                   child, "BSD Name" as CFString, kCFAllocatorDefault, 0
               )?.takeRetainedValue() as? String {
                let removable = IORegistryEntryCreateCFProperty(
                    child, "Removable" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? Bool
                let ejectable = IORegistryEntryCreateCFProperty(
                    child, "Ejectable" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? Bool
                found = WholeDiskMedia(
                    bsd: bsd,
                    isRemovable: removable,
                    isEjectable: ejectable
                )
            }
            IOObjectRelease(child)
            child = IOIteratorNext(it)
        }
        return found
    }
}

// MARK: - Login Item (SMAppService)

/// 로그인 시 자동 실행 — `SMAppService.mainApp` (macOS 13+).
/// 사용자가 메뉴 토글로 ON/OFF, 시스템 설정 → 일반 → 로그인 항목 에 등록됨.
///
/// **status 의미**:
/// - `.notRegistered` — 미등록 (default)
/// - `.enabled` — 등록 + 시스템 설정에서 허용 → 자동 실행됨
/// - `.requiresApproval` — 등록 했으나 시스템 설정에서 사용자가 허용 안 함 → 자동 실행 안 됨
/// - `.notFound` — `Contents/Library/LoginItems/` 안 가짜 helper 못 찾음 (mainApp 모드는 무관)
enum LoginItem {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static func register() throws {
        try SMAppService.mainApp.register()
    }

    static func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    /// 시스템 설정 → 일반 → 로그인 항목 페이지 직접 열기.
    /// 사용자가 requiresApproval 상태인 우리 앱을 거기서 토글 켤 수 있도록.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

// MARK: - Sparkle Delegates (조용한 알림 패턴)

/// 자동 업데이트 UX:
///   1. Sparkle 이 24h 주기로 백그라운드 체크
///   2. 새 버전 발견 → Sparkle 다이얼로그 띄우지 않고 우리에게 위임
///   3. 메뉴바 아이콘에 빨간 점 + 메뉴 안 "🔴 새 버전 X.Y.Z 사용 가능" 항목 표시
///   4. 사용자가 그 항목 클릭 → 표준 Sparkle 다이얼로그 표시 → 다운로드/설치
///   5. 사용자가 다이얼로그 본 시점에 빨간 점 제거
///
/// 메뉴 안 "업데이트 확인…" 은 사용자 직접 트리거 — userInitiated=true 라
/// 이 hook 들이 가로채지 않고 표준 다이얼로그가 바로 뜬다.
extension AppDelegate: SPUStandardUserDriverDelegate {

    /// gentle reminder 모드 활성화 — Sparkle 이 자동 체크에서 발견한 업데이트를
    /// 즉시 다이얼로그로 띄우지 않고, willHandleShowingUpdate 로 위임한다.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// 자동 체크에서 발견된 업데이트를 Sparkle 표준 다이얼로그로 띄울지 결정.
    /// 메뉴바 앱(LSUIElement)은 immediate focus 상황이 거의 없고, 갑자기 모달이
    /// 뜨면 사용자가 깜짝 놀란다. 항상 false → 우리가 메뉴바 알림으로 처리.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        return false
    }

    /// 다이얼로그 표시 직전 호출. handleShowingUpdate=false 면 Sparkle 이 안 띄움 → 우리 차례.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate {
            log.notice("Sparkle: gentle reminder — pending update \(update.displayVersionString, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                self?.pendingUpdate = update
            }
        }
    }

    /// 사용자가 업데이트 다이얼로그 봤음 → 빨간 점 제거.
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        log.notice("Sparkle: user saw update dialog for \(update.displayVersionString, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.pendingUpdate = nil
        }
    }
}

extension AppDelegate: SPUUpdaterDelegate {
    // 옵셔널 hook 들. 기본 동작으로 충분 — 향후 필요 시 추가:
    //   - feedURLString(for:) : 동적으로 SUFeedURL 변경 (예: beta 채널)
    //   - allowedSystemProfileKeys(for:) : 익명 텔레메트리 옵트인
    //   - bestValidUpdate(in:for:) : 사용자 시스템에 맞는 best 버전 선택 로직 커스텀
}

// MARK: - 익명 오류 수집 (crash & error reporting)
//
// 직배포(Developer ID + Sparkle) 환경은 Apple 크래시 집계에 안 잡힌다. 외부 SaaS(Sentry 등) 없이
// 데이터 통제권을 유지하기 위해 자체 Cloudflare Worker(appcast 텔레메트리와 같은 스택)로 보낸다.
//
// 설계 핵심:
//   - 인프로세스 시그널 핸들러 없음. macOS 가 적어둔 `~/Library/Logs/DiagnosticReports/DiskOUT-*.ips`
//     를 *다음 실행* 때 수확(deferred harvest) → 파싱 → 스크럽 → POST. 견고하고 async-signal-safe 걱정 0.
//   - 프라이버시 최우선: 디스크명·볼륨명·경로·유저명·원본 IP 는 절대 전송 안 함. 불확실하면 필드 생략.
//   - 전부 best-effort: 모든 네트워크/파싱 에러 swallow. 앱을 절대 크래시시키지 않는다.
//   - `SettingsStore.crashReportingEnabled`(default ON) 으로 전체 게이트.

/// 리포트 전송 공통 인프라 — 엔드포인트, 버전 메타, 스크럽, 무시-실패 POST.
fileprivate enum ReportEndpoint {
    static let url = URL(string: "https://diskout-appcast.sukmack.workers.dev/report")!
    static let expectedBundleID = "com.yongza.ejectdrives"
    static let signatureLimit = 256
    static let detailLimit = 4096   // ~4KB cap
    private static let operations = CancelableOperationRegistry(enabled: false)

    /// Turning diagnostics off is a hard boundary: reject queued work and cancel active requests.
    static func setReportingEnabled(_ enabled: Bool) {
        operations.setEnabled(enabled)
    }

    /// CFBundleShortVersionString — 못 읽으면 "?".
    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    /// macOS 버전 — coarse "major.minor.patch" 만 (빌드 번호·하드웨어 미포함).
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// best-effort POST — 짧은 타임아웃, 모든 에러 swallow, 절대 throw/crash 안 함.
    /// payload 의 모든 문자열 값은 호출 전에 스크럽·truncate 가 끝나 있어야 한다.
    /// `completion(success)` 는 실제 2xx 응답일 때만 true (오프라인·타임아웃·non-2xx → false).
    /// 호출부가 결과에 따라 dedup 기록 여부를 정할 수 있게 (예: 크래시 at-least-once).
    static func post(_ payload: [String: String], completion: ((Bool) -> Void)? = nil) {
        guard SettingsStore.crashReportingEnabled else {
            completion?(false)
            return
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            completion?(false)
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let completionGate = OneShotBooleanCallback(completion)
        // 응답·에러는 best-effort. success = (에러 없음 && HTTP 2xx). completion 절대 throw/crash 안 함.
        let operationID = UUID()
        let task = session.dataTask(with: request) { _, response, error in
            let success = error == nil
                && ((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false)
            operations.finish(id: operationID)
            completionGate.call(success)
            session.finishTasksAndInvalidate()
        }
        guard operations.register(id: operationID, cancel: {
            task.cancel()
            session.invalidateAndCancel()
        }) else {
            session.invalidateAndCancel()
            completionGate.call(false)
            return
        }
        task.resume()
    }
}

/// 전송 전 클라이언트 스크럽 — `.ips` 엔 홈 경로·유저명·마운트 볼륨명이 섞인다.
/// 설정 고지("디스크명·경로·신원 절대 미전송")의 약속을 지키는 마지막 방어선.
fileprivate enum ReportScrubber {
    /// `NSHomeDirectory()`/`/Users/<name>/…` → `~/…`, `/Volumes/<name>` 제거,
    /// 비경로 토큰에 박힌 유저명 치환, secret 패턴 마스킹.
    /// 순서 중요: 홈 경로 prefix 치환 먼저 → 그래야 그 뒤 패턴들이 익명화된 경로를 본다.
    static func scrub(_ input: String) -> String {
        var s = input

        // 1) 홈 경로 익명화.
        //    1a) 리터럴 NSHomeDirectory() prefix 를 먼저 ~ 로 — 공백·아포스트로피 등
        //        특수문자 포함 유저명까지 완전 커버 (제네릭 정규식이 꼬리를 흘리는 문제 차단).
        let home = NSHomeDirectory()
        if !home.isEmpty {
            s = s.replacingOccurrences(of: home, with: "~")
        }
        //    1b) 제네릭 /Users/<name>/  →  ~/   (이름 부분이 곧 유저명이라 함께 제거).
        //        세그먼트를 *다음 슬래시까지* 소비 → 공백·아포스트로피 포함 이름(다른 사용자
        //        경로 포함)도 꼬리 안 흘리고 제거. 과다 스크럽은 프라이버시상 안전한 방향.
        s = replace(s, pattern: #"/Users/[^/\n]+/"#, with: "~/")
        //    경로 끝(슬래시 없이 끝나는) /Users/<name> 도 처리
        s = replace(s, pattern: #"/Users/[^/\n]+"#, with: "~")
        // /private/var/folders/... (유저별 임시 경로) — 식별 가능성 차단
        s = replace(s, pattern: #"/private/var/folders/[^\s"']*"#, with: "~tmp")
        s = replace(s, pattern: #"/var/folders/[^\s"']*"#, with: "~tmp")

        // 2) 마운트된 볼륨 이름 제거 — 그 자체가 개인정보 (외장 라벨 등).
        //    멀티워드 라벨("My Passport")까지 먹도록 줄 끝/따옴표까지 소비
        //    (꼬리 토큰 과다 스크럽은 프라이버시 측면에서 안전한 방향).
        s = replace(s, pattern: #"/Volumes/[^"'\n]*"#, with: "/Volumes/…")

        // 3) 비경로 토큰에 남은 유저명 치환 — reverse-DNS id(com.<name>.helper),
        //    dispatch-queue 라벨, 서명 문자열 등은 위 경로 규칙을 안 거친다.
        //    word-boundary + 대소문자 무시로 단독 등장만 <user> 로.
        let user = NSUserName()
        if !user.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: user)
            s = replace(s, pattern: #"(?i)\b"# + escaped + #"\b"#, with: "<user>")
        }

        // 4) 명백한 secret 패턴 마스킹 (key/token/password/secret = value)
        s = replace(s, pattern: #"(?i)(api[_-]?key|secret|token|password|passwd|pwd|bearer)\b\s*[:=]\s*\S+"#, with: "$1=***")
        // sk-/ghp_ 같은 잘 알려진 토큰 prefix
        s = replace(s, pattern: #"\b(sk|pk|ghp|gho|ghs|xox[baprs])[-_][A-Za-z0-9]{8,}"#, with: "***")

        return s
    }

    private static func replace(_ s: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }
}

/// 핸들드 에러(eject 실패 등) 카테고리 집계 — `kind:"error"`.
/// 호출부는 **코스 카테고리만** 넘긴다 (디스크명·볼륨명·BSD·경로 금지).
/// 클라이언트 dedup: 같은 `(signature, app_version)` 은 영구히 1회만 전송.
fileprivate enum ErrorReporter {
    private static let sentKey = "errorReporting.sentSignatures"
    private static let sentCap = 500
    private static let lock = NSLock()

    /// 코스 카테고리 시그니처를 1회 한정 전송. crashReportingEnabled OFF 면 no-op.
    /// 모든 작업은 best-effort — 절대 throw/crash 안 함.
    static func report(signature rawSignature: String) {
        guard SettingsStore.crashReportingEnabled else { return }

        let version = ReportEndpoint.appVersion
        // 전송될 시그니처(truncate 후)로 dedup 키를 만든다 — POST 되는 값과 dedup 기준 일치.
        let signature = String(rawSignature.prefix(ReportEndpoint.signatureLimit))
        // dedup 키 = "signature|version" — 같은 버전에서 같은 에러는 한 번만.
        let dedupKey = "\(signature)|\(version)"

        lock.lock()
        // 순서 보존 array — cap 초과 trim 시 오래된 것부터 버리고 방금 넣은 키는 절대 안 버림.
        var sent = UserDefaults.standard.stringArray(forKey: sentKey) ?? []
        if sent.contains(dedupKey) {
            lock.unlock()
            return
        }
        sent.append(dedupKey)
        // array 무한 성장 방지 — 안전 상한 (시그니처 종류는 본질적으로 적음). 가장 오래된 것부터 drop.
        if sent.count > sentCap {
            sent.removeFirst(sent.count - sentCap)
        }
        UserDefaults.standard.set(sent, forKey: sentKey)
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            guard SettingsStore.crashReportingEnabled else { return }
            ReportEndpoint.post([
                "kind": "error",
                "signature": signature,
                "app_version": version,
                "os_version": ReportEndpoint.osVersion,
            ])
        }
    }
}

/// 크래시 사후 수확 — DiagnosticReports 의 새 `.ips` 만 스캔·파싱·스크럽·전송.
fileprivate enum CrashReporter {
    // 이미 리포트한 크래시 신원(incident_id 등)의 *순서 보존* 배열을 보관한다.
    // 단일 watermark(lastSeenCrashDate) 방식은 파싱 실패한 .ips 를 영구히 건너뛰어
    // (spec §2 "진짜 새 크래시 영구 억제 금지" 위반) 폐기. 신원 집합으로 dedup 한다.
    private static let reportedKey = "crashReporting.reportedIdentities"
    private static let reportedCap = 200
    // mtime 은 디렉터리 스캔 범위를 좁히는 *나이 사전필터* 로만 사용 (식별엔 안 씀).
    // Time Machine/iCloud/마이그레이션이 mtime 을 리셋해도 신원 집합이 dedup 을 책임진다.
    private static let maxAgeSeconds: TimeInterval = 30 * 24 * 60 * 60   // ~30일
    private static let topFrameLimit = 20
    private static let lock = NSLock()

    /// crashReportingEnabled 면 백그라운드 utility 큐에서 수확 시작. launch 를 절대 막지 않음.
    static func harvestIfEnabled() {
        guard SettingsStore.crashReportingEnabled else { return }
        DispatchQueue.global(qos: .utility).async {
            harvest()
        }
    }

    /// 단일 패스 수확 — 어떤 `.ips` 가 malformed 여도 전체가 안전하게 진행.
    /// 신원이 이미 리포트 집합에 있으면 skip. 파싱 + 전송 2xx 성공 후에만 신원을 집합에 추가.
    private static func harvest() {
        let fm = FileManager.default
        guard let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true) else { return }

        let candidates: [URL]
        do {
            let contents = try fm.contentsOfDirectory(
                at: logsDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
            candidates = contents.filter {
                $0.pathExtension == "ips" && $0.lastPathComponent.hasPrefix("DiskOUT-")
            }
        } catch {
            return  // 폴더 없음/권한 등 — best-effort, 조용히 종료.
        }

        // 리포트된 신원 집합을 한 번 읽어와 메모리에서 비교 (순서 보존).
        // 이 스냅샷은 *이전 실행* 까지의 신원 — 같은 실행 내 파일은 신원이 서로 달라 중복 전송 없음.
        let reported = loadReported()
        let cutoff = Date().addingTimeInterval(-maxAgeSeconds)

        for url in candidates {
            guard SettingsStore.crashReportingEnabled else { return }
            // 나이 사전필터: ~30일보다 오래된 .ips 는 스캔 비용 절감 위해 무시 (식별 아님).
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard mtime >= cutoff else { continue }

            // 파싱·전송은 개별 try? 로 격리 — 한 파일이 깨져도 다음 파일 계속.
            // 파싱 실패 → continue (신원 미기록 → 다음 실행 때 재시도).
            guard let parsed = parseIPS(at: url) else { continue }

            // 이미 리포트한 신원이면 skip.
            if reported.contains(parsed.identity) { continue }

            ReportEndpoint.post([
                "kind": "crash",
                "signature": parsed.signature,
                "detail": parsed.detail,
                "app_version": parsed.appVersion,
                "os_version": parsed.osVersion,
            ]) { success in
                // at-least-once: 실제 2xx 성공 시에만 신원 기록. 실패(오프라인·타임아웃·5xx)면
                // 미기록 → 다음 실행 때 재시도 (.ips 는 30일 내 디스크에 남아있음). 중복 전송은
                // 서버측 UNIQUE(day,install_hash,kind,signature) dedup 이 흡수.
                if success { recordReported(parsed.identity) }
            }
        }
    }

    /// 리포트된 신원 배열 로드 (순서 보존).
    private static func loadReported() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return UserDefaults.standard.stringArray(forKey: reportedKey) ?? []
    }

    /// 신원 1건 기록 후 cap 초과 시 *가장 오래된 것부터* drop (방금 추가한 건 절대 안 버림).
    /// POST 완료 콜백(백그라운드 큐)에서 호출 — 디스크 최신본을 다시 읽어 동시성 손실 방지.
    private static func recordReported(_ identity: String) {
        lock.lock(); defer { lock.unlock() }
        var arr = UserDefaults.standard.stringArray(forKey: reportedKey) ?? []
        if arr.contains(identity) { return }
        arr.append(identity)
        if arr.count > reportedCap {
            arr.removeFirst(arr.count - reportedCap)
        }
        UserDefaults.standard.set(arr, forKey: reportedKey)
    }

    private struct ParsedCrash {
        let identity: String
        let signature: String
        let detail: String
        let appVersion: String
        let osVersion: String
    }

    /// modern `.ips` = 헤더 JSON 한 줄 + 바디 JSON. 둘 다 파싱해 시그니처/디테일 추출.
    /// 어느 단계든 형식이 어긋나면 nil (best-effort).
    private static func parseIPS(at url: URL) -> ParsedCrash? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        // 헤더 = 첫 번째 비어있지 않은 줄(JSON object). 바디 = 그 뒤 나머지 전체(JSON object).
        guard let firstNewline = raw.firstIndex(of: "\n") else { return nil }
        let headerLine = String(raw[raw.startIndex..<firstNewline])
        let bodyText = String(raw[raw.index(after: firstNewline)...])

        guard let headerData = headerLine.data(using: .utf8),
              let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any] else {
            return nil
        }

        // 매칭 확정: 헤더 bundleID == com.yongza.ejectdrives.
        let bundleID = (header["bundleID"] as? String) ?? (header["bundleId"] as? String)
        guard bundleID == ReportEndpoint.expectedBundleID else { return nil }

        guard let bodyData = bodyText.data(using: .utf8),
              let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
            return nil
        }

        // 앱 버전 — 헤더의 app_version 우선, 없으면 현재 번들 버전.
        let crashAppVersion = (header["app_version"] as? String).map { String($0.prefix(64)) }
            ?? ReportEndpoint.appVersion
        // OS 버전 — 바디 osVersion.train / .build 사용, 없으면 현재 OS.
        let crashOSVersion = osVersionString(from: body) ?? ReportEndpoint.osVersion

        // 예외 타입 (signal). exception.type 가 핵심.
        let exception = body["exception"] as? [String: Any]
        let exceptionType = (exception?["type"] as? String) ?? "UNKNOWN_EXCEPTION"
        let exceptionSignal = exception?["signal"] as? String
        let exceptionLabel = exceptionSignal.map { "\(exceptionType) (\($0))" } ?? exceptionType

        // 크래시 스레드 백트레이스 추출.
        let (topAppSymbol, frameLines) = backtrace(from: body)

        // SIGNATURE = 예외타입 + top 앱 프레임 심볼.
        let rawSignature = topAppSymbol.map { "\(exceptionLabel) @ \($0)" } ?? exceptionLabel
        let signature = String(ReportScrubber.scrub(rawSignature).prefix(ReportEndpoint.signatureLimit))

        // DETAIL = 스크럽된 백트레이스 (예외 라벨 + 상위 N 프레임), ~4KB cap.
        var detailLines = ["\(exceptionLabel)"]
        detailLines.append(contentsOf: frameLines)
        let scrubbedDetail = ReportScrubber.scrub(detailLines.joined(separator: "\n"))
        let detail = String(scrubbedDetail.prefix(ReportEndpoint.detailLimit))

        // 크래시 내재 타임스탬프 — 바디 captureTime 우선, 없으면 헤더 timestamp.
        // 신원 해시 fallback 에만 쓰고, mtime 은 절대 신원에 안 쓴다(dedup 은 신원 집합이 책임).
        let captureTime = (body["captureTime"] as? String) ?? (header["timestamp"] as? String)

        // 신원 = 헤더 incident_id(UUID) → crashReporterKey → (captureTime+signature) 안정 해시.
        let identity = crashIdentity(header: header, captureTime: captureTime, signature: signature)

        return ParsedCrash(identity: identity,
                           signature: signature,
                           detail: detail,
                           appVersion: crashAppVersion,
                           osVersion: crashOSVersion)
    }

    /// 크래시 신원 한 줄: incident_id(UUID) 우선, 없으면 crashReporterKey,
    /// 둘 다 없으면 (captureTime + signature) 의 안정 해시. dedup 의 기준.
    private static func crashIdentity(header: [String: Any], captureTime: String?, signature: String) -> String {
        if let incident = (header["incident_id"] as? String), !incident.isEmpty {
            return "iid:" + incident
        }
        if let key = (header["crashReporterKey"] as? String), !key.isEmpty {
            return "crk:" + key
        }
        // fallback: 외부 의존 없는 결정적 해시(FNV-1a 64-bit, hex). 같은 크래시는 항상 같은 값.
        let basis = (captureTime ?? "") + "|" + signature
        return "h:" + stableHashHex(basis)
    }

    /// FNV-1a 64-bit → 16자리 hex. CryptoKit 의존 없이 안정·결정적 (dedup 키 용도로 충분).
    private static func stableHashHex(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }

    /// 바디 osVersion = { "train": "macOS 14.5", "build": "..." } 형태. train 만 (build 미포함).
    private static func osVersionString(from body: [String: Any]) -> String? {
        guard let os = body["osVersion"] as? [String: Any] else { return nil }
        if let train = os["train"] as? String { return String(train.prefix(64)) }
        return nil
    }

    /// 크래시 스레드의 백트레이스를 (top 앱 심볼, "프레임 라인" 배열) 로 추림.
    /// 레지스터 덤프·환경변수·스레드 전체 덤프는 제외 — 프레임 심볼/바이너리만.
    /// 앱 프레임 = imageIndex 가 procName == DiskOUT 인 이미지인 프레임.
    private static func backtrace(from body: [String: Any]) -> (topAppSymbol: String?, frames: [String]) {
        let images = body["usedImages"] as? [[String: Any]] ?? []
        // DiskOUT 메인 이미지 인덱스들 — 앱 프레임 판별용.
        var appImageIndices = Set<Int>()
        for (idx, img) in images.enumerated() {
            if let name = img["name"] as? String, name == "DiskOUT" {
                appImageIndices.insert(idx)
            }
        }

        // 크래시 스레드 찾기: threads[].triggered == true 우선, 없으면 faultingThread 인덱스.
        let threads = body["threads"] as? [[String: Any]] ?? []
        var crashThread: [String: Any]?
        for t in threads where (t["triggered"] as? Bool) == true {
            crashThread = t
            break
        }
        if crashThread == nil, let faulting = body["faultingThread"] as? Int, faulting < threads.count {
            crashThread = threads[faulting]
        }
        if crashThread == nil { crashThread = threads.first }

        let frames = (crashThread?["frames"] as? [[String: Any]]) ?? []
        var lines: [String] = []
        var topAppSymbol: String?

        for frame in frames.prefix(topFrameLimit) {
            let imageIndex = frame["imageIndex"] as? Int
            let isAppFrame = imageIndex.map { appImageIndices.contains($0) } ?? false
            let binaryName: String
            if let imageIndex, imageIndex < images.count,
               let n = images[imageIndex]["name"] as? String {
                binaryName = n
            } else {
                binaryName = "?"
            }

            // 심볼: symbol(디멩글된 이름) 우선, 없으면 imageOffset 만.
            let symbol = (frame["symbol"] as? String).map { String($0.prefix(120)) }
            let offset = frame["imageOffset"] as? Int
            let symbolText: String
            if let symbol {
                symbolText = symbol
            } else if let offset {
                symbolText = "\(binaryName) + \(offset)"
            } else {
                symbolText = binaryName
            }

            if isAppFrame, topAppSymbol == nil, let symbol {
                topAppSymbol = symbol
            } else if isAppFrame, topAppSymbol == nil {
                topAppSymbol = symbolText
            }

            lines.append("\(binaryName)  \(symbolText)")
        }

        return (topAppSymbol, lines)
    }
}
