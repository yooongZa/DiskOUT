# CHANGELOG

## Unreleased — 배포 노선 결정: Mac App Store 단일

**배경**: 한국 1인 개발자 + 사업자등록 미보유 + 해외 결제 인프라 부재 → Stripe / MoR 식 직접 판매 비현실적. App Store 의 결제·세무 인프라가 가장 합리적. 사용자 신뢰 측면에서도 App Store 라는 울타리가 유리.

### 결정 사항

- **Mac App Store 단일 노선**. Developer ID + GitHub Releases 노선은 폐기. 이중 SKU 운영 부담 (sandbox ON/OFF 두 빌드, 코드 분기) 이 1인 운영에 큼.
- **유료화 모델 확정**: 핵심 기능 전부 무료. 유료 = 캐릭터 애니메이션 / 사운드 등 cosmetic IAP. 출시 후 2~3개월 시점에 IAP 도입.
- **App Sandbox ON 으로 복원**. App Store 가 강제하는 요건. 현재 `EjectDrives.entitlements` = `app-sandbox=true` + `device.usb` + `temporary-exception /Volumes/`.

### 제거된 것

- `Scripts/release.sh` (Developer ID + 노타리 자동화 스크립트) — App Store 노선과 무관.
- `processesUsing()` / `annotateFailure()` 헬퍼 + 4곳 호출 (lsof 점유 프로세스 표기) — sandbox 가 다른 프로세스 fd 들여다보기를 명시적 차단. 우회 불가능. 우리 차별점이었지만 App Store 양립 불가능해 폐기.

### DiskArbitration / IOKit 재작성 — 완료

모든 외부 명령 spawn (`diskutil` / `hdiutil`) 을 framework 직접 호출로 교체. sandbox 안에서 동작.

**새 파일** [DiskArbitrationBackend.swift](DiskArbitrationBackend.swift) (~270줄):

- `unmount(disk:)` — `DADiskUnmount` 동기 wrapper. graceful 만 시도, force 폐기.
- `mount(disk:)` — `DADiskMount` 동기 wrapper.
- `disk(forVolumePath:)` / `disk(forBSDName:)` — DADisk 핸들 생성.
- `description(for:)` / `isVirtualDisk(_:)` — DA description 기반 DMG/sparseimage 식별 (`kDADiskDescriptionDeviceProtocolKey == "Disk Image"`).
- `enumerateExternalWholeDisks()` — IOKit `IOMedia` enumerate, internal=false 만 (`diskutil list -plist external` 대체).
- `childPartitions(ofWholeDisk:)` — IOKit 으로 child partition + APFS synth volume enumerate (`diskutil mountDisk` 의 partition 자동 mount 동작 모방).

**호출 패턴**:
- DA 비동기 callback → `DispatchSemaphore` sync wrapper. `runDiskutil` 과 같은 sync 호출 패턴 유지 → 기존 코드 구조 보존.
- DA session 은 background `DispatchQueue` 에 묶음 (`DASessionSetDispatchQueue`). main thread 에서 호출 시 deadlock 방지 위해 background thread 에서만 호출.
- C function pointer callback ↔ Swift closure 간 결과 전달은 `Unmanaged.passRetained` + `ResultBox` reference type 사용.

**기능 변화**:
- ❌ **force unmount fallback 폐기** — `diskutil unmount force` 동등 동작이 sandbox + non-root 환경에서 거절. graceful 실패 시 사용자에게 *"디스크가 사용 중"* 노출만.
- ❌ **`DADiskEject` 사용 X** — power off 까지 가는 eject 는 sandbox 에서 거절 가능성. unmount 만 사용 (Jettison 도 동일). 사용자 체감엔 차이 없음 (`/Volumes` 에서 사라짐).
- ✅ **DMG/sparseimage/CoreSimulator 식별** — `DeviceProtocol` 키 기반. `hdiutil info` 보다 빠르고 sandbox 호환.
- ✅ **APFS Container child synth volume enumerate** — IORegistry parent chain traversal 로 동작.

**제거된 코드**:
- `runDiskutil()` helper
- `DiskImages.mountedPaths()` (hdiutil 호출)
- `UnmountedExternal.busProtocol(for:)` (diskutil info 호출)
- `UnmountedExternal.firstVolumeName(in:)` (plist 파싱)
- 합 ~120줄 삭감

