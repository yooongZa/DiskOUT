# CHANGELOG

## v0.1.0 — 2026-05-05

**혼자 쓰는 초간단 버전 첫 릴리즈.** macOS 메뉴바 외장 드라이브 자동 추출 앱.

---

### 한 줄 요약

> "뚜껑 닫을 때 외장 드라이브 알아서 다 빼주는 메뉴바 앱"

---

### 왜 만들었나 — macOS default 동작의 빈자리

| 상황 | macOS default | 결과 |
|---|---|---|
| 뚜껑 닫음 → sleep 진입 | 외장하드 mount(마운트 = 인식) 상태 그대로 | 자동 추출 X |
| 사용자가 dock 분리 | 외장하드 강제 disconnect(연결 해제) | "디스크가 올바르게 추출되지 않았습니다" 알림 + dangling(매달림) 등록 + file system corruption(파일시스템 손상) 위험 |

**macOS 에는 "sleep 시 외장하드 자동 추출" 옵션이 아예 없다.** 이 gap(갭 = 빈자리) 을 메우는 것이 앱의 핵심 가치.

---

### 구현된 기능

| # | 기능 | 설명 |
|---|---|---|
| 1 | 메뉴바 ⏏ 아이콘 | 진입점. `LSUIElement = YES` 로 Dock 아이콘 없는 백그라운드 앱 |
| 2 | 드라이브 목록 + 개별/전체 추출 | 클릭 시 동적 메뉴 빌드 |
| 3 | **뚜껑 닫을 때만** 자동 추출 | clamshell 토글. 시간 지난 자동 sleep, 메뉴→잠자기 는 추출 안 함 (IOKit `AppleClamshellState` 분기) |
| 4 | 전역 단축키 `⌥⌘E` | NSEvent global monitor + Accessibility(액세스빌리티 = 접근성) 권한 |
| 5 | 우클릭 = 모두 추출 | `button.sendAction(on: [.leftMouseDown, .rightMouseDown])` |
| 6 | **graceful + force fallback** | 1단계 `diskutil eject` (정상 추출) → 실패 시 2단계 `diskutil unmount force` (강제 마운트 해제, write cache flush) |
| 7 | 메뉴바 아이콘으로 결과 표시 | ✓ (모두 성공) · ⚠ (일부 성공) · ✗ (모두 실패) · ? (추출할 거 없음). 메뉴 열면 reset |
| 8 | wake 후 아이콘 자동 복원 | `NSWorkspace.didWakeNotification` observer + 0.5s delay 후 last result symbol 다시 set |
| 9 | 병렬 추출 | `DispatchGroup` 으로 N개 디스크 동시 추출 |
| 10 | 통합 로깅 | `os_log` (subsystem = `com.yongza.ejectdrives`) — Console.app 또는 `log show` 로 추적 가능 |
| 11 | 무음 알림 banner | `UNNotification` (도서관 등 조용한 환경 고려, 사운드 없음). 권한 거부 시 메뉴바 아이콘으로 fallback |

---

### 발생했던 이슈와 해결 (시간 순)

#### 1. 메뉴바 아이콘 안 보임 (macOS 26)

- **증상**: `NSStatusBar.system.statusItem(...)` 호출 성공, button/image 다 정상 생성, NSLog 로 모든 step 확인됐는데 메뉴바에 아이콘 안 보임
- **진단**: `NSApp.windows` 순회 결과 `NSStatusBarWindow` 의 frame(프레임 = 위치/크기) 이 `(0, 0, 32, 0)` — **height(높이) = 0**. WindowServer 에 정상 등록 안 됨
- **원인**: macOS 26 의 새 정책 또는 status item 시스템의 미묘한 변경
- **해결**: `setFrame()` 으로 강제 크기 설정 + `orderFrontRegardless()` 로 WindowServer 등록 강제
  ```swift
  if let win = button.window {
      let thickness = NSStatusBar.system.thickness
      win.setFrame(NSRect(x: 0, y: 0, width: 32, height: thickness),
                   display: true, animate: false)
      win.orderFrontRegardless()
  }
  ```

