# DiskOUT 개발 기획서 & 계획안

> 작성일: 2026-05-03
> 작성: Claude (with yongZa)
> 관련 문서: `DiskOUT_분석.md`
> 상태: v1.0 출시 준비 보류 — 2026-05-07 현재 App Store/sandbox 노선 포기, sandbox OFF + `diskutil` 직접 실행 경로로 회귀

---

> 2026-05-07 업데이트: Mac App Store 단일 배포와 sandbox 호환 구현은 현재 유효하지 않다. `DADiskMount` / `DADiskUnmount` / `SMAppService.daemon` 조합으로 mount 안정성을 확보하지 못해, 현재 제품 방향은 개인 사용 및 향후 Developer ID 배포 검토로 변경됐다. 핵심 디스크 작업은 `diskutil mountDisk`, `diskutil eject`, 실패 시 `diskutil unmount force`, `diskutil list -plist external`, `diskutil info -plist`, `hdiutil info -plist` 를 사용한다.
>
> 2026-05-10 업데이트: sleep(잠자기) / display sleep(화면 꺼짐) / "추출하고 잠자기" 는 `Disk Arbitration API` 의 `DADiskUnmount(force)` 를 volume-first(볼륨 우선) 로 병렬 시도한 뒤 `diskutil` fallback 으로 내려간다. IOKit power notification(전원 알림) 으로 sleep 을 잠깐 지연하고, 성공한 디스크만 wake/remount(깨움/재마운트) 대상으로 기록한다.
>
> 2026-05-10 (정비) 업데이트: 코드 검토 결과 21 개 항목을 일괄 fix — 메뉴바 표시 강제 코드 복원(macOS 26 워크어라운드), 공유 state thread safety, 단축키 충돌 자동 정정, ProcessRunner timeout hang 방지, 권한 누락 메뉴 안내, About 탭, 우클릭 추출 opt-out, 결과 아이콘 자동 reset, tryRemount 의 IORegistry 직접 검사 전환, archive 디렉토리 분리 등. 자세한 내용은 `CHANGELOG.md` 의 "MVP 정비" 항목 참조.

# Part 1. 개발 기획서 (Specification)

## 1. 제품 개요

### 1.1 한 줄 정의
**"맥OS의 'Disk Not Ejected Properly' 경고를 영원히 끄는 메뉴바 유틸리티."**

### 1.2 제품명
- 정식: **DiskOUT**
- 마스코트: **Tako** (문어)
- 카피라이트 표기: `DiskOUT by yongZa`

### 1.3 플랫폼
- macOS 13 Ventura 이상 (`SMAppService` API 요구사항)
- Apple Silicon + Intel 동시 지원 (Universal Binary)
- 한국어 / 영어 (v1.0), 일본어 / 중국어 (v1.1+)

### 1.4 비즈니스 모델

**수정 (2026-05-07)**:

- **배포 채널**: Mac App Store **보류/포기**. 현재는 sandbox OFF 개인 사용 / 향후 Developer ID + notarization 검토.
- **가격**: 출시는 **무료**. 핵심 기능 (추출, 마운트, 자동 추출, 단축키, 자동 실행 등) 전부 무료.
- **유료화**: App Store 재도전 전까지 보류.
- **신뢰**: App Store 신뢰보다 핵심 기능의 실제 mount/eject 안정성을 우선한다.

---

## 2. 핵심 가치 제안

### 2.1 사용자에게 약속하는 것
1. **그 짜증나는 경고 알람을 영원히 안 본다**
2. **5개 드라이브를 2초 만에 동시 추출한다**
3. **뚜껑만 닫으면 알아서 처리된다**
4. **귀여운 문어가 옆에서 함께한다**

### 2.2 차별화 포인트 (vs Jettison)
| 항목 | Jettison | DiskOUT |
|---|---|---|
| 병렬 추출 | 순차 | **병렬 (5배 빠름)** |
| 캐릭터 인터랙션 | 없음 | **Tako 마스코트 + 진화 시스템** |
| 단축키 프리셋 | 1개 | **4개 + 커스텀** |
| 디자인 | 전통적 | **모던 / 미니멀** |
| 가격 | $9.99 | **무료 + cosmetic IAP** |

---

## 3. 타겟 사용자

### 3.1 주요 페르소나

**Persona A: 도킹 스테이션 헤비 유저**
- MacBook Pro/Air + CalDigit·OWC·Anker 도킹
- 외장 SSD 2~4개 상시 연결
- 매일 노트북 휴대 → 매일 추출 페인
- 결제 의향 강함

**Persona B: 외장 백업 사용자**
- Time Machine 외장 드라이브 사용자
- 작업 후 "그 알람" 반복 노출
- 가끔씩 추출 — 페인 빈도 낮음, 결제 의향 중간

**Persona C: 사진/영상 작업자**
- SD 카드 리더 + 외장 SSD
- 작업당 여러 드라이브 추출
- 속도가 가치, 결제 의향 강함

### 3.2 비-타겟 (배제)
- 외장 드라이브 사용 안 하는 일반 Mac 유저
- iMac + 내장 스토리지만 사용자
- Windows 전환 고려자

---

## 4. 기능 명세

### 4.1 v1.0 MVP 코어 기능

