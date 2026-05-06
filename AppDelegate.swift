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
import os

/// 통합 로깅 (unified logging) — Console.app 에서 다음 명령으로 확인:
///   log stream --predicate 'subsystem == "com.yongza.ejectdrives"' --info
private let log = Logger(subsystem: "com.yongza.ejectdrives", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {

    private var statusItem: NSStatusItem!
    private var globalKeyMonitor: Any?
    private var lastEjectAt: Date = .distantPast
    private var lastMountAt: Date = .distantPast
    /// 마지막 추출 결과 symbol (wake 후 복원용). nil 이면 default ⏏ 표시.
    private var lastResultSymbol: String?
    /// flashIcon 의 지연 reset 이 그 사이 set 된 결과 아이콘을 덮어쓰는 race 방지용.
    /// flashIcon 호출 시 +1, reset 시점에 같은 값이면 그대로 reset, 다르면 skip.
    /// setPersistentIcon / resetIcon 도 +1 해서 진행중인 reset 무효화.
    private var iconFlashGeneration: Int = 0
    /// 자동(lid-close) 추출된 disk BSD names — wake 시 재마운트 대상.
    /// 수동 추출(단축키/메뉴)은 여기 안 들어감 — 사용자 의도 존중.
    private var autoEjectedDisks: Set<String> = []
    private lazy var cachedDefaultIcon: NSImage? = {
        let img = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject Drives")
        img?.isTemplate = true
        return img
    }()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            log.notice("requestAuthorization: granted=\(granted, privacy: .public) error=\(error?.localizedDescription ?? "nil", privacy: .public)")
        }

        // 권한 상태 진단
        center.getNotificationSettings { settings in
            log.notice("notif settings: authStatus=\(settings.authorizationStatus.rawValue, privacy: .public) alert=\(settings.alertSetting.rawValue, privacy: .public) center=\(settings.notificationCenterSetting.rawValue, privacy: .public)")
            // authStatus: 0=notDetermined 1=denied 2=authorized 3=provisional 4=ephemeral
            // alert/center: 0=notSupported 1=disabled 2=enabled
        }

        setupStatusItem()
        setupSleepObserver()
        installHotkey()
        log.notice("EjectDrives launched")
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
            log.info("RIGHTCLICK on status item")
            flashIcon(symbol: "hand.tap.fill", duration: 0.3)
            ejectAll(caller: "rightclick")
            return
        }

        // 좌클릭 → 메뉴 표시 (임시로 menu set 해서 popup, 닫히면 nil 로 복원)
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
        // 메뉴 열면 추출 결과 아이콘 reset — 사용자가 결과 확인했다고 간주
        resetIcon()

        menu.removeAllItems()

        let drives = ExternalDrive.list()

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
                item.image = NSImage(systemSymbolName: drive.isTimeMachine ? "clock.arrow.circlepath" : "externaldrive",
                                     accessibilityDescription: nil)
                // submenu 폐기 — submenu 가 있으면 macOS 가 클릭 시 action 무시 (추출 안 됨).
                // 자동 추출 제외 토글은 메뉴 하단의 별도 "자동 추출 제외 디스크" submenu 로 이동.
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
            let ejectAllItem = NSMenuItem(title: String(localized: "Eject all  (⌥⌘E · or right-click)"),
                                          action: #selector(ejectAllAction(_:)),
                                          keyEquivalent: "e")
            ejectAllItem.keyEquivalentModifierMask = [.command, .option]
            ejectAllItem.target = self
            menu.addItem(ejectAllItem)
        }

        // Mount 섹션 — 마운트 안 된 외장이 있을 때만 표시.
        // 사용자가 추출 후 다시 쓰고 싶거나, macOS 가 wake 후 자동 mount 못 한 케이스 회복용.
        let unmounted = UnmountedExternal.list()
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
                item.image = NSImage(systemSymbolName: "externaldrive.badge.plus",
                                     accessibilityDescription: nil)
                item.toolTip = String(localized: "Click to mount.  ⌘+click to also open in Finder.")
                menu.addItem(item)
            }

            if unmounted.count >= 2 {
                let mountAllItem = NSMenuItem(title: String(localized: "Mount all  (⌃⌘E)"),
                                              action: #selector(mountAllAction(_:)),
                                              keyEquivalent: "e")
                mountAllItem.keyEquivalentModifierMask = [.command, .control]
                mountAllItem.target = self
                menu.addItem(mountAllItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let toggle = NSMenuItem(title: String(localized: "Eject on sleep"),
                                action: #selector(toggleSleepEject),
                                keyEquivalent: "")
        toggle.target = self
        toggle.state = SleepEject.enabled ? .on : .off
        menu.addItem(toggle)

        let toggleDisp = NSMenuItem(title: String(localized: "Eject on display sleep (experimental)"),
                                    action: #selector(toggleDisplaySleepEject),
                                    keyEquivalent: "")
        toggleDisp.target = self
        toggleDisp.state = DisplaySleepEject.enabled ? .on : .off
        toggleDisp.toolTip = String(localized: "Eject on display sleep tooltip")
        menu.addItem(toggleDisp)

        // 외장 라이브러리 앱 자동 종료 — Music / Photos 가 외장 라이브러리 lock 잡고 있으면
        // 추출 실패. 옵션 ON 이면 sleep 직전 quit, wake 후 relaunch.
        let toggleLib = NSMenuItem(title: String(localized: "Quit Music/Photos before sleep"),
                                   action: #selector(toggleLibraryAppManagement),
                                   keyEquivalent: "")
        toggleLib.target = self
        toggleLib.state = LibraryAppManagement.enabled ? .on : .off
        toggleLib.toolTip = String(localized: "Auto-quit Music and Photos before sleep, relaunch on wake. Useful when libraries are on external drives.")
        menu.addItem(toggleLib)

        // 로그인 시 자동 실행 — SMAppService.mainApp 으로 시스템 로그인 항목 등록.
        // status 가 .requiresApproval 이면 시스템 설정에서 사용자가 직접 허용해야 함.
        let loginItemStatus = LoginItem.status
        let loginToggle = NSMenuItem(title: String(localized: "Launch at login"),
                                     action: #selector(toggleLoginItem),
                                     keyEquivalent: "")
        loginToggle.target = self
        loginToggle.state = (loginItemStatus == .enabled) ? .on : .off
        if loginItemStatus == .requiresApproval {
            loginToggle.toolTip = String(localized: "Approve in System Settings → General → Login Items")
        }
        menu.addItem(loginToggle)

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

        let quit = NSMenuItem(title: String(localized: "Quit"),
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleSleepEject() {
        SleepEject.enabled.toggle()
        log.info("SleepEject toggled → \(SleepEject.enabled, privacy: .public)")
    }

    @objc private func toggleDisplaySleepEject() {
        DisplaySleepEject.enabled.toggle()
        log.info("DisplaySleepEject toggled → \(DisplaySleepEject.enabled, privacy: .public)")
    }

    /// 디스크별 *"자동 추출 제외"* 토글. representedObject = Volume UUID.
    @objc private func toggleExcludeVolume(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        ExcludedVolumes.toggle(uuid)
        log.info("ExcludedVolumes toggled \(uuid, privacy: .public) → excluded=\(ExcludedVolumes.isExcluded(uuid), privacy: .public)")
    }

    /// 외장 라이브러리 앱 (Music / Photos) 자동 종료 토글.
    @objc private func toggleLibraryAppManagement() {
        LibraryAppManagement.enabled.toggle()
        log.info("LibraryAppManagement toggled → \(LibraryAppManagement.enabled, privacy: .public)")
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

    /// 로그인 항목 등록/해제 토글. requiresApproval 상태면 시스템 설정 직접 열어줌.
    @objc private func toggleLoginItem() {
        let before = LoginItem.status
        log.info("LoginItem toggle: status before = \(before.rawValue, privacy: .public)")

        // 사용자가 시스템 설정에서 허용 안 한 상태에서 토글하면 → 시스템 설정 열어줌
        if before == .requiresApproval {
            LoginItem.openSystemSettings()
            log.notice("LoginItem: opened System Settings (requiresApproval)")
            return
        }

        do {
            if before == .enabled {
                try LoginItem.unregister()
                log.notice("LoginItem: unregistered")
            } else {
                try LoginItem.register()
                log.notice("LoginItem: registered (status now = \(LoginItem.status.rawValue, privacy: .public))")
                // register 직후 status 가 requiresApproval 이면 시스템 설정 안내
                if LoginItem.status == .requiresApproval {
                    notify(title: String(localized: "Login item needs approval"),
                           body: String(localized: "Toggle EjectDrives on in System Settings → Login Items."),
                           archived: true)
                    LoginItem.openSystemSettings()
                }
            }
        } catch {
            log.error("LoginItem toggle failed: \(error.localizedDescription, privacy: .public)")
            notify(title: String(localized: "Couldn't update launch-at-login"),
                   body: error.localizedDescription,
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

    /// 개별 드라이브 추출 (메뉴 아이템 클릭).
    @objc private func ejectOne(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let name = sender.title
        let path = url.path
        log.info("EJECTONE start: \(name, privacy: .public) at \(path, privacy: .public)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.diskutilEject(volumePath: path)
            log.info("EJECTONE done: \(name, privacy: .public) success=\(result.success, privacy: .public) err=\(result.errorMessage ?? "-", privacy: .public)")
            DispatchQueue.main.async {
                if result.success {
                    self.notify(title: String(localized: "Ejected"), body: name)
                } else {
                    self.notify(title: String(localized: "Couldn't eject \(name)"),
                                body: result.errorMessage ?? String(localized: "Unknown error"),
                                archived: true)
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

    private func notifyResult(_ result: (attempted: [String], success: [String], failure: [(String, String)])) {
        guard !result.attempted.isEmpty else {
            notify(title: String(localized: "No drives to eject"),
                   body: String(localized: "No external drives connected."))
            return
        }
        let title: String
        let archived: Bool
        if result.failure.isEmpty {
            title = String(localized: "All drives ejected")
            archived = false   // 성공 — 결과 아이콘 ✓ 으로 즉시 피드백 충분
        } else if result.success.isEmpty {
            title = String(localized: "Eject failed")
            archived = true    // 실패 — 어떤 디스크인지 사후 확인 가치
        } else {
            title = String(localized: "Some drives didn't eject")
            archived = true
        }
        var lines: [String] = []
        if !result.success.isEmpty {
            lines.append(String(localized: "Succeeded: \(result.success.joined(separator: ", "))"))
        }
        if !result.failure.isEmpty {
            lines.append(String(localized: "Failed: \(result.failure.map { $0.0 }.joined(separator: ", "))"))
        }
        notify(title: title, body: lines.joined(separator: "\n"), archived: archived)
    }

    /// 병렬 추출. background thread 에서 호출하라.
    /// - parameter applyExcludeFilter: true 면 ExcludedVolumes 에 등록된 디스크는 추출 제외.
    ///   자동 (sleep / display sleep) path 에서만 true. 사용자 명시 추출은 false (사용자 의도 우선).
    @discardableResult
    private func ejectAllSilently(applyExcludeFilter: Bool = false) -> (attempted: [String], success: [String], failure: [(String, String)]) {
        var drives = ExternalDrive.list()
        if applyExcludeFilter {
            let before = drives.count
            drives = drives.filter { !ExcludedVolumes.isExcluded($0.volumeUUID) }
            let skipped = before - drives.count
            if skipped > 0 {
                log.info("ejectAllSilently: filtered out \(skipped, privacy: .public) excluded disks")
            }
        }
        log.info("ejectAllSilently: \(drives.count) drives = \(drives.map { $0.name }, privacy: .public)")
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
                log.info("→ eject start: \(drive.name, privacy: .public) at \(drive.url.path, privacy: .public)")
                let result = self.diskutilEject(volumePath: drive.url.path)
                let elapsed = Date().timeIntervalSince(started)
                if result.success {
                    log.info("✓ eject OK:    \(drive.name, privacy: .public) in \(String(format: "%.2f", elapsed), privacy: .public)s")
                } else {
                    log.error("✗ eject FAIL:  \(drive.name, privacy: .public) in \(String(format: "%.2f", elapsed), privacy: .public)s — \(result.errorMessage ?? "unknown", privacy: .public)")
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
        group.wait()
        return (drives.map { $0.name }, success, failure)
    }

    /// whole disk 의 mountable partition 들을 모두 mount.
    /// `diskutil mountDisk <whole>` 의 sandbox-호환 대체.
    /// 하나라도 mount 되면 success. 모두 실패면 마지막 에러 반환.
    /// background thread 에서만 호출.
    private func daMountWholeDisk(bsdName: String) -> (success: Bool, errorMessage: String?) {
        let backend = DiskArbitrationBackend.shared
        let parts = backend.childPartitions(ofWholeDisk: bsdName)
        if parts.isEmpty {
            // child partition 없으면 disk 자체에 mount 시도 (synth disk 인 경우)
            guard let disk = backend.disk(forBSDName: bsdName) else {
                return (false, "no mountable partitions on \(bsdName)")
            }
            let r = backend.mount(disk: disk)
            return (r.success, r.errorMessage)
        }
        var anyMounted = false
        var lastError: String?
        for p in parts {
            guard let disk = backend.disk(forBSDName: p) else { continue }
            let r = backend.mount(disk: disk)
            if r.success {
                anyMounted = true
                log.info("daMount: \(p, privacy: .public) OK")
            } else {
                log.notice("daMount: \(p, privacy: .public) failed — \(r.errorMessage ?? "?", privacy: .public)")
                lastError = r.errorMessage
            }
        }
        return (anyMounted, anyMounted ? nil : (lastError ?? "all partitions failed to mount"))
    }

    /// 외장하드 unmount — DiskArbitration framework graceful 시도.
    ///
    /// **이전 force fallback 폐기 사유**:
    /// - App Store sandbox 환경에서 `diskutil unmount force` 동등 동작이 거절될 수 있음
    /// - DA framework 의 `kDADiskUnmountOptionForce` 도 root 권한 없이는 실패 (sandbox 무관)
    /// - 점유 프로세스가 있으면 사용자에게 알리고 직접 해소하게 하는 게 더 안전 (file system corruption 회피)
    ///
    /// **이전 동작과의 차이**: 점유 디스크는 unmount 실패 → 사용자 알림. graceful 만 시도, retry 없음.
    /// background thread 에서만 호출 (semaphore wait blocking).
    private func diskutilEject(volumePath: String) -> (success: Bool, errorMessage: String?) {
        let backend = DiskArbitrationBackend.shared
        guard let disk = backend.disk(forVolumePath: volumePath) else {
            return (false, "disk not found at \(volumePath)")
        }
        let r = backend.unmount(disk: disk)
        return (r.success, r.errorMessage)
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
            log.info("MOUNTONE done: \(displayName, privacy: .public) success=\(r.success, privacy: .public)")
            DispatchQueue.main.async {
                if r.success {
                    self.notify(title: String(localized: "Mounted"), body: displayName)
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
                                archived: true)
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
                   body: success.joined(separator: ", "))
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
        notify(title: title, body: lines.joined(separator: "\n"), archived: true)
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
    }

    /// wake 직후:
    /// 1. macOS 가 status bar view 를 redraw 하면서 button.image 가 reset 되는 케이스 보호 —
    ///    마지막 결과 symbol 다시 set.
    /// 2. 자동(lid-close) 추출된 디스크들 자동 재마운트 시도 — 사용자 무감각 UX.
    @objc private func systemDidWake() {
        log.info("didWake notification received")

        // 1) 아이콘 복원
        if lastResultSymbol != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, let symbol = self.lastResultSymbol else { return }
                log.info("didWake → restore icon: \(symbol, privacy: .public)")
                self.setPersistentIcon(symbol: symbol)
            }
        }

        // 2) 자동 추출된 디스크 재마운트 — 2초 후 (USB 안정화 대기)
        let toRemount = autoEjectedDisks
        autoEjectedDisks = []  // 즉시 clear (중복 트리거 방지)
        guard !toRemount.isEmpty else {
            // remount 대상 없어도 라이브러리 앱 재실행은 시도 (option ON 인 경우)
            if LibraryAppManagement.enabled {
                LibraryAppHandler.relaunchQuitApps()
            }
            return
        }
        log.info("didWake → schedule remount: \(toRemount.sorted(), privacy: .public)")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.remountWithBackoff(disks: toRemount)
            // remount 끝난 뒤 라이브러리 앱 재실행 — 외장에 라이브러리 있을 때 mount 후 launch.
            if LibraryAppManagement.enabled {
                LibraryAppHandler.relaunchQuitApps()
            }
        }
    }

    @objc private func systemWillSleep() {
        log.info("willSleep notification received")
        guard SleepEject.enabled else {
            log.info("EJECT(sleep) SKIPPED — SleepEject disabled")
            return
        }
        log.info("EJECT(sleep) START")

        // 추출 직전 BSD 이름 기록 — wake 시 재마운트 대상.
        // 모든 sleep 에서 추출 + wake 재마운트가 한 쌍으로 동작.
        // 짧은 sleep 후 wake → 자동 재마운트로 사용자 무감각.
        // 긴 sleep 후 분리 → 재마운트 시도하지만 silent (분리 의도 감지).
        // 자동 추출 제외 디스크 (Time Machine 등) 는 BSD 기록도 안 함 (재마운트 대상 아님).
        let drives = ExternalDrive.list().filter { !ExcludedVolumes.isExcluded($0.volumeUUID) }
        autoEjectedDisks = Set(drives.compactMap { $0.wholeDiskBSDName })
        log.info("EJECT(sleep) recorded BSDs: \(self.autoEjectedDisks.sorted(), privacy: .public)")

        // 외장 라이브러리 앱 자동 종료 (Music / Photos) — 옵션 ON 시 추출 직전.
        if LibraryAppManagement.enabled {
            LibraryAppHandler.quitLibraryApps()
        }

        let r = ejectAllSilently(applyExcludeFilter: true)
        log.info("EJECT(sleep) DONE — success=\(r.success.count) failure=\(r.failure.count)")

        // Sleep 추출 실패는 부재 중 발생한 negative event → 알림 센터에 보관.
        // unmount 안 된 채 sleep 진입했으니 dock 분리 시 file system 손상 위험.
        // sleep 진입 직전이지만 UNUserNotificationCenter 는 OS-level 이라 등록만 되면 OS 가 처리.
        if !r.failure.isEmpty {
            let failedNames = r.failure.map { $0.0 }.joined(separator: ", ")
            notify(title: String(localized: "\(r.failure.count) drive(s) didn't eject before sleep"),
                   body: String(localized: "\(failedNames)\nDisks went to sleep still mounted. Disconnect risk. Eject manually after wake."),
                   archived: true)
        }
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
        log.info("screensDidSleep notification received")
        guard DisplaySleepEject.enabled else {
            log.info("EJECT(displaysleep) SKIPPED — DisplaySleepEject disabled")
            return
        }
        // system sleep 핸들러가 먼저 발화해 이미 추출 진행/완료한 경우 skip.
        // autoEjectedDisks 가 비어있지 않으면 다른 trigger 가 이미 처리 중.
        guard autoEjectedDisks.isEmpty else {
            log.info("EJECT(displaysleep) SKIPPED — autoEjectedDisks not empty (other trigger active)")
            return
        }
        log.info("EJECT(displaysleep) START")

        // 자동 추출 제외 디스크 (Time Machine 등) 는 BSD 기록도 안 함.
        let drives = ExternalDrive.list().filter { !ExcludedVolumes.isExcluded($0.volumeUUID) }
        autoEjectedDisks = Set(drives.compactMap { $0.wholeDiskBSDName })
        log.info("EJECT(displaysleep) recorded BSDs: \(self.autoEjectedDisks.sorted(), privacy: .public)")

        // 외장 라이브러리 앱 자동 종료 (옵션 ON 시).
        if LibraryAppManagement.enabled {
            LibraryAppHandler.quitLibraryApps()
        }

        let r = ejectAllSilently(applyExcludeFilter: true)
        log.info("EJECT(displaysleep) DONE — success=\(r.success.count) failure=\(r.failure.count)")

        if !r.failure.isEmpty {
            let failedNames = r.failure.map { $0.0 }.joined(separator: ", ")
            notify(title: String(localized: "\(r.failure.count) drive(s) didn't eject at display sleep"),
                   body: String(localized: "\(failedNames)\nDisks still mounted. Disconnect risk. Wake screen and eject manually."),
                   archived: true)
        }
    }

    /// 화면 다시 켜질 때 재마운트.
    /// systemDidWake 와 동일한 재마운트 함수 호출. autoEjectedDisks 가 첫 호출에서 비워지므로
    /// 두 trigger (system + display) 가 모두 와도 idempotent.
    @objc private func screensDidWake() {
        log.info("screensDidWake notification received")
        let toRemount = autoEjectedDisks
        autoEjectedDisks = []
        guard !toRemount.isEmpty else {
            log.info("screensDidWake → no remount target")
            if LibraryAppManagement.enabled {
                LibraryAppHandler.relaunchQuitApps()
            }
            return
        }
        log.info("screensDidWake → schedule remount: \(toRemount.sorted(), privacy: .public)")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.remountWithBackoff(disks: toRemount)
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
    private func remountWithBackoff(disks: Set<String>) {
        let lock = NSLock()
        var mountFailed: [String] = []
        let group = DispatchGroup()
        let parallel = DispatchQueue(label: "com.yongza.ejectdrives.remount", attributes: .concurrent)

        for bsd in disks {
            group.enter()
            parallel.async { [weak self] in
                defer { group.leave() }
                guard let self = self else { return }
                switch self.tryRemount(bsd: bsd, delays: [0, 1, 3, 7]) {
                case .success:
                    break
                case .userDisconnected:
                    log.info("remount: \(bsd, privacy: .public) treated as user disconnect — silent")
                case .mountFailed:
                    lock.lock(); mountFailed.append(bsd); lock.unlock()
                }
            }
        }
        group.wait()

        guard !mountFailed.isEmpty else {
            log.info("remount: all disks handled (success or user disconnect)")
            return
        }
        let list = mountFailed.sorted().joined(separator: ", ")
        log.error("remount: mount FAILED = \(list, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.notify(title: String(localized: "Remount failed"),
                         body: String(localized: "\(list)\nDisks detected but won't mount. Try Disk Utility."),
                         archived: true)
        }
    }

    /// 한 BSD 디스크에 대해 지정된 delays(초) 간격으로 mountDisk 재시도.
    /// 각 시도마다 먼저 `diskutil info` 로 enumerate 여부 확인 — 분리 의도 감지.
    /// 첫 시도 delay=0 즉시. 이후 1, 3, 7s 백오프 (USB 재인식 시간 확보).
    /// 이미 마운트된 디스크에 호출되면 idempotent (no-op success).
    private func tryRemount(bsd: String, delays: [Int]) -> RemountOutcome {
        var everEnumerated = false
        var lastMountError: String?

        for (i, delay) in delays.enumerated() {
            if delay > 0 { Thread.sleep(forTimeInterval: TimeInterval(delay)) }

            // 1) 디스크가 시스템에 보이나? — DA 로 disk handle 생성 가능한지로 판단.
            //    nil 이면 IOKit/DA 가 enumerate 못 함 = 사용자 분리로 간주.
            guard DiskArbitrationBackend.shared.disk(forBSDName: bsd) != nil else {
                log.notice("attempt \(i + 1, privacy: .public)/\(delays.count, privacy: .public): \(bsd, privacy: .public) not enumerated — wait for re-detection")
                continue
            }
            everEnumerated = true

            // 2) 디스크 보임 → mount 시도
            let mount = daMountWholeDisk(bsdName: bsd)
            if mount.success {
                log.info("✓ remount OK: \(bsd, privacy: .public) (attempt \(i + 1, privacy: .public)/\(delays.count, privacy: .public))")
                return .success
            }
            lastMountError = mount.errorMessage
            log.notice("attempt \(i + 1, privacy: .public) mount failed: \(bsd, privacy: .public) — \(mount.errorMessage ?? "?", privacy: .public)")
        }

        if !everEnumerated {
            log.info("✗ \(bsd, privacy: .public) never enumerated across \(delays.count, privacy: .public) attempts — user disconnect")
            return .userDisconnected
        }
        log.error("✗ remount FAIL: \(bsd, privacy: .public) — enumerate OK but mount failed all \(delays.count, privacy: .public) attempts")
        return .mountFailed(lastMountError ?? "unknown")
    }

    // MARK: - Notifications

    /// archived=true 면 알림 센터에 보관 (사후 확인 가치 있는 negative event 등),
    /// false 면 banner 만 잠깐 표시되고 사라짐 (즉시 인지 가능한 positive event 등).
    /// userInfo 에 flag 를 박아 willPresent 콜백에서 옵션 분기.
    private func notify(title: String, body: String, archived: Bool = false) {
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

    // MARK: - Global Hotkey (⌥⌘E 추출, ⌃⌘E 마운트)
    // NSEvent.addGlobalMonitorForEvents 만 사용. Accessibility 권한 필요.
    // 우클릭 monitor 는 제거 — false positive 위험. 우클릭은 button.sendAction 으로 받음.

    private func installHotkey() {
        let trusted = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
        log.notice("Accessibility trusted = \(trusted, privacy: .public)")

        let ejectFlags: NSEvent.ModifierFlags = [.command, .option]    // ⌥⌘E 추출
        let mountFlags: NSEvent.ModifierFlags = [.command, .control]   // ⌃⌘E 마운트
        let eKeyCode: UInt16 = 14   // kVK_ANSI_E — 물리 키 코드, IME 무관

        // GLOBAL monitor — 다른 앱이 활성일 때 잡음 (Accessibility 권한 필요)
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == eKeyCode else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .help, .capsLock])
            if flags == ejectFlags {
                log.info("HOTKEY GLOBAL eject fired (isARepeat=\(event.isARepeat, privacy: .public))")
                self?.flashIcon(symbol: "bolt.fill", duration: 0.3)
                DispatchQueue.main.async { self?.ejectAll(caller: "hotkey-global") }
            } else if flags == mountFlags {
                log.info("HOTKEY GLOBAL mount fired (isARepeat=\(event.isARepeat, privacy: .public))")
                self?.flashIcon(symbol: "arrow.down.circle", duration: 0.3)
                DispatchQueue.main.async { self?.mountAll(caller: "hotkey-global") }
            }
        }
        log.notice("globalKeyMonitor = \(self.globalKeyMonitor != nil ? "REGISTERED" : "NIL — failed!", privacy: .public)")

        // LOCAL monitor — 우리 앱 활성일 때
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == eKeyCode else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .help, .capsLock])
            if flags == ejectFlags {
                log.info("HOTKEY LOCAL eject fired (isARepeat=\(event.isARepeat, privacy: .public))")
                self?.flashIcon(symbol: "bolt.fill", duration: 0.3)
                DispatchQueue.main.async { self?.ejectAll(caller: "hotkey-local") }
                return nil
            } else if flags == mountFlags {
                log.info("HOTKEY LOCAL mount fired (isARepeat=\(event.isARepeat, privacy: .public))")
                self?.flashIcon(symbol: "arrow.down.circle", duration: 0.3)
                DispatchQueue.main.async { self?.mountAll(caller: "hotkey-local") }
                return nil
            }
            return event
        }
    }
}

// MARK: - External Drive Detection

struct ExternalDrive {
    let name: String
    let url: URL
    /// Volume UUID — Per-disk 설정 (ExcludedVolumes 등) 의 안정적 식별자.
    /// BSD/이름은 케이블/슬롯 변경에 따라 변하지만 UUID 는 디스크 파일시스템에 박혀있음.
    let volumeUUID: String?
    /// Time Machine 백업 디스크인지 여부. 자동 추출 default 제외 대상.
    let isTimeMachine: Bool

    static func list() -> [ExternalDrive] {
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

        let backend = DiskArbitrationBackend.shared
        var drives: [ExternalDrive] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let isInternal  = v.volumeIsInternal  ?? false
            let isBrowsable = v.volumeIsBrowsable ?? false
            let isLocal     = v.volumeIsLocal     ?? false
            // 외장 = 내장 아님 + 사용자에게 보임 + 로컬 (network mount 제외)
            // ejectable/removable 은 체크 안 함 — Thunderbolt 외장 SSD 등이 false 로 보고됨
            guard !isInternal, isBrowsable, isLocal else { continue }
            // DMG / sparseimage / CoreSimulator 제외 — Chrome.dmg 같은 마운트된 디스크 이미지가
            // 같이 빠지면 사고. DiskArbitration 의 DeviceProtocol 키로 식별 (sandbox 호환).
            var volumeUUID: String? = nil
            if let disk = backend.disk(forVolumePath: url.path) {
                if backend.isVirtualDisk(disk) {
                    log.debug("filter: virtual disk excluded \(url.path, privacy: .public)")
                    continue
                }
                if let desc = backend.description(for: disk),
                   let uuidRef = desc[kDADiskDescriptionVolumeUUIDKey as String] {
                    // CFUUID → String. unsafeBitCast 안 쓰고 CFUUIDCreateString 사용.
                    let cfuuid = uuidRef as! CFUUID
                    volumeUUID = (CFUUIDCreateString(kCFAllocatorDefault, cfuuid) as String?)
                }
            }
            let name = v.volumeName ?? url.lastPathComponent
            let isTM = isTimeMachineDisk(volumeURL: url)
            drives.append(ExternalDrive(name: name, url: url,
                                        volumeUUID: volumeUUID,
                                        isTimeMachine: isTM))
        }
        return drives
    }

    /// Time Machine 백업 디스크 식별 — sandbox 호환 (file 존재 검사만).
    /// - APFS Time Machine: 루트의 `.com.apple.timemachine.donotpresent` 파일
    /// - Legacy HFS+: `Backups.backupdb/` 디렉토리
    private static func isTimeMachineDisk(volumeURL: URL) -> Bool {
        let fm = FileManager.default
        // (1) APFS Time Machine marker
        let marker1 = volumeURL.appendingPathComponent(".com.apple.timemachine.donotpresent")
        if fm.fileExists(atPath: marker1.path) { return true }
        // (2) Legacy HFS+ backup folder
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

    /// IOKit + DiskArbitration 조합으로 unmounted 외장 디스크 검출 (sandbox 호환).
    ///
    /// **로직**:
    /// 1. `ExternalDrive.list()` 로 현재 마운트된 외장 whole disk BSD set 수집
    /// 2. `DA.enumerateExternalWholeDisks()` 로 모든 외장(internal=false) whole disk 후보 수집
    /// 3. mountedBSDs 에 없는 후보 중 가상 디스크 제외, 사용자 데이터 partition 이 있는 것만
    static func list() -> [UnmountedExternal] {
        let mountedBSDs = Set(ExternalDrive.list().compactMap { $0.wholeDiskBSDName })
        let backend = DiskArbitrationBackend.shared
        let externals = backend.enumerateExternalWholeDisks()

        var result: [UnmountedExternal] = []
        for bsd in externals {
            if mountedBSDs.contains(bsd) { continue }
            // 가상 디스크 (DMG / CoreSimulator) 제외
            if let disk = backend.disk(forBSDName: bsd), backend.isVirtualDisk(disk) {
                log.debug("UnmountedExternal: skip virtual bsd=\(bsd, privacy: .public)")
                continue
            }
            // 사용자 데이터 partition 의 VolumeName 추출 (EFI / 시스템 partition 자동 제외).
            // 없으면 RAID 멤버 / EFI-only 디스크 — skip.
            guard let name = volumeName(forWholeDisk: bsd) else { continue }
            result.append(UnmountedExternal(bsdName: bsd, displayName: name))
        }
        log.info("UnmountedExternal.list: found \(result.count, privacy: .public) candidates = \(result.map { "\($0.displayName)(\($0.bsdName))" }, privacy: .public)")
        return result
    }

    /// whole disk 의 child partitions / APFS volumes 중 *사용자가 마운트 의미 있는* 첫 VolumeName.
    /// 3중 방어: (1) DA Mountable 키 (2) MediaContent blacklist (3) VolumeName blacklist.
    /// 모두 시스템이거나 mount 불가면 nil (RAID 멤버 디스크 등 → 후보 제외).
    private static func volumeName(forWholeDisk bsd: String) -> String? {
        // (2) Partition map type fallback — kDADiskDescriptionMediaContentKey
        let systemContents: Set<String> = [
            "EFI", "Microsoft Reserved", "Apple_Boot",
            "Apple_KernelCoreDump", "Recovery",
            "Apple_RAID", "Apple_RAID_Offline"   // RAID 멤버 디스크 (직접 mount 불가)
        ]
        // (3) VolumeName fallback blacklist — MediaContent 키가 macOS 26+ 에서 변경/missing 시 보호
        let systemNames: Set<String> = ["EFI", "Boot OS X", "Recovery", "Recovery HD"]

        let backend = DiskArbitrationBackend.shared
        let parts = backend.childPartitions(ofWholeDisk: bsd)
        for p in parts {
            guard let disk = backend.disk(forBSDName: p),
                  let desc = backend.description(for: disk)
            else { continue }

            // (1) DA 의 Volume Mountable 키 — user-mountable 로 marking 안 된 volume skip.
            //     EFI / Apple_Boot / Apple_RAID 모두 false 로 marking 됨 (가장 robust 한 방어).
            //     키가 missing 이면 fallback 검사로 진행.
            if let mountable = desc[kDADiskDescriptionVolumeMountableKey as String] as? Bool,
               !mountable { continue }

            // (2) Partition map type
            if let content = desc[kDADiskDescriptionMediaContentKey as String] as? String,
               systemContents.contains(content) { continue }

            // (3) VolumeName
            if let name = desc[kDADiskDescriptionVolumeNameKey as String] as? String,
               !name.isEmpty,
               !systemNames.contains(name) {
                return name
            }
        }
        return nil
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
    static func quitLibraryApps() {
        let workspace = NSWorkspace.shared
        var quit: [String] = []
        for app in workspace.runningApplications {
            guard let bid = app.bundleIdentifier, bundleIDs.contains(bid) else { continue }
            log.notice("LibraryAppHandler: terminating \(bid, privacy: .public)")
            // graceful terminate — 앱이 sleep 진입 전 정리 시간 가짐 (write cache flush 등).
            // forceTerminate() 는 안 씀 (사용자 데이터 손실 위험).
            if app.terminate() {
                quit.append(bid)
            } else {
                log.error("LibraryAppHandler: terminate denied for \(bid, privacy: .public)")
            }
        }
        quitBundles = quit
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

import ServiceManagement

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