### 실기 검증 (2026-05-06)

sandbox 활성 + entitlements (USB, /Volumes/, user-selected) 채운 상태에서 외장 USB SSD 로 실제 동작 확인:

| 시나리오 | 결과 | 소요 |
|---|---|---|
| 외장 디스크 추출 (메뉴 클릭) | ✓ success | ~700ms |
| 추출된 디스크가 "마운트 안 된 외장" 섹션 등장 | ✓ 즉시 | — |
| 마운트 클릭 → 다시 마운트 | ✓ success | ~550ms |
| 마운트 후 해당 항목 섹션에서 사라짐 | ✓ 즉시 | — |

이전 `diskutil eject` (1~2초) 보다 추출 속도 더 빠름 — DA framework 가 process spawn overhead 없이 직접 IOKit 호출.

### entitlements 관리 — xcodegen 함정

`project.yml` 의 `entitlements:` 에 `path:` 만 적고 `properties:` 를 안 적으면, xcodegen 이 매 generate 때 entitlements 파일을 빈 dict 로 reset 시킴. **`properties:` 에 권한 키들을 직접 명시** 해야 매번 그 내용으로 보장됨. 본 commit 부터 [project.yml](project.yml) 에 4개 키 모두 명시.

---

## SMAppService 자동 실행 + 다국어 (ko + en) — 추가 (Unreleased)

### SMAppService — 로그인 시 자동 실행 토글

[AppDelegate.swift](AppDelegate.swift) 에 `LoginItem` enum 추가 (`SleepEject` 옆 패턴). 메뉴에 "로그인 시 자동 실행" 토글 노출.

- macOS 13+ `SMAppService.mainApp` 사용. 시스템 설정 → 일반 → 로그인 항목 에 자동 등록.
- `status == .requiresApproval` 케이스 (사용자가 시스템 설정에서 허용 안 한 상태) 처리:
  - 토글 상태에 따라 toolTip 으로 *"시스템 설정에서 허용 필요"* 안내
  - register 직후 status 가 requiresApproval 이면 알림 + `SMAppService.openSystemSettingsLoginItems()` 로 시스템 설정 자동 오픈
- **이전 README 의 수동 안내 폐기** — 사용자가 `~/Applications/EjectDrives.app` 을 직접 시스템 설정에 추가하던 절차 → 메뉴 토글 한 번으로 끝.

### 다국어 — `Localizable.xcstrings` (Xcode 15+ String Catalog)

신규 파일 [Localizable.xcstrings](Localizable.xcstrings) — 36개 사용자 텍스트의 영어 source + 한국어 번역. 메뉴 / 알림 / 토글 / tooltip 모든 표면.

- **Source 언어 영어** (`developmentLanguage: en` + `CFBundleDevelopmentRegion: en`)
- **지원 언어**: en, ko (`CFBundleLocalizations`)
- **API**: `String(localized: "...")` + string interpolation (`"Couldn't eject \(name)"`)
- **영어 톤**: 미니멀. *"Eject all"* / *"Mounted"* / *"Couldn't eject %@"* — 메뉴바 너비 의식.
- **한국어 톤**: 기존 어투 보존. *"모두 추출"* / *"마운트 완료"* / *"추출 실패: %@"*

빌드 결과:
- `EjectDrives.app/Contents/Resources/{en,ko}.lproj/Localizable.strings` 자동 컴파일
- `Info.plist` 의 `CFBundleLocalizations = [en, ko]` 박힘
- 시스템 언어 한국어/영어 자동 전환 (사용자가 시스템 설정 → 언어 및 지역 변경 시)

### 코드 변화

- 사용자에게 보이는 모든 텍스트 35+개를 `String(localized: ...)` 로 치환
- 로그 출력의 fallback 문자열 ("알 수 없는 오류") 도 일관성 위해 영어 ("unknown") 로 통일 (사용자엔 노출 안 됨)
- `LoginItem` enum + `toggleLoginItem(_:)` 메서드 추가 (~50줄)

### 알려진 제약 / 다음 작업

