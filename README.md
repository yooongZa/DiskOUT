# EjectDrives — 메뉴바 외장 드라이브 추출 유틸

**v0.4.0+** · 자세한 변경사항 / 발생했던 이슈 / 기술 배경 → [CHANGELOG.md](CHANGELOG.md)

맥 외장 드라이브를 한방에 안전하게 추출 / 마운트하는 메뉴바 앱.
현재는 **Mac App Store / sandbox 노선을 포기**하고, 개인 사용 및 향후 Developer ID 배포를 전제로 `diskutil` 직접 실행 방식으로 회귀했다.

## 현재 상태 (2026-05-13 기준)

✅ **sandbox OFF + `diskutil` 직접 실행 경로로 복원**. macOS 26.4.1 (Apple Silicon) 에서 Debug/Release build, `diskutil mountDisk`, `diskutil list -plist external`, 메뉴 snapshot cache(스냅샷 캐시), async menu refresh(비동기 메뉴 갱신), refresh stuck recovery(갱신 고착 복구), `lsof` 실패 진단, "추출하고 잠자기" 빌드 확인 완료. sleep/display sleep/"추출하고 잠자기" 경로는 `Disk Arbitration API` 의 **정상(non-force) unmount 를 먼저 시도**하고 (whole-disk option 우선) 실패 시에만 force / `diskutil` fallback 으로 떨어진다. logout/restart/shutdown 전 자동 추출은 코드가 남아 있지만 현재 default OFF.

✅ **sleep eject "비정상 추출" 알림 감소 (2026-05-13)** — APFS multi-volume container 디스크에서 알림이 sub-volume 마다 떴던 문제 fix. sleep eject 가 처음부터 `force` 로 시작하는 대신 정상 unmount 단계를 1번 거치고, force 단계도 whole-disk option 우선으로 sub-volume 들을 한꺼번에 처리. 자세한 내용은 [CHANGELOG.md](CHANGELOG.md) 의 "sleep eject 알림 감소" 항목 참고.

✅ **MVP 정비 완료 (2026-05-10)** — 코드 검토 결과 21 개 항목 일괄 fix. 메뉴바 표시 강제 코드 복원, 공유 state thread safety, 단축키 충돌 자동 정정, `ProcessRunner` timeout hang 방지, 권한 누락 메뉴 안내, About 탭, 우클릭 추출 opt-out, 결과 아이콘 자동 reset 등. 자세한 내용은 [CHANGELOG.md](CHANGELOG.md) 의 "MVP 정비" 항목 참고.

| 항목 | 값 |
|---|---|
| Bundle ID | `com.yongza.ejectdrives` |
| 사인 | `Apple Development: sukmack@gmail.com` (개발 빌드, 자동) |
| Hardened Runtime | YES |
| App Sandbox | **NO** (`ENABLE_APP_SANDBOX = NO`) |
| 배포 노선 | **App Store 보류/포기**. 현재는 sandbox 없는 개인/Developer ID 계열 배포 전제 |
| Developer ID 상태 | `Developer ID Application: roh yongwook (495S4FVMCB)` 서명 가능 확인. Notarization(공증)은 `notarytool` credential(자격 증명) 미설정으로 미완료 |
| 빌드 시스템 | Xcodegen + xcodebuild |
| 진입점 | `main.swift` (명시적 `NSApplication.shared.run()`) |
| 디스크 작업 | 기본 수동 추출은 `/usr/sbin/diskutil` 직접 실행 (`eject`, `unmount force`, `mountDisk`, `list -plist external`, `info -plist`). sleep/display sleep/"추출하고 잠자기"는 `Disk Arbitration API` 의 정상(non-force) unmount 를 whole-disk option 으로 먼저 시도 → 실패 시 force unmount → 그래도 실패하면 `diskutil unmountDisk force` / `eject force` fallback. disk image(DMG/CoreSimulator) 필터는 `/usr/bin/hdiutil info -plist` 1초 timeout + `diskutil info` fallback. 실패 진단은 `/usr/sbin/lsof`, 수동 sleep 요청은 `/usr/bin/pmset sleepnow` |

