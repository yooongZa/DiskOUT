//
//  AppDelegate.swift
//  EjectDrives — 혼자 쓰는 초간단 버전
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

/// 통합 로깅 (unified logging) — Console.app 에서 다음 명령으로 확인:
///   log stream --predicate 'subsystem == "com.yongza.ejectdrives"' --info
private let log = Logger(subsystem: "com.yongza.ejectdrives", category: "app")

private let ioMessageCanSystemSleep: UInt32 = 0xe0000270
private let ioMessageSystemWillSleep: UInt32 = 0xe0000280
private let ioMessageSystemWillNotSleep: UInt32 = 0xe0000290
private let ioMessageSystemHasPoweredOn: UInt32 = 0xe0000300
private let ioPMMessageClamshellStateChange = UInt32(bitPattern: Int32(-536657664))
private let clamshellStateBit = 1 << 0
private let clamshellSleepBit = 1 << 1

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {

    private var statusItem: NSStatusItem!
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var settingsWindowController: SettingsWindowController?
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
    /// 자동(lid-close) 추출된 disk BSD names — wake 시 재마운트 대상.
    /// 수동 추출(단축키/메뉴)은 여기 안 들어감 — 사용자 의도 존중.
    private var _autoEjectedDisks: Set<String> = []
    private var autoEjectedDisks: Set<String> {
        get { autoEjectStateLock.lock(); defer { autoEjectStateLock.unlock() }; return _autoEjectedDisks }
        set { autoEjectStateLock.lock(); defer { autoEjectStateLock.unlock() }; _autoEjectedDisks = newValue }
    }
    /// 자동 추출부터 wake/remount 까지 같은 사건을 묶는 진단용 ID.
    private var _autoEjectOperationID: String?
    private var autoEjectOperationID: String? {
        get { autoEjectStateLock.lock(); defer { autoEjectStateLock.unlock() }; return _autoEjectOperationID }
        set { autoEjectStateLock.lock(); defer { autoEjectStateLock.unlock() }; _autoEjectOperationID = newValue }
    }
    private var _autoEjectOperationReason: String?
    private var autoEjectOperationReason: String? {
        get { autoEjectStateLock.lock(); defer { autoEjectStateLock.unlock() }; return _autoEjectOperationReason }
        set { autoEjectStateLock.lock(); defer { autoEjectStateLock.unlock() }; _autoEjectOperationReason = newValue }
    }
    /// `Eject and Sleep` 이 이미 추출한 직후 들어오는 willSleep 중복 자동 추출 방지.
    private var _skipSleepAutoEjectUntil: Date?
    private var skipSleepAutoEjectUntil: Date? {
        get { autoEjectStateLock.lock(); defer { autoEjectStateLock.unlock() }; return _skipSleepAutoEjectUntil }
        set { autoEjectStateLock.lock(); defer { autoEjectStateLock.unlock() }; _skipSleepAutoEjectUntil = newValue }
    }
    private var powerRootPort: io_connect_t = 0
    private var powerNotifyPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var clamshellRootDomain: io_service_t = 0
    private var clamshellNotifier: io_object_t = 0
    private var handlingPowerSleep = false
    private let sleepEjectQueue = DispatchQueue(label: "com.yongza.ejectdrives.sleep.eject")
    private let sleepEjectStateLock = NSLock()
    private var activeSleepEjectGroup: DispatchGroup?
    private var activeSleepEjectOperationID: String?
    private var activeSleepEjectReason: String?
    private var lastSleepEjectOperationID: String?
    private var lastSleepEjectCompletedAt: Date?
    /// logout/restart/shutdown 전 자동 추출은 현재 제품 가치가 낮아 기본 비활성화.
    private let powerOffAutoEjectEnabled = false
    /// logout/restart/shutdown 직전 자동 추출 상태.
    private var powerOffEjectInProgress = false
    private var powerOffEjectCompleted = false
    private var shouldEjectBeforeTerminate = false
    private var pendingTerminateReplyApp: NSApplication?
    private lazy var cachedDefaultIcon: NSImage? = {
        let img = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject Drives")
        img?.isTemplate = true
        return img
    }()
    /// 마지막으로 확인한 알림 권한 상태. `getNotificationSettings` 가 비동기라 메뉴에서
    /// 동기 표시할 수 없어 캐싱. launch / menu 열 때 background refresh.
    private var lastKnownNotificationStatus: UNAuthorizationStatus = .notDetermined

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        if SettingsStore.notificationsEnabled {
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                log.notice("requestAuthorization: granted=\(granted, privacy: .public) error=\(error?.localizedDescription ?? "nil", privacy: .public)")
            }

            // 권한 상태 진단 + 메뉴 표시용 캐싱
            center.getNotificationSettings { [weak self] settings in
                log.notice("notif settings: authStatus=\(settings.authorizationStatus.rawValue, privacy: .public) alert=\(settings.alertSetting.rawValue, privacy: .public) center=\(settings.notificationCenterSetting.rawValue, privacy: .public)")
                // authStatus: 0=notDetermined 1=denied 2=authorized 3=provisional 4=ephemeral
                // alert/center: 0=notSupported 1=disabled 2=enabled
                DispatchQueue.main.async {
                    self?.lastKnownNotificationStatus = settings.authorizationStatus
                }
            }
        }

        setupStatusItem()
        setupSleepObserver()
        setupPowerSleepObserver()
        setupClamshellObserver()
        DiskMenuSnapshotCache.warm()
        installHotkey()
        log.notice("EjectDrives launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        tearDownPowerSleepObserver()
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = cachedDefaultIcon
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
            flashIcon(symbol: "hand.tap.fill", duration: 0.3)
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
                             #selector(openAccessibilitySettings)))
        }
        if SettingsStore.notificationsEnabled,
           lastKnownNotificationStatus == .denied {
            warnings.append((String(localized: "Allow notifications to see eject results"),
                             #selector(openNotificationSettings)))
        }
        return warnings
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openLoginItemSettings() {
        LoginItem.openSystemSettings()
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
            let updating = NSMenuItem(title: String(localized: "Updating disk status..."),
                                      action: nil, keyEquivalent: "")
            updating.isEnabled = false
            menu.addItem(updating)
            menu.addItem(NSMenuItem.separator())
        } else if let refreshError = snapshot.refreshError {
            let failed = NSMenuItem(title: String(localized: "Disk status update failed"),
                                    action: nil,
                                    keyEquivalent: "")
            failed.isEnabled = false
            failed.toolTip = refreshError
            menu.addItem(failed)
            menu.addItem(NSMenuItem.separator())
        }

        if drives.isEmpty {
            let empty = NSMenuItem(title: String(localized: "No external drives"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            // Time Machine 디스크 첫 등장 시 자동으로 ExcludedVolumes 에 추가 + 1회 알림.
            // 사용자가 모르는 사이 백업 디스크가 자동 추출되어 백업 사이클 깨지는 사고 방지.
            autoExcludeNewTimeMachineDisks(drives)

            for drive in drives {
                // 메뉴 항목 라벨 — 상태 suffix 로 한 눈에 파악:
                //   "업무백업 (Time Machine, 자동 제외)" / "SSD_W (자동 제외)" / "SYSJO"
                let isExcluded = ExcludedVolumes.isExcluded(drive.volumeUUID)
                var labels: [String] = []
                if drive.isTimeMachine { labels.append("Time Machine") }
                if isExcluded && !drive.isTimeMachine { labels.append(String(localized: "auto-eject excluded")) }
                let suffix = labels.isEmpty ? "" : " (\(labels.joined(separator: ", ")))"

                let item = NSMenuItem(title: drive.name + suffix,
                                      action: #selector(ejectOne(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = drive.url
                item.isEnabled = !isRefreshing
                item.image = menuSymbol(drive.isTimeMachine ? "clock.arrow.circlepath" : drive.kind.symbolName,
                                        fallback: "externaldrive")
                // submenu 폐기 — submenu 가 있으면 macOS 가 클릭 시 action 무시 (추출 안 됨).
                // 자동 추출 제외 토글은 메뉴 하단의 별도 "자동 추출 제외 디스크" submenu 로 이동.
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
            let ejectHotkey = SettingsStore.ejectHotkey
            let ejectAllItem = NSMenuItem(title: String(localized: "Eject all  (\(ejectHotkey.title) · or right-click)"),
                                          action: #selector(ejectAllAction(_:)),
                                          keyEquivalent: "e")
            ejectAllItem.keyEquivalentModifierMask = ejectHotkey.flags
            ejectAllItem.target = self
            ejectAllItem.isEnabled = !isRefreshing
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
            let header = NSMenuItem(title: String(localized: "Unmounted drives"),
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
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
                let mountAllItem = NSMenuItem(title: String(localized: "Mount all  (\(mountHotkey.title))"),
                                              action: #selector(mountAllAction(_:)),
                                              keyEquivalent: "e")
                mountAllItem.keyEquivalentModifierMask = mountHotkey.flags
                mountAllItem.target = self
                mountAllItem.isEnabled = !isRefreshing
                menu.addItem(mountAllItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // 메뉴에는 자주 토글하는 핵심 옵션만 둔다. display sleep / Music·Photos 자동 종료 /
        // 로그인 자동 실행은 한 번 설정하고 끝나는 항목이라 환경설정 창 (Settings...) 으로 이동.
        // 양쪽에 같은 토글이 있으면 어디서 켰는지 사용자가 헷갈림.
        let toggle = NSMenuItem(title: String(localized: "Eject on sleep"),
                                action: #selector(toggleSleepEject),
                                keyEquivalent: "")
        toggle.target = self
        toggle.state = SleepEject.enabled ? .on : .off
        menu.addItem(toggle)

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
            menu.addItem(NSMenuItem.separator())
            let parent = NSMenuItem(title: String(localized: "Auto-eject excluded disks"),
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

        menu.addItem(NSMenuItem.separator())

        let settings = NSMenuItem(title: String(localized: "Settings..."),
                                  action: #selector(showSettingsWindow(_:)),
                                  keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        settings.image = menuSymbol("gearshape", fallback: "gear")
        menu.addItem(settings)

        let quit = NSMenuItem(title: String(localized: "Quit EjectDrives"),
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        let elapsed = Date().timeIntervalSince(started)
        log.info("menuWillOpen: built in \(String(format: "%.3f", elapsed), privacy: .public)s drives=\(drives.count, privacy: .public) unmounted=\(unmounted.count, privacy: .public) refreshing=\(isRefreshing, privacy: .public)")
    }

    @objc private func toggleSleepEject() {
        SleepEject.enabled.toggle()
        log.info("SleepEject toggled → \(SleepEject.enabled, privacy: .public)")
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
            })
        }
        settingsWindowController?.show()
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
            button.image = newImg
            self.iconFlashGeneration += 1
            let myGen = self.iconFlashGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self = self, let button = self.statusItem.button else { return }
                // 그 사이 다른 flashIcon / setPersistentIcon / resetIcon 호출되었으면 skip.
                guard self.iconFlashGeneration == myGen else { return }
                button.image = self.cachedDefaultIcon
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
            button.image = img
            self.iconFlashGeneration += 1   // 진행중인 flashIcon reset 무효화
            let myGen = self.iconFlashGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
                guard let self = self, self.iconFlashGeneration == myGen else { return }
                self.resetIcon()
            }
        }
    }

    /// 메뉴바 아이콘을 default ⏏ 로 reset. lastResultSymbol 도 clear.
    private func resetIcon() {
        lastResultSymbol = nil
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            button.image = self.cachedDefaultIcon
            self.iconFlashGeneration += 1   // 진행중인 flashIcon reset 무효화
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

    /// 개별 드라이브 추출 (메뉴 아이템 클릭).
    @objc private func ejectOne(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let name = sender.title
        let path = url.path
        log.info("EJECTONE start: \(name, privacy: .public) at \(path, privacy: .public)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.diskutilEject(volumePath: path)
            DiskMenuSnapshotCache.invalidate()
            DiskMenuSnapshotCache.warm()
            log.info("EJECTONE done: \(name, privacy: .public) success=\(result.success, privacy: .public) err=\(result.errorMessage ?? "-", privacy: .public)")
            DispatchQueue.main.async {
                if result.success {
                    self.notify(title: String(localized: "Ejected"), body: name, kind: .success)
                } else {
                    self.notify(title: String(localized: "Couldn't eject \(name)"),
                                body: result.errorMessage ?? String(localized: "Unknown error"),
                                archived: true,
                                kind: .failure)
                }
            }
        }
    }

    /// 모든 외장 드라이브 추출. caller 는 식별용 문자열.
    private func ejectAll(caller: String) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastEjectAt)
        if elapsed < 1.5 {
            log.info("EJECT(\(caller, privacy: .public)) DEBOUNCED — last fired \(String(format: "%.2f", elapsed), privacy: .public)s ago")
            flashIcon(symbol: "circle.dashed", duration: 0.3)
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
                let resultSymbol: String
                if result.attempted.isEmpty {
                    resultSymbol = "questionmark.circle"
                } else if result.failure.isEmpty {
                    resultSymbol = "checkmark.circle.fill"      // 모두 성공
                } else if result.success.isEmpty {
                    resultSymbol = "xmark.octagon.fill"          // 모두 실패
                } else {
                    resultSymbol = "exclamationmark.triangle.fill"  // 일부 성공/실패
                }
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
        lastEjectAt = now
        log.info("EJECT_AND_SLEEP(\(caller, privacy: .public)) START")
        flashIcon(symbol: "moon.zzz.fill", duration: 1.0)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let operation = self.newOperationID(reason: "ejectAndSleep")
            let result = self.ejectAllForSleep(operationID: operation,
                                               applyExcludeFilter: false,
                                               context: "ejectAndSleep")
            log.info("EJECT_AND_SLEEP(\(caller, privacy: .public)) eject done — attempted=\(result.attempted.count, privacy: .public) success=\(result.success.count, privacy: .public) failure=\(result.failure.count, privacy: .public)")

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.notifyResult((attempted: result.attempted,
                                   success: result.success,
                                   failure: result.failure))

                guard result.failure.isEmpty else {
                    log.notice("EJECT_AND_SLEEP(\(caller, privacy: .public)) sleep canceled because eject failed")
                    self.notify(title: String(localized: "Sleep canceled"),
                                body: String(localized: "Some drives didn't eject. Sleep was not started."),
                                archived: true,
                                kind: .failure)
                    self.setPersistentIcon(symbol: result.success.isEmpty ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    return
                }

                self.autoEjectOperationID = operation
                self.autoEjectOperationReason = "ejectAndSleep"
                self.autoEjectedDisks = result.remountTargets
                self.skipSleepAutoEjectUntil = Date().addingTimeInterval(15)
                log.info("EJECT_AND_SLEEP(\(caller, privacy: .public)) recorded successful BSDs: \(result.remountTargets.sorted(), privacy: .public)")

                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }
                    let sleep = self.requestSystemSleep()
                    guard !sleep.success else { return }
                    DispatchQueue.main.async { [weak self] in
                        self?.skipSleepAutoEjectUntil = nil
                        self?.notify(title: String(localized: "Couldn't start sleep"),
                                     body: sleep.errorMessage ?? String(localized: "Unknown error"),
                                     archived: true,
                                     kind: .failure)
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
            for (name, message) in result.failure.prefix(2) {
                lines.append("\(name): \(message)")
            }
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

    /// 병렬 추출. background thread 에서 호출하라.
    /// - parameter applyExcludeFilter: true 면 ExcludedVolumes 에 등록된 디스크는 추출 제외.
    ///   자동 (sleep / display sleep) path 에서만 true. 사용자 명시 추출은 false (사용자 의도 우선).
    @discardableResult
    private func ejectAllSilently(applyExcludeFilter: Bool = false,
                                  operationID: String? = nil) -> (attempted: [String], success: [String], failure: [(String, String)]) {
        let operation = operationID ?? "-"
        let listStarted = Date()
        var drives = ExternalDrive.list()
        log.info("cycle \(operation, privacy: .public) ejectAll list complete count=\(drives.count, privacy: .public) elapsed=\(self.elapsedText(since: listStarted), privacy: .public)s")
        if applyExcludeFilter {
            let filterStarted = Date()
            let before = drives.count
            drives = drives.filter { !ExcludedVolumes.isExcluded($0.volumeUUID) }
            let skipped = before - drives.count
            if skipped > 0 {
                log.info("cycle \(operation, privacy: .public) ejectAll filtered out \(skipped, privacy: .public) excluded disks elapsed=\(self.elapsedText(since: filterStarted), privacy: .public)s")
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
                                  context: String = "sleep") -> (attempted: [String],
                                                                 success: [String],
                                                                 failure: [(String, String)],
                                                                 remountTargets: Set<String>) {
        let listStarted = Date()
        var drives = ExternalDrive.list()
        log.info("cycle \(operationID, privacy: .public) \(context, privacy: .public) eject list complete count=\(drives.count, privacy: .public) elapsed=\(self.elapsedText(since: listStarted), privacy: .public)s")

        if applyExcludeFilter {
            let filterStarted = Date()
            let before = drives.count
            drives = drives.filter { !ExcludedVolumes.isExcluded($0.volumeUUID) }
            let skipped = before - drives.count
            if skipped > 0 {
                log.info("cycle \(operationID, privacy: .public) \(context, privacy: .public) eject filtered out \(skipped, privacy: .public) excluded disks elapsed=\(self.elapsedText(since: filterStarted), privacy: .public)s")
            }
        }

        let targets = drives.map { drive in
            (name: drive.name,
             volumePath: drive.url.path,
             wholeDiskBSDName: drive.wholeDiskBSDName)
        }
        log.info("cycle \(operationID, privacy: .public) \(context, privacy: .public) eject targets count=\(targets.count, privacy: .public) names=\(targets.map { $0.name }, privacy: .public) bsds=\(targets.compactMap { $0.wholeDiskBSDName }.sorted(), privacy: .public)")
        guard !targets.isEmpty else { return ([], [], [], []) }

        let lock = NSLock()
        var success: [String] = []
        var failure: [(String, String)] = []
        var remountTargets = Set<String>()
        let group = DispatchGroup()
        let parallelQueue = DispatchQueue(label: "com.yongza.ejectdrives.sleep.parallel",
                                          attributes: .concurrent)

        for target in targets {
            group.enter()
            parallelQueue.async {
                defer { group.leave() }
                let started = Date()
                log.info("cycle \(operationID, privacy: .public) → \(context, privacy: .public) eject start: \(target.name, privacy: .public) at \(target.volumePath, privacy: .public) bsd=\(target.wholeDiskBSDName ?? "-", privacy: .public)")
                let result = self.diskutilEjectForSleep(volumePath: target.volumePath,
                                                        wholeDiskBSDName: target.wholeDiskBSDName,
                                                        operationID: operationID,
                                                        context: context)
                let elapsed = Date().timeIntervalSince(started)
                lock.lock()
                if result.success {
                    success.append(target.name)
                    if let bsd = target.wholeDiskBSDName {
                        remountTargets.insert(bsd)
                    }
                } else {
                    failure.append((target.name, result.errorMessage ?? String(localized: "Unknown error")))
                }
                lock.unlock()

                if result.success {
                    log.info("cycle \(operationID, privacy: .public) ✓ \(context, privacy: .public) eject OK: \(target.name, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
                } else {
                    log.error("cycle \(operationID, privacy: .public) ✗ \(context, privacy: .public) eject FAIL: \(target.name, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s error=\(result.errorMessage ?? "unknown", privacy: .public)")
                }
            }
        }

        let waitStarted = Date()
        group.wait()
        log.info("cycle \(operationID, privacy: .public) \(context, privacy: .public) eject wait complete elapsed=\(self.elapsedText(since: waitStarted), privacy: .public)s success=\(success.count, privacy: .public) failure=\(failure.count, privacy: .public) remountTargets=\(remountTargets.sorted(), privacy: .public)")
        DiskMenuSnapshotCache.invalidate()
        log.info("cycle \(operationID, privacy: .public) \(context, privacy: .public) eject snapshot invalidated; warm skipped")
        return (targets.map { $0.name }, success, failure, remountTargets)
    }

    /// whole disk 의 mountable partition 들을 모두 mount.
    /// App Store/sandbox 포기 경로: helper daemon 없이 `diskutil mountDisk` 직접 실행.
    /// background thread 에서만 호출.
    private func daMountWholeDisk(bsdName: String, operationID: String? = nil) -> (success: Bool, errorMessage: String?) {
        let operation = operationID ?? "-"
        let r = runDiskutil(["mountDisk", bsdName], operationID: operationID)
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

        guard SettingsStore.forceFallbackEnabled else {
            log.notice("cycle \(operation, privacy: .public) force fallback disabled for \(volumePath, privacy: .public)")
            return eject
        }
        log.notice("cycle \(operation, privacy: .public) diskutil eject failed for \(volumePath, privacy: .public), fallback to unmount force — \(eject.errorMessage ?? "?", privacy: .public)")
        let force = runDiskutil(["unmount", "force", volumePath], operationID: operationID)
        if force.success {
            log.notice("cycle \(operation, privacy: .public) force fallback succeeded for \(volumePath, privacy: .public)")
            return force
        }

        let ejectMessage = eject.errorMessage ?? "diskutil eject failed"
        let forceMessage = force.errorMessage ?? "diskutil unmount force failed"
        var details = [ejectMessage, "force fallback: \(forceMessage)"]
        if let blockers = LsofInspector.diagnosticMessage(forVolumePath: volumePath) {
            details.append(blockers)
        }
        return (false, details.joined(separator: "\n"))
    }

    private func diskutilEjectForSleep(volumePath: String,
                                       wholeDiskBSDName: String?,
                                       operationID: String? = nil,
                                       context: String = "sleep") -> (success: Bool, errorMessage: String?) {
        let operation = operationID ?? "-"
        let forceTarget = wholeDiskBSDName ?? volumePath

        if SettingsStore.forceFallbackEnabled {
            log.notice("cycle \(operation, privacy: .public) \(context, privacy: .public) DA volume force unmount first target=\(volumePath, privacy: .public)")
            let daVolumeUnmount = diskArbitrationForceUnmountForSleep(volumePath: volumePath,
                                                                      wholeDiskBSDName: nil,
                                                                      operationID: operationID,
                                                                      timeout: 1.0,
                                                                      context: context)
            if daVolumeUnmount.success {
                log.notice("cycle \(operation, privacy: .public) \(context, privacy: .public) DA volume force unmount succeeded target=\(volumePath, privacy: .public)")
                return daVolumeUnmount
            }
            log.notice("cycle \(operation, privacy: .public) \(context, privacy: .public) DA volume force unmount failed target=\(volumePath, privacy: .public), fallback to diskutil unmountDisk force — \(daVolumeUnmount.errorMessage ?? "?", privacy: .public)")

            log.notice("cycle \(operation, privacy: .public) \(context, privacy: .public) unmountDisk force first target=\(forceTarget, privacy: .public)")
            let unmount = runDiskutil(["unmountDisk", "force", forceTarget],
                                      operationID: operationID,
                                      timeout: 10.0)
            if unmount.success {
                log.notice("cycle \(operation, privacy: .public) \(context, privacy: .public) force unmount succeeded target=\(forceTarget, privacy: .public)")
                return unmount
            }
            log.notice("cycle \(operation, privacy: .public) \(context, privacy: .public) force unmount failed target=\(forceTarget, privacy: .public), fallback to diskutil eject force — \(unmount.errorMessage ?? "?", privacy: .public)")

            log.notice("cycle \(operation, privacy: .public) \(context, privacy: .public) eject force second target=\(forceTarget, privacy: .public)")
            let force = runDiskutil(["eject", "force", forceTarget],
                                    operationID: operationID,
                                    timeout: 10.0)
            if force.success {
                log.notice("cycle \(operation, privacy: .public) \(context, privacy: .public) force eject succeeded target=\(forceTarget, privacy: .public)")
                return force
            }
            log.notice("cycle \(operation, privacy: .public) \(context, privacy: .public) force eject failed target=\(forceTarget, privacy: .public), fallback to normal eject — \(force.errorMessage ?? "?", privacy: .public)")

            let normal = runDiskutil(["eject", volumePath],
                                     operationID: operationID,
                                     timeout: 3.0)
            if normal.success {
                return normal
            }

            let forceMessage = force.errorMessage ?? "diskutil eject force failed"
            let normalMessage = normal.errorMessage ?? "diskutil eject failed"
            let daVolumeMessage = daVolumeUnmount.errorMessage ?? "DA volume force unmount failed"
            let unmountMessage = unmount.errorMessage ?? "diskutil unmountDisk force failed"
            return (false, ["\(context) DA volume force unmount: \(daVolumeMessage)", "\(context) force unmount: \(unmountMessage)", "\(context) force eject: \(forceMessage)", normalMessage].joined(separator: "\n"))
        }

        log.notice("cycle \(operation, privacy: .public) \(context, privacy: .public) force eject disabled for \(volumePath, privacy: .public)")
        return runDiskutil(["eject", volumePath],
                           operationID: operationID,
                           timeout: 10.0)
    }

    private func diskArbitrationForceUnmountForSleep(volumePath: String,
                                                     wholeDiskBSDName: String?,
                                                     operationID: String? = nil,
                                                     timeout: TimeInterval,
                                                     context: String = "sleep") -> (success: Bool, errorMessage: String?) {
        let operation = operationID ?? "-"
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return (false, "DASessionCreate failed")
        }

        let queue = DispatchQueue(label: "com.yongza.ejectdrives.sleep.da", qos: .userInitiated)
        DASessionSetDispatchQueue(session, queue)

        let disk: DADisk?
        let target: String
        let options: DADiskUnmountOptions
        if let bsd = wholeDiskBSDName,
           let wholeDisk = bsd.withCString({ DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }) {
            disk = wholeDisk
            target = bsd
            options = DADiskUnmountOptions(kDADiskUnmountOptionForce | kDADiskUnmountOptionWhole)
        } else {
            let url = URL(fileURLWithPath: volumePath) as CFURL
            disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url)
            target = volumePath
            options = DADiskUnmountOptions(kDADiskUnmountOptionForce)
        }

        guard let disk else {
            return (false, "DADiskCreate failed for \(target)")
        }

        let box = SleepDAUnmountBox(session: session, disk: disk)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        let started = Date()
        log.notice("cycle \(operation, privacy: .public) \(context, privacy: .public) DA force unmount start target=\(target, privacy: .public) timeout=\(String(format: "%.1f", timeout), privacy: .public)s")

        DADiskUnmount(disk, options, { (_, dissenter, ctx) in
            guard let ctx else { return }
            let box = Unmanaged<SleepDAUnmountBox>.fromOpaque(ctx).takeRetainedValue()
            if let dissenter {
                let status = DADissenterGetStatus(dissenter)
                let reason = (DADissenterGetStatusString(dissenter) as String?) ?? daDissenterStatusText(status)
                box.result = (false, "DA force unmount declined: \(reason)")
            } else {
                box.result = (true, nil)
            }
            box.semaphore.signal()
        }, ctx)

        if box.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            log.notice("cycle \(operation, privacy: .public) \(context, privacy: .public) DA force unmount timeout target=\(target, privacy: .public) elapsed=\(self.elapsedText(since: started), privacy: .public)s")
            return (false, "DA force unmount timed out")
        }

        let result = box.result ?? (false, "DA force unmount unknown result")
        if result.0 {
            log.notice("cycle \(operation, privacy: .public) \(context, privacy: .public) DA force unmount succeeded target=\(target, privacy: .public) elapsed=\(self.elapsedText(since: started), privacy: .public)s")
            return (true, nil)
        }

        log.notice("cycle \(operation, privacy: .public) \(context, privacy: .public) DA force unmount failed target=\(target, privacy: .public) elapsed=\(self.elapsedText(since: started), privacy: .public)s error=\(result.1 ?? "unknown", privacy: .public)")
        return (false, result.1)
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

    private func remountTargetsForCurrentExternalDrives(applyExcludeFilter: Bool,
                                                        operationID: String? = nil) -> Set<String> {
        let operation = operationID ?? "-"
        let started = Date()
        var drives = ExternalDrive.list()
        let listed = drives.count
        if applyExcludeFilter {
            drives = drives.filter { !ExcludedVolumes.isExcluded($0.volumeUUID) }
        }
        let targets = Set(drives.compactMap { $0.wholeDiskBSDName })
        log.info("cycle \(operation, privacy: .public) remount target scan listed=\(listed, privacy: .public) filtered=\(drives.count, privacy: .public) targets=\(targets.sorted(), privacy: .public) elapsed=\(self.elapsedText(since: started), privacy: .public)s")
        return targets
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
                                body: r.errorMessage ?? String(localized: "Unknown error"),
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
        log.notice("IOKit clamshell observer registered notifier=\(notifier, privacy: .public) closed=\(self.boolText(state.closed), privacy: .public) causesSleep=\(self.boolText(state.causesSleep), privacy: .public)")
    }

    private func tearDownPowerSleepObserver() {
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
            log.notice("IOKit canSystemSleep received notificationID=\(notificationID, privacy: .public); allowing idle sleep")
            allowPowerChange(notificationID: notificationID, operationID: "-")
        case ioMessageSystemWillSleep:
            handlePowerSystemWillSleep(notificationID: notificationID)
        case ioMessageSystemWillNotSleep:
            handlingPowerSleep = false
            log.notice("IOKit systemWillNotSleep received notificationID=\(notificationID, privacy: .public)")
        case ioMessageSystemHasPoweredOn:
            handlingPowerSleep = false
            log.notice("IOKit systemHasPoweredOn received notificationID=\(notificationID, privacy: .public)")
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

        guard closed else { return }
        if !causesSleep {
            log.notice("IOKit clamshell pre-eject continuing although lid close does not report sleep")
        }
        guard SleepEject.enabled else {
            log.info("IOKit clamshell pre-eject skipped — SleepEject disabled")
            return
        }

        let task = startSleepEjectIfNeeded(reason: "clamshell")
        log.notice("cycle \(task.operationID, privacy: .public) clamshell close pre-eject \((task.started ? "started" : "joined"), privacy: .public)")
    }

    private func handlePowerSystemWillSleep(notificationID: Int) {
        guard !handlingPowerSleep else {
            let task = currentSleepEjectTask()
            let operation = task?.operationID ?? newOperationID(reason: "sleep")
            log.notice("cycle \(operation, privacy: .public) IOKit systemWillSleep duplicate; waiting for active sleep eject before allowing notificationID=\(notificationID, privacy: .public)")
            task?.group.wait()
            allowPowerChange(notificationID: notificationID, operationID: operation)
            return
        }

        handlingPowerSleep = true
        let task = startSleepEjectIfNeeded(reason: "powerSleep")
        log.notice("cycle \(task.operationID, privacy: .public) IOKit systemWillSleep received; delaying sleep notificationID=\(notificationID, privacy: .public) ejectStarted=\(task.started, privacy: .public)")
        task.group.wait()
        handlingPowerSleep = false
        allowPowerChange(notificationID: notificationID, operationID: task.operationID)
    }

    private func currentSleepEjectTask() -> (operationID: String, group: DispatchGroup)? {
        sleepEjectStateLock.lock()
        defer { sleepEjectStateLock.unlock() }
        guard let operationID = activeSleepEjectOperationID,
              let group = activeSleepEjectGroup
        else { return nil }
        return (operationID, group)
    }

    private func startSleepEjectIfNeeded(reason: String) -> (operationID: String, group: DispatchGroup, started: Bool) {
        sleepEjectStateLock.lock()
        if let operationID = activeSleepEjectOperationID,
           let group = activeSleepEjectGroup {
            let activeReason = activeSleepEjectReason ?? "-"
            sleepEjectStateLock.unlock()
            log.notice("cycle \(operationID, privacy: .public) sleep eject already active; join reason=\(reason, privacy: .public) activeReason=\(activeReason, privacy: .public)")
            return (operationID, group, false)
        }

        if let completedAt = lastSleepEjectCompletedAt,
           Date().timeIntervalSince(completedAt) < 10,
           let operationID = lastSleepEjectOperationID {
            sleepEjectStateLock.unlock()
            log.notice("cycle \(operationID, privacy: .public) sleep eject already completed recently; skip duplicate reason=\(reason, privacy: .public)")
            return (operationID, DispatchGroup(), false)
        }

        let operation = newOperationID(reason: "sleep")
        let group = DispatchGroup()
        group.enter()
        activeSleepEjectGroup = group
        activeSleepEjectOperationID = operation
        activeSleepEjectReason = reason
        sleepEjectStateLock.unlock()

        sleepEjectQueue.async { [weak self] in
            guard let self else {
                group.leave()
                return
            }
            let totalStarted = Date()
            self.performSystemSleepEject(operation: operation,
                                         totalStarted: totalStarted,
                                         reason: reason)
            self.sleepEjectStateLock.lock()
            self.lastSleepEjectOperationID = operation
            self.lastSleepEjectCompletedAt = Date()
            if self.activeSleepEjectOperationID == operation {
                self.activeSleepEjectGroup = nil
                self.activeSleepEjectOperationID = nil
                self.activeSleepEjectReason = nil
            }
            self.sleepEjectStateLock.unlock()
            group.leave()
        }

        return (operation, group, true)
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

    private func allowPowerChange(notificationID: Int, operationID: String) {
        guard powerRootPort != 0 else {
            log.notice("cycle \(operationID, privacy: .public) IOAllowPowerChange skipped — powerRootPort unavailable")
            return
        }
        let result = IOAllowPowerChange(powerRootPort, notificationID)
        log.notice("cycle \(operationID, privacy: .public) IOAllowPowerChange notificationID=\(notificationID, privacy: .public) result=0x\(String(result, radix: 16), privacy: .public)")
    }

    @objc private func volumesDidChange(_ notification: Notification) {
        log.info("volume changed: \(notification.name.rawValue, privacy: .public)")
        DiskMenuSnapshotCache.invalidate()
        DiskMenuSnapshotCache.warm()
    }

    /// wake 직후:
    /// 1. macOS 가 status bar view 를 redraw 하면서 button.image 가 reset 되는 케이스 보호 —
    ///    마지막 결과 symbol 다시 set.
    /// 2. 자동(lid-close) 추출된 디스크들 자동 재마운트 시도 — 사용자 무감각 UX.
    @objc private func systemDidWake() {
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

        // 2) 자동 추출된 디스크 재마운트 — 2초 후 (USB 안정화 대기)
        let toRemount = autoEjectedDisks
        autoEjectedDisks = []  // 즉시 clear (중복 트리거 방지)
        guard !toRemount.isEmpty else {
            log.info("cycle \(operation, privacy: .public) didWake → no remount target")
            // remount 대상 없어도 라이브러리 앱 재실행은 시도 (option ON 인 경우)
            if LibraryAppManagement.enabled {
                LibraryAppHandler.relaunchQuitApps()
            }
            return
        }
        log.notice("cycle \(operation, privacy: .public) didWake → schedule remount after 2.0s targets=\(toRemount.sorted(), privacy: .public)")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.remountWithBackoff(disks: toRemount, operationID: operation)
            // remount 끝난 뒤 라이브러리 앱 재실행 — 외장에 라이브러리 있을 때 mount 후 launch.
            if LibraryAppManagement.enabled {
                LibraryAppHandler.relaunchQuitApps()
            }
        }
    }

    @objc private func systemWillSleep() {
        let operation = newOperationID(reason: "sleep")
        let totalStarted = Date()
        guard powerRootPort == 0 else {
            log.info("cycle \(operation, privacy: .public) NSWorkspace willSleep skipped — IOKit power observer active")
            return
        }

        log.notice("cycle \(operation, privacy: .public) NSWorkspace willSleep fallback received")
        performSystemSleepEject(operation: operation,
                                totalStarted: totalStarted,
                                reason: "workspaceSleep")
    }

    private func performSystemSleepEject(operation: String,
                                         totalStarted: Date,
                                         reason: String) {
        log.notice("cycle \(operation, privacy: .public) willSleep handler settings source=\(reason, privacy: .public) sleepEject=\(SleepEject.enabled, privacy: .public) displaySleepEject=\(DisplaySleepEject.enabled, privacy: .public) forceFallback=\(SettingsStore.forceFallbackEnabled, privacy: .public) libraryMgmt=\(LibraryAppManagement.enabled, privacy: .public)")
        if let until = skipSleepAutoEjectUntil, Date() < until {
            skipSleepAutoEjectUntil = nil
            log.info("cycle \(operation, privacy: .public) EJECT(sleep) SKIPPED — already handled by Eject and Sleep")
            return
        }
        skipSleepAutoEjectUntil = nil

        guard SleepEject.enabled else {
            log.info("cycle \(operation, privacy: .public) EJECT(sleep) SKIPPED — SleepEject disabled")
            return
        }
        autoEjectOperationID = operation
        autoEjectOperationReason = reason
        log.info("cycle \(operation, privacy: .public) EJECT(sleep) START")

        autoEjectedDisks = []

        // 외장 라이브러리 앱 자동 종료 (Music / Photos) — 옵션 ON 시 추출 직전.
        if LibraryAppManagement.enabled {
            let quitStarted = Date()
            LibraryAppHandler.quitLibraryApps()
            log.info("cycle \(operation, privacy: .public) EJECT(sleep) library apps quit complete elapsed=\(self.elapsedText(since: quitStarted), privacy: .public)s")
        }

        let ejectStarted = Date()
        let r = ejectAllForSleep(operationID: operation)
        autoEjectedDisks = r.remountTargets
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
        let operation = newOperationID(reason: "displaySleep")
        let totalStarted = Date()
        log.notice("cycle \(operation, privacy: .public) screensDidSleep notification received settings sleepEject=\(SleepEject.enabled, privacy: .public) displaySleepEject=\(DisplaySleepEject.enabled, privacy: .public) forceFallback=\(SettingsStore.forceFallbackEnabled, privacy: .public) libraryMgmt=\(LibraryAppManagement.enabled, privacy: .public) existingTargets=\(self.autoEjectedDisks.sorted(), privacy: .public)")
        guard DisplaySleepEject.enabled else {
            log.info("cycle \(operation, privacy: .public) EJECT(displaysleep) SKIPPED — DisplaySleepEject disabled")
            return
        }
        if let activeSleep = currentSleepEjectTask() {
            log.info("cycle \(operation, privacy: .public) EJECT(displaysleep) SKIPPED — system sleep eject active cycle=\(activeSleep.operationID, privacy: .public)")
            return
        }
        // system sleep 핸들러가 먼저 발화해 이미 추출 진행/완료한 경우 skip.
        // autoEjectedDisks 가 비어있지 않으면 다른 trigger 가 이미 처리 중.
        guard autoEjectedDisks.isEmpty else {
            log.info("cycle \(operation, privacy: .public) EJECT(displaysleep) SKIPPED — autoEjectedDisks not empty (other trigger active)")
            return
        }
        autoEjectOperationID = operation
        autoEjectOperationReason = "displaySleep"
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
                                 context: "displaySleep")
        autoEjectedDisks = r.remountTargets
        log.info("cycle \(operation, privacy: .public) EJECT(displaysleep) recorded successful BSDs: \(self.autoEjectedDisks.sorted(), privacy: .public)")
        log.notice("cycle \(operation, privacy: .public) EJECT(displaysleep) DONE — success=\(r.success.count, privacy: .public) failure=\(r.failure.count, privacy: .public) remountTargets=\(r.remountTargets.sorted(), privacy: .public) ejectElapsed=\(self.elapsedText(since: ejectStarted), privacy: .public)s totalElapsed=\(self.elapsedText(since: totalStarted), privacy: .public)s")

        if !r.failure.isEmpty {
            let failedNames = r.failure.map { $0.0 }.joined(separator: ", ")
            notify(title: String(localized: "\(r.failure.count) drive(s) didn't eject at display sleep"),
                   body: String(localized: "\(failedNames)\nDisks still mounted. Disconnect risk. Wake screen and eject manually."),
                   archived: true,
                   kind: .failure)
        }
    }

    /// 화면 다시 켜질 때 재마운트.
    /// systemDidWake 와 동일한 재마운트 함수 호출. autoEjectedDisks 가 첫 호출에서 비워지므로
    /// 두 trigger (system + display) 가 모두 와도 idempotent.
    @objc private func screensDidWake() {
        let operation = autoEjectOperationID ?? "-"
        let reason = autoEjectOperationReason ?? "-"
        log.info("cycle \(operation, privacy: .public) screensDidWake notification received reason=\(reason, privacy: .public) storedTargets=\(self.autoEjectedDisks.sorted(), privacy: .public)")
        let toRemount = autoEjectedDisks
        autoEjectedDisks = []
        guard !toRemount.isEmpty else {
            log.info("cycle \(operation, privacy: .public) screensDidWake → no remount target")
            if LibraryAppManagement.enabled {
                LibraryAppHandler.relaunchQuitApps()
            }
            return
        }
        log.notice("cycle \(operation, privacy: .public) screensDidWake → schedule remount after 2.0s targets=\(toRemount.sorted(), privacy: .public)")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.remountWithBackoff(disks: toRemount, operationID: operation)
            if LibraryAppManagement.enabled {
                LibraryAppHandler.relaunchQuitApps()
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
    }

    /// 여러 디스크를 병렬로 backoff 재시도. mount 실패 디스크만 알림.
    /// 사용자 분리 (USB 케이블 뽑힌 케이스) 는 silent.
    private func remountWithBackoff(disks: Set<String>, operationID: String? = nil) {
        let operation = operationID ?? "-"
        let totalStarted = Date()
        log.notice("cycle \(operation, privacy: .public) remount START targets=\(disks.sorted(), privacy: .public)")
        let lock = NSLock()
        var mountFailed: [String] = []
        let group = DispatchGroup()
        let parallel = DispatchQueue(label: "com.yongza.ejectdrives.remount", attributes: .concurrent)

        for bsd in disks {
            group.enter()
            parallel.async { [weak self] in
                defer { group.leave() }
                guard let self = self else { return }
                let diskStarted = Date()
                switch self.tryRemount(bsd: bsd, delays: [0, 1, 3, 7], operationID: operationID) {
                case .success:
                    log.info("cycle \(operation, privacy: .public) remount disk handled: \(bsd, privacy: .public) outcome=success elapsed=\(self.elapsedText(since: diskStarted), privacy: .public)s")
                    break
                case .userDisconnected:
                    log.info("cycle \(operation, privacy: .public) remount disk handled: \(bsd, privacy: .public) outcome=userDisconnected elapsed=\(self.elapsedText(since: diskStarted), privacy: .public)s")
                case .mountFailed:
                    log.notice("cycle \(operation, privacy: .public) remount disk handled: \(bsd, privacy: .public) outcome=mountFailed elapsed=\(self.elapsedText(since: diskStarted), privacy: .public)s")
                    lock.lock(); mountFailed.append(bsd); lock.unlock()
                }
            }
        }
        group.wait()

        guard !mountFailed.isEmpty else {
            log.notice("cycle \(operation, privacy: .public) remount DONE all disks handled elapsed=\(self.elapsedText(since: totalStarted), privacy: .public)s")
            return
        }
        let list = mountFailed.sorted().joined(separator: ", ")
        log.error("cycle \(operation, privacy: .public) remount DONE mount FAILED = \(list, privacy: .public) elapsed=\(self.elapsedText(since: totalStarted), privacy: .public)s")
        DispatchQueue.main.async { [weak self] in
            self?.notify(title: String(localized: "Remount failed"),
                         body: String(localized: "\(list)\nDisks detected but won't mount. Try Disk Utility."),
                         archived: true,
                         kind: .failure)
        }
    }

    /// 한 BSD 디스크에 대해 지정된 delays(초) 간격으로 mountDisk 재시도.
    /// 각 시도마다 IORegistry 직접 enumerate 검사 — 분리 의도 감지 + `diskutil info` 호출 회피
    /// (info 호출당 수백 ms 소요 → wake 직후 사용자 체감 지연 누적).
    /// 첫 시도 delay=0 즉시. 이후 1, 3, 7s 백오프 (USB 재인식 시간 확보).
    /// 이미 마운트된 디스크에 호출되면 idempotent (no-op success).
    private func tryRemount(bsd: String, delays: [Int], operationID: String? = nil) -> RemountOutcome {
        let operation = operationID ?? "-"
        var everEnumerated = false
        var lastMountError: String?

        for (i, delay) in delays.enumerated() {
            if delay > 0 {
                log.info("cycle \(operation, privacy: .public) remount attempt \(i + 1, privacy: .public)/\(delays.count, privacy: .public): \(bsd, privacy: .public) waiting \(delay, privacy: .public)s before retry")
                Thread.sleep(forTimeInterval: TimeInterval(delay))
            }

            // 1) 디스크가 시스템에 보이나? — IORegistry 직접 검사 (process spawn 없음).
            guard ioRegistryHasBSDDisk(bsd) else {
                log.notice("cycle \(operation, privacy: .public) remount attempt \(i + 1, privacy: .public)/\(delays.count, privacy: .public): \(bsd, privacy: .public) not enumerated — wait for re-detection")
                continue
            }
            everEnumerated = true

            // 2) 디스크 보임 → mount 시도
            let mount = daMountWholeDisk(bsdName: bsd, operationID: operationID)
            if mount.success {
                log.info("cycle \(operation, privacy: .public) ✓ remount OK: \(bsd, privacy: .public) (attempt \(i + 1, privacy: .public)/\(delays.count, privacy: .public))")
                return .success
            }
            lastMountError = mount.errorMessage
            log.notice("cycle \(operation, privacy: .public) remount attempt \(i + 1, privacy: .public) mount failed: \(bsd, privacy: .public) — \(mount.errorMessage ?? "?", privacy: .public)")
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

    /// archived=true 면 알림 센터에 보관 (사후 확인 가치 있는 negative event 등),
    /// false 면 banner 만 잠깐 표시되고 사라짐 (즉시 인지 가능한 positive event 등).
    /// userInfo 에 flag 를 박아 willPresent 콜백에서 옵션 분기.
    private func notify(title: String, body: String, archived: Bool = false, kind: AppNotificationKind = .info) {
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
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["archived": archived]
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

        let trusted = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
        log.notice("Accessibility trusted = \(trusted, privacy: .public)")

        // 저장된 설정이 어떤 경위로 같은 preset 두 개를 갖게 되었으면 시작 시 자동 정정.
        // (구버전 → 신버전 마이그레이션, defaults 직접 편집 등)
        if SettingsStore.ejectHotkey == SettingsStore.mountHotkey {
            let original = SettingsStore.mountHotkey
            let replacement = SettingsHotkeyPreset.allCases.first(where: { $0 != original }) ?? original
            SettingsStore.mountHotkey = replacement
            log.notice("hotkey conflict detected at startup: mount moved \(original.title, privacy: .public) → \(replacement.title, privacy: .public)")
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

        if flags == SettingsStore.ejectHotkey.flags {
            log.info("HOTKEY \(scope, privacy: .public) eject fired")
            flashIcon(symbol: "bolt.fill", duration: 0.3)
            DispatchQueue.main.async { [weak self] in self?.ejectAll(caller: "hotkey-\(scope.lowercased())") }
            return true
        }

        if flags == SettingsStore.mountHotkey.flags {
            log.info("HOTKEY \(scope, privacy: .public) mount fired")
            flashIcon(symbol: "arrow.down.circle", duration: 0.3)
            DispatchQueue.main.async { [weak self] in self?.mountAll(caller: "hotkey-\(scope.lowercased())") }
            return true
        }

        if let preset = SettingsStore.ejectAndSleepHotkey, flags == preset.flags {
            log.info("HOTKEY \(scope, privacy: .public) eject-and-sleep fired")
            flashIcon(symbol: "moon.zzz.fill", duration: 0.3)
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

private final class SleepDAUnmountBox {
    let semaphore = DispatchSemaphore(value: 0)
    let session: DASession
    let disk: DADisk
    var result: (Bool, String?)?

    init(session: DASession, disk: DADisk) {
        self.session = session
        self.disk = disk
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
    }

    private static func bool(for key: String, default defaultValue: Bool) -> Bool {
        if let value = UserDefaults.standard.object(forKey: key) as? Bool { return value }
        return defaultValue
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
}

private final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onHotkeyChanged: () -> Void
    private let onClosed: () -> Void

    private var loginToggle: NSButton!
    private var sleepToggle: NSButton!
    private var displaySleepToggle: NSButton!
    private var libraryAppToggle: NSButton!
    private var notificationsToggle: NSButton!
    private var successNotificationsToggle: NSButton!
    private var failureNotificationsToggle: NSButton!
    private var forceFallbackToggle: NSButton!
    private var rightClickEjectToggle: NSButton!
    private var ejectHotkeyPopup: NSPopUpButton!
    private var mountHotkeyPopup: NSPopUpButton!
    private var ejectAndSleepHotkeyPopup: NSPopUpButton!

    init(onHotkeyChanged: @escaping () -> Void, onClosed: @escaping () -> Void) {
        self.onHotkeyChanged = onHotkeyChanged
        self.onClosed = onClosed
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = String(localized: "Settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContentView()
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

    private func makeContentView() -> NSView {
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(tab(label: String(localized: "General"), view: makeGeneralView()))
        tabView.addTabViewItem(tab(label: String(localized: "Hotkeys"), view: makeHotkeysView()))
        tabView.addTabViewItem(tab(label: String(localized: "Notifications"), view: makeNotificationsView()))
        tabView.addTabViewItem(tab(label: String(localized: "Eject Behavior"), view: makeEjectBehaviorView()))
        tabView.addTabViewItem(tab(label: String(localized: "About"), view: makeAboutView()))

        let container = NSView()
        container.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            tabView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            tabView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            tabView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        return container
    }

    private func tab(label: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    private func makeGeneralView() -> NSView {
        loginToggle = checkbox(title: String(localized: "Launch at login"), action: #selector(toggleLoginItem(_:)))
        sleepToggle = checkbox(title: String(localized: "Eject on sleep"), action: #selector(toggleSleepEject(_:)))
        displaySleepToggle = checkbox(title: String(localized: "Eject on display sleep (experimental)"), action: #selector(toggleDisplaySleepEject(_:)))
        libraryAppToggle = checkbox(title: String(localized: "Quit Music/Photos before sleep"), action: #selector(toggleLibraryAppManagement(_:)))
        return tabStack([loginToggle, sleepToggle, displaySleepToggle, libraryAppToggle])
    }

    private func makeHotkeysView() -> NSView {
        ejectHotkeyPopup = hotkeyPopup(action: #selector(ejectHotkeyChanged(_:)))
        mountHotkeyPopup = hotkeyPopup(action: #selector(mountHotkeyChanged(_:)))
        ejectAndSleepHotkeyPopup = optionalHotkeyPopup(action: #selector(ejectAndSleepHotkeyChanged(_:)))
        return tabStack([
            formRow(label: String(localized: "Eject all"), control: ejectHotkeyPopup),
            formRow(label: String(localized: "Mount all"), control: mountHotkeyPopup),
            formRow(label: String(localized: "Eject and Sleep"), control: ejectAndSleepHotkeyPopup)
        ])
    }

    private func makeNotificationsView() -> NSView {
        notificationsToggle = checkbox(title: String(localized: "Notifications"), action: #selector(toggleNotifications(_:)))
        successNotificationsToggle = checkbox(title: String(localized: "Success notifications"), action: #selector(toggleSuccessNotifications(_:)))
        failureNotificationsToggle = checkbox(title: String(localized: "Failure notifications"), action: #selector(toggleFailureNotifications(_:)))
        return tabStack([notificationsToggle, successNotificationsToggle, failureNotificationsToggle])
    }

    private func makeEjectBehaviorView() -> NSView {
        forceFallbackToggle = checkbox(title: String(localized: "Force fallback"), action: #selector(toggleForceFallback(_:)))
        rightClickEjectToggle = checkbox(title: String(localized: "Right-click menu bar icon to eject all"),
                                         action: #selector(toggleRightClickEject(_:)))
        rightClickEjectToggle.toolTip = String(localized: "When off, right-click (and ctrl+click) opens the menu instead of ejecting all drives.")
        return tabStack([forceFallbackToggle, rightClickEjectToggle])
    }

    private func makeAboutView() -> NSView {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        let copyright = (info?["NSHumanReadableCopyright"] as? String) ?? "EjectDrives by yongZa"

        let title = NSTextField(labelWithString: "EjectDrives")
        title.font = .boldSystemFont(ofSize: 18)
        let versionLabel = NSTextField(labelWithString: "v\(version) (build \(build))")
        let copyrightLabel = NSTextField(labelWithString: copyright)
        copyrightLabel.textColor = .secondaryLabelColor
        let hint = NSTextField(wrappingLabelWithString: String(localized: "Notifications are silent by design — no sound. Look for the menu bar icon for results."))
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)

        return tabStack([title, versionLabel, copyrightLabel, hint])
    }

    private func checkbox(title: String, action: Selector) -> NSButton {
        NSButton(checkboxWithTitle: title, target: self, action: action)
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

    private func formRow(label: String, control: NSView) -> NSView {
        let text = NSTextField(labelWithString: label)
        text.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let row = NSStackView(views: [text, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        return row
    }

    private func tabStack(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -24)
        ])
        return container
    }

    private func refreshControls() {
        let loginStatus = LoginItem.status
        loginToggle.title = loginStatus == .requiresApproval
            ? String(localized: "Launch at login (needs approval)")
            : String(localized: "Launch at login")
        loginToggle.state = (loginStatus == .enabled || loginStatus == .requiresApproval) ? .on : .off
        sleepToggle.state = SleepEject.enabled ? .on : .off
        displaySleepToggle.state = DisplaySleepEject.enabled ? .on : .off
        libraryAppToggle.state = LibraryAppManagement.enabled ? .on : .off
        notificationsToggle.state = SettingsStore.notificationsEnabled ? .on : .off
        successNotificationsToggle.state = SettingsStore.successNotificationsEnabled ? .on : .off
        failureNotificationsToggle.state = SettingsStore.failureNotificationsEnabled ? .on : .off
        forceFallbackToggle.state = SettingsStore.forceFallbackEnabled ? .on : .off
        rightClickEjectToggle.state = SettingsStore.rightClickEjectEnabled ? .on : .off
        selectHotkey(SettingsStore.ejectHotkey, in: ejectHotkeyPopup)
        selectHotkey(SettingsStore.mountHotkey, in: mountHotkeyPopup)
        selectOptionalHotkey(SettingsStore.ejectAndSleepHotkey, in: ejectAndSleepHotkeyPopup)
        refreshNotificationControlState()
    }

    private func refreshNotificationControlState() {
        let enabled = SettingsStore.notificationsEnabled
        successNotificationsToggle.isEnabled = enabled
        failureNotificationsToggle.isEnabled = enabled
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
            showError(error.localizedDescription)
        }
        refreshControls()
    }

    @objc private func toggleSleepEject(_ sender: NSButton) {
        SleepEject.enabled = sender.state == .on
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

    @objc private func ejectHotkeyChanged(_ sender: NSPopUpButton) {
        let chosen = SettingsHotkeyPreset.allCases[sender.indexOfSelectedItem]
        // 추출/마운트 단축키가 같은 preset 이면 충돌 — handleHotkey 가 추출만 매칭하고 마운트는 영원히 안 발화.
        // 사용자에게 알리고 mount 를 자동으로 다른 preset 으로 옮긴다.
        if chosen == SettingsStore.mountHotkey {
            SettingsStore.mountHotkey = nextDistinctPreset(from: chosen)
            selectHotkey(SettingsStore.mountHotkey, in: mountHotkeyPopup)
            showHotkeyConflictAlert(displacedKind: .mount)
        }
        SettingsStore.ejectHotkey = chosen
        onHotkeyChanged()
    }

    @objc private func mountHotkeyChanged(_ sender: NSPopUpButton) {
        let chosen = SettingsHotkeyPreset.allCases[sender.indexOfSelectedItem]
        if chosen == SettingsStore.ejectHotkey {
            SettingsStore.ejectHotkey = nextDistinctPreset(from: chosen)
            selectHotkey(SettingsStore.ejectHotkey, in: ejectHotkeyPopup)
            showHotkeyConflictAlert(displacedKind: .eject)
        }
        SettingsStore.mountHotkey = chosen
        onHotkeyChanged()
    }

    /// 주어진 preset 과 다른 첫 번째 preset (allCases 순서). 충돌 회피용.
    private func nextDistinctPreset(from preset: SettingsHotkeyPreset) -> SettingsHotkeyPreset {
        SettingsHotkeyPreset.allCases.first(where: { $0 != preset }) ?? preset
    }

    @objc private func ejectAndSleepHotkeyChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if index == 0 {
            SettingsStore.ejectAndSleepHotkey = nil
            onHotkeyChanged()
            return
        }
        let chosen = SettingsHotkeyPreset.allCases[index - 1]
        // eject / mount 와 같은 preset 이면 handleHotkey 가 이쪽까지 도달 안 함 — 자동으로 다른 값으로.
        if chosen == SettingsStore.ejectHotkey || chosen == SettingsStore.mountHotkey {
            let alert = NSAlert()
            alert.messageText = String(localized: "Hotkey conflict")
            alert.informativeText = String(localized: "Eject and Sleep can't share its shortcut with Eject all or Mount all. Pick a different one.")
            alert.alertStyle = .informational
            alert.runModal()
            selectOptionalHotkey(SettingsStore.ejectAndSleepHotkey, in: sender)
            return
        }
        SettingsStore.ejectAndSleepHotkey = chosen
        onHotkeyChanged()
    }

    private enum HotkeyKind { case eject, mount }

    private func showHotkeyConflictAlert(displacedKind: HotkeyKind) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Hotkey conflict")
        let kindLabel = displacedKind == .eject
            ? String(localized: "Eject all")
            : String(localized: "Mount all")
        alert.informativeText = String(localized: "Eject and Mount can't share the same shortcut. \(kindLabel) was moved to a different preset.")
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            log.notice("settings requestAuthorization: granted=\(granted, privacy: .public) error=\(error?.localizedDescription ?? "nil", privacy: .public)")
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Settings update failed")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private func menuSymbol(_ name: String, fallback: String) -> NSImage? {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)
    image?.isTemplate = true
    return image
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
                return ProcessResult(success: false,
                                     stdout: finalStdout,
                                     errorMessage: "\(executableName) timed out",
                                     timedOut: true,
                                     terminationStatus: task.terminationStatus)
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

    static func volumeUUID(forVolumePath path: String) -> String? {
        volumeUUID(in: plist(for: path))
    }

    static func volumeUUID(in info: [String: Any]?) -> String? {
        info?["VolumeUUID"] as? String
    }

    static func busProtocol(forBSDName bsd: String) -> String? {
        busProtocol(in: plist(for: bsd))
    }

    static func busProtocol(in info: [String: Any]?) -> String? {
        info?["BusProtocol"] as? String
    }

    static func isSDCard(forVolumePath path: String) -> Bool {
        isSDCard(info: plist(for: path))
    }

    static func isSDCard(forBSDName bsd: String) -> Bool {
        isSDCard(info: plist(for: bsd))
    }

    static func isSDCard(info: [String: Any]?) -> Bool {
        guard let info else { return false }
        let values = [
            info["BusProtocol"] as? String,
            info["MediaName"] as? String,
            info["IORegistryEntryName"] as? String,
            info["DeviceTreePath"] as? String
        ].compactMap { $0?.lowercased() }

        return values.contains { value in
            value.contains("secure digital")
                || value.contains("sd card")
                || value.contains("sdxc")
                || value.contains("sd/mmc")
                || value.contains("card reader")
        }
    }
}

/// 마운트된 DMG/sparseimage/CoreSimulator 같은 disk image 는 외장 디스크처럼 보일 수 있음.
/// 잘못 처리 시 "Chrome 설치 중인데 DMG 가 빠짐" 같은 사고 발생.
private enum DiskImages {
    /// 현재 마운트된 모든 디스크 이미지(`/Volumes/Chrome` 같은) 의 mount path 집합.
    static func mountedPaths(timeout: TimeInterval? = 1.0) -> Set<String> {
        mountedPathsOrNil(timeout: timeout) ?? []
    }

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
    let deviceIdentifier: String?
    let name: String
    let mountPoint: String?
    let volumeUUID: String?
}

private struct DiskUtilExternalList {
    let entries: [[String: Any]]

    private static let systemContents: Set<String> = [
        "EFI", "Microsoft Reserved", "Apple_Boot",
        "Apple_KernelCoreDump", "Recovery",
        "Apple_RAID", "Apple_RAID_Offline"
    ]
    private static let systemNames: Set<String> = ["EFI", "Boot OS X", "Recovery", "Recovery HD"]

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
        if let content = dict["Content"] as? String, systemContents.contains(content) { return }
        guard let name = dict["VolumeName"] as? String,
              !name.isEmpty,
              !systemNames.contains(name)
        else { return }

        volumes.append(DiskUtilExternalVolume(deviceIdentifier: dict["DeviceIdentifier"] as? String,
                                              name: name,
                                              mountPoint: dict["MountPoint"] as? String,
                                              volumeUUID: dict["VolumeUUID"] as? String))
    }
}

private struct DiskMenuSnapshot {
    let drives: [ExternalDrive]
    let unmounted: [UnmountedExternal]
    let createdAt: Date
    let refreshError: String?

    static func load() -> DiskMenuSnapshot {
        let started = Date()
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
            drives = ExternalDrive.listFromMountedVolumes()
            unmounted = []
            refreshError = drives.isEmpty ? "diskutil list -plist external failed or timed out" : nil
            if !drives.isEmpty {
                log.notice("DiskMenuSnapshot.load: diskutil external list failed; using mounted volume fallback drives=\(drives.map { $0.name }, privacy: .public)")
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        log.info("DiskMenuSnapshot.load: \(String(format: "%.3f", elapsed), privacy: .public)s drives=\(drives.map { $0.name }, privacy: .public) unmounted=\(unmounted.map { $0.displayName }, privacy: .public) refreshError=\(refreshError ?? "-", privacy: .public)")
        return DiskMenuSnapshot(drives: drives,
                                unmounted: unmounted,
                                createdAt: Date(),
                                refreshError: refreshError)
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
            lock.lock()
            cached = fresh
            refreshRequested = false
            if ownsRefresh {
                refreshing = false
            }
            lock.unlock()
            return fresh
        }

        if refreshing {
            lock.unlock()
            log.info("DiskMenuSnapshotCache.current: initial refresh in progress, loading synchronously")
            let fresh = DiskMenuSnapshot.load()
            lock.lock()
            cached = fresh
            refreshRequested = false
            lock.unlock()
            return fresh
        }
        refreshing = true
        lock.unlock()

        let snapshot = DiskMenuSnapshot.load()
        lock.lock()
        cached = snapshot
        refreshing = false
        refreshRequested = false
        lock.unlock()
        return snapshot
    }

    static func warm() {
        lock.lock()
        guard !refreshing else {
            lock.unlock()
            return
        }
        refreshing = true
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
            refreshRequested = false
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
    case sdCard

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
            if let internalFlag = entry["OSInternal"] as? Bool, internalFlag { continue }
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
            // 외장 = 내장 아님 + 사용자에게 보임 + 로컬 (network mount 제외)
            // ejectable/removable 은 체크 안 함 — Thunderbolt 외장 SSD 등이 false 로 보고됨
            guard !isInternal, isBrowsable, isLocal else { continue }
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
            drives.append(ExternalDrive(name: name, url: url,
                                        kind: .disk,
                                        volumeUUID: nil,
                                        isTimeMachine: isTM))
        }
        return drives
    }

    /// Time Machine 백업 디스크 식별 — file 존재 검사만.
    /// - APFS Time Machine: 루트의 `.com.apple.timemachine.donotpresent` 파일
    /// - Legacy HFS+: `Backups.backupdb/` 디렉토리
    private static func isTimeMachineDisk(volumeURL: URL) -> Bool {
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
        guard let match = bsd.range(of: #"^disk\d+"#, options: .regularExpression)
        else { return nil }
        return String(bsd[match])
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

// MARK: - Sleep Eject Toggle (UserDefaults)

/// 잠자기 진입 시 자동 추출 여부.
/// 노트북 / 데스크탑 / sleep 종류 무관 — 모든 sleep 에서 추출. wake 시 자동 재마운트로 짝.
///
/// **마이그레이션**: v0.1.0 의 `ejectOnLidClose` key 가 있으면 그 값 승계, 없으면 default true.
enum SleepEject {
    private static let key = "ejectOnSleep"
    private static let legacyKey = "ejectOnLidClose"

    static var enabled: Bool {
        get {
            let d = UserDefaults.standard
            if let v = d.object(forKey: key) as? Bool { return v }
            if let legacy = d.object(forKey: legacyKey) as? Bool {
                d.set(legacy, forKey: key)
                d.removeObject(forKey: legacyKey)
                return legacy
            }
            return true
        }
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

    /// wake 시 relaunch 대상 — sleep 직전에 종료한 앱들의 bundle ID.
    /// process 상에 보관 — 앱 자체 재시작에는 살아남지 않지만 sleep/wake 사이엔 유효.
    private static var quitBundles: [String] = []

    /// 실행 중인 Music / Photos 종료. 종료된 bundle 들은 quitBundles 에 기록.
    /// background thread 또는 main thread 어디서든 호출 가능 (NSWorkspace 는 thread-safe).
    /// terminate() 는 비동기라, 라이브러리 lock 이 풀릴 때까지 짧은 polling 으로 기다린다 —
    /// 그렇지 않으면 직후 추출이 lock 에 걸려 실패할 수 있다.
    static func quitLibraryApps() {
        let workspace = NSWorkspace.shared
        var quitTargets: [NSRunningApplication] = []
        var quit: [String] = []
        for app in workspace.runningApplications {
            guard let bid = app.bundleIdentifier, bundleIDs.contains(bid) else { continue }
            log.notice("LibraryAppHandler: terminating \(bid, privacy: .public)")
            // graceful terminate — 앱이 sleep 진입 전 정리 시간 가짐 (write cache flush 등).
            // forceTerminate() 는 안 씀 (사용자 데이터 손실 위험).
            if app.terminate() {
                quit.append(bid)
                quitTargets.append(app)
            } else {
                log.error("LibraryAppHandler: terminate denied for \(bid, privacy: .public)")
            }
        }
        quitBundles = quit

        // 종료 완료까지 최대 ~3초 polling. graceful terminate 라 보통 100~500ms 에 끝남.
        // sleep 자체가 IOKit 으로 잠깐 지연된 상태이므로 이 정도는 허용 범위.
        let deadline = Date().addingTimeInterval(3.0)
        for target in quitTargets {
            while !target.isTerminated && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if !target.isTerminated {
                log.notice("LibraryAppHandler: \(target.bundleIdentifier ?? "?", privacy: .public) still running after 3s — proceeding anyway")
            }
        }
        log.info("LibraryAppHandler: quit \(quit.count, privacy: .public) apps = \(quit, privacy: .public)")
    }

    /// 앞서 종료한 앱들 재실행. 없으면 no-op.
    /// 사용자가 wake 후 즉시 화면 보지 못해도 백그라운드로 라이브러리 다시 마운트되어 있도록.
    static func relaunchQuitApps() {
        let toLaunch = quitBundles
        quitBundles = []   // 즉시 clear (멀티 wake / 재진입 보호)
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