**메뉴바 코어**
- [F1] 메뉴바 아이콘 표시 (Tako 캐릭터)
- [F2] 클릭 시 연결된 외장 드라이브 목록 드롭다운
- [F3] 드라이브 이름 클릭 → 개별 추출
- [F4] "모두 추출" 메뉴 항목
- [F5] 추출 결과 알림 (성공/실패)

**드라이브 식별**
- [F6] 외장 드라이브만 필터링 (내장 디스크 제외)
- [F7] 드라이브 이름·아이콘·용량 표시
- [F8] 사용 중 상태 감지 (최종 추출 실패 후 `lsof` 기반 best-effort 진단)

**환경설정 창**
- [F9] 일반 / 단축키 / 정보 탭 구성

### 4.2 v1.0 MVP 전체 기능

> **무료/유료 분리 (확정)** — 아래 모든 기능 v1.0 무료 포함. **유료 = 캐릭터 애니메이션 / 사운드 팩 등 cosmetic IAP**, 기능 잠금 없음. IAP 도입은 v1.0 출시 후 2~3개월.

**자동화**
- [P1] ✅ 잠자기 진입 시 모든 외장 드라이브 자동 추출 (v0.2.0+). 2026-05-10 기준 IOKit sleep delay(잠자기 지연) + `DADiskUnmount(force)` volume-first 경로 사용
- [P2] 단축키 — `⌥⌘E` (추출) + `⌃⌘E` (마운트) ✅ 구현됨. 4가지 프리셋은 환경설정 창 도입 시점에 검토.
- [P3] ✅ 로그인 시 자동 실행 (`SMAppService.mainApp`, 메뉴 토글)
- [P12] ✅ "추출하고 잠자기" 메뉴 항목 — volume-first force unmount(볼륨 우선 강제 마운트 해제) 후 전체 추출 성공 시에만 `pmset sleepnow`
- [P13] 보류: logout/restart/shutdown 전 자동 추출 — 구현 코드 존재, 현재 `powerOffAutoEjectEnabled = false`

**안전 (Jettison 비교 후 추가)**
- [P9] ✅ Per-disk 자동 추출 제외 (Volume UUID 기반, 메뉴 submenu)
- [P10] ✅ Time Machine 디스크 자동 식별 + default 제외 + 1회 알림
- [P11] ✅ 외장 라이브러리 앱 (Music / Photos) 자동 quit / wake 후 relaunch (옵션, default OFF)
- [P14] ✅ 추출 실패 원인 표시 — `lsof -nP -w -Fpcfn -- <volumePath>` 로 점유 process(프로세스) / open file(열린 파일) 알림

**성능**
- [P4] ✅ 병렬 추출 (`diskutil` 직접 호출 + `DispatchGroup`)
- [P5] 빠른 실패 처리 (사용 중 드라이브는 즉시 스킵) — graceful unmount 가 dissenter 빨리 반환해서 사실상 동작

**캐릭터 인터랙션**
- [P6] 단축키 발동 시 Tako 흔들림 + 💨 파티클 + 사운드
- [P7] Silent / Audible 사운드 토글
- [P8] 드라이브 개수에 따라 캐릭터 크기 변화

### 4.3 후속 버전 백로그

**v1.1 (출시 후 3개월)**
- 추출 카운터 ("이번 달 N번 막음")
- 추가 캐릭터 (병아리, 기린, 무당벌레 등) — cosmetic IAP
- 추가 사운드 효과 (방귀 외 다양화) — cosmetic IAP
- 일본어 / 중국어 로컬라이즈 — `Localizable.xcstrings` 에 새 lang key + `CFBundleLocalizations` 갱신만으로 가능 (v1.0 의 ko/en 인프라 그대로 재사용)

**v1.2 (출시 후 6개월)**
- Shortcuts.app 연동
- AppleScript 지원
- CLI 명령어 (`diskout all`)
- Port-adjacent mode (실험적)
- 이스터에그 캐릭터 (11~20단계)

**v2.0 (출시 후 1년)**
- Year in Review (연말 통계 카드)
- 가능 시 macOS 26 신기능 활용

> **후속 버전 유료화 모델 (확정)** — cosmetic IAP (캐릭터 팩, 사운드 팩) 단일 노선. 기능 IAP 는 도입하지 않음. 가격 / 번들 구성은 첫 IAP 출시 시점에 시장 반응 보고 조정.

---

## 5. 기술 아키텍처

### 5.1 기술 스택
- **언어**: Swift 5.9+
- **UI 프레임워크**: AppKit (SwiftUI 부분 사용 가능)
- **타겟**: macOS 13.0+
- **빌드**: Xcode 15+

### 5.2 핵심 API/프레임워크

| 기능 | API/프레임워크 |
|---|---|
| 드라이브 감지·추출 | 현재 구현: 수동 경로는 `diskutil` / `hdiutil` / `lsof` 직접 실행. sleep 계열 경로는 `DiskArbitration.framework` 의 `DADiskUnmount(force)` 를 먼저 쓰고 `diskutil` fallback |
| 잠자기 감지 | IOKit power notification(전원 알림) + clamshell state(뚜껑 상태) observer + `NSWorkspace.willSleepNotification` fallback |
| 전역 단축키 | `Carbon.HIToolbox` (RegisterEventHotKey) |
| 로그인 자동 실행 | `ServiceManagement.SMAppService` (macOS 13+) |
| 결제(IAP) | `StoreKit 2` |
| 알림 | `UserNotifications` |
| 메뉴바 | `NSStatusBar` + `NSStatusItem` |
| 캐릭터 애니메이션 | `Core Animation` (CALayer + CAKeyframeAnimation) |
| 사운드 | `AVFoundation.AVAudioPlayer` |