- **단축키 기호 `⌥⌘E` / `⌃⌘E`** — 메뉴 라벨에 그대로 노출. macOS 시스템 표기와 일치.
- **App Store 메타데이터 다국어화** — App Store Connect 의 앱 이름 / 부제 / 설명 / 키워드 / 스크린샷 ko/en 따로 입력 필요. 출시 직전 작업.
- **추가 언어 (일본어 / 중국어 등)** — `Localizable.xcstrings` 에 새 lang key 추가 + `CFBundleLocalizations` 갱신만으로 가능. v1.1+ 검토.

### 유지된 것 (배포 노선과 무관, 그대로 유효)

- `project.yml` 의 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 변수화 — App Store 빌드에도 동일하게 유용.
- `Info.plist` 가 `$(MARKETING_VERSION)` 참조하는 구조.

---

## v0.4.0 — 2026-05-06

**마운트 안 된 외장 디스크 mount 기능 추가.** 경쟁사 (Jettison, MountMate) 둘 다 가진 기능 중 우리만 빠져있던 마지막 갭. 추출 / 마운트가 한 쌍의 자연스러운 동작으로 완성.

---

### 한 줄 요약

> "꽂혀있는데 마운트 안 된 외장도 메뉴에서 한 번에 마운트 — `⌘+클릭` 으로 Finder 까지 자동."

---

### 배경 — 경쟁사 비교

| 앱 | 마운트 안 된 외장 표시 | 개별 mount | 일괄 mount | 추가 |
|---|---|---|---|---|
| **Jettison** ($6.95) | ✓ | ✓ | ✓ | ⌘+클릭 = "Mount and Open" — Finder 열기까지 |
| **MountMate** (무료, OSS) | ✓ | ✓ | (불명) | 단축키 `⌘⇧M` / `⌘⇧U` |
| Ejectify (€6.99, OSS) | ✗ | ✗ | ✗ | 자동 unmount + auto remount on wake 만 |
| EjectBar (무료) | ✗ | ✗ | ✗ | 추출 위주 |
| **EjectDrives v0.3.0** | ✗ | ✗ | ✗ | 우리만 빠져있던 갭 |

→ Jettison 패턴 (별도 MOUNT 섹션 + ⌘+클릭 Finder) 채택.

---

### 추가된 기능

| # | 기능 | 동작 |
|---|---|---|
| 1 | **마운트 안 된 외장 자동 감지** | `diskutil list -plist external` 파싱 + `ExternalDrive.list()` 의 마운트된 외장 BSD 와 비교. 차집합이 후보 |
| 2 | **메뉴 MOUNT 섹션 자동 노출** | 후보 있을 때만 표시. "마운트 안 된 외장" 헤더 + 디스크 별 항목 |
| 3 | **개별 마운트** | 메뉴 항목 클릭 → `diskutil mountDisk <bsd>` |
| 4 | **⌘+클릭 = 마운트 + Finder 열기** | Jettison 의 "Mount and Open" 동등. mount path (`/Volumes/<displayName>`) 가 존재하면 Finder 로 open |
| 5 | **일괄 마운트 — ⌃⌘E 단축키** | 후보 2개 이상이면 메뉴에 "모두 마운트 (⌃⌘E)" 항목. 단축키는 항상 동작 (후보 없으면 *"마운트할 외장 없음"* 알림) |
| 6 | **시스템 partition / DMG 자동 제외** | 두 단계 필터: (1) `Content` 가 EFI/Microsoft Reserved/Apple_Boot/Apple_KernelCoreDump/Recovery 이면 skip (2) `BusProtocol == "Disk Image"` (Xcode CoreSimulator 등) skip |
| 7 | **결과 알림** | 일괄 마운트 성공: banner 만. 실패: banner + 알림 센터 보관 (negative event 매트릭스 일관성) |

---

### 단축키 매핑

| 단축키 | 동작 |
|---|---|
| `⌥⌘E` | 모든 외장 **추출** (v0.1.0 부터) |
| `⌃⌘E` (신규) | 마운트 안 된 외장 **일괄 마운트** |

같은 `E` 키 + 다른 modifier — 외우기 쉬운 대칭. `⌘⌥W` 가 시스템 "Close All Windows" 와 충돌 위험이 있어 `⌃⌘E` 채택.