#### 2. 외장 드라이브 인식 안 됨 (Thunderbolt SSD)

- **증상**: `FileManager.mountedVolumeURLs` 로 가져온 URL 들에서 외장하드들이 필터링됨 ("연결된 외장 드라이브 없음")
- **진단**: `volumeIsEjectable` 과 `volumeIsRemovable` 둘 다 `false` 로 보고됨
- **원인**: macOS 26 에서 Thunderbolt 외장 SSD 와 일부 USB 디바이스가 `ejectable/removable=false`. 풀버전 EjectDrives 의 원래 필터 (`isEjectable || isRemovable`) 가 깨짐
- **해결**: 필터 완화 — `!isInternal && isBrowsable && isLocal`. `isLocal` 가드로 네트워크 마운트만 제외, 외장 디스크는 전부 통과

#### 3. `com.apple.provenance` xattr 로 codesign 거부

- **증상**: codesign(코드사인 = 코드 서명) 시 "resource fork, Finder information, or similar detritus not allowed" 에러
- **원인**: macOS 의 fileprovider 서비스 (iCloud Drive 등) 가 `~/Documents/` 안 파일에 자동으로 `com.apple.provenance` extended attribute(확장 속성) 부착. `xattr -cr` 로 정리해도 곧 다시 붙음
- **해결**: 빌드를 `/tmp/` 등 fileprovider 영향 없는 곳에서 수행. `xcodebuild -derivedDataPath /tmp/EjectDrives-derived`

#### 4. 단축키 등록 실패 (Carbon HotKey, macOS Sequoia+)

- **증상**: `RegisterEventHotKey` 가 success 반환했는데 키 입력해도 무반응. 또는 `-9868 eventInternalErr`
- **원인 (1)**: macOS Sequoia 부터 Apple 이 keylogging(키로깅 = 키 기록) 방지로 Option-only / Option+Shift 단축키 차단
- **원인 (2)**: macOS 26 + LSUIElement(엘에스유아이엘리먼트 = 메뉴바 전용 앱) + provisioning profile 없는 Apple Development sign 의 경우 Carbon hotkey 가 자주 ignored
- **해결**: Carbon `RegisterEventHotKey` 폐기 → `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` 으로 전환. **Accessibility 권한 필요** (`AXIsProcessTrustedWithOptions`)
- **추가 단축키 변경 history**: `⌃⇧₩` → `⌥⇧E` (Sequoia 차단) → `⇧⌘E` (Claude Code 와 충돌) → **`⌥⌘E`** (최종)

#### 5. Korean IME 문제 — 단축키가 한글 모드에서 안 잡힘

- **증상**: 영문 모드에선 `⌥⌘E` 잘 작동, 한글 모드 (2벌식) 에선 무반응
- **원인**: `event.charactersIgnoringModifiers` 가 한글 IME 활성 시 "ㄷ" 같은 한글 문자 반환 → "e" 와 비교 실패
- **해결**: 문자 대신 **physical key code(피지컬 키 코드 = 물리 키 코드)** 로 비교. `event.keyCode == 14` (kVK_ANSI_E)

#### 6. 우클릭 동작 안 함

- **증상**: `button.sendAction(on: [.leftMouseUp, .rightMouseUp])` 만으로는 우클릭이 button.action 으로 안 들어옴
- **원인**: NSStatusBarButton 에서 NSButton 의 sendAction(on:) mask 가 cell(셀 = 버튼의 그리는 부분) 레벨 설정 없이 ignored
- **해결**: button + cell 양쪽에 mask 설정. 또한 `.leftMouseUp/.rightMouseUp` → `.leftMouseDown/.rightMouseDown` (메뉴 표시 timing 일치)
  ```swift
  button.sendAction(on: [.leftMouseDown, .rightMouseDown])
  (button.cell as? NSButtonCell)?.sendAction(on: [.leftMouseDown, .rightMouseDown])
  ```