### 5.3 파일 구조 (제안)

```
DiskOUT/
├── App/
│   ├── AppDelegate.swift           # 진입점, 라이프사이클
│   ├── DiskOUTApp.swift        # @main
│   └── Info.plist
├── Core/
│   ├── DriveManager.swift          # DiskArbitration 래퍼
│   ├── EjectService.swift          # 추출 로직 (병렬, 실패 처리)
│   ├── SleepObserver.swift         # 잠자기 감지
│   ├── HotkeyManager.swift         # Carbon 단축키
│   └── LoginItemManager.swift      # SMAppService 래퍼
├── UI/
│   ├── MenuBar/
│   │   ├── StatusItemController.swift
│   │   ├── DropdownMenu.swift
│   │   └── TakoMascotView.swift    # 캐릭터 뷰
│   ├── Settings/
│   │   ├── SettingsWindowController.swift
│   │   ├── GeneralTabView.swift
│   │   ├── HotkeyTabView.swift
│   │   └── AboutTabView.swift
│   └── Notifications/
│       └── NotificationCenter.swift
├── IAP/
│   ├── StoreManager.swift          # StoreKit 2
│   └── ProGate.swift               # 프로 기능 게이트
├── Resources/
│   ├── Assets.xcassets
│   ├── Sounds/
│   │   ├── eject_silent.wav        # 무음 (placeholder)
│   │   ├── eject_pop.wav
│   │   └── eject_fart.wav
│   └── Localizable/
│       ├── ko.lproj
│       └── en.lproj
└── Tests/
    ├── DriveManagerTests.swift
    └── EjectServiceTests.swift
```

### 5.4 핵심 데이터 흐름

```
[사용자 액션]
   ↓
[StatusItemController]
   ↓
[ProGate] — Pro 기능 체크
   ↓
[EjectService.ejectAll()]
   ↓
[DriveManager] → diskutil 병렬 호출
   ↓
[NotificationCenter] → 사용자 알림
   ↓
[TakoMascotView] → 캐릭터 애니메이션
```

### 5.5 권한 / Entitlements

**2026-05-07 현재 상태** — App Store/sandbox 노선 보류. 현재 빌드는 sandbox OFF 이며 아래 entitlements 는 과거 App Store 검토 기록이다.

```xml
<key>com.apple.security.app-sandbox</key>           <true/>
<key>com.apple.security.device.usb</key>            <true/>
<key>com.apple.security.files.user-selected.read-write</key> <true/>
<key>com.apple.security.temporary-exception.files.absolute-path.read-write</key>
<array><string>/Volumes/</string></array>
```

- 현재 구현: `diskutil` / `hdiutil` 직접 실행. `DiskOUT.entitlements` 는 빌드 미사용.
- App Store 재도전 조건: sandbox 안에서 `diskutil` 없이 동등한 mount/eject 안정성 확보.
- 단축키 (`⌥⌘E`, `⌃⌘E`): Accessibility 권한 별도 요청 — 첫 실행 시 사용자 안내 다이얼로그

### 5.6 핵심 알고리즘

기술적으로 신경 써야 할 알고리즘. 이 7개가 앱 품질을 좌우함.

#### 5.6.1 "사용 중" 감지 (최우선)
가장 까다로움. 너무 보수적이면 짜증, 너무 공격적이면 데이터 손실.

**고려할 신호**
- 열린 파일 핸들: 현재 sandbox OFF 경로에서는 `lsof -nP -w -Fpcfn -- <volumePath>` 로 최종 실패 후 best-effort 진단을 표시한다. App Store sandbox 재도전 시에는 다시 비활성화하거나 휴리스틱(heuristic = 경험적 추정)으로 대체해야 한다.
- 백그라운드 서비스: `mds` (Spotlight), `backupd` (Time Machine), `fseventsd` — 일부 추론 가능
- VFS 레벨 락(lock) — sandbox 안에서 제한적
- Finder가 해당 볼륨 열어놓은 상태 — 직접 검출 불가, 사용자에게 *"Finder 창 닫고 재시도"* 안내로 대체
- 디스크 이미지 마운트 체인 — `kDADiskDescriptionDeviceProtocolKey` 로 식별 가능

**판단 트리**
```
if Time Machine 백업 진행 중      → 절대 추출 X (사용자 알림)
elif 사용자 앱이 파일 쓰기 중      → 5초 대기 후 재시도 (1회)
elif Spotlight 인덱싱만 활성       → 즉시 시도 (실패해도 OK)
else                               → 즉시 추출
```

#### 5.6.2 드라이브 의존성 그래프
APFS Container 안에 Volume 여러 개 + Container는 외장 SSD 위.
- 잘못된 순서로 추출 시 좀비 마운트 발생
- `DASessionRef` 레벨에서 부모-자식 관계 트래킹
- **위상 정렬(Topological sort) 후 leaf부터 추출**