## 기능

| 기능 | 설명 |
|---|---|
| 메뉴바 드롭다운 | 연결된 외장 드라이브 목록. stale cache(오래된 캐시)는 즉시 표시하고 background refresh(백그라운드 갱신) 완료 후 메뉴를 다시 채워 창 열림 지연을 줄임. 갱신 실패 시 기존 cache 를 유지하고 실패 row(행)를 표시 |
| 개별 추출 | 드라이브 이름 클릭 |
| 모두 추출 | 메뉴 항목 또는 단축키 |
| **추출하고 잠자기** | 메뉴 항목. sleep 계열 volume-first force unmount(볼륨 우선 강제 마운트 해제) 경로로 전체 추출 후, 모두 성공할 때만 `pmset sleepnow` 로 시스템 sleep(잠자기) 시작. 실패가 있으면 sleep 취소 + 알림 |
| 전역 단축키 (추출) | 기본 `⌥⌘E` (한/영 IME 무관, 물리 키 코드 비교). 환경설정에서 E 기반 preset(프리셋) 변경 가능 |
| 전역 단축키 (마운트) | 기본 `⌃⌘E` — 마운트 안 된 외장 일괄 마운트. 환경설정에서 변경 가능 |
| 우클릭 = 모두 추출 | 메뉴바 아이콘 우클릭 또는 ctrl+좌클릭. 환경설정 → Eject Behavior 에서 끄면 우클릭이 메뉴를 띄움 (실수 추출 방지 opt-out) |
| **마운트 안 된 외장 마운트** | 메뉴에 "마운트 안 된 외장" 섹션 자동 노출 (후보 있을 때만). 클릭 = 마운트, ⌘+클릭 = 마운트 + Finder 열기 |
| **마운트/미마운트 상태 정합성** | `diskutil list -plist external` 한 snapshot(스냅샷)에서 mounted(마운트됨) / unmounted(마운트 안 됨)를 함께 계산해, 실제 마운트가 없는데 mounted 섹션에 남는 stale state(오래된 상태)를 줄임 |
| **디스크 종류 아이콘** | `diskutil info -plist` 의 SD card 신호가 확인되면 `sdcard` 아이콘, 그 외 외장은 `externaldrive` 계열 아이콘 사용 |
| **잠자기 진입 시** 자동 추출 | 메뉴 토글. IOKit power notification(전원 알림)으로 sleep(잠자기)을 잠깐 지연하고, 각 디스크에 대해 정상 DA unmount(whole-disk 우선) → DA force unmount(whole-disk 우선) → `diskutil unmountDisk force` → `eject force` 순서로 시도. 정상 unmount 가 통과하면 macOS 비정상 추출 알림이 뜨지 않음 |
| **화면 꺼질 때도 자동 추출** (v0.3.0, 옵션) | 메뉴 토글, default OFF. `pmset sleep=0` (자동 sleep 끈) 환경의 도킹 분리 사고 방지. sleep 계열 정상→force→`diskutil` 5 단계 경로 사용. 빈번한 발동 우려로 명시적 opt-in |
| **wake / 화면 켜질 때 자동 재마운트** | 자동 추출에 성공한 디스크만 재마운트. enumerate(열거) 안 되면 사용자가 분리한 것으로 보고 silent |
| **DMG / sparseimage 제외** | 마운트된 이미지는 `hdiutil info -plist` 1초 timeout + `diskutil info` fallback, unmounted 후보는 `BusProtocol == "Disk Image"` 로 제외 |
| 추출 경로 | 수동 추출은 1차 `diskutil eject <volumePath>` → 실패 시 `diskutil unmount force <volumePath>` fallback. sleep/display sleep/"추출하고 잠자기"는 **정상 DA unmount (whole disk 우선, 2s)** → **DA force unmount (whole disk 우선, 3s)** → `diskutil unmountDisk force` (6s) → `diskutil eject force` (5s) → `diskutil eject` (3s) 5단계. 정상 unmount 가 통과하면 macOS 비정상 추출 알림이 뜨지 않는다. APFS multi-volume container 도 whole-disk option 으로 한 번에 처리. 최종 실패 시 수동 경로는 `lsof` 로 점유 process(프로세스) / open file(열린 파일) 진단을 알림에 추가 |
| 결과 알림 | **무음** banner + 메뉴바 아이콘 ✓/⚠/✗. 부재 중 발생하거나 negative 결과 (실패·재마운트 실패·sleep 추출 실패) 만 **알림 센터에 보관**, 본인 trigger + 성공은 banner 만 잠깐 표시. 매트릭스는 [CHANGELOG.md](CHANGELOG.md) v0.2.1 |
| 병렬 추출 | `DispatchGroup` 으로 N개 드라이브 동시 추출 |
| **로그인 시 자동 실행** | 메뉴 토글. `SMAppService.mainApp` 사용. `.requiresApproval` 상태도 체크 표시 + "로그인 항목 허용 필요" 라벨로 표시 |
| **환경설정 창** | `⌘,` 또는 메뉴의 "환경설정..."에서 로그인 실행, sleep/display sleep 추출, Music/Photos 종료, 단축키 (Eject all / Mount all / Eject and Sleep), 알림, force fallback(강제 fallback), 우클릭=모두 추출 토글, About(버전/저작권) 설정. 메뉴엔 자주 토글하는 *"잠자기 시 자동 추출"* 만 노출 — 나머지는 환경설정 전용 |
| **단축키 충돌 자동 정정** | 추출 / 마운트 / 추출하고 잠자기 단축키가 같은 preset 으로 저장되면 충돌 감지 + 다른 preset 으로 자동 이동 + alert |
| **권한 누락 메뉴 안내** | Accessibility(손쉬운 사용) / 알림 권한이 미허용 상태면 메뉴 상단에 ⚠ 경고 row 표시. 클릭하면 시스템 설정의 해당 페이지로 이동 |
| **알림 세부 제어** | 전체 알림, 성공 알림, 실패 알림을 각각 toggle(토글). 기본은 모두 ON |
| **다국어 (ko + en)** | `Localizable.xcstrings` 73개 키. 시스템 언어 따라 자동 전환. 향후 일본어/중국어 추가 가능 |
| **Per-disk 자동 추출 제외** | 디스크 메뉴 항목 ▶ submenu 의 *"자동 추출 제외"* 토글. Volume UUID 기반 (케이블 슬롯 바뀌어도 유지). 자동 path 만 영향, 명시적 추출은 그대로. |
| **Time Machine 자동 보호** | TM 백업 디스크 자동 식별 (`Backups.backupdb` / `.com.apple.timemachine.donotpresent` 검사) → 첫 등장 시 자동 추출에서 제외 + 1회 알림. 메뉴에 시계 아이콘 + *(Time Machine)* 표기 |
| **외장 라이브러리 앱 처리** | 메뉴 토글 (default OFF). ON 이면 sleep 직전 Music / Photos 자동 quit (외장 라이브러리 lock 풀어 추출 가능), wake 후 백그라운드 자동 relaunch |