#### 7. 우클릭 monitor 의 좌표 false positive

- **증상**: 외장하드가 가만히 있는데 자동으로 인식↔추출 반복
- **원인**: 별도로 등록한 global rightMouseDown monitor 의 좌표 검사가 `NSMouseInRect(NSEvent.mouseLocation, btnWin.frame, false)` 인데, `btnWin.frame` 이 macOS 26 우회 코드에서 강제로 `(0, 0, 32, 22)` (화면 좌하단) 로 박혀있음. 사용자가 좌하단에서 우클릭 (트랙패드 ghost-tap, Dock 좌측 등) 시 추출 trigger
- **해결**: global rightMouseDown monitor 자체 제거. 우클릭은 `button.sendAction` 표준 방식으로

#### 8. dock cascade — USB Hub 까지 같이 빠짐

- **증상**: 외장하드 추출했는데 도킹 스테이션 자체가 disconnect 됨
- **원인**: `FileManager.unmountVolume(at:options: [.allPartitionsAndEjectDisk])` 의 `.allPartitionsAndEjectDisk` 옵션이 USB hub 의 모든 partition 까지 cascade(캐스케이드 = 연쇄) eject
- **해결**: `.allPartitionsAndEjectDisk` 폐기 → `.withoutUI` (단순 unmount) 로 전환

#### 9. `.withoutUI` 의 자동 재마운트 문제

- **증상**: 추출하면 곧바로 macOS 가 다시 mount → 사용자 시점에선 추출 안 된 것처럼 보임
- **원인**: `.withoutUI` 는 단순 unmount 일 뿐. 디스크 power off(전원 차단) 안 함 → macOS 가 재인식해서 자동 mount
- **해결**: `FileManager.unmountVolume` 폐기 → **`Process` 로 `/usr/sbin/diskutil eject` 외부 명령 호출**. Finder 와 동일 동작 (mount 해제 + 디스크 power off)

#### 10. `AppleClamshellState` 값 의미 반대 해석

- **증상**: 뚜껑 닫았는데 우리 앱이 "lid open(라이드 오픈 = 뚜껑 열림)" 으로 판정 → 추출 안 함
- **진단**: kernel 로그에는 `Clamshell closed` 인데 우리 앱 로그는 `EJECT(sleep) SKIPPED — lid open`
- **원인**: IOKit 의 `AppleClamshellState` property(프로퍼티) 의미가 직관과 반대
  - `AppleClamshellState = Yes` (true) → 뚜껑 **닫힘**
  - `AppleClamshellState = No` (false) → 뚜껑 **열림**
- **해결**: 변수명 `isOpen` → `isClosed` 로 의미 정확히 바꾸고 부호 뒤집기 제거. default 값은 `false` (못 읽으면 데스크탑 맥 = lid 없음 = 추출 안 함, 안전)

#### 11. fseventsd dissent — graceful eject 거부

- **증상**: lid close 추출 시 SYSJO (APFS RAID) 만 실패. SSD_W (exFAT) 는 성공
- **진단 로그**:
  ```
  Unmount of disk12 failed: at least one volume could not be unmounted
  Unmount was dissented by PID 343 (.../fseventsd)
  ```
