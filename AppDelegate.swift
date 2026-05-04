//
//  AppDelegate.swift
//  EjectDrives — 혼자 쓰는 초간단 버전
//
//  - 메뉴바 아이콘 + 드라이브 목록 + 모두 추출
//  - 뚜껑 닫을 때만 자동 추출 (메뉴에서 토글, 시간 지난 자동 sleep 은 무시)
//  - 전역 단축키 ⌥⌘E
//  - 우클릭 = 모두 추출
//  - 추출 결과 알림
//

import Cocoa
import UserNotifications
import Carbon.HIToolbox
import IOKit
import os

/// 통합 로깅 (unified logging) — Console.app 에서 다음 명령으로 확인:
///   log stream --predicate 'subsystem == "com.yongza.ejectdrives"' --info
private let log = Logger(subsystem: "com.yongza.ejectdrives", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {

    private var statusItem: NSStatusItem!
    private var globalKeyMonitor: Any?
    private var lastEjectAt: Date = .distantPast
    /// 마지막 추출 결과 symbol (wake 후 복원용). nil 이면 default ⏏ 표시.
    private var lastResultSymbol: String?
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

        menu.addItem(NSMenuItem.separator())

        let toggle = NSMenuItem(title: "뚜껑 닫을 때 자동 추출",
                                action: #selector(toggleLidEject),
                                keyEquivalent: "")
        toggle.target = self
        toggle.state = LidEject.enabled ? .on : .off
        menu.addItem(toggle)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "종료",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleLidEject() {
        LidEject.enabled.toggle()
        log.info("LidEject toggled → \(LidEject.enabled, privacy: .public)")
    }

    // MARK: - Status Icon Feedback (단축키/추출 시각 피드백)

    /// 메뉴바 아이콘 잠시 다른 심볼로 변경 후 원복 (회전화살표 등 임시 표시용).
    private func flashIcon(symbol: String, duration: TimeInterval = 0.4) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            guard let newImg = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
                log.error("flashIcon: symbol '\(symbol, privacy: .public)' not found")
                return
            }
            newImg.isTemplate = true
            button.image = newImg
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self = self, let button = self.statusItem.button else { return }
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
        }
    }

    /// 메뉴바 아이콘을 default ⏏ 로 reset. lastResultSymbol 도 clear.
    private func resetIcon() {
        lastResultSymbol = nil
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            button.image = self.cachedDefaultIcon
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
                    self.notify(title: "추출 실패: \(name)", body: result.errorMessage ?? "알 수 없는 오류")
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
        if result.failure.isEmpty {
            title = "모든 드라이브 추출 완료"
        } else if result.success.isEmpty {
            title = "추출 실패"
        } else {
            title = "일부 추출 실패"
        }
        var lines: [String] = []
        if !result.success.isEmpty {
            lines.append("성공: " + result.success.joined(separator: ", "))
        }
        if !result.failure.isEmpty {
            lines.append("실패: " + result.failure.map { $0.0 }.joined(separator: ", "))
        }
        notify(title: title, body: lines.joined(separator: "\n"))
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
    }

    /// wake 직후 macOS 가 status bar view 를 redraw 하면서 우리 button.image 가
    /// reset 되는 케이스 보호 — 마지막 결과 symbol 다시 set.
    @objc private func systemDidWake() {
        log.info("didWake notification received")
        guard let symbol = lastResultSymbol else { return }
        // status bar 가 완전히 ready 되기까지 약간 시간 필요
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, let symbol = self.lastResultSymbol else { return }
            log.info("didWake → restore icon: \(symbol, privacy: .public)")
            self.setPersistentIcon(symbol: symbol)
        }
    }

    @objc private func systemWillSleep() {
        log.info("willSleep notification received")
        guard LidEject.enabled else {
            log.info("EJECT(sleep) SKIPPED — LidEject disabled")
            return
        }
        guard Self.isLidClosed() else {
            log.info("EJECT(sleep) SKIPPED — lid open")
            return
        }
        log.info("EJECT(sleep) START — lid closed")
        let r = ejectAllSilently()
        log.info("EJECT(sleep) DONE — success=\(r.success.count) failure=\(r.failure.count)")
    }

    /// IOPMrootDomain 의 AppleClamshellState 조회.
    ///
    /// **중요 — IOKit 의 의미는 직관과 반대**:
    /// - `AppleClamshellState = Yes` (true)  → 뚜껑 **닫힘** (closed)
    /// - `AppleClamshellState = No`  (false) → 뚜껑 **열림** (open)
    /// - property 자체가 없으면 → 데스크탑 맥 (lid 없음)
    ///
    /// 검증: `ioreg -r -k AppleClamshellState` 로 현재 raw value 직접 확인 가능.
    ///
    /// - returns: true = 뚜껑 닫힘. false = 열려있거나 property 없음(데스크탑) → 안전하게 추출 안 함.
    private static func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != 0 else {
            log.error("isLidClosed: IOPMrootDomain service not found")
            return false
        }
        defer { IOObjectRelease(service) }

        guard let cfProp = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            log.info("isLidClosed: AppleClamshellState property is nil (desktop Mac?) → return false")
            return false
        }
        // raw value: Yes(true) = closed, No(false) = open
        let isClosed = (cfProp.takeRetainedValue() as? Bool) ?? false
        log.info("isLidClosed: AppleClamshellState raw=\(isClosed, privacy: .public) → \(isClosed ? "CLOSED" : "OPEN", privacy: .public)")
        return isClosed
    }

    // MARK: - Notifications

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
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
        completionHandler([.banner])  // 사운드 제외 — 항상 무음 banner
    }

    // MARK: - Global Hotkey (⌥⌘E)
    // NSEvent.addGlobalMonitorForEvents 만 사용. Accessibility 권한 필요.
    // 우클릭 monitor 는 제거 — false positive 위험. 우클릭은 button.sendAction 으로 받음.

    private func installHotkey() {
        let trusted = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
        log.notice("Accessibility trusted = \(trusted, privacy: .public)")

        let requiredFlags: NSEvent.ModifierFlags = [.command, .option]
        let eKeyCode: UInt16 = 14   // kVK_ANSI_E — 물리 키 코드, IME 무관

        // GLOBAL monitor — 다른 앱이 활성일 때 잡음 (Accessibility 권한 필요)
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .help, .capsLock])
            guard flags == requiredFlags, event.keyCode == eKeyCode else { return }
            log.info("HOTKEY GLOBAL fired (isARepeat=\(event.isARepeat, privacy: .public))")
            self?.flashIcon(symbol: "bolt.fill", duration: 0.3)
            DispatchQueue.main.async {
                self?.ejectAll(caller: "hotkey-global")
            }
        }
        log.notice("globalKeyMonitor = \(self.globalKeyMonitor != nil ? "REGISTERED" : "NIL — failed!", privacy: .public)")

        // LOCAL monitor — 우리 앱 활성일 때
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .help, .capsLock])
            if flags == requiredFlags && event.keyCode == eKeyCode {
                log.info("HOTKEY LOCAL fired (isARepeat=\(event.isARepeat, privacy: .public))")
                self?.flashIcon(symbol: "bolt.fill", duration: 0.3)
                DispatchQueue.main.async {
                    self?.ejectAll(caller: "hotkey-local")
                }
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

        var drives: [ExternalDrive] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let isInternal  = v.volumeIsInternal  ?? false
            let isBrowsable = v.volumeIsBrowsable ?? false
            let isLocal     = v.volumeIsLocal     ?? false
            // 외장 = 내장 아님 + 사용자에게 보임 + 로컬 (network mount 제외)
            // ejectable/removable 은 체크 안 함 — Thunderbolt 외장 SSD 등이 false 로 보고됨
            guard !isInternal, isBrowsable, isLocal else { continue }
            let name = v.volumeName ?? url.lastPathComponent
            drives.append(ExternalDrive(name: name, url: url))
        }
        return drives
    }
}

// MARK: - Lid Eject Toggle (UserDefaults)

enum LidEject {
    private static let key = "ejectOnLidClose"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