## 파일 구성

```
diskOUT/
├── AppDelegate.swift            # 메인 로직 (diskutil 실행, 메뉴 캐시, sleep/wake 처리)
├── Localizable.xcstrings        # ko + en 번역 (Xcode String Catalog)
├── main.swift                   # 명시적 entry point (NSApp.run)
├── Info.plist                   # bundle metadata (xcodegen 자동 생성)
├── EjectDrives.entitlements     # 빈 plist. project.yml 의 entitlements 명시 함정 방지용
├── project.yml                  # xcodegen 설정 (sandbox OFF)
├── EjectDrives.xcodeproj/       # Xcode 프로젝트 (xcodegen 으로 재생성 가능)
├── archive/                     # 폐기된 sandbox/helper 시절 코드 — 빌드 미사용, .gitignore 됨
│   ├── DiskArbitrationBackend.swift
│   ├── EjectDrives.entitlements (sandbox=true 시절)
│   ├── Helper/
│   ├── HelperClient.swift
│   └── Shared/HelperProtocol.swift
├── README.md                    # 이 파일
└── EjectDrives_*.md             # 풀버전 기획/분석 문서들
```

## 빌드 + 설치

### 한 번만

```bash
cd ~/Documents/diskOUT
xcodegen generate                  # project.yml → EjectDrives.xcodeproj
```

