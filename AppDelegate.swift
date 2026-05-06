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
            let empty = NSMenuItem(title: "연결된 외장 드라이브 없음", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for drive in drives {
                let item = NSMenuItem(title: drive.name,
                                      action: #selector(ejectOne(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = drive.url
                item.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
            let ejectAllItem = NSMenuItem(title: "모두 추출  (⌥⌘E · 또는 메뉴바 우클릭)",
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
            let header = NSMenuItem(title: "마운트 안 된 외장",
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
                item.toolTip = "클릭 = 마운트.  ⌘+클릭 = 마운트 + Finder 열기."
                menu.addItem(item)
            }

            if unmounted.count >= 2 {
                let mountAllItem = NSMenuItem(title: "모두 마운트  (⌃⌘E)",
                                              action: #selector(mountAllAction(_:)),
                                              keyEquivalent: "e")
                mountAllItem.keyEquivalentModifierMask = [.command, .control]
                mountAllItem.target = self
                menu.addItem(mountAllItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let toggle = NSMenuItem(title: "잠자기 시 자동 추출",
                                action: #selector(toggleSleepEject),
                                keyEquivalent: "")
        toggle.target = self
        toggle.state = SleepEject.enabled ? .on : .off
        menu.addItem(toggle)

        let toggleDisp = NSMenuItem(title: "화면 꺼질 때도 자동 추출 (실험)",
                                    action: #selector(toggleDisplaySleepEject),
                                    keyEquivalent: "")
        toggleDisp.target = self
        toggleDisp.state = DisplaySleepEject.enabled ? .on : .off
        toggleDisp.toolTip = "pmset sleep=0 환경에서 화면 꺼질 때 추출. 자리 잠깐 비울 때 잦은 추출/재마운트 가능."
        menu.addItem(toggleDisp)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "종료",
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
                    self.notify(title: "추출 완료", body: name)
                } else {
                    self.notify(title: "추출 실패: \(name)",
                                body: result.errorMessage ?? "알 수 없는 오류",
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
            notify(title: "추출할 드라이브 없음", body: "연결된 외장 드라이브가 없습니다")
            return
        }
        let title: String
        let archived: Bool
        if result.failure.isEmpty {
            title = "모든 드라이브 추출 완료"
            archived = false   // 성공 — 결과 아이콘 ✓ 으로 즉시 피드백 충분
        } else if result.success.isEmpty {
            title = "추출 실패"
            archived = true    // 실패 — 어떤 디스크인지 사후 확인 가치
        } else {
            title = "일부 추출 실패"
            archived = true
        }
        var lines: [String] = []
        if !result.success.isEmpty {
            lines.append("성공: " + result.success.joined(separator: ", "))
        }
        if !result.failure.isEmpty {
            lines.append("실패: " + result.failure.map { $0.0 }.joined(separator: ", "))
        }
        notify(title: title, body: lines.joined(separator: "\n"), archived: archived)
    }

    /// 병렬 추출. background thread 에서 호출하라.
    @discardableResult
    private func ejectAllSilently() -> (attempted: [String], success: [String], failure: [(String, String)]) {
        let drives = ExternalDrive.list()
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
                    log.error("✗ eject FAIL:  \(drive.name, privacy: .public) in \(String(format: "%.2f", elapsed), privacy: .public)s — \(result.errorMessage ?? "알 수 없는 오류", privacy: .public)")
                }
                lock.lock()
                if result.success {
                    success.append(drive.name)
                } else {
                    failure.append((drive.name, result.errorMessage ?? "알 수 없는 오류"))
                }
                lock.unlock()
                group.leave()
            }
        }
        group.wait()
        return (drives.map { $0.name }, success, failure)
    }

    /// 외장하드 추출 — 2단계 fallback 으로 안전성 우선.
    ///
    /// **단계**:
    /// 1. `diskutil eject <path>` — graceful 시도 (Finder 와 동일, 디스크 power off 까지)
    /// 2. 실패 시 `diskutil unmount force <path>` — fseventsd 등 dissent 무시 + write cache flush
    ///
    /// **왜 force fallback?** 뚜껑 덮기 = 자리 떠남 = 곧 dock 분리. graceful 실패 후 그냥 두면
    /// ungraceful disconnect 로 file system corruption 위험. force unmount 는 cache flush 까지
    /// 수행하므로 훨씬 안전. write 중 file 잘릴 위험은 sleep 직전 시나리오에선 극히 낮음.
    ///
    /// background thread 에서만 호출 (waitUntilExit blocking).
    private func diskutilEject(volumePath: String) -> (success: Bool, errorMessage: String?) {
        // 1차: graceful eject
        let r1 = runDiskutil(["eject", volumePath])
        if r1.success { return (true, nil) }

        // 2차: force unmount (fseventsd dissent 무시)
        log.notice("retry with force unmount: \(volumePath, privacy: .public) — graceful failed: \(r1.errorMessage ?? "?", privacy: .public)")
        let r2 = runDiskutil(["unmount", "force", volumePath])
        if r2.success {
            log.notice("force unmount OK: \(volumePath, privacy: .public)")
            return (true, nil)
        }

        // 둘 다 실패
        let combined = "graceful: \(r1.errorMessage ?? "?") | force: \(r2.errorMessage ?? "?")"
        return (false, combined)
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
            let r = self.runDiskutil(["mountDisk", bsd])
            log.info("MOUNTONE done: \(displayName, privacy: .public) success=\(r.success, privacy: .public)")
            DispatchQueue.main.async {
                if r.success {
                    self.notify(title: "마운트 완료", body: displayName)
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
                    self.notify(title: "마운트 실패: \(displayName)",
                                body: r.errorMessage ?? "알 수 없는 오류",
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
                    self?.notify(title: "마운트할 외장 없음",
                                 body: "꽂혀있고 마운트 안 된 외장이 없습니다")
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
                    let r = self.runDiskutil(["mountDisk", u.bsdName])
                    if r.success {
                        log.info("✓ mount OK:    \(u.displayName, privacy: .public) (\(u.bsdName, privacy: .public))")
                    } else {
                        log.error("✗ mount FAIL:  \(u.displayName, privacy: .public) — \(r.errorMessage ?? "?", privacy: .public)")
                    }
                    lock.lock()
                    if r.success { success.append(u.displayName) }
                    else { failure.append((u.displayName, r.errorMessage ?? "알 수 없는 오류")) }
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
            notify(title: "모두 마운트 완료",
                   body: success.joined(separator: ", "))
            return
        }
        let title: String
        if success.isEmpty { title = "마운트 실패" }
        else { title = "일부 마운트 실패" }
        var lines: [String] = []
        if !success.isEmpty {
            lines.append("성공: " + success.joined(separator: ", "))
        }
        lines.append("실패: " + failure.map { $0.0 }.joined(separator: ", "))
        notify(title: title, body: lines.joined(separator: "\n"), archived: true)
    }

    /// diskutil 외부 명령 실행 helper.
    private func runDiskutil(_ args: [String]) -> (success: Bool, errorMessage: String?) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = args
        let errPipe = Pipe()
        let outPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = outPipe
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                return (true, nil)
            }
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let msg = errStr.isEmpty ? "diskutil exit code \(task.terminationStatus)" : errStr
            return (false, msg)
        } catch {
            return (false, error.localizedDescription)
        }
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
        guard !toRemount.isEmpty else { return }
        log.info("didWake → schedule remount: \(toRemount.sorted(), privacy: .public)")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.remountWithBackoff(disks: toRemount)
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
        let drives = ExternalDrive.list()
        autoEjectedDisks = Set(drives.compactMap { $0.wholeDiskBSDName })
        log.info("EJECT(sleep) recorded BSDs: \(self.autoEjectedDisks.sorted(), privacy: .public)")

        let r = ejectAllSilently()
        log.info("EJECT(sleep) DONE — success=\(r.success.count) failure=\(r.failure.count)")

        // Sleep 추출 실패는 부재 중 발생한 negative event → 알림 센터에 보관.
        // unmount 안 된 채 sleep 진입했으니 dock 분리 시 file system 손상 위험.
        // sleep 진입 직전이지만 UNUserNotificationCenter 는 OS-level 이라 등록만 되면 OS 가 처리.
        if !r.failure.isEmpty {
            let failedNames = r.failure.map { $0.0 }.joined(separator: ", ")
            notify(title: "Sleep 시 \(r.failure.count)개 디스크 추출 실패",
                   body: "\(failedNames)\n디스크가 unmount 안 된 채 sleep — 분리 시 손상 위험. wake 후 메뉴에서 수동 추출 권장.",
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

        let drives = ExternalDrive.list()
        autoEjectedDisks = Set(drives.compactMap { $0.wholeDiskBSDName })
        log.info("EJECT(displaysleep) recorded BSDs: \(self.autoEjectedDisks.sorted(), privacy: .public)")

        let r = ejectAllSilently()
        log.info("EJECT(displaysleep) DONE — success=\(r.success.count) failure=\(r.failure.count)")

        if !r.failure.isEmpty {
            let failedNames = r.failure.map { $0.0 }.joined(separator: ", ")
            notify(title: "화면 꺼짐 시 \(r.failure.count)개 디스크 추출 실패",
                   body: "\(failedNames)\n디스크가 unmount 안 된 채 — 분리 시 손상 위험. 화면 켜고 메뉴에서 수동 추출 권장.",
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
            return
        }
        log.info("screensDidWake → schedule remount: \(toRemount.sorted(), privacy: .public)")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.remountWithBackoff(disks: toRemount)
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
            self?.notify(title: "재마운트 실패",
                         body: "\(list)\n디스크는 인식되는데 mount 안 됨 — 디스크 검사 필요할 수 있음",
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

            // 1) 디스크가 시스템에 보이나? — diskutil info exit code 만 확인
            let info = runDiskutil(["info", bsd])
            guard info.success else {
                log.notice("attempt \(i + 1, privacy: .public)/\(delays.count, privacy: .public): \(bsd, privacy: .public) not enumerated — wait for re-detection")
                continue
            }
            everEnumerated = true

            // 2) 디스크 보임 → mount 시도
            let mount = runDiskutil(["mountDisk", bsd])
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

// MARK: - Disk Image Detection

/// 마운트된 DMG / sparseimage / sparsebundle 의 mount path 조회.
/// `hdiutil info -plist` 출력 파싱.
///
/// **왜 필요?** 외장 USB/Thunderbolt 디스크 와 DMG 디스크 이미지를 반드시 구분해야 함.
/// 잘못 처리 시 "Chrome 설치 중인데 DMG 가 빠짐" 같은 사고 발생.
enum DiskImages {
    /// 현재 마운트된 모든 디스크 이미지(`/Volumes/Chrome` 같은) 의 mount path 집합.
    /// hdiutil 호출 ~50ms. 메뉴 열 때마다 호출되어도 OK.
    static func mountedPaths() -> Set<String> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["info", "-plist"]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()  // 무시
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                log.error("hdiutil info exit code \(task.terminationStatus, privacy: .public)")
                return []
            }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard let plist = try PropertyListSerialization
                    .propertyList(from: data, format: nil) as? [String: Any],
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
        } catch {
            log.error("hdiutil info failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

// MARK: - External Drive Detection

struct ExternalDrive {
    let name: String
    let url: URL

    static func list() -> [ExternalDrive] {
        let dmgPaths = DiskImages.mountedPaths()

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
            guard !dmgPaths.contains(url.path) else {
                log.debug("filter: DMG excluded \(url.path, privacy: .public)")
                continue
            }
            let name = v.volumeName ?? url.lastPathComponent
            drives.append(ExternalDrive(name: name, url: url))
        }
        return drives
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

    /// `diskutil list -plist external` + `ExternalDrive.list()` 비교로 unmounted 외장 검출.
    ///
    /// **로직**:
    /// 1. 현재 마운트된 외장의 whole disk BSD set 수집 (`ExternalDrive.list()` 의 wholeDiskBSDName)
    /// 2. `diskutil list -plist external` 의 모든 OSInternal=false whole disk entry 검사
    /// 3. mountedBSDs 에 없는 entry 중 mountable sub-volume(VolumeName 있는 partition/APFSVolume) 가
    ///    하나라도 있는 것만 후보. RAID 멤버 디스크 같은 건 자동 제외.
    static func list() -> [UnmountedExternal] {
        let mountedBSDs: Set<String> = Set(
            ExternalDrive.list().compactMap { $0.wholeDiskBSDName }
        )

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["list", "-plist", "external"]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return [] }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard let plist = try PropertyListSerialization
                    .propertyList(from: data, format: nil) as? [String: Any],
                  let entries = plist["AllDisksAndPartitions"] as? [[String: Any]]
            else { return [] }

            var result: [UnmountedExternal] = []
            for entry in entries {
                guard let bsd = entry["DeviceIdentifier"] as? String else { continue }
                if let internalFlag = entry["OSInternal"] as? Bool, internalFlag { continue }
                if mountedBSDs.contains(bsd) { continue }
                // 사용자 데이터 partition 의 VolumeName 추출 (EFI / 시스템 partition 자동 제외).
                // 없으면 RAID 멤버 / EFI-only 디스크 — skip.
                guard let name = firstVolumeName(in: entry) else { continue }
                // BusProtocol 추가 검증 — Xcode CoreSimulator DMG 같은 가상 디스크 차단.
                // ExternalDrive.list() 의 DMG 필터는 hdiutil 의 mounted DMG 에만 적용되므로
                // unmounted 후보엔 다시 체크 필요.
                if busProtocol(for: bsd) == "Disk Image" {
                    log.debug("UnmountedExternal: skip disk image bsd=\(bsd, privacy: .public)")
                    continue
                }
                result.append(UnmountedExternal(bsdName: bsd, displayName: name))
            }
            log.info("UnmountedExternal.list: found \(result.count, privacy: .public) candidates = \(result.map { "\($0.displayName)(\($0.bsdName))" }, privacy: .public)")
            return result
        } catch {
            log.error("diskutil list failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// entry 의 Partitions / APFSVolumes 에서 사용자 데이터 partition 의 VolumeName 반환.
    /// EFI / Microsoft Reserved / Apple_Boot 같은 시스템 partition 의 VolumeName 은 무시.
    /// 모두 시스템이거나 비어있으면 nil — 즉 mount 대상 아님 (RAID 멤버, EFI-only 디스크 등).
    private static func firstVolumeName(in entry: [String: Any]) -> String? {
        let systemContents: Set<String> = ["EFI", "Microsoft Reserved", "Apple_Boot",
                                            "Apple_KernelCoreDump", "Recovery"]
        if let parts = entry["Partitions"] as? [[String: Any]] {
            for p in parts {
                if let content = p["Content"] as? String, systemContents.contains(content) { continue }
                if let name = p["VolumeName"] as? String, !name.isEmpty { return name }
            }
        }
        if let vols = entry["APFSVolumes"] as? [[String: Any]] {
            for v in vols {
                if let name = v["VolumeName"] as? String, !name.isEmpty { return name }
            }
        }
        return nil
    }

    /// `diskutil info -plist <bsd>` 의 BusProtocol 키 조회.
    /// "USB" / "Thunderbolt" = 진짜 외장. "Disk Image" = DMG / sparseimage / CoreSimulator. nil = 알 수 없음.
    private static func busProtocol(for bsd: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["info", "-plist", bsd]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let plist = try PropertyListSerialization
                .propertyList(from: data, format: nil) as? [String: Any]
            return plist?["BusProtocol"] as? String
        } catch {
            return nil
        }
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