#### 5.6.3 병렬 추출 백프레셔 제어
순진한 동시 호출 → I/O 폭주, 한 드라이브 실패가 다른 드라이브 영향.

**올바른 구현**
- 동시 추출 한도 N개 (실측 후 결정, 보통 4~8)
- `DispatchSemaphore`로 동시성 제한
- 실패 시 지수 backoff 재시도 큐
- 드라이브당 30초 타임아웃

#### 5.6.4 잠자기 취소 처리 (Race Condition)
`willSleepNotification` → 추출 시작 → 사용자 잠자기 취소.

- `didWakeNotification` 수신 시 재마운트 시도
- USB는 물리적 분리 시 재마운트 불가 → 사용자 알림
- 추출 시작 후 5초 grace period 검토

#### 5.6.5 디바운싱 (Debouncing)
사용자가 단축키 3번 빠르게 누름 → 추출·알림 1번만.
- 디바운스 윈도우 1초, leading-edge fire

#### 5.6.6 단축키 충돌 감지
`RegisterEventHotKey()` 에러 -9868 = 다른 앱 점유.
- 등록 실패 시 토스트 알림
- 4개 프리셋 자동 시도 → 첫 성공 사용
- 환경설정에서 충돌 표시 UI

#### 5.6.7 IAP 검증
StoreKit 2 `Transaction.verify()` JWS 서명 검증.
- 환불 처리: `Transaction.updates` 스트림 구독
- 가족 공유: `ownershipType` 체크
- 오프라인 grace period 7일

#### 5.6.8 디스크 이미지(DMG) 필터링 (중요)

USB 외장 드라이브와 DMG·디스크 이미지를 **반드시 구분**해야 함. 잘못 처리 시 "Chrome 설치 중인데 DMG가 빠짐" 같은 평판 박살 시나리오 발생.

**구분 신호 (조합 필수)**

| 신호 | 키 | 판정 |
|---|---|---|
| 디바이스 프로토콜 | `kDADiskDescriptionDeviceProtocolKey` | `"Virtual Interface"` = DMG ★ |
| 내장 여부 | `kDADiskDescriptionDeviceInternalKey` | true = 제외 |
| 마운트 여부 | `kDADiskDescriptionVolumePathKey` | nil = 제외 |
| 네트워크 볼륨 | `kDADiskDescriptionVolumeNetworkKey` | true = 제외 |
| 마운트 가능 여부 | `kDADiskDescriptionVolumeMountableKey` | false = 제외 (스냅샷) |

**프로토콜 값별 분류**

```
"USB"              → 외장 USB ✓
"Thunderbolt"      → 외장 TB ✓
"SATA"             → 외장 도킹 SATA ✓
"PCI"              → 내장 SSD ✗
"Virtual Interface"→ DMG ✗
"Disk Image"       → DMG ✗
```

**필터링 코드**

```swift
func shouldShowInList(_ disk: DADisk) -> Bool {
    guard let desc = DADiskCopyDescription(disk) as? [String: Any] else {
        return false
    }
    
    // 1. 외장 여부
    let isInternal = desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? true
    guard !isInternal else { return false }
    
    // 2. 마운트 여부
    guard desc[kDADiskDescriptionVolumePathKey as String] != nil else { return false }
    
    // 3. 프로토콜 체크 — DMG 제외
    let proto = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
    let virtualProtocols = ["Virtual Interface", "Disk Image", "Disk Image (UDIF)"]
    if virtualProtocols.contains(proto) {
        return false
    }
    
    // 4. 네트워크 볼륨 제외
    let isNetwork = desc[kDADiskDescriptionVolumeNetworkKey as String] as? Bool ?? false
    guard !isNetwork else { return false }
    
    // 5. 마운트 가능 여부 (APFS 스냅샷 제외)
    let isMountable = desc[kDADiskDescriptionVolumeMountableKey as String] as? Bool ?? true
    guard isMountable else { return false }
    
    return true
}
```

**제품 정책 결정**

- **v1.0**: DMG는 메뉴에서 **무조건 제외**. 99% 사용자가 DMG를 "외장 드라이브"로 인식 안 함.
- **v1.1+**: 환경설정에 "디스크 이미지 포함" 토글 추가 검토. 활성화 시 별도 섹션에 회색 표시.

**잠자기 자동 추출 시나리오**

| 디스크 종류 | v1.0 자동 추출 | 이유 |
|---|---|---|
| USB / Thunderbolt SSD | ✓ | 핵심 가치 제안 |
| DMG (Chrome.dmg 등) | ✗ | 설치 진행 보호 |
| Time Machine 외장 | ✗ default | v0.5.0+ 자동 식별 후 제외. 사용자가 메뉴 토글 OFF 하면 추출 (백업 중 detection 은 v1.1+) |
| APFS 스냅샷 | ✗ | 시스템 보호 |
| 가상 머신 디스크 | ✗ | VM 무결성 보호 |

**메뉴 UI 권장**

```
🐙 DiskOUT
─────────────────
USB DRIVES
📦 SanDisk SSD              ⌘1
📦 Samsung T7               ⌘2
─────────────────
DISK IMAGES (v1.1, 환경설정 활성화 시)
💿 Chrome (DMG)             [회색]
💿 Backup.sparseimage       [회색]
─────────────────
🔘 모두 추출 (USB만)        ⌘⌥E
```

**추가 함정**