### 매 빌드

```bash
cd ~/Documents/diskOUT
xcodebuild -project EjectDrives.xcodeproj -scheme EjectDrives -configuration Release \
  -derivedDataPath /tmp/EjectDrives-derived build
pkill -f EjectDrives
rm -rf ~/Applications/EjectDrives.app
cp -R /tmp/EjectDrives-derived/Build/Products/Release/EjectDrives.app ~/Applications/
open ~/Applications/EjectDrives.app
```

또는 Xcode 열어서 `EjectDrives.xcodeproj` → `Cmd+R`.

### 안전 설치 (롤백 가능)

새 빌드 검증 안 끝났을 때 권장. 기존 .app 을 먼저 백업 후 교체.

```bash
# 1. 빌드
cd ~/Documents/diskOUT
xcodebuild -project EjectDrives.xcodeproj -scheme EjectDrives -configuration Debug build

# 2. 종료 + 백업 + 교체
pkill -f EjectDrives
mv ~/Applications/EjectDrives.app ~/Applications/EjectDrives.app.prev.bak
DERIVED=$(find ~/Library/Developer/Xcode/DerivedData -name "EjectDrives.app" -type d | head -1)
cp -R "$DERIVED" ~/Applications/EjectDrives.app
xattr -cr ~/Applications/EjectDrives.app   # provenance/quarantine 정리
open ~/Applications/EjectDrives.app

# 3. 검증 (메뉴 동작, 로그 확인)
log show --predicate 'subsystem == "com.yongza.ejectdrives"' --info --last 1m

# 4a. 문제 없으면 백업 제거
rm -rf ~/Applications/EjectDrives.app.prev.bak

# 4b. 문제 있으면 롤백
pkill -f EjectDrives
rm -rf ~/Applications/EjectDrives.app
mv ~/Applications/EjectDrives.app.prev.bak ~/Applications/EjectDrives.app
open ~/Applications/EjectDrives.app
```

> Debug 빌드는 `~/Library/Developer/Xcode/DerivedData/EjectDrives-<hash>/Build/Products/Debug/` 에 생성됨. Release 는 `Release/`. xcodebuild 의 `-derivedDataPath` 를 안 줄 때만 default 위치 사용.

### 배포 메모 (2026-05-07)

Mac App Store 노선은 현재 보류/포기. 이유는 핵심 기능인 mount/eject 안정성이 sandbox + DA/SMAppService helper 조합에서 충분히 확보되지 않았기 때문.

현재 기준 배포 방향:

1. 개발/개인 사용: `Apple Development` + sandbox OFF
2. 외부 배포가 필요하면: Developer ID + notarization 검토
3. App Store 재도전은 `diskutil mount/eject` 없이 동등 안정성을 확보할 때만 재검토

## 사용법

