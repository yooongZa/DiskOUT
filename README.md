<div align="center">

<img src="DiskOUT-eject-transparent.png" width="180" alt="DiskOUT">

# DiskOUT

**한국어** · [English](README.en.md) · [日本語](README.ja.md) · [简体中文](README.zh-Hans.md)

### Mac 필수 무료 프로그램, DiskOUT 을 소개합니다.

**한국어 · English · 日本語 · 中文 (简体)** · 자동 추출 · Apple Silicon 네이티브

<br>

[![Download Latest](https://img.shields.io/github/v/release/yooongZa/DiskOUT?style=for-the-badge&label=Download&color=007AFF&logo=apple)](https://github.com/yooongZa/DiskOUT/releases/latest)

![macOS](https://img.shields.io/badge/macOS-14%2B-lightgrey?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-native-A855F7)
![Languages](https://img.shields.io/badge/i18n-4_languages-3B82F6)
![Developer ID](https://img.shields.io/badge/Developer_ID-signed-22C55E)
![Notarized](https://img.shields.io/badge/Apple-notarized-22C55E)

[다운로드](https://github.com/yooongZa/DiskOUT/releases/latest) ·
[변경 내역](CHANGELOG.md) ·
[이슈 / 피드백](https://github.com/yooongZa/DiskOUT/issues)

</div>

---

> Mac 은 완벽합니다 — *"디스크가 정상적으로 추출되지 않았습니다"* 알림을 제외하면 말이죠.

## 아무것도 안 해도, 디스크가 정상적으로 추출됩니다. 완벽하게.

이젠 맥북을 덮고, 뽑고, 넣고 외출하세요.

Apple 의 SSD 가격은 미쳤습니다. 심지어 업그레이드도 불가능하죠. 외장하드로 버티고 있지만 *"Disk Not Ejected Properly"* 알림은 지겹습니다. **DiskOUT** 을 사용하면 이제 더 이상 그런 알림을 볼 필요가 없습니다.

---

## 어떻게요?

### 1️⃣ 노트북을 덮는 순간, 모든 외장이 안전하게 추출됩니다.

덮으면 추출, 다시 열면 마운트.
잠들면 추출, 깨어나면 마운트.

### 2️⃣ 10개의 외장 하드도 한 번에 추출하세요.

단축키 한 번, 메뉴바 우클릭 한 번으로 모두 다 추출.

### 3️⃣ 외장 디스크가 몇 개인지, 한눈에 확인하세요.

메뉴바에 연결된 디스크 수가 숫자로 표시됩니다.

---

## 안심하고 쓸 수 있게

|  |  |
|---|---|
| **Time Machine 자동 보호** | TM 백업 디스크는 자동 추출 대상에서 자동 제외 — 실수로 백업 끊김 방지 |
| **DMG · 디스크 이미지 무시** | 마운트된 디스크 이미지는 메뉴에도 안 뜨고, 자동 추출 대상도 아님 |
| **"비정상 추출" 알림 없음** | sleep 추출은 정상 unmount(마운트 해제) 를 먼저 시도 — macOS 의 "improperly ejected" 알림이 안 뜸 |
| **Per-disk 옵트아웃** | 자동 추출에서 빼고 싶은 디스크만 개별 토글. Volume UUID 기반이라 케이블 슬롯 바뀌어도 유지 |
| **광고 · 추적 0** | 외장 디스크 다루는 일에만 집중. 자동 업데이트 체크 외에는 외부 통신 없음 |
| **Developer ID + Apple 공증** | Gatekeeper(게이트키퍼) 통과 — "확인되지 않은 개발자" 경고 없이 그냥 열림 |
| **자동 업데이트 (조용한 알림)** | 새 버전이 나오면 메뉴바 아이콘 옆에 작은 빨간 점 + 메뉴 안 항목으로만 표시. 모달 안 뜸. EdDSA + Apple Code Signing 이중 검증 후 설치 |

---

## 다운로드

<div align="center">

### [최신 릴리즈 받기 →](https://github.com/yooongZa/DiskOUT/releases/latest)

`DiskOUT-X.Y.Z.dmg` · 약 3MB · Apple Silicon 전용

</div>

### 설치 (30 초)

1. DMG 더블클릭 → **응용 프로그램** 폴더로 드래그
2. 첫 실행 시 macOS 가 한 번 묻습니다 → **열기** 클릭
3. 메뉴바에 숫자 아이콘이 뜸 (꽂힌 외장이 없으면 `0`)

### 시스템 요구사항

- macOS 14 (Sonoma) 이상
- Apple Silicon (M1 / M2 / M3 / M4)

---

## 사용법

| 동작 | 방법 |
|---|---|
| 개별 추출 | 메뉴바 아이콘 → 드라이브 이름 클릭 |
| 모두 추출 | 메뉴 "모두 추출" 또는 <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| 즉시 모두 추출 | 메뉴바 아이콘 **우클릭** |
| 추출 + 잠자기 | 메뉴 "추출하고 잠자기" — 모두 성공해야 잠자기 시작 |
| 마운트 안 된 외장 마운트 | 메뉴 하단 섹션 클릭 또는 <kbd>⌃</kbd><kbd>⌘</kbd><kbd>E</kbd> |
| 마운트 + Finder 열기 | 마운트 안 된 외장에 <kbd>⌘</kbd>+클릭 |
| 환경설정 | 메뉴 "환경설정..." 또는 <kbd>⌘</kbd><kbd>,</kbd> |

### 자동 실행

메뉴의 **"로그인 시 자동 실행"** 토글 → 시스템 자동 등록. macOS 가 추가 승인을 요청하면 시스템 설정 → 일반 → 로그인 항목에서 한 번 허용해주면 됩니다.

---

## FAQ

<details>
<summary><b>App Store(앱 스토어) 에 안 올라온 이유는?</b></summary>

mount / eject 같은 디스크 조작은 sandbox(샌드박스) 환경에서 제약이 많습니다. 안정성을 충분히 확보하기 어려워 Developer ID 직접 배포 노선으로 갔습니다. 대신 Apple 공증(notarization) 을 받아서 Gatekeeper 는 문제 없이 통과합니다.

</details>

<details>
<summary><b>안전한가요? 데이터 손실 위험은?</b></summary>

수동 추출은 `diskutil eject` 표준 경로를 사용합니다 (Finder 의 "추출"과 동일). 자동(잠자기) 추출은 정상 unmount 를 먼저 시도하고, 실패할 때만 force 단계로 떨어집니다. 사용 중인 디스크는 점유 프로세스를 진단해서 알림에 표시합니다.

단, force 단계까지 가도 추출되지 않는 디스크는 그대로 두고 알림만 띄웁니다 — 데이터 위험을 감수하면서 강제 추출하지 않습니다.

</details>

<details>
<summary><b>무료인가요?</b></summary>

현재는 무료 다운로드입니다. 향후 정책 변경 가능성을 위해 라이센스는 "All rights reserved" 로 두었지만, 개인 사용자가 받아 쓰는 데는 제한 없습니다.

</details>

<details>
<summary><b>Intel Mac 도 되나요?</b></summary>

현재 빌드는 Apple Silicon 전용입니다. Intel 빌드는 계획에 없습니다.

</details>

<details>
<summary><b>"비정상 추출" 알림이 떠요</b></summary>

DiskOUT 의 자동(잠자기) 추출은 정상 unmount 단계를 먼저 시도하기 때문에 보통은 알림이 뜨지 않습니다. 그래도 뜬다면 보통 다음 경우입니다.

- **사용 중인 앱이 있어 정상 unmount 실패 → force fallback 으로 진행**: 메뉴의 "force fallback" 토글이 ON 일 때.
- **macOS 가 먼저 추출을 시작한 케이스**: 잠자기 직전 다른 시스템 컴포넌트가 먼저 시도.

해결: 외장에 액세스하던 앱을 종료한 뒤 잠자기, 또는 환경설정에서 force fallback 을 OFF.

</details>

---

## 알려진 제한

- **클램쉘 모드 (외장 모니터 + 전원 + 뚜껑 닫음)**: macOS 가 sleep(잠자기) 자체를 안 들어감 → 자동 추출도 트리거 안 됨. 어차피 dock(도크) 분리도 안 일어나므로 안전.
- **사용 중 드라이브**: 1차 정상 추출 실패 시 force unmount(강제 마운트 해제) 를 시도하지만, 점유 앱이 있는 경우 데이터 위험을 여전히 주의해야 합니다.
- **사용자가 슬립 중 외장만 뽑아간 경우**: 우리 앱이 잡을 수 있는 영역이 아닙니다. 슬립 중 안전 추출이 필요하면 <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> 추천 — wake(깨우기) + 추출 한 번에.
- **재마운트 신뢰도**: 자동 추출에 성공한 디스크만 wake 후 재마운트합니다. 물리적으로 이미 빠진 디스크는 앱이 다시 마운트할 수 없습니다.

자세한 기술적 제한 사항은 [CHANGELOG.md](CHANGELOG.md) 참고.

---

## 전체 기능

<details>
<summary>기능 매트릭스 펼치기</summary>

| 기능 | 설명 |
|---|---|
| 메뉴바 드롭다운 | 연결된 외장 드라이브 목록. stale cache(오래된 캐시)는 즉시 표시하고 background refresh(백그라운드 갱신) 완료 후 메뉴를 다시 채워 창 열림 지연을 줄임. 갱신 실패 시 기존 cache 를 유지하고 실패 row(행)를 표시. **갱신 source 는 DA event-driven 인벤토리가 1순위** → SD 카드 삽입으로 `storagekitd` 가 막혀도 메뉴 즉시 정상 |
| **메뉴바 아이콘 = 마운트 개수** | 마운트된 외장 *디바이스* 개수를 숫자(텍스트)로 표시 — 0, 1, 2 … (상한 없음). 다중 파티션·RAID·APFS 합성 볼륨은 1 개로 집계. `DAInventory` 변화에 이벤트 기반 자동 갱신 (폴링 없음). 추출 진행/결과 표시 중에는 임시 심볼(↻·✓·✗)이 우선 |
| 개별 추출 | 드라이브 이름 클릭 |
| 모두 추출 | 메뉴 항목 또는 단축키 |
| **추출하고 잠자기** | 메뉴 항목. sleep 계열 volume-first force unmount(볼륨 우선 강제 마운트 해제) 경로로 전체 추출 후, 모두 성공할 때만 `pmset sleepnow` 로 시스템 sleep(잠자기) 시작. 실패가 있으면 sleep 취소 + 알림 |
| 전역 단축키 (추출) | 기본 <kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> (한/영 IME 무관, 물리 키 코드 비교). 환경설정에서 E 기반 preset(프리셋) 변경 가능 |
| 전역 단축키 (마운트) | 기본 <kbd>⌃</kbd><kbd>⌘</kbd><kbd>E</kbd> — 마운트 안 된 외장 일괄 마운트. 환경설정에서 변경 가능 |
| 우클릭 = 모두 추출 | 메뉴바 아이콘 우클릭 또는 ctrl+좌클릭. 환경설정 → Eject Behavior 에서 끄면 우클릭이 메뉴를 띄움 (실수 추출 방지 opt-out) |
| **마운트 안 된 외장 마운트** | 메뉴에 "마운트 안 된 외장" 섹션 자동 노출 (후보 있을 때만). 클릭 = 마운트, <kbd>⌘</kbd>+클릭 = 마운트 + Finder 열기 |
| **마운트/미마운트 상태 정합성** | `diskutil list -plist external` 한 snapshot(스냅샷)에서 mounted(마운트됨) / unmounted(마운트 안 됨)를 함께 계산해, 실제 마운트가 없는데 mounted 섹션에 남는 stale state(오래된 상태)를 줄임 |
| **디스크 종류 아이콘** | `diskutil info -plist` 의 SD card 신호가 확인되면 `sdcard` 아이콘, 그 외 외장은 `externaldrive` 계열 아이콘 사용 |
| **잠자기 진입 시** 자동 추출 | 메뉴 토글. IOKit power notification(전원 알림)으로 sleep(잠자기)을 잠깐 지연하고, 각 디스크에 대해 정상 DA unmount(whole-disk 우선) → DA force unmount(whole-disk 우선) → `diskutil unmountDisk force` → `eject force` 순서로 시도. 정상 unmount 가 통과하면 macOS 비정상 추출 알림이 뜨지 않음 |
| **화면 꺼질 때도 자동 추출** (옵션) | 메뉴 토글, default OFF. `pmset sleep=0` (자동 sleep 끈) 환경의 도킹 분리 사고 방지. sleep 계열 정상→force→`diskutil` 5 단계 경로 사용. 빈번한 발동 우려로 명시적 opt-in |
| **wake / 화면 켜질 때 자동 재마운트** | 자동 추출에 성공한 디스크만 재마운트. enumerate(열거) 안 되면 사용자가 분리한 것으로 보고 silent |
| **DMG / sparseimage 제외** | 마운트된 이미지는 `hdiutil info -plist` 1초 timeout + `diskutil info` fallback, unmounted 후보는 `BusProtocol == "Disk Image"` 로 제외 |
| 추출 경로 | 수동 추출은 1차 `diskutil eject <volumePath>` → 실패 시 `diskutil unmount force <volumePath>` fallback. sleep/display sleep/"추출하고 잠자기"는 **정상 DA unmount (whole disk 우선, 2s)** → **DA force unmount (whole disk 우선, 3s)** → `diskutil unmountDisk force` (6s) → `diskutil eject force` (5s) → `diskutil eject` (3s) 5단계. 정상 unmount 가 통과하면 macOS 비정상 추출 알림이 뜨지 않는다. APFS multi-volume container 도 whole-disk option 으로 한 번에 처리. 최종 실패 시 수동 경로는 `lsof` 로 점유 process / open file 진단을 알림에 추가 |
| 결과 알림 | **무음** banner + 메뉴바 아이콘 ✓/⚠/✗. 부재 중 발생하거나 negative 결과 (실패·재마운트 실패·sleep 추출 실패) 만 **알림 센터에 보관**, 본인 trigger + 성공은 banner 만 잠깐 표시 |
| 병렬 추출 | `DispatchGroup` 으로 N개 드라이브 동시 추출 |
| **로그인 시 자동 실행** | 메뉴 토글. `SMAppService.mainApp` 사용. `.requiresApproval` 상태도 체크 표시 + "로그인 항목 허용 필요" 라벨로 표시 |
| **환경설정 창** | <kbd>⌘</kbd><kbd>,</kbd> 또는 메뉴의 "환경설정..."에서 로그인 실행, sleep/display sleep 추출, Music/Photos 종료, 단축키 (Eject all / Mount all / Eject and Sleep), 알림, force fallback, 우클릭=모두 추출 토글, About(버전/저작권) 설정 |
| **단축키 충돌 자동 정정** | 추출 / 마운트 / 추출하고 잠자기 단축키가 같은 preset 으로 저장되면 충돌 감지 + 다른 preset 으로 자동 이동 + alert |
| **권한 누락 메뉴 안내** | Accessibility(손쉬운 사용) / 알림 권한이 미허용 상태면 메뉴 상단에 ⚠ 경고 row 표시. 클릭하면 시스템 설정의 해당 페이지로 이동 |
| **알림 세부 제어** | 전체 알림, 성공 알림, 실패 알림을 각각 토글. 기본은 모두 ON |
| **다국어 (ko + en + ja + zh-Hans)** | `Localizable.xcstrings` 105개 키. 첫 launch 에서 시스템 언어 자동 매칭 (지원 외 언어 사용자는 영어 fallback) + 환경설정 일반 탭의 Language 팝업에서 강제 선택 가능 |
| **자동 업데이트 (Sparkle 2)** | 24시간 주기로 백그라운드 체크. 새 버전 발견 시 다이얼로그 안 띄우고 **메뉴바 아이콘에 작은 systemRed `●` + 메뉴 안 "🔴 새 버전 X.Y.Z 사용 가능" 항목** 으로만 표시 (gentle reminder). 사용자가 클릭하면 표준 Sparkle 다운로드/설치 다이얼로그 → 자동 재시작. EdDSA(Ed25519) + Apple Code Signing 이중 검증. appcast 호스팅은 GitHub Pages, DMG 호스팅은 GitHub Releases — 무료 운영 |
| **Per-disk 자동 추출 제외** | 디스크 메뉴 항목 ▶ submenu 의 *"자동 추출 제외"* 토글. Volume UUID 기반 (케이블 슬롯 바뀌어도 유지). 자동 path 만 영향, 명시적 추출은 그대로. |
| **Time Machine 자동 보호** | TM 백업 디스크 자동 식별 (`Backups.backupdb` / `.com.apple.timemachine.donotpresent` 검사) → 첫 등장 시 자동 추출에서 제외 + 1회 알림. 메뉴에 시계 아이콘 + *(Time Machine)* 표기 |
| **외장 라이브러리 앱 처리** | 메뉴 토글 (default OFF). ON 이면 sleep 직전 Music / Photos 자동 quit (외장 라이브러리 lock 풀어 추출 가능), wake 후 백그라운드 자동 relaunch |

</details>

---

## 개발자 안내

<details>
<summary>빌드 · 설치 · 기술 메모 펼치기</summary>

### 기술 스택

| 항목 | 값 |
|---|---|
| Bundle ID | `com.yongza.ejectdrives` |
| Hardened Runtime | YES |
| App Sandbox | **NO** (`ENABLE_APP_SANDBOX = NO`) |
| 빌드 시스템 | Xcodegen + xcodebuild |
| 진입점 | `main.swift` (명시적 `NSApplication.shared.run()`) |
| 디스크 작업 | 수동 추출은 `/usr/sbin/diskutil` 직접 실행. sleep/display sleep/"추출하고 잠자기"는 `Disk Arbitration API` 의 정상 unmount → force unmount → `diskutil` fallback 의 5단계 경로 |

### 파일 구성

```
diskOUT/
├── AppDelegate.swift            # 메인 로직 (diskutil 실행, 메뉴 캐시, sleep/wake 처리)
├── Localizable.xcstrings        # ko + en + ja + zh-Hans 번역 (Xcode String Catalog, 105 키)
├── main.swift                   # 명시적 entry point (NSApp.run)
├── Info.plist                   # bundle metadata (xcodegen 자동 생성)
├── DiskOUT.entitlements         # 빈 plist. project.yml 의 entitlements 명시 함정 방지용
├── project.yml                  # xcodegen 설정 (sandbox OFF)
├── DiskOUT.xcodeproj/           # Xcode 프로젝트 (xcodegen 으로 재생성 가능)
├── CHANGELOG.md
└── README.md
```

### 빌드

**한 번만 (프로젝트 생성)**

```bash
cd ~/Documents/diskOUT
xcodegen generate                  # project.yml → DiskOUT.xcodeproj
```

**매 빌드**

```bash
cd ~/Documents/diskOUT
xcodebuild -project DiskOUT.xcodeproj -scheme DiskOUT -configuration Release \
  -derivedDataPath /tmp/DiskOUT-derived build
pkill -f DiskOUT
rm -rf ~/Applications/DiskOUT.app
cp -R /tmp/DiskOUT-derived/Build/Products/Release/DiskOUT.app ~/Applications/
open ~/Applications/DiskOUT.app
```

또는 Xcode 열어서 `DiskOUT.xcodeproj` → <kbd>⌘</kbd><kbd>R</kbd>.

**안전 설치 (롤백 가능)**

새 빌드 검증이 안 끝났을 때 권장. 기존 .app 을 먼저 백업 후 교체.

```bash
# 1. 빌드
cd ~/Documents/diskOUT
xcodebuild -project DiskOUT.xcodeproj -scheme DiskOUT -configuration Debug build

# 2. 종료 + 백업 + 교체
pkill -f DiskOUT
mv ~/Applications/DiskOUT.app ~/Applications/DiskOUT.app.prev.bak
DERIVED=$(find ~/Library/Developer/Xcode/DerivedData -name "DiskOUT.app" -type d | head -1)
cp -R "$DERIVED" ~/Applications/DiskOUT.app
xattr -cr ~/Applications/DiskOUT.app   # provenance/quarantine 정리
open ~/Applications/DiskOUT.app

# 3. 검증
log show --predicate 'subsystem == "com.yongza.ejectdrives"' --info --last 1m

# 4a. 문제 없으면 백업 제거
rm -rf ~/Applications/DiskOUT.app.prev.bak

# 4b. 문제 있으면 롤백
pkill -f DiskOUT
rm -rf ~/Applications/DiskOUT.app
mv ~/Applications/DiskOUT.app.prev.bak ~/Applications/DiskOUT.app
open ~/Applications/DiskOUT.app
```

### 옵션 변경 위치

대부분은 메뉴의 **환경설정...** 에서 바로 변경. 코드 수정이 필요한 항목만:

| 바꿀 것 | 위치 |
|---|---|
| 단축키 preset 추가 | `AppDelegate.swift` 의 `SettingsHotkeyPreset` |
| 자동추출 기본값 | `SleepEject.enabled` 의 default 값 |
| 재마운트 backoff 간격 | `tryRemount(bsd:delays:operationID:)` 호출 시 `delays: [0, 1, 3, 7]` 수정 |
| 메뉴 텍스트 | `populateMenu(_:snapshot:isRefreshing:)` 의 문자열 |

키 코드는 Carbon `Events.h` 의 `kVK_ANSI_*` 상수 참조.

### 진단 메모 — `NSStatusBarWindow` height = 0

초기 빌드 중 메뉴바에 status item 이 표시되지 않는 문제 발생. 코드는 100% 정상 동작 (NSLog 출력, statusItem / button / image 모두 정상 생성) 인데 메뉴바엔 안 보였음. 진단:

```
DIAG: NSApp.windows.count=1
DIAG window: class=NSStatusBarWindow frame=(0.0, 0.0, 32.0, 0.0) visible=true level=25
                                                            ^^^ height=0
```

`NSStatusBarWindow` 가 process 안에는 만들어졌지만 `WindowServer` 에 등록되지 않거나 height=0 으로 갇혀 있었음. macOS 26 의 새 정책 또는 status item 시스템의 미묘한 변경으로 추정.

**우회 코드** (`AppDelegate.swift` 의 `setupStatusItem`):

```swift
if let win = button.window {
    let thickness = NSStatusBar.system.thickness
    win.setFrame(NSRect(x: 0, y: 0, width: 32, height: thickness),
                 display: true, animate: false)
    win.orderFrontRegardless()
}
```

이 두 줄이 빠지면 메뉴바에 표시되지 않음.

### 진단 메모 — 외장 드라이브 필터

원래 필터:

```swift
guard !isInternal, isBrowsable, (isEjectable || isRemovable) else { continue }
```

macOS 26 에서는 Thunderbolt 외장 SSD / 일부 USB 가 `isEjectable=false, isRemovable=false` 로 보고되는 케이스 발견. 수정:

```swift
guard !isInternal, isBrowsable, isLocal else { continue }
```

`isLocal` 가드로 네트워크 마운트만 제외. 외장 디스크는 모두 통과.

### 다른 깨알 정보

- **노치 모델**: status items 가 메뉴바 좌측 (앱 메뉴 옆) 에도 배치될 수 있음 — 우측이 가득 차면 노치 너머 좌측에 등장.
- **`com.apple.provenance` xattr**: macOS 의 fileprovider 서비스 (iCloud Drive / OneDrive 등) 가 `~/Documents/` 안의 파일에 자동으로 붙임. codesign 이 이걸 보면 "resource fork, Finder information, or similar detritus not allowed" 로 사인 거부. `xattr -cr` 로 정리해도 곧 다시 붙음. **빌드는 `/tmp/` 등 fileprovider 영향 없는 곳에서 하는 게 안전.**
- **CGWindowList 의 한계**: `kCGWindowOwnerName == "DiskOUT"` 검색으로 윈도우 0개라도 메뉴바에 떠 있을 수 있음. `ControlCenter` 가 status item 의 view 를 자체 윈도우 안에 그리는 케이스가 있어 외부에서는 안 보임.
- **`ProcessRunner` stdout/stderr drain**: `Process` 의 stdout/stderr 를 `readabilityHandler` 로 비동기 drain 하고 종료 후 남은 data 도 회수. `lsof` 는 3초 timeout, `pmset sleepnow` 는 5초 timeout.

</details>

---

<div align="center">

**DiskOUT** · © 2026 LIMOD · All rights reserved

[릴리즈](https://github.com/yooongZa/DiskOUT/releases) ·
[변경 내역](CHANGELOG.md) ·
[이슈](https://github.com/yooongZa/DiskOUT/issues)

</div>