1. **외장 SSD 안의 DMG**: 부모 디스크 추적 필요. `kDADiskDescriptionMediaWholeKey`로 검증.
2. **VM 가상 디스크**: VMware, Parallels는 BSD name 패턴 또는 mount path 추가 검사 필요.
3. **macOS 설치 USB**: 진짜 USB라 Virtual Interface 아님. 정상 표시되어야 함.

#### 알고리즘 구현 우선순위

| 알고리즘 | 중요도 | 구현 난이도 |
|---|---|---|
| 사용 중 감지 | 🔥 최상 | 중 |
| 병렬 추출 백프레셔 | 🔥 최상 | 중 |
| **DMG 필터링** | **🔥 최상** | **하** |
| 잠자기 취소 race condition | 상 | 상 |
| 의존성 그래프 (APFS) | 상 | 중 |
| 디바운싱 | 중 | 하 |
| 단축키 충돌 | 중 | 하 |
| IAP 검증 | 중 | 하 |

### 5.7 AI 통합 전략

대부분의 "AI 기능" 아이디어는 **AI 워싱(AI-washing)**이 됨. 진짜 가치 있는 것만 선별.

#### 5.7.1 거를 것 (Anti-pattern)
- ❌ "AI 스마트 추출" — 룰 기반이 더 정확
- ❌ 메뉴바 AI 챗봇
- ❌ AI 추천 드라이브 관리 (정의 모호)
- ❌ AI 캐릭터 변형 (카피라이트·품질 지옥)
- ❌ LLM 자연어 환경설정 입력 (체크박스가 더 빠름)

#### 5.7.2 진짜 가치 있는 것

**A. App Intents + Apple Intelligence (★ v1.0 추천)**

직접 AI 만들 필요 없음. Apple이 다 해줌.

구현: `AppIntents` 프레임워크로 액션 노출
- "Eject all drives" Intent
- "Eject [Drive Name]" Intent (parameterized)
- "Eject when sleeping" toggle Intent

자동으로 얻는 것:
- Siri: "Hey Siri, 외장하드 다 빼줘"
- Spotlight: "eject" 검색 시 액션 노출
- Shortcuts.app 자동화에서 사용 가능
- Apple Intelligence (macOS 26+) 자연어 명령 자동 매칭

**비용**: 200~400 LOC(Lines of Code, 코드 줄 수) — 1~2일 작업
**ROI**: 압도적. v1.0 포함.

**B. 추출 실패 진단 메시지 개선**

시스템 메시지 `"one or more programs may be using it"` 는 모호하다.

현재 sandbox OFF 경로에서는 `diskutil eject` 와 `diskutil unmount force` 가 모두 실패한 뒤 `lsof -nP -w -Fpcfn -- <volumePath>` 를 3초 timeout(타임아웃)으로 실행해 점유 process / open file 을 알림에 붙인다. macOS privacy(개인정보 보호) 제한 때문에 Full Disk Access(전체 디스크 접근)가 필요할 수 있다.

App Store sandbox 재도전 시에는 `lsof` / `proc_pidfdinfo` 등 다른 프로세스 fd 검사가 다시 차단된다. 그 경우 대체 접근은 다음으로 제한한다:
- *외장 라이브러리 앱 자동 종료* (Music / Photos) 옵션 — lock 의 대표 케이스 자동 우회
- Time Machine 디스크 자동 식별 + default 자동 추출 제외
- 백그라운드 서비스 패턴 추정 (`backupd`, Spotlight 등) + 액션 가능한 안내

**C. 사용 패턴 학습 (v2.0)**

엄밀히는 통계 학습. 마케팅상 "AI"로 칭할 수 있음.
- "Time Machine은 밤새 안 빼더라" → 자동 추출 제외
- "이 SD 카드는 꽂자마자 30초 안에 빼더라" → 자동 추출 제안

온디바이스, 프라이버시 안전. 데이터 누적 후 v2.0 검토.

#### 5.7.3 AI 기능 우선순위

| 기능 | v1.0 | v1.1 | v2.0 | 비고 |
|---|---|---|---|---|
| App Intents + Apple Intelligence | ✅ | | | 진짜 가치, 비용 낮음 |
| 추출 실패 진단 (룰 기반) | ✅ | | | "AI" 아니지만 실용 |
| Apple Intelligence Writing Tools 통합 | | ✅ | | 메시지 자연어 |
| 사용 패턴 학습 | | | ✅ | 데이터 쌓인 후 |
| 그 외 모든 "AI" 아이디어 | ❌ | ❌ | ❌ | 워싱 |

#### 5.7.4 마케팅 활용
App Intents 통합 시 정당화 가능 카피:
- "Apple Intelligence ready"
- "Hey Siri, eject all drives"
- "Works with Shortcuts"
- App Store "AI Apps" 카테고리 노출 가능 (운영 시)

#### 5.7.5 결론
**v1.0에는 App Intents 1개만.** 나머지는 다 거름. 1인 개발자가 AI 기능 욕심 부리면 코어 기능 품질이 떨어짐. DiskOUT의 본질은 **"빠르고 조용한 추출"**이지 AI 어시스턴트가 아님.

---

## 6. UX/UI 명세