- 메뉴바 좌측의 **⏏ 추출 아이콘** 클릭 → 드라이브 목록. 디스크 상태 갱신 중이면 먼저 현재 cache(캐시)를 보여주고 완료 후 자동 갱신
- 드라이브 이름 클릭 → 개별 추출
- "모두 추출" → 전체 추출
- "추출하고 잠자기" → volume-first force unmount 경로로 전체 추출이 모두 성공하면 시스템 잠자기 시작. 실패가 있으면 잠자기 취소
- `⌥⌘E` → 어디서든 전체 추출 (기본값, 환경설정에서 변경 가능)
- 메뉴바 아이콘 우클릭 → 즉시 모두 추출 (메뉴 안 거침)
- 메뉴 하단 "마운트 안 된 외장" 섹션 (후보 있을 때만 자동 노출) → 클릭으로 개별 마운트, **⌘+클릭** = 마운트 + Finder 열기
- `⌃⌘E` → 마운트 안 된 외장 일괄 마운트 (기본값, 환경설정에서 변경 가능)
- "잠자기 시 자동 추출" 토글 → ON 이면 모든 sleep 진입 시 자동 추출. wake 후엔 자동 재마운트로 사용자 무감각 UX
- 사용자 단축키 / 메뉴 클릭 추출 시엔 wake 후 재마운트 안 함 (사용자 의도 존중)
- "환경설정..." 또는 `⌘,` → 단축키, 알림, force fallback, 자동 실행/자동 추출 계열 옵션 변경

## 로그인 시 자동 실행

메뉴에서 **"로그인 시 자동 실행"** 토글 → `SMAppService.mainApp` 으로 시스템 자동 등록. macOS 가 `.requiresApproval` 을 반환하면 메뉴에는 체크 표시와 함께 **"로그인 항목 허용 필요"** 가 붙는다. 이 상태에서는 시스템 설정 → 일반 → 로그인 항목에서 EjectDrives 를 허용해야 실제 로그인 실행이 활성화된다.

## 옵션 바꾸고 싶을 때

대부분은 메뉴의 **환경설정...** 에서 바로 바꾼다. 코드 수정이 필요한 항목만 아래에 남긴다.

| 바꿀 것 | 위치 |
|---|---|
| 단축키 preset 추가 | `AppDelegate.swift` 의 `SettingsHotkeyPreset` |
| 자동추출 기본값 | `SleepEject.enabled` 의 default 값 |
| 재마운트 backoff 간격 | `tryRemount(bsd:delays:operationID:)` 호출 시 `delays: [0, 1, 3, 7]` 수정 |
| 메뉴 텍스트 | `populateMenu(_:snapshot:isRefreshing:)` 의 문자열 |

키 코드는 Carbon `Events.h` 의 `kVK_ANSI_*` 상수 참조.

## 알려진 제한

- **클램쉘 모드 (외장 모니터 + 전원 + 뚜껑 닫음)**: macOS 가 sleep 자체를 안 들어감 → `willSleep` 노티 발생 X → 자동 추출도 트리거 안 됨. **자동으로 안전하게 보호됨** (어차피 dock 분리 안 일어남).
- **사용 중 드라이브**: 1차 `diskutil eject` 실패 시 `diskutil unmount force` 를 시도한다. force 는 완전한 eject(power off)가 아니라 mount 해제 fallback 이므로, 점유 앱이 있는 경우 사용자 데이터 위험을 여전히 주의해야 한다.
- **`lsof` 실패 진단**: 최종 추출 실패 뒤 best-effort(최선 노력)로 점유 process / open file 을 표시한다. macOS privacy(개인정보 보호) 정책 때문에 일부 앱/경로는 **Full Disk Access(전체 디스크 접근)** 권한 없이는 확인이 제한될 수 있다.
- **logout/restart/shutdown 전 자동 추출**: macOS 가 원래 종료 과정에서 볼륨 정리를 시도하고, 사용자 질문 기준 기능 가치가 낮아 현재 `powerOffAutoEjectEnabled = false` 로 꺼져 있다. 사용자에게 보이는 동작은 없다.
- **재마운트 신뢰도**: 자동 추출에 성공한 디스크만 wake 후 `diskutil mountDisk` 로 재마운트한다. 재인식 안 되는 디스크는 사용자 분리로 간주해 silent 처리한다. 물리적으로 이미 빠진 디스크는 앱이 다시 마운트할 수 없다.
- **사용자 분리 시나리오 4번** (sleep 중에 외장하드만 뽑아서 가져감): 우리 앱이 잡을 수 없는 영역. 깨우고 추출 대신 `⌥⌘E` 단축키 추천 — 슬립 중에도 wake + 추출 한 번에.
- **`pmset sleep = 0` 환경에서 화면 꺼짐 ≠ system sleep**: v0.2.x 까지는 화면만 꺼져도 추출 안 됨. v0.3.0 의 "화면 꺼질 때도 자동 추출" 토글로 보완 (명시적 opt-in). 트레이드오프: 자리 잠깐 비울 때마다 추출/재마운트 사이클 발생 가능 — 빈번하면 disk wear / 작업 흐름 끊김.
- **재설치 후 `로그인 항목 허용 필요` 메시지 잔존 가능**: 이전 sandbox/helper 노선 빌드를 설치했었던 머신은 BTM(Background Task Management) 에 helper daemon 등록이 stale 로 남아 있어, 새 빌드에서도 `SMAppService.mainApp.status == .requiresApproval` 로 보고된다. 시스템 설정 → 일반 → 로그인 항목 에서 EjectDrives 관련 stale entry 를 직접 OFF / 제거한 뒤 환경설정 → "Launch at login" 을 한 번 OFF/ON 하면 정정된다. (`sudo sfltool resetbtm` 은 다른 백그라운드 앱 등록도 reset 되므로 권장 안 함.)