---

### 동작 변경 (v0.3.0 → v0.4.0)

| 항목 | v0.3.0 | v0.4.0 |
|---|---|---|
| 메뉴 항목 | 추출만 | 추출 + (조건부) 마운트 섹션 |
| 전역 단축키 | `⌥⌘E` 만 | `⌥⌘E` + `⌃⌘E` |
| `UnmountedExternal` struct | 없음 | 추가 (~80줄) |
| `UnmountedExternal.busProtocol(for:)` 추가 호출 | 없음 | 후보 별 ~30ms (메뉴 열 때) |

---

### 발생했던 이슈와 해결

#### 1. CoreSimulator DMG 가 unmounted 후보로 잡힘

**증상**: `disk6: "WatchOS 26.4 Simulator"`, `disk8: "iOS 26.4.1 Simulator"` 가 *마운트 안 된 외장* 으로 분류됨.
**원인**: `ExternalDrive.list()` 의 DMG 필터는 hdiutil 의 *마운트된* DMG 에만 적용. Unmounted 후보 검출엔 hdiutil 정보가 없음.
**해결**: 후보 별 `diskutil info -plist <bsd>` 추가 호출 → `BusProtocol == "Disk Image"` 이면 skip. CoreSim / DMG / sparseimage 모두 차단.

#### 2. EFI partition 만 있는 RAID 멤버 디스크

**증상**: `disk9`, `disk10` 의 VolumeName 이 *"EFI"* 로 잡혀 mount 후보로 노출 위험.
**원인**: APFS RAID 멤버 디스크는 보통 `[EFI partition, RAID member]` 구조. RAID member partition 은 VolumeName 없고, EFI 만 VolumeName 가짐.
**해결**: `firstVolumeName(in:)` 에서 `Content` 가 `["EFI", "Microsoft Reserved", "Apple_Boot", "Apple_KernelCoreDump", "Recovery"]` 인 partition 은 skip. → 결과적으로 RAID 멤버 디스크가 자동으로 후보에서 제외 (사용자 데이터 partition 없음).

#### 3. 단축키 `⌘⌥W` vs `⌃⌘E` 결정

처음 사용자가 `⌘⌥W` 제안. 검토 결과:
- macOS 표준 "Close All Windows" 와 충돌 (Finder, Safari, Mail, Pages 등)
- 우리 코드 `NSEvent.addGlobalMonitorForEvents` 는 이벤트 *소비 안 함* — 충돌이 아니라 **공동 발화**. 시스템상 동작은 OK.
- 단 사용자 경험상 짜증 (Safari 작업 중 실수로 누르면 윈도우 다 닫힘 + mount 시도)

대안 비교:
- `⌘⌥M` — "Minimize All Windows" 와 동일 충돌
- `⌘⌥⇧E` — 의미 매칭 좋지만 4-키
- **`⌃⌘E`** — 자유롭고 추출 단축키와 같은 키 (E)

→ `⌃⌘E` 채택. "E 키는 외장 디스크 — modifier 가 동작 결정" 일관성.

---

### 메뉴 UI

```
🟢 연결된 외장 (마운트됨)
  📦 SYSJO
  📦 SSD_W
─────
모두 추출  (⌥⌘E · 또는 메뉴바 우클릭)
─────  마운트 안 된 외장  ─────  ← 후보 있을 때만 노출
  ⊕ Backup_HDD          [클릭 = 마운트.  ⌘+클릭 = 마운트 + Finder 열기]
  ⊕ ARCHIVE
  모두 마운트  (⌃⌘E)            ← 후보 2개 이상일 때만
─────
잠자기 시 자동 추출 ✓
화면 꺼질 때도 자동 추출 (실험)
종료
```

---

### 코드 라인 변화

| 파일 | v0.3.0 | v0.4.0 | 변화 |
|---|---|---|---|
| `AppDelegate.swift` | ~860줄 | ~1095줄 | **+235줄** (UnmountedExternal struct, mountOne / mountAll / mountAllAction / notifyMountResult, 단축키 분기 확장, 메뉴 섹션) |

---

### 알려진 갭 (v0.5.0 검토)