### 6.1 메뉴바 아이콘
- 크기: 22×22 pt
- 상태별 변화:
  - 외장 드라이브 0개: Tako 회색 / 작음
  - 1~2개: Tako 컬러 / 중간
  - 3개+: Tako 다리 펼침 / 큼
- Dark / Light 모드 자동 대응

### 6.2 드롭다운 메뉴

```
🐙 DiskOUT
─────────────────
📦 SanDisk SSD (1.8TB)        ⌘1
📦 Samsung T7 (500GB)         ⌘2
📦 Time Machine (4TB)         ⌘3
─────────────────
🔘 모두 추출                   ⌘⌥E
─────────────────
⚙️  환경설정...
ℹ️  DiskOUT 정보
종료
```

### 6.3 환경설정 창

> **무료/유료 구분**: 모든 기능 무료. IAP 는 캐릭터 / 사운드 팩 등 cosmetic 만.
> **v1.0 단계**: 환경설정 창 도입 안 함 — 모든 토글이 메뉴 안에 있음. 환경설정 창은 IAP 도입 (v1.1+) 시점에 검토.

**v1.0 메뉴 토글** (전부 무료, 환경설정 창 없이 메뉴에서 직접)
- ✅ 로그인 시 자동 실행 (`SMAppService.mainApp` + 메뉴 토글, v0.5.0)
- ✅ 잠자기 시 자동 추출 (v0.2.0+)
- ✅ 화면 꺼질 때도 자동 추출 (실험, default OFF, v0.3.0+)
- ✅ "추출하고 잠자기" 메뉴 명령 (2026-05-07) — 전체 추출 성공 시에만 sleep 시작
- ✅ 잠자기 전 Music / Photos 자동 종료 (default OFF, v0.5.0) — 외장 라이브러리 lock 풀이용
- ✅ 디스크별 *"자동 추출 제외"* 토글 — 메뉴 디스크 항목의 submenu (v0.5.0)
- ✅ Time Machine 디스크 자동 식별 + default 제외 (v0.5.0)
- ❌ logout/restart/shutdown 전 자동 추출 — 현재 default OFF, UI 노출 없음

**v1.1+ 환경설정 창 (예정)**
- [ ] Tako 캐릭터 표시 토글 (기본 Tako 무료)
- [ ] 사운드: ⚪ 무음 ⚪ 효과음 — *방귀 등 추가 사운드는 IAP 사운드 팩*

**단축키 탭** (전부 무료)
- 단축키 프리셋 라디오:
  - ⚪ ⌘⌥E (기본)
  - ⚪ ⌘⌥⇧E
  - ⚪ ⌘⌃E
  - ⚪ ⌃⌥E
- 충돌 감지 표시

**정보 탭**
- 버전 / 빌드 번호
- 개발자 / 라이선스
- IAP 구매 (캐릭터 팩 / 사운드 팩) / 구매 복원 — *v1.0 출시 후 2~3개월에 추가*
- 피드백 보내기

### 6.4 알림 디자인
- **성공**: "3개 드라이브가 안전하게 추출되었습니다 🐙"
- **부분 실패**: "2개 추출됨 / SanDisk SSD는 사용 중입니다"
- **전체 실패**: "Time Machine 백업이 진행 중입니다"

### 6.5 캐릭터 애니메이션 사양

| 트리거 | 애니메이션 |
|---|---|
| 단축키 발동 | 0.3초 흔들림 + 💨 파티클 3개 위로 fade out |
| 추출 시작 | 다리 1개씩 쏙쏙 들어감 (per drive) |
| 추출 완료 | "휴—" 표정 0.5초 |
| 드라이브 연결 | 다리 1개 펼침 |
| 추출 실패 | 다리 흔들림 + ❌ 표시 |

---

## 7. 차별화 카피 (마케팅 연계)

### 7.1 App Store 설명 후보

```
Stop seeing "Disk Not Ejected Properly" forever.

DiskOUT safely removes all your external drives
when you close the lid — silently, automatically, fast.

✓ 5x faster than macOS default (parallel ejection)
✓ Auto-eject on sleep
✓ Global hotkey support
✓ Cute octopus mascot
```

### 7.2 한국어 카피

```
"디스크가 올바르게 제거되지 않았습니다."
이 알람, 이제 그만 보세요.

뚜껑만 닫으면 DiskOUT의 Tako가
모든 외장 드라이브를 알아서 안전하게 추출합니다.

✓ macOS 기본보다 5배 빠른 병렬 추출
✓ 잠자기 시 자동 추출
✓ 전역 단축키 지원
✓ 귀여운 문어 마스코트
```

> **가격·포지셔닝 (확정)** — v1.0 무료 (App Store). 사용자 진입 장벽 0. *"Jettison ($9.99) 의 핵심 기능을 무료로"* 카피 가능. cosmetic IAP 도입 시점 (출시 후 2~3개월) 에 *"개발 응원해주세요"* 톤으로 자연스럽게 추가.

---

# Part 2. 개발 계획안 (Schedule)

## 8. 타임라인 (12주 / 3개월)

```
[Phase 1: Build]       Week 1-6    코어 개발
[Phase 2: Polish]      Week 7-8    품질·테스트
[Phase 3: Pre-launch]  Week 9-10   마케팅 자산
[Phase 4: Launch]      Week 11-12  출시·마케팅
```