---

# 빌드 / 설치 히스토리 (2026-05-04 진단 기록)

처음 swiftc 단독 빌드로 진행하다 메뉴바에 status item 이 표시되지 않는 문제 발생. 다음 단계들을 거쳐 해결.

## 시도한 것들 (시간 순)

| # | 시도 | 결과 |
|---|---|---|
| 1 | `swiftc AppDelegate.swift -parse-as-library` | 빌드 성공, 프로세스 launch, **메뉴바에 안 보임** |
| 2 | ad-hoc 사인 (`codesign --sign -`) + `xattr -cr` | 동일 |
| 3 | `Apple Development: sukmack@gmail.com` 인증서로 사인 | 동일 |
| 4 | `Developer ID Application` + Hardened Runtime | 동일 |
| 5 | `main.swift` 분리 + `setActivationPolicy(.accessory)` 를 `app.run()` 전에 호출 | 동일 |
| 6 | `Info.plist` 에 `NSPrincipalClass = NSApplication` 추가 | 동일 |
| 7 | `PkgInfo` 파일 (`APPL????`) 추가 | 동일 |
| 8 | `CFBundleInfoDictionaryVersion = "6.0"` + `CFBundleSupportedPlatforms` 추가 | 동일 |
| 9 | `lsregister` 로 LaunchServices DB 재등록 + `ControlCenter` 재시작 | 동일 |
| 10 | `~/Documents/` 안에서 빌드 → `/tmp/` 로 이동 (iCloud fileprovider 의 `com.apple.provenance` xattr 가 codesign 망가뜨리는 문제 회피) | 사인은 정상 됨, 여전히 메뉴바 안 보임 |
| 11 | `xcodegen` + `xcodebuild` 로 정식 Xcode 빌드 (`provisioning profile` + entitlements 자동 임베드) | 동일 |
| 12 | **App Sandbox + entitlements** (`com.apple.security.app-sandbox`, `device.usb`, `temporary-exception.files /Volumes/`) | 동일 |
| 13 | **`NSStatusBarWindow` 의 `setFrame` + `orderFrontRegardless()` 강제 호출** ✅ | **메뉴바 표시 해결!** |
| 14 | App Sandbox 비활성화 (혼자 쓰는 앱, 무관 확인) | entitlements 깨끗해짐 |
| 15 | **`ExternalDrive.list()` 필터 완화** ✅ | **외장 드라이브 인식 해결!** |

## 결정적 진단 — `NSStatusBarWindow` 의 height = 0

코드는 100% 정상 동작 (STEP 1~6 모든 NSLog 출력, statusItem/button/image 다 정상 생성) 하는데도 메뉴바에 안 보였음. 진단 결과:

```
DIAG: NSApp.windows.count=1
DIAG window: class=NSStatusBarWindow frame=(0.0, 0.0, 32.0, 0.0) visible=true level=25
                                                            ^^^ height=0
```