- **mount path 정확도**: 현재는 `/Volumes/<displayName>` 추측. macOS 가 `(2)` suffix 붙이는 케이스 등에선 Finder 열기 silent fail. `diskutil mountDisk` 의 stdout 파싱하면 정확히 알 수 있음.
- **APFS encrypted volume 비밀번호**: macOS 가 GUI prompt 자동 띄우지만 우리 알림과 race 가능. 검증 필요.
- **mount 진행 상태 아이콘**: 현재 0.6s 짧은 flash 만. 일괄 마운트가 길어지면 (2~3 디스크) 진행 표시 약함.

---

## v0.3.0 — 2026-05-05

**화면 꺼짐 시 자동 추출 (display sleep eject) 추가.** `pmset sleep = 0` 환경의 도킹 분리 사고 보호. Jettison 1.9.1 의 동등 기능.

---

### 한 줄 요약

> "자동 sleep 끈 환경 (`pmset sleep = 0`) 에서도 화면 꺼지면 외장 추출 + 화면 켜지면 재마운트."

---

### 배경 — 왜 필요했나

v0.2.x 까지는 **system sleep** 만 처리. 그런데 다음 환경에서 갭:

- `pmset -g` 의 `sleep = 0` (자동 system sleep 비활성)
- 데스크탑 / 외장 모니터 + Mac mini / 백그라운드 작업 돌리는 환경에서 흔함
- 화면이 꺼져도 (display sleep) 시스템은 awake → EjectDrives 동작 X
- 그 상태에서 도킹/외장 분리 = ungraceful disconnect (`danglingVolumeList` 등록, "Disk Not Ejected Properly" 알림)

실제 사고 사례: 2026-05-05 22:40 — 사용자가 "화면 꺼짐 = sleep" 으로 오인하고 도킹 분리. SYSJO/SSD_W 두 디스크 강제 unmount.

Jettison 도 이 갭을 인지해 1.9.1 (2025-04) 에 동등 기능 추가. 우리도 따라잡음.

---

### 추가된 기능

| # | 기능 | 동작 |
|---|---|---|
| 1 | **화면 꺼짐 시 자동 추출** | `NSWorkspace.screensDidSleepNotification` 옵저버. 화면 꺼지는 즉시 외장 추출 + BSD 기록 |
| 2 | **화면 켜질 때 재마운트** | `screensDidWakeNotification` 옵저버. 2초 대기 후 `[0,1,3,7]s` 백오프 |
| 3 | **메뉴 토글 신설** | "화면 꺼질 때도 자동 추출 (실험)" — 기존 sleep 토글과 별개 |
| 4 | **중복 추출 가드** | `autoEjectedDisks` 가드로 system sleep + display sleep 양쪽 trigger 시 중복 호출 방지 (idempotent) |
| 5 | **추출 실패 시 알림** | "화면 꺼짐 시 N개 디스크 추출 실패" — banner + 알림 센터 보관 (v0.2.1 의 archived 정책 준수) |

---

### 동작 변경

| 항목 | v0.2.1 | v0.3.0 |
|---|---|---|
| sleep eject trigger | system sleep only | system sleep + (옵션) display sleep |
| display sleep 시 보호 | ✗ | ✓ (토글 ON 시) |
| 메뉴 토글 | 1개 | 2개 |
| UserDefaults key | `ejectOnSleep` | + `ejectOnDisplaySleep` (default: false) |
| 옵저버 | 2개 (will/didSleep) | 4개 (+ screensDid Sleep/Wake) |

---

### 트레이드오프 (사용자에게 솔직)

display sleep eject 는 강력하지만 **default = false**. 이유:

- ⚠️ **빈번한 발동**: 자리 5분 비우면 화면 꺼짐 → 추출. 돌아와서 마우스 흔들면 재마운트. 잦으면 disk wear / 사용 흐름 끊김
- ⚠️ **영상 재생 / 작업 중**: 외장 SSD 의 영상 보다 화면 sleep 만 발동되는 케이스 (예: 음악 재생 중 디스플레이만 sleep) 에서 추출 시도 → graceful 거부 → force unmount → 작업 끊김
- ⚠️ **macOS 가 화면 sleep 직전 알림 못함**: Jettison 측도 명시 — display 가 *꺼진 후* 노티 받음. 추출 시작 시점에 0~3초의 mount 상태 존재