### 8.1 Week 1-2: 코어 기능
- [ ] 프로젝트 셋업 (Xcode, 디렉토리 구조)
- [x] ✅ 외장 드라이브 감지 (`ExternalDrive.list()` + `URLResourceValues`)
- [x] ✅ 개별/전체 추출 (`diskutil eject` + 실패 시 `diskutil unmount force`)
- [x] ✅ 메뉴바 아이콘 + 드롭다운
- [x] ✅ 추출 결과 알림 (banner / 알림 센터 매트릭스)

### 8.2 Week 3-4: 자동화 기능

> 모두 무료 — 기능 IAP 폐기 (cosmetic IAP 만)

- [x] ✅ Sleep / display sleep 감지 (`NSWorkspace` notifications)
- [x] ✅ "추출하고 잠자기" (`pmset sleepnow`, 실패 시 sleep 취소)
- [x] ✅ 전역 단축키 (`⌥⌘E` 추출, `⌃⌘E` 마운트, Carbon `RegisterEventHotKey` + `NSEvent.addGlobalMonitorForEvents`)
- [x] ✅ `SMAppService` 로그인 항목 (메뉴 토글, requiresApproval 자동 처리)
- [ ] StoreKit 2 IAP 통합 — v1.1+ (cosmetic IAP 도입 시점)

### 8.3 Week 5: 캐릭터 & 인터랙션 (v1.1+ 로 미룸)

cosmetic IAP 의 핵심 자산. v1.0 출시 후 데이터 보고 도입 시점 결정.

- [ ] Tako 마스코트 디자인 (외주 또는 직접)
- [ ] `TakoMascotView` 구현
- [ ] 캐릭터 애니메이션 (Core Animation)
- [ ] 사운드 효과 제작/구매
- [ ] 단축키 발동 시 인터랙션 통합

### 8.4 Week 6: 성능 최적화

- [x] ✅ 병렬 추출 (`diskutil` + `DispatchGroup`)
- [x] ✅ 빠른 실패 — `diskutil eject` 실패 시 force fallback 으로 마무리
- [x] ✅ `ProcessRunner` stdout/stderr drain + timeout 옵션 (`lsof` 3초, `pmset` 5초)
- [ ] 벤치마크 (1/3/5개 시나리오) — 출시 직전 측정 + 마케팅 자료

### 8.5 Week 7: 품질
- [x] ✅ 에러 핸들링 — `diskutil eject` 실패 시 `diskutil unmount force` fallback + `lsof` 진단 + 사용자 알림
- [x] ✅ 다국어 (ko + en) — `Localizable.xcstrings`, 84 개 키 (MVP 정비로 새 11 키 추가)
- [x] ✅ Thread safety / 단축키 충돌 / ProcessRunner hang / 권한 누락 안내 등 MVP 정비 (2026-05-10) — 자세한 내용은 `CHANGELOG.md`
- [ ] 다크/라이트 모드 점검 (출시 전)
- [ ] Accessibility (VoiceOver 등) — 출시 전. 권한 거부 / 미허용 상태 메뉴 안내는 완료 (2026-05-10).
- [ ] Sandbox 호환성 검증 — 2026-05-07 기준 보류/포기

### 8.6 Week 8: 베타 테스트
- [ ] TestFlight 빌드 업로드
- [ ] 베타 테스터 모집 (지인 5~10명, Korea Mac Users 커뮤니티)
- [ ] 1주일 베타 기간
- [ ] 크래시·버그 수정

### 8.7 Week 9-10: 마케팅 자산
- [ ] 랜딩 페이지 제작 (정적, GitHub Pages 무료)
- [ ] App Store 스크린샷 5종 (Before/After 알람 강조)
- [ ] 데모 GIF 3종 (단일 추출, 병렬 추출, 캐릭터 인터랙션)
- [ ] App Store 소개 텍스트 (한/영)
- [ ] Product Hunt 자료 (헌터 섭외, 갤러리 이미지)
- [ ] 블로그 글 1~2개 작성 ("How I built DiskOUT")

### 8.8 Week 11: App Store 제출
- [ ] App Store Connect 메타데이터 입력
- [ ] 심사 제출 (평균 1~3일)
- [ ] 거부 시 수정·재제출
- [ ] 승인 후 "Manual Release" 상태 유지

### 8.9 Week 12: 런칭
- [ ] **Day 1 (월요일)**: 한국 커뮤니티 (Clien, GeekNews) 사전 노출
- [ ] **Day 2 (화요일 PST 0시)**: Product Hunt 런칭
- [ ] **Day 3**: Show HN 게시
- [ ] **Day 4-5**: r/macapps, r/MacOS, r/macsetups 순차 게시
- [ ] **Day 6-7**: 피드백 수집·대응

---

## 9. 출시 전 검증 체크리스트 (Pre-development)

> **코드 한 줄 짜기 전에 이 4가지부터.** 1주일 안에 끝낸다.

- [ ] **검색량 측정**: Ahrefs / Google Keyword Planner로 다음 키워드 월간 검색량 확인
  - "disk not ejected properly"
  - "Jettison alternative"
  - "Mac auto eject"
  - "맥 디스크 추출 경고"