`NSStatusBarWindow` 가 우리 process 안에는 만들어졌지만 `WindowServer` 에 등록 안 되거나 height=0 으로 갇혀있었음. macOS 26 의 새 정책 또는 status item 시스템의 미묘한 변경으로 추정.

## 우회 코드 (`AppDelegate.swift` 의 `setupStatusItem`)

```swift
if let win = button.window {
    let thickness = NSStatusBar.system.thickness
    win.setFrame(NSRect(x: 0, y: 0, width: 32, height: thickness),
                 display: true, animate: false)
    win.orderFrontRegardless()
}
```

**이 두 줄이 빠지면 메뉴바에 안 보임.** macOS 26 에서 `NSStatusBar.system.statusItem(...)` 으로 만든 status item 의 window 를 명시적으로 frame 강제 설정 + WindowServer 에 등록 강제 해줘야 표시됨.

## 외장 드라이브 필터 (macOS 26 에서 깨진 풀버전 로직)

풀버전 EjectDrives 의 원래 필터:
```swift
guard !isInternal, isBrowsable, (isEjectable || isRemovable) else { continue }
```

**macOS 26 에서는 Thunderbolt 외장 SSD / 일부 USB 가 `isEjectable=false, isRemovable=false` 로 보고됨** (사용자 환경 진단: `SYSJO`, `업무백업` 두 외장 드라이브 모두 ejectable/removable 둘 다 false).

수정된 필터:
```swift
guard !isInternal, isBrowsable, isLocal else { continue }
```

`isLocal` 가드로 네트워크 마운트 (예: 다른 Mac 의 `skynet` 공유) 만 제외. 외장 디스크는 모두 통과.

## 다른 깨알 정보

- **노치 모델**: status items 가 메뉴바 좌측 (앱 메뉴 옆) 에도 배치될 수 있음 — 우측이 가득 차면 노치 너머 좌측에 등장.
- **`com.apple.provenance` xattr**: macOS 의 fileprovider 서비스 (iCloud Drive / OneDrive 등) 가 `~/Documents/` 안의 파일에 자동으로 붙임. codesign 이 이걸 보면 "resource fork, Finder information, or similar detritus not allowed" 로 사인 거부. `xattr -cr` 로 정리해도 곧 다시 붙음. **빌드는 `/tmp/` 등 fileprovider 영향 없는 곳에서 하는 게 안전.**
- **CGWindowList 의 한계**: `kCGWindowOwnerName == "EjectDrives"` 검색으로 윈도우 0개라도 메뉴바에 떠있을 수 있음. `ControlCenter` 가 status item 의 view 를 자체 윈도우 안에 그리는 케이스가 있어 외부에서는 안 보임. **진짜 보이는지 검증은 시각적 확인 필수.**
- **`ProcessRunner` stdout/stderr drain 개선 완료**: `Process` 의 stdout/stderr 를 `readabilityHandler` 로 비동기 drain(비우기)하고 종료 후 남은 data(데이터)도 회수한다. `lsof` 는 3초 timeout(타임아웃), `pmset sleepnow` 는 5초 timeout 을 둔다. 기존 `diskutil` 호출은 동작 보존을 위해 아직 명시 timeout 없이 실행한다.

---

# 풀버전 기획

App Store 출시 + 마스코트(Tako) + cosmetic IAP 까지 포함한 v1.0 계획. 관련 문서:

- [EjectDrives_개발기획서.md](EjectDrives_개발기획서.md) — 기능 명세, 아키텍처, 일정
- [EjectDrives_분석.md](EjectDrives_분석.md) — 시장 조사, 캐릭터 IAP 전략
- [EjectDrives_애니메이션_가이드.md](EjectDrives_애니메이션_가이드.md) — 캐릭터 애니메이션 구현 (cosmetic IAP 의 핵심 자산)

이 README 는 그 일부 코어 기능을 먼저 구현한 작업본.