→ 명시적으로 opt-in 필요한 사용자만 (특히 `pmset sleep = 0` 환경) 켜는 게 맞음.

---

### 검증 시나리오

| 환경 | sleep 토글 | display 토글 | 동작 |
|---|---|---|---|
| 노트북 + 자동 sleep ON | ON | OFF | system sleep 시 추출 (v0.2.x 동일) |
| 데스크탑 + `sleep=0` | ON | **ON** | 화면 꺼지는 즉시 추출 → wake 시 재마운트 |
| 양쪽 모두 OFF | OFF | OFF | 자동 추출 없음 (수동만) |
| 양쪽 모두 ON, system sleep 진입 | ON | ON | display sleep 먼저 발화 → 추출 → system sleep 발화 시 `autoEjectedDisks` 가드로 skip (no double-eject) |

---

### 알려진 갭 (v0.4.0 검토)

- **Pre-eject delay**: 화면 꺼진 후 30초~5분 동안 추출 보류 → 그 사이 wake 되면 cancel. 빠르게 돌아오는 사용자 보호 (현 시점 즉시 추출)
- **추출 제외 화이트리스트**: Time Machine 디스크 / 항상 mount 유지하고 싶은 외장 등 사용자 지정 ignore
- **재마운트 성공 알림 옵션**: 사용자가 추출/재마운트 사이클을 인지하기 위한 한 줄 banner

---

### 설치 / 검증 기록

- **2026-05-05 23:05** — 안전 설치 절차로 교체 완료
  - 기존 v0.2.0 (PID 67951) 종료 → `~/Applications/EjectDrives.app.v0.2.0.bak` 백업
  - DerivedData 의 Debug 빌드 (`23:02` 산출물) 를 `~/Applications/` 로 복사 + `xattr -cr` 로 provenance 정리
  - 새 PID 63837 으로 정상 실행, `globalKeyMonitor REGISTERED` / `Accessibility trusted = true` 확인
- **검증 환경** — macOS 26.4.1 (Apple Silicon), `pmset sleep = 0`, `displaysleep = 20` 분
- **알림 권한** — 여전히 denied (`authStatus=1`). 알림 매트릭스 검증 원하면 시스템 설정 → 알림 → EjectDrives 켜야 함
- **롤백 절차** — README "안전 설치" 섹션 참조

---

## v0.2.1 — 2026-05-05

**버그 fix + 알림 정책 정비.** 빠른 추출에서 결과 아이콘이 사라지던 race 수정. 알림을 importance 별로 banner-only / 알림 센터 보관 분리. Sleep 추출 실패 알림 신설.

---

### 한 줄 요약

> "결과 아이콘은 안 사라지고, 중요한 알림만 알림 센터에 남는다."

---

### 수정 / 변경

| 항목 | 변경 |
|---|---|
| **결과 아이콘 race fix** | `flashIcon` 의 1초 지연 reset 이 그 사이 `setPersistentIcon` 으로 표시된 ✓/⚠️/✗ 결과 아이콘을 default ⏏ 로 덮어쓰던 race 수정. generation 토큰 도입. SSD 등 빠른 추출에서 결과 아이콘이 항상 안정 표시됨. |
| **알림 정책 — banner vs 알림 센터** | importance 별 분리. 사후 확인 가치 있는 negative event 만 알림 센터 (`.list`) 에 보관. `notify(archived:)` 인자 + `willPresent` 콜백 분기로 구현. |
| **Sleep 추출 실패 알림 신설** | unmount 안 된 채 sleep 진입 케이스 명시적 알림 (banner + 알림 센터). 이전엔 silent 라 사용자 부재 중 발생 시 인지 불가. dock 분리 시 file system 손상 위험을 사후에라도 인지 가능. |

---

### 알림 매트릭스