- **원인**: `fseventsd` (FSEvents daemon = 파일 이벤트 데몬) 가 APFS 볼륨에 항상 listen handle(리슨 핸들 = 감시 연결) 을 잡고 있음. graceful unmount 시 fseventsd 가 release(릴리즈 = 놓기) 해야 하는데, sleep 진입 중 macOS 의 process freeze(프리즈 = 일시 정지) 로 fseventsd 가 negotiate(네고시에이트 = 협상) 응답 못 함 → dissent(디센트 = 거부) 응답 보냄. exFAT 같은 non-APFS 는 fseventsd 안 붙어서 영향 없음
- **해결**: **graceful + force fallback 도입**. 1단계 `diskutil eject` 실패 시 2단계 `diskutil unmount force` 자동 재시도. force 는 fseventsd dissent 무시하지만 write cache flush 는 수행 → ungraceful disconnect 보다 훨씬 안전
  ```swift
  // 1차: graceful
  let r1 = runDiskutil(["eject", volumePath])
  if r1.success { return (true, nil) }
  // 2차: force unmount (fseventsd dissent 무시)
  let r2 = runDiskutil(["unmount", "force", volumePath])
  ```

#### 12. 알림 권한 거부 — banner 안 뜸

- **증상**: 추출 완료 알림 banner 가 안 뜸
- **진단**: `requestAuthorization` → `granted=false, error=Notifications are not allowed for this application`. `notif settings: authStatus=1 (denied)`
- **원인**: 사용자가 알림을 다 꺼놨거나 처음 권한 요청 시 거부. 한 번 denied 되면 코드에서 다시 요청해도 거부됨 — 시스템 설정에서 직접 켜야만 변경 가능
- **해결**: 알림에 의존하지 않고 **메뉴바 아이콘 자체를 결과 상태로 영구 변경**. 사용자가 wake 후 메뉴바 보면 ✓ / ⚠ / ✗ 즉시 확인 가능

#### 13. wake 후 메뉴바 아이콘 reset

- **증상**: `setPersistentIcon("checkmark.circle.fill")` 호출했는데 wake 후 메뉴바엔 default ⏏ 만 보임
- **원인**: wake 시 macOS 가 status item view(스테이터스 아이템 뷰 = 메뉴바 항목 그리는 영역) 를 redraw(리드로 = 다시 그림) 하면서 button.image 가 reset 됨
- **해결**: `lastResultSymbol` 변수에 마지막 결과 저장 + `NSWorkspace.didWakeNotification` observer 등록 + wake 후 0.5s delay (status bar ready 대기) 후 `setPersistentIcon` 다시 호출

#### 14. NSLog 가 unified logging 에 안 들어감

- **증상**: `log show --predicate 'eventMessage CONTAINS "[EjectDrives]"'` 검색 결과 0건. NSLog 호출은 했는데 unified logging(통합 로깅) 시스템에 흔적 없음
- **원인**: macOS 26 에서 NSLog 가 stderr 로만 가고 unified logging 으로 forwarding(포워딩 = 전달) 안 되는 케이스. LSUIElement 앱은 stderr 가 dropped(드롭드 = 폐기) 될 수 있음
- **해결**: `NSLog` 전부 → `os.Logger` API 로 변환. subsystem(서브시스템 = 검색용 식별자) = `com.yongza.ejectdrives`, category(카테고리) = `app`. `log show --predicate 'subsystem == "com.yongza.ejectdrives"'` 로 정확히 추적 가능

#### 15. USB-C cable bouncing — DeckDock(덱독) 깜빡임

- **증상**: dock 빼고 다시 꽂는 동안 dock 이 혼자 깜빡깜빡 → 외장하드들 강제 disconnect → "추출되지 않았습니다" 알림 + dangling
- **진단**: 우리 앱 trigger 흔적 없음. diskarbitrationd 로그에 `disk disappeared` 가 graceful unmount 절차 없이 등장
- **원인**: USB-C 의 hardware-level bouncing(바운싱 = 짧은 변동). 24-pin 커넥터가 mate(메이트 = 접점 연결) 시 동시에 닿지 않고 순차로 닿음 → controller chip 이 enumeration(에뉴머레이션 = 인식 절차) 여러 번 시도. 케이블 quality(저항/길이) 가 주된 원인
- **해결**: 사용자 측 — **USB-C 케이블 교체** (Type C Gen2 PD3 100W 인증 케이블로). 우리 앱은 무관