- [ ] **커뮤니티 누적 페인 확인**: r/MacOS, r/macbookpro에서 위 키워드 검색 → 게시물 수 / 댓글 톤 측정
- [ ] **Jettison 리뷰 분석**: App Store 리뷰 100개 읽고 "경고 알람" 언급 빈도 카운트
- [ ] **사용자 인터뷰 10명**: 외장 드라이브 사용자에게 "그 알람 짜증나죠?" 반응 측정

**검증 결과 판단 기준**
- 통과: 키워드 월 검색량 1,000+ AND 인터뷰 10명 중 6명+ 강한 동의
- 보류: 검색량 200~1,000 OR 인터뷰 동의 중간
- 중단: 검색량 200 미만 AND 인터뷰 동의 약함

---

## 10. KPI / 성공 지표

### 10.1 출시 1개월 목표
- 다운로드: **1,000건**
- App Store 평점: **4.5+**
- 리뷰: **20개+**

### 10.2 출시 3개월 목표
- 다운로드: **3,000건**
- 검색 키워드 SEO: "disk not ejected properly" 1페이지 진입
- IAP 도입 준비 완료 (캐릭터 팩 / 사운드 팩 자산 + StoreKit 2 통합)

### 10.3 출시 12개월 목표
- 다운로드: **8,000건**
- v1.1, v1.2 릴리스 완료
- IAP 매출: **$500~$2,000** (보수~낙관 시나리오, App Store 30% 차감 후)
- IAP 전환율: **1~3%**

---

## 11. Kill Criteria (타임박스)

> 1인 개발자가 죽는 가장 흔한 이유: **잘 안 되는 프로젝트를 못 놓는 것.**

다음 조건 충족 시 **다음 프로젝트로 전환**:

- [ ] **3개월 시점**: 다운로드 500건 미만 → 마케팅 전략 재검토 (App Store 검색 키워드 / 캐릭터 비주얼)
- [ ] **6개월 시점**: 다운로드 1,500건 미만 → 포지셔닝 피벗 또는 종료
- [ ] **12개월 시점**: IAP 도입 후 6개월 매출 $100 미만 → IAP 모델 재검토 (캐릭터 vs 사운드 vs 다른 포맷)

**중요**: 종료해도 실패가 아님. 학습·포트폴리오 자산 + 다음 앱 빌드 인 퍼블릭 채널 확보.

---

## 12. 리스크 & 대응

| 리스크 | 가능성 | 대응 |
|---|---|---|
| Apple이 macOS에 "경고 끄기" 토글 추가 | 중 | 마케팅 카피 다양화, 속도·캐릭터 차별화 강조 |
| App Store 심사 거부 | 낮음 | Sandbox 호환 사전 검증, 캐릭터 톤 점잖게 |
| Jettison 가격 인하 / 무료화 | 낮음 | 속도·디자인 차별화 유지, 한국어 시장 선점 |
| 출시 후 트래픽 0 | 높음 | Kill criteria 가동, 다음 프로젝트로 |
| 1인 개발 번아웃 | 중 | 주말 작업으로 한정, 3개월 데드라인 엄수 |

---

## 13. 예산 (개발자 본인 시간 외)

| 항목 | 금액 |
|---|---|
| Apple Developer Program | 연 $99 (한화 약 14만 원) |
| 도메인 (선택) | 연 $12 |
| Tako 캐릭터 일러스트 (외주) | $50~200 (Fiverr / 크몽) |
| 사운드 효과 (라이선스) | $20~50 (Pond5 / Soundsnap) |
| Product Hunt 런칭 | 무료 |
| 랜딩 페이지 (GitHub Pages) | 무료 |
| **합계** | **약 한화 25~40만 원** |

**손익분기 (cosmetic IAP 기준)**:

- 초기 비용 약 30만 원 = 약 $230
- App Store 30% 수수료 차감 후 객단가 $2 가정
- 손익분기 = **약 115회 IAP 구매**
- 다운로드 5,000건 × 전환율 2.3% = 115회. **출시 12개월 내 도달 가능 시나리오**

> 단, 본 프로젝트는 *수익 목적이 아닌 학습 / 포트폴리오 / 자기 사용 도구*. 손익분기 도달은 보너스로 본다.

---

## 14. 다음 액션 (Today / This Week)

- [ ] **오늘**: 검증 체크리스트(섹션 9) 4개 항목 시작
- [ ] **이번 주**: 검증 결과 정리 → 진행/보류/중단 결정
- [ ] **다음 주 (진행 결정 시)**: Xcode 프로젝트 셋업 + DriveManager 프로토타입
- [ ] **2주 후**: 첫 빌드 메뉴바에서 동작 확인

---

## 부록 A: 영감받은 앱 분석 (Reference)

| 앱 | 학습 포인트 |
|---|---|
| RunCat (Kyome) | IAP 콘텐츠 모델, 캐릭터 인터랙션 |
| Maccy (Rodionov) | 오픈소스 + 유료 분리, 단순한 단일 목적 |
| LinearMouse (Lu) | 깨끗한 GitHub README, 무료 정신 |
| Jettison (St. Clair) | 카테고리 정의, 가격 ($9.99 = 천장) |
| Bartender | 메뉴바 앱 UI/UX 표준 |

## 부록 B: 참고 문서
- `DiskOUT_분석.md` — 시장 분석, 냉철한 비판, 페인 포인트 정의
- 기존 코드 베이스 (`AppDelegate.swift`, `SettingsWindowController.swift`)