| 케이스 | banner | 알림 센터 |
|---|---|---|
| 단일 추출 — 성공 | ✓ | ✗ |
| 단일 추출 — 실패 | ✓ | ✓ |
| 모두 추출 — 전체 성공 | ✓ | ✗ |
| 모두 추출 — 일부/전체 실패 | ✓ | ✓ |
| 모두 추출 — 디스크 없음 | ✓ | ✗ |
| Sleep 추출 — 전체 성공 | ✗ | ✗ |
| **Sleep 추출 — 실패 있음** | **✓ (신규)** | **✓ (신규)** |
| Wake 재마운트 — 모두 OK | ✗ | ✗ |
| Wake 재마운트 — mount 실패 | ✓ | ✓ |

원칙: 본인 trigger + positive 결과는 결과 아이콘으로 충분 → banner 만. 부재 중 또는 negative 결과 → 알림 센터에 보관해 사후 확인 가능.

---

### 문서

- README "다른 깨알 정보" 에 `runDiskutil` stdout drain 잠재 hang 위험 메모 추가 (현 시점 발생 확률 낮음, 코드 수정 보류).

---

## v0.2.0 — 2026-05-05

**경쟁사 갭 메우기 + 데스크탑 맥 지원.** 두 가지 시급한 코어 갭(DMG 필터링 부재, wake 후 재마운트 부재) 을 메우고, 자동 추출을 lid-close 한정에서 *모든 sleep* 으로 일반화.

---

### 한 줄 요약

> "잠자기 들어가면 추출하고, 깨어나면 알아서 다시 마운트한다 — 노트북·데스크탑 동일."

---

### 추가된 기능

| # | 기능 | 동작 |
|---|---|---|
| 1 | **DMG / sparseimage 필터** | `hdiutil info -plist` 파싱해 마운트된 가상 디스크 식별. 메뉴 / 자동 추출 대상에서 제외. Chrome.dmg 같은 마운트가 잠자기 시 같이 빠지는 사고 방지 |
| 2 | **잠자기 진입 시 자동 추출 (일반화)** | 노트북 lid close 한정 → **모든 sleep** 에서 동작. 데스크탑 맥(Mac mini, iMac, Studio) 도 자동 추출 ✓ |
| 3 | **wake 후 자동 재마운트** | 자동 추출된 디스크(BSD name) 만 wake 후 `diskutil mountDisk` 로 재마운트. `[0, 1, 3, 7]s` 백오프 |
| 4 | **사용자 분리 의도 감지** | 각 재시도 직전 `diskutil info <bsd>` 로 enumerate 여부 확인. 한 번도 enumerate 안 되면 사용자가 케이블 분리한 것으로 간주, **silent**. mount 만 실패하면 알림 (FS 손상 가능) |
| 5 | 수동 추출은 재마운트 안 함 | 단축키 / 메뉴 / 개별 클릭 추출 → BSD 기록 안 함 → wake 후 재마운트 대상 X. **자동은 자동 회복, 수동은 사용자 책임** |

---

### 동작 변경 (v0.1.0 → v0.2.0)

| 항목 | v0.1.0 | v0.2.0 |
|---|---|---|
| 자동 추출 trigger | lid close 한정 (`AppleClamshellState`) | **모든 sleep** |
| 데스크탑 맥 | 자동 추출 안 함 | 자동 추출 ✓ |
| 메뉴→잠자기 / 시간 자동 sleep | 추출 안 함 | 추출 ✓ |
| Wake 후 재마운트 | ✗ | ✓ |
| DMG / sparseimage 필터 | ✗ | ✓ |
| `IOKit` import / `isLidClosed()` 함수 | 사용됨 | **제거** (dead code) |
| 메뉴 토글 텍스트 | "뚜껑 닫을 때 자동 추출" | "잠자기 시 자동 추출" |
| UserDefaults key | `ejectOnLidClose` | `ejectOnSleep` (자동 마이그레이션) |

---

### 디자인 결정 — 왜 lid-close 한정에서 일반화로?

v0.1.0 의 lid-close 한정 추출은 **시나리오 3번 보호** 가 목적이었음:
- 사용자가 시간 지나 자동 sleep 들어갔다가 자리 돌아옴 → 외장하드 사라지면 짜증

v0.2.0 에서는 **wake 후 자동 재마운트 로직** 이 추가되어 이 비용이 사라짐 (1~2초 재마운트 지연으로 대체). 그러면서 시나리오 4번 (slipt 상태에서 외장하드만 뽑아 감 — 데스크탑 맥의 표준 use case) 까지 자동으로 커버.