#### 16. First Aid 경고 — 사용자가 추출 없이 dock 분리

- **증상**: 다음날 아침 dock 연결 시 macOS 가 "First Aid(퍼스트 에이드 = 디스크 검사) 권장" 알림. SYSJO 의 RAID 멤버 disk9s2 가 dirty(더티 = 미완료) 상태
- **진단**: 우리 앱 활동 0건. 마지막 정상 추출 후 사용자가 dock 다시 꽂아 작업 → 추출 없이 dock 분리 → ungraceful disconnect → SYSJO 의 RAID 멤버가 dirty
- **원인**: APFS RAID 는 멤버 디스크 둘의 sync(싱크 = 동기화) 가 필요해서 ungraceful 에 가장 약함. SSD_W (exFAT 단일) 는 영향 없음
- **해결**: macOS 의 자동 fsck repair 가 처리. 향후 예방은 사용자가 dock 분리 전 ⌥⌘E 또는 lid close 자동 추출

---

### 기술적 배경 정리

#### graceful eject vs force unmount

| 항목 | graceful (`diskutil eject`) | force (`diskutil unmount force`) |
|---|---|---|
| 사용 중 process(프로세스) 와 협상 | ✅ | ❌ 무시 |
| write cache flush(플러시 = 디스크 강제 기록) | ✅ | ✅ |
| file system journal(저널 = 변경 기록) commit(커밋 = 확정) | ✅ | ✅ |
| 디스크 power off | ✅ | ❌ (mount 해제만) |
| 사용 중인 file 안전 | ✅ | ⚠ 잘릴 수 있음 (sleep 직전엔 거의 없음) |
| **ungraceful disconnect 보다 훨씬 안전** | ✅ | ✅ |

→ graceful 시도 후 실패 시 force fallback = 항상 file system 깨끗히 정리.

#### IOKit `AppleClamshellState` 의미

```bash
# 뚜껑 열린 상태에서:
$ ioreg -r -k AppleClamshellState
"AppleClamshellState" = No
```

- `Yes (true)` → 뚜껑 **닫힘** (closed)
- `No (false)` → 뚜껑 **열림** (open)
- property 자체 없음 → 데스크탑 맥 (lid 없음)

직관과 반대. 코드 작성 시 변수명을 `isClosed` 로 명확히.

#### `NSWorkspace.willSleepNotification` vs lid close 직접 감지

우리 앱은 lid close 자체를 직접 감지하지 않음. 대신:
1. macOS sleep 진입 시 `willSleepNotification` 받음
2. 콜백 안에서 `isLidClosed()` 로 lid 상태 확인
3. lid 닫힘 + LidEject 토글 ON → 추출 trigger

장점: macOS 의 sleep 사이클에 자연스럽게 hook(훅 = 갈고리 연결)
한계: clamshell mode (외부 모니터 + 전원 + 뚜껑 닫음) 에서는 sleep 자체 안 들어감 → notification 안 옴

#### USB-C bouncing 과 케이블

USB Type-C spec(스펙 = 규격) 자체가 CC line(라인) 에 100ms debounce(디바운스 = 짧은 변동 무시) 시간 minimum(미니멈 = 최소) 으로 가정. macOS 의 USB-C stack 이 100ms 안의 짧은 변동을 항상 정확히 무시 못 하고 가끔 진짜 disconnect 로 처리 — brand 무관 macOS 자체의 quirk(쿼크 = 특이 동작).

가장 효과적 fix = **인증 케이블 사용**. Type C Gen2 PD3 (100W Power Delivery 인증) 짧은 (1m 이하) 케이블.

#### unified logging 사용법