| 시나리오 | v0.1.0 동작 | v0.2.0 동작 |
|---|---|---|
| 1. 뚜껑 닫음 → 분리 (이동) | 자동 추출 ✓ | 동일 |
| 2. 뚜껑 닫음 → 그대로 → 작업 재개 | 자동 추출 ✓ but 재마운트 ✗ | 자동 추출 ✓ + 자동 재마운트 ✓ |
| 3. sleep → 작업 재개 | 추출 X (의도) | 추출 ✓ + 자동 재마운트 ✓ (사용자 무감각) |
| 4. 데스크탑 sleep → 외장하드만 분리 | 추출 X (불가능) | 추출 ✓ |

---

### 발생했던 이슈와 해결

#### 1. DMG 필터 — `hdiutil info` 의 mount-point 추출

DiskArbitration framework 호출도 가능하지만 `hdiutil info -plist` 의 system-entities → mount-point 가 더 단순. 50 ms 호출, 메뉴 열 때마다 호출되어도 OK.

검증: 현재 환경에 Xcode CoreSimulator 의 watchOS / iOS 시뮬레이터 디스크 두 개가 마운트되어 있음. 이전엔 외장으로 잘못 분류될 가능성, 이제 차단.

#### 2. BSD name 추출 — `statfs` 의 `f_mntfromname` 파싱

`/Volumes/SYSJO` → statfs → `/dev/disk12s1` → 정규식 `^disk\d+` → `disk12` (whole disk).

`diskutil mountDisk disk12` 로 해당 disk 의 모든 partition 한 번에 mount.

#### 3. 사용자 분리 의도 감지 — `diskutil info` exit code

각 백오프 시도 직전:
- `diskutil info disk12` → exit 0 → 디스크 USB 재인식됨 → mount 시도
- `diskutil info disk12` → exit 1 → 시스템에 없음 → 다음 시도 (재인식 대기)

4회 시도 (0, 1, 3, 7s) 동안 한 번도 enumerate 안 되면 **사용자가 분리한 것으로 간주** → 알림 X.

이전 설계에서는 4회 시도 후 무조건 *"USB 케이블 다시 꽂아주세요"* 알림 → 사용자가 의도적으로 분리했는데 알림 뜨면 짜증. 정정.

#### 4. UserDefaults key 마이그레이션

```swift
if let v = d.object(forKey: "ejectOnSleep") as? Bool { return v }
if let legacy = d.object(forKey: "ejectOnLidClose") as? Bool {
    d.set(legacy, forKey: "ejectOnSleep")
    d.removeObject(forKey: "ejectOnLidClose")
    return legacy
}
return true
```

v0.1.0 에서 토글 끈 적 있는 사용자도 그 상태 그대로 승계. 첫 실행 시 한 번만 마이그레이션.

---

### 코드 라인 변화

| 파일 | v0.1.0 | v0.2.0 | 변화 |
|---|---|---|---|
| `AppDelegate.swift` | ~580줄 | ~700줄 | **+120줄** (DMG filter, BSD helper, remount logic) / `isLidClosed` 35줄 제거 |
| `import IOKit` | 사용 | 제거 | dead code |
| `import Darwin` | — | 추가 | `statfs` 호출 |

---

### 알려진 갭 (v0.3.0 검토)

- **사용 중 프로세스 표기**: 추출 실패 시 `lsof +D /Volumes/X` 로 어떤 앱이 잡고 있는지 표시. "Photoshop이 IMG_1234.psd 사용 중" 같은 사용자 친화적 메시지.
- **재마운트 신뢰도 향상**: `diskutil eject` 대신 DiskArbitration framework 의 `DARegisterDiskMountApprovalCallback` 으로 자동 mount 차단 + 명시적 mount 제어. 현재는 `diskutil` 의존이라 USB-C 재인식 들쭉날쭉을 못 피함.
- **재마운트 후 결과 알림**: 현재는 실패 시에만 알림. 성공 시에도 "재마운트: SYSJO, SSD_W ✓" 한 줄 banner 가 사용자 안심에 도움 가능. (단, 스팸 위험)

---

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