```bash
# 실시간 stream
log stream --predicate 'subsystem == "com.yongza.ejectdrives"' --info

# 과거 이력 (지난 10분)
log show --predicate 'subsystem == "com.yongza.ejectdrives"' --last 10m --info

# debug level 까지 (자세히)
log show --predicate 'subsystem == "com.yongza.ejectdrives"' --last 10m --debug
```

log level:
- `notice`: 중요 이벤트 (앱 시작, hotkey 등록, Accessibility 권한)
- `info`: 일반 진단 (EJECT 시작/완료, willSleep, 결과 아이콘 set)
- `debug`: 자세한 내부 상태 (statusItemClicked event type)
- `error`: 에러 (symbol not found, IOKit 실패)

---

### 의존성 / 빌드 환경

| 항목 | 값 |
|---|---|
| 언어 | Swift 5.0+ |
| 최소 macOS | 13.0 (Logger API) |
| 검증 환경 | macOS 26.4.1 (Apple Silicon) |
| Bundle ID | `com.yongza.ejectdrives` |
| Code Sign | `Apple Development` (Personal Team, 자동) |
| Hardened Runtime | YES |
| App Sandbox | NO (혼자 쓰는 앱) |
| 빌드 시스템 | xcodegen + xcodebuild |
| 진입점 | `main.swift` (명시적 `NSApplication.shared.run()`) |
| 권한 | Accessibility (NSEvent global monitor), 알림 (선택) |

코드 라인:
- `AppDelegate.swift` ~430줄
- `main.swift` 16줄
- `project.yml` 44줄

---

### 알려진 제한

1. **Clamshell mode (외장 모니터 + 전원 + 뚜껑 닫음)**: macOS 가 sleep 자체를 안 들어감 → `willSleepNotification` 발생 X → 자동 추출 trigger 안 됨. **자동으로 안전하게 보호됨** (어차피 dock 분리 안 일어남)
2. **사용 중 디스크**: graceful eject 거부 시 force fallback 으로 대부분 처리. 단 진짜 write 중 file 은 잘릴 수 있음 (sleep 직전 시나리오엔 거의 없음)
3. **추출 후 wake 시 자동 재마운트**: macOS 의 USB-C power management 가 일관성 없음 — wake 시 디스크 재인식하기도, 안 하기도 함. 진짜 외출 시나리오 (lid close → dock 분리) 에서는 문제 없음. 테스트 시나리오 (lid close → 바로 lid open) 에선 보임
4. **데스크탑 맥 (Mac Mini, Studio, iMac)**: 뚜껑 자체가 없어 `AppleClamshellState` 키 없음 → 자동 추출 trigger 안 됨. 단축키 ⌥⌘E 또는 메뉴 클릭으로 수동 추출만 가능
5. **알림 권한 거부 시**: banner(배너) 안 뜸. 메뉴바 아이콘 ✓/⚠/✗ 표시로 fallback (시스템 설정에서 알림 켜면 banner 도 뜸)

---

### 다음 버전 후보 (v0.2.0 검토)

- **AC 어댑터 disconnect 트리거**: 충전 끊기면 = dock 빼기 직전 신호로 해석해 자동 추출. false positive(거짓 양성) 위험 (다른 충전기 잠깐 분리 시도) — 메뉴 토글로 사용자 선택권
- **Power assertion(파워 어서션 = sleep 지연 요청)**: `IOPMAssertionCreateWithName` 으로 sleep 지연 → fseventsd 가 응답할 시간 확보. 이번 force fallback 으로 대부분 해결돼서 우선순위 낮음
- **메뉴에 마지막 추출 결과 표시**: "마지막 추출: 08:32 (성공 2/2)" 같은 disabled item
- **로그인 시 자동 실행 자동화**: 현재는 시스템 설정에서 수동 등록. `SMAppService` 로 코드에서 등록 가능

---

### Repo

- GitHub: https://github.com/yooongZa/EjectDrives (private)
- 빌드 / 사용법: [README.md](README.md) 참조
