# CHANGELOG

## Unreleased — 2026-05-14: 메뉴바 아이콘에 마운트된 외장 개수 표시

**배경**: 메뉴바 아이콘이 고정 ⏏ 심볼이라 현재 상태를 알 수 없었다. 연결된 외장 개수에 따라 아이콘이 바뀌길 원함 — **1차로 숫자 표시**부터 구현 (후속 비주얼은 별도 검토).

### 변경 ([AppDelegate.swift](AppDelegate.swift))

#### 1. 고정 ⏏ → 마운트된 외장 "디바이스" 개수 숫자

- `cachedDefaultIcon` (eject.fill 템플릿 이미지) 제거. 메뉴바 버튼을 `button.image` 대신 `button.title` (텍스트) 로 표시 — `applyCountTitle()` 신설.
- 처음엔 `<n>.circle.fill` SF Symbol 로 구현했으나 Apple 이 0~50 까지만 제공 → **텍스트 title 로 전환**해 상한 제거 (임의 수 표시 가능, `variableLength` 라 폭 자동 조정).
- 추출 중 회전 화살표·결과 ✓/✗ 같은 임시 심볼 (`flashIcon` / `setPersistentIcon`) 은 그대로 우선. 심볼 표시 시 `button.title = ""` 로 비워 "⏏3" 겹침 방지, 임시 심볼이 끝나면 `applyCountTitle()` 로 숫자 복귀.

#### 2. 카운트 단위 — 물리 디스크 (whole-disk BSD)

- `mountedExternalDeviceCount(drives:)` — `ExternalDrive.wholeDiskBSDName` 으로 집계. 한 디스크에 파티션이 여러 개 마운트돼 있어도 1개. RAID / APFS 합성 볼륨은 합성 컨테이너의 whole-disk 로 잡혀 자연스럽게 1개.
- 예: 8TB RAID 박스 (disk6 + disk7 → RAID disk8 → APFS disk13 = "SYSJO" 볼륨) 는 박스 1개 = 1 로 카운트 → "꽂은 물리 장치 수" 와 일치.

#### 3. 자가 보정 트리거 — `DAInventory.onInventoryChanged` 훅 신설

- 초기 구현은 mount/unmount 노티 + 고정 딜레이 후 **단발 샘플링** → RAID 볼륨처럼 느리게 마운트되는 디스크가 샘플링 시점에 아직 인벤토리에 없으면 카운트가 낮게 나오고 그대로 멈추는 레이스 발생 (실제 4 개인데 3 표시).
- `DAInventory` 가 디스크 appeared / disappeared / mount 경로 변경 시마다 `onInventoryChanged` 콜백 발화 — mount 상태 변화에만 (count 무관한 description 변경 제외). consumer 가 받아 카운트 재계산 → 느린 디스크가 늦게 떠도 **자동 보정**.
- `applicationDidFinishLaunching` 에서 `DAInventory.start()` **이전에** 훅을 걸어 초기 enumeration 이벤트 (기존 디스크들) 도 빠짐없이 수신.

#### 4. 갱신 경로 / 주기

- `refreshMountedDriveCountIcon` 이 `DAInventory.shared.snapshot()` 을 직접 조회 — DA 콜백 직후 호출되므로 변경분이 이미 반영돼 있다. DA 미준비 (cold start) 시에만 `DiskMenuSnapshotCache` (diskutil 폴백) 경유.
- `scheduleMountedDriveCountRefresh` 0.3s debounce — RAID 조립·다중 파티션 등 연쇄 이벤트를 마지막 기준 1 회로 합침.
- 트리거: **DA 인벤토리 변경 (주 경로)** + NSWorkspace mount/unmount 노티 + launch (0.7s) + wake (1.0s). 주기적 폴링 없음 — 순수 이벤트 기반.
- 결과 아이콘 (`setPersistentIcon`) 표시 중에는 카운트만 저장하고 숫자는 안 덮어씀 — `resetIcon` 시점에 최신 카운트로 복귀.

### 검증

| 항목 | 결과 |
|---|---|
| `xcodebuild -project DiskOUT.xcodeproj -scheme DiskOUT -configuration Debug build` | BUILD SUCCEEDED (경고 0) |
| 실사용 — 외장 4 개 환경 (USB SSD 3 + 8TB RAID 박스 1) | 디바이스 4 개로 정확히 집계. RAID 박스의 "SYSJO" 볼륨이 disk6 + disk7 → 합성 disk13 으로 1 개 처리 확인 |
| 레이스 재현 / 수정 검증 | 수정 전: RAID 볼륨이 늦게 마운트 → **3 에서 멈춤**. `onInventoryChanged` 훅 추가 후: 늦게 떠도 3 → 4 자가 보정 |
| 메뉴바 픽셀 육안 확인 | ⚠️ 자동 확인 미완 — `screencapture` 화면 녹화 권한 없음 + DiskOUT 이 `LSUIElement` 라 computer-use 타겟 불가 + `log show` 출력 없음. 사용자 육안 확인으로 대체 (숫자 표시 + 카운트 값 정상) |

## Unreleased — 2026-05-14: DA 이벤트 기반 인벤토리 + sleep eject OS race-skip

**배경**: 사용자 보고 — SD 카드 삽입 직후 (07:02) 외장하드 메뉴가 깨지고 sleep eject 가 모두 실패. 로그 분석 결과 두 가지 독립 원인:

1. `DiskMenuSnapshot.load()` 가 `diskutil list -plist external` shellout 에 의존 → SD 인덱싱으로 macOS `storagekitd` (시스템 싱글톤 daemon) 가 새 디스크 프로빙으로 바쁘면 우리 호출이 3s timeout. 앱이 스레드 100개로 던져도 OS 안에서 직렬화 — 앱 차원에선 회피 불가.
2. `diskutilEjectForSleep` 가 `systemWillSleep` 받자마자 force unmount 시퀀스 (Step A→B→C→D→E, 최대 19s) 진입. 동시에 macOS sleep 시퀀스도 unmount 시도 → 같은 락 두고 경쟁 → 1~6s 헛수고 후 "Failed to find disk" (이미 OS 가 unmount 했음).

### 변경

#### 1. DA-event-driven `DAInventory` 신설 ([AppDelegate.swift](AppDelegate.swift))

- `DARegisterDiskAppearedCallback` / `DiskDisappearedCallback` / `DiskDescriptionChangedCallback` 등록한 long-lived `DASession` 으로 외장 디스크 인벤토리를 in-process 메모리에 유지.
- `DAInventory.shared.start()` — `applicationDidFinishLaunching` 에서 1회 호출. DA 가 등록 직후 모든 기존 디스크에 대해 appeared 이벤트 즉시 dispatch → 0.5s 후 `ready`.
- `snapshot()` — wholeDisk BSD 별 그룹핑으로 mounted `[ExternalDrive]` + unmounted `[UnmountedExternal]` 반환. 기존 diskutil 경로와 동일한 필터 (internal 제외 / `Disk Image` · `Virtual Interface` 프로토콜 제외 / EFI · Recovery · Apple_Boot 같은 system content 제외 / CoreSimulator 경로 제외).
- `isVolumePresent(at:)` — sleep eject race-skip 용. ready 전엔 `true` (불확실 → 진행), ready 후 mount 사라졌으면 `false`.

#### 2. `DiskMenuSnapshot.load()` 우선순위 재구성

```
1) DAInventory.shared.snapshot()  ← in-process, 외부 daemon 비의존, SD 인덱싱과 무관
2) diskutil list -plist external   ← DA 인벤토리 미준비 (cold start 0.5s) 시 fallback
3) FileManager.mountedVolumeURLs   ← diskutil 도 timeout 시 최후 fallback
```

→ 평상시 모든 메뉴 갱신은 (1) 에서 즉시 처리. SD 카드 삽입 직후에도 `storagekitd` 와 무관하게 메뉴 정상.

#### 3. `diskutilEjectForSleep` 에 OS race-skip 체크 5곳 삽입

각 fallback 단계 직전 + Step A 진입 직전에 `DAInventory.shared.isVolumePresent(at: volumePath)` 확인. 다른 흐름 (macOS sleep 자체 unmount, `kDADiskUnmountOptionWhole` 의 sibling unmount, 사용자 수동 추출) 으로 이 volume 이 이미 사라졌으면 즉시 `(true, nil)` 리턴 — 1~6s 헛수고 + "Failed to find disk" 에러 회피.

#### 4. `ExternalDrive.isTimeMachineDisk` 가시성 변경

`private static` → `fileprivate static` — `DAInventory.snapshot()` 에서 호출 가능하도록.

### 검증

| 항목 | 결과 |
|---|---|
| `xcodebuild -project DiskOUT.xcodeproj -scheme DiskOUT -configuration Debug build` | BUILD SUCCEEDED |
| 새 빌드 launch (PID 96463) → DAInventory 초기화 | `DAInventory: started` → 0.55s 후 `DAInventory: ready disks=41 mounted=12` |
| 첫 displaySleep 사이클 (11:41:47, disk13/disk4 병렬) — race-skip 작동 검증 | ✅ **`success=2 failure=0`** (이전 빌드 동일 시나리오: `success=0 failure=2`) |
| → Step A (DA normal, 2.0s) timeout → Step B (DA force, 3.0s) timeout → Step C (`diskutil unmountDisk force`, 6.0s) timeout → race-skip 발동 | `displaySleep volume gone after Step C — treat as success (OS unmounted concurrently)` |
| Wake 후 remount (11:42:07) | **0.73s** (이전 빌드 16.85s 대비 23배 빠름 — DA 인벤토리가 wake 직후 디스크 상태 즉시 알아 `diskutil list` 미호출) |

### 추가 관찰 — 향후 최적화 여지 (이번 PR 범위 밖)

위 11:41:47 사이클에서 Step C 가 6초 통째로 헛돔이 보였다. macOS sleep 시퀀스의 자체 unmount 가 약 5-6초 안에 끝나는데 우리 코드는 그 사이 force 시퀀스를 돌리며 락 경쟁. 두 옵션:

- **(A)** `systemWillSleep` 직후 300-500ms 의도적 delay → OS 에 unmount 기회 양보 후 시작
- **(B)** 각 step 진행 중 DA `disappeared` 이벤트 도착하면 진행 중인 unmount 즉시 cancel + return success

지금 fix 만으로도 사용자 보고 사건의 핵심 (`success=0 failure=2` + "비정상 추출" 알림) 은 해결. 추가 최적화는 별도 사이클 누적 후 결정.

### 영향 / 향후

- `hdiutil info` (DiskImages.mountedPathsOrNil) 호출은 fallback 경로에 그대로 — DA 가 `DABusProtocol == "Disk Image"` 로 1차 필터하므로 평상시엔 호출 안 됨.
- `DiskMenuSnapshotCache.warm()` 의 cache 5s TTL 는 그대로 — DA snapshot 도 같은 TTL 사용 (불필요한 매 메뉴 오픈마다 DA 재집계 회피).
- 차후 정리: `ExternalDrive.list()` / `ExternalDrive.listFromMountedVolumes()` 도 DA 우선 경로로 통일 가능 (현재는 DiskMenuSnapshot 만 변경).

---

## Unreleased — 2026-05-14: 앱 이름 EjectDrives → DiskOUT 으로 변경

**배경**: 브랜딩 단순화 + 검색성. "EjectDrives" 는 동작 설명 그대로라 검색 노이즈가 크고, "DiskOUT" 이 짧고 외우기 쉬워 메뉴바 앱 정체성에 더 적합.

### 변경 영역 (사용자 노출 + Xcode 프로젝트)

- **Info.plist**: `CFBundleName`, `CFBundleDisplayName`, `NSHumanReadableCopyright` → `DiskOUT`. 메뉴바 앱 이름 / Finder 표시 이름 / About 탭 카피라이트 한꺼번에 갱신.
- **About 탭 / Quit 메뉴 / accessibilityDescription** (`AppDelegate.swift`): 사용자 노출 문자열 (`"EjectDrives"`, `"Quit EjectDrives"`, eject 메뉴바 아이콘 a11y label) → `DiskOUT`.
- **Localizable.xcstrings**: 사용자 노출 키 (`"Quit EjectDrives"`, `"Toggle EjectDrives on in System Settings → Login Items."`) 및 en/ko 번역값 모두 `DiskOUT` 으로 변경.
- **Xcode 프로젝트**: `EjectDrives.xcodeproj` → `DiskOUT.xcodeproj` rename, `project.yml` 의 `name` / `targets.<name>` 갱신 후 `xcodegen generate` 로 재생성. scheme 이름 = `DiskOUT` 자동 적용. `xcodebuild -list -project DiskOUT.xcodeproj` 로 인식 확인.
- **entitlements 파일**: `EjectDrives.entitlements` → `DiskOUT.entitlements` rename (빈 dict 유지).
- **문서**: `README.md`, `EjectDrives_개발기획서.md`, `EjectDrives_분석.md`, `EjectDrives_애니메이션_가이드.md` 의 모든 `EjectDrives` 표기 → `DiskOUT`. 파일명도 `DiskOUT_*.md` 로 rename.
- **CHANGELOG.md 본문**: 과거 항목 안에 등장하는 `EjectDrives` 도 일괄 `DiskOUT` 으로 변경 (단 historical 시작 로그 출력값 `` `EjectDrives launched` `` 은 코드의 실제 로그 메시지와 일치시키기 위해 원래대로 유지).
- **.gitignore**: `/tmp` 빌드 산출물 패턴 + 충돌 복사본 예시 주석 `DiskOUT` 으로 갱신 (구 `EjectDrives-derived/` 패턴은 호환 위해 함께 보존).

### 의도적으로 유지한 영역

- **Bundle ID `com.yongza.ejectdrives`** — `PRODUCT_BUNDLE_IDENTIFIER`, Logger subsystem, DispatchQueue label, BTM 등록, 기존 `UserDefaults` / `SMAppService` / 키체인 호환성을 위해 그대로 둠. Bundle ID 를 바꾸면 사용자가 새 앱처럼 인식되어 환경설정·로그인 항목 등록을 처음부터 다시 해야 한다.
- **내부 심볼 / 코멘트 일부** — `archive/` 안의 폐기된 sandbox/helper 시절 코드 (`EjectDrivesHelper`, `EjectDrivesHelperProtocol`, `kEjectDrivesHelperMachServiceName`) 는 historical artifact 라 변경 안 함.
- **로그 메시지 `"EjectDrives launched"`** (`AppDelegate.swift:135`) — Console.app 으로만 보이는 디버그 로그, 사용자 노출 아님. Bundle ID/subsystem 과 일관성 유지 차원에서 그대로 둠.
- **파일 헤더 주석**: `// DiskOUT — ... (구 EjectDrives)` 형태로 historical 정보만 남김.

### 확인 필요 / 다음 단계

- ⚠️ **Bundle ID 와 표시 이름이 불일치한 상태**. 향후 Developer ID / App Store 배포 시 일관성을 잡을지 (그때는 사용자 데이터 마이그레이션 비용 감수) 별도 결정 필요.
- ⚠️ **`~/Applications/EjectDrives.app` 기존 설치본**: 새 빌드는 `DiskOUT.app` 으로 생성됨. 다음 빌드/설치 시 기존 `.app` 수동 제거 + LoginItem 토글 한 번 OFF/ON 권장.
- ⚠️ **앱 아이콘 자산**: 현재는 SF Symbol `eject.fill` 만 사용하므로 영향 없음. 향후 별도 아이콘 추가 시 새 이름에 맞춰 갱신.
- ⚠️ **macOS BTM 잔재**: 기존 EjectDrives 등록 + 신규 DiskOUT 등록이 둘 다 BTM 에 올라가 `로그인 항목 허용 필요` 메시지가 나올 수 있음. 시스템 설정 → 일반 → 로그인 항목에서 EjectDrives stale entry 제거 후 DiskOUT 만 활성화.

### 검증

- `xcodebuild -list -project DiskOUT.xcodeproj` → `Targets: DiskOUT`, `Schemes: DiskOUT` 정상 인식 확인.
- 빌드 자체는 사용자가 별도 검증 (`xcodebuild -project DiskOUT.xcodeproj -scheme DiskOUT -configuration Release build`).

---

## Unreleased — 2026-05-13: sleep eject "비정상 추출" 알림 감소

**배경**: 디스플레이 sleep 진입 시 `Extreme SSD` (APFS multi-volume container) 에 대해 macOS "디스크가 제대로 추출되지 않음" 알림이 4번 떴다. 로그 분석 결과 sleep eject 가 처음부터 `force` 옵션으로 시작 → DA volume-only force unmount(1s) 타임아웃 → `diskutil unmountDisk force`(10s) 타임아웃 → `diskutil eject force` 로 강제 추출되었기 때문. 강제 추출 단계까지 도달하면 macOS 가 비정상 추출로 인식하고, sub-volume 마다 알림을 띄운다.

### 변경 ([AppDelegate.swift](AppDelegate.swift) `diskutilEjectForSleep` / `diskArbitrationUnmountForSleep`)

- **`diskArbitrationForceUnmountForSleep` → `diskArbitrationUnmountForSleep` 으로 일반화**: `force: Bool` 파라미터 추가. `force=false` 면 `kDADiskUnmountOptionDefault`, `true` 면 `kDADiskUnmountOptionForce` 사용. 양쪽 모두 `wholeDiskBSDName` 이 있으면 `kDADiskUnmountOptionWhole` 함께 적용해 sub-volume 들을 한 번에 처리한다.
- **sleep eject 흐름 재구성** — 정상 unmount 1단계 추가, force 단계는 whole-disk 우선:
  1. **Step A (NEW)**: DA normal unmount (whole disk 우선, 2.0s timeout) — 다른 process 가 disk 를 빠르게 놓으면 여기서 끝나며, 정상 unmount 라 macOS 알림이 뜨지 않는다.
  2. **Step B**: DA force unmount (whole disk 우선, 3.0s timeout) — 기존 1.0s + volume-only 였던 단계. timeout 을 늘리고 whole-disk option 으로 sub-volume 한 번에 처리.
  3. **Step C**: `diskutil unmountDisk force` (6s timeout) — 기존 10s 에서 단축. 여기까지 도달했다는 건 이미 kernel-level unmount 가 막혀 있다는 뜻이라 10s 까지 기다릴 의미가 적음.
  4. **Step D**: `diskutil eject force` (5s timeout) — 기존 10s 에서 단축. 마지막 수단.
  5. **Step E**: `diskutil eject` (3s) — fallback.
- **최대 소요 시간**: 24s → 19s. wake 후 remount 가 시작되기까지의 잠재 지연 감소.

### 기대 효과

- 정상 sleep 진입 (사용 중 process 없음) 시 **Step A 에서 종료 → 알림 0개**.
- Step B 이상으로 떨어져도 whole-disk option 덕분에 sub-volume 마다 따로 force-unmount 되지 않으므로 알림 개수가 줄어든다 (이전 4개 → 1개 또는 0개 기대).
- 수동 추출 (`diskutilEject`) 경로는 변경 없음.

### 검증

| 항목 | 결과 |
|---|---|
| `xcodebuild -project DiskOUT.xcodeproj -scheme DiskOUT -configuration Debug build` | BUILD SUCCEEDED |
| 호출부 / 시그니처 정합성 (`grep diskArbitrationForceUnmountForSleep`) | 잔재 0건 |

실제 알림 감소는 다음 sleep 사이클 이후 `log show --predicate 'subsystem == "com.yongza.ejectdrives"' --last 1h` 로 Step A/B 도달 여부를 확인하면서 검증한다.

---

## Unreleased — 2026-05-10: MVP 정비 (코드 검토 후 일괄 fix)

코드 + 문서 전체 검토 결과 발견된 21 개 항목을 우선순위 순으로 정비. 기능 추가보다는 잠재 버그 / UX 함정 / 코드 위생 정리에 집중. Debug 빌드 ✅ 검증 완료, 새 빌드 `~/Applications/` 설치까지 확인.

### 안정성 / 잠재 버그

- **status item 표시 강제 코드 복원**: macOS 26 의 `NSStatusBarWindow` 가 height=0 으로 갇혀 메뉴바 아이콘이 보이지 않는 워크어라운드를 `setupStatusItem()` 에 다시 넣었다. 이전에 README 에는 "이 두 줄이 빠지면 메뉴바에 안 보임"으로 기록돼 있었지만 실제 코드에선 빠져 있어, 사용자 환경에 따라 메뉴바 아이콘 자체가 안 보일 수 있는 상태였다.
- **공유 state thread safety**: `autoEjectedDisks: Set<String>`, `autoEjectOperationID/Reason`, `skipSleepAutoEjectUntil` 4 개를 `autoEjectStateLock` 으로 감싸는 computed property 로 교체했다. `sleepEjectQueue` 와 main thread 양쪽에서 락 없이 read/write 하던 race 가능성을 막았다. Swift `Set` 은 thread-unsafe 라 race 시 crash 가능했다.
- **`ProcessRunner` timeout 후 hang 방지**: SIGKILL 된 child 가 grandchild 를 fork (예: `hdiutil`) 했으면 pipe fd 가 닫히지 않아 `readDataToEndOfFile` 가 무한 대기할 수 있었다. timeout 시엔 `readabilityHandler` 가 모은 데이터만 사용하고 추가 read 를 건너뛴다.
- **`LibraryAppHandler.quitLibraryApps` quit/eject race 완화**: `app.terminate()` 가 비동기라 라이브러리 lock 이 풀리기 전에 추출이 시작되던 케이스가 있었다. 종료 완료까지 최대 3 초 polling (100 ms 간격) 으로 lock 풀림 보장.
- **`tryRemount` 가 매 시도마다 `diskutil info` 호출하던 부분을 IORegistry 직접 검사로 교체**: process spawn overhead 가 시도당 수백 ms 였다. wake 직후 사용자 체감 지연이 줄어든다.
- **단축키 preset 충돌 자동 정정**: 추출 / 마운트 단축키가 같은 preset 으로 저장돼 있으면 mount 가 영원히 발화 안 되던 함정. 환경설정 popup 변경 시 충돌 감지 + 다른 preset 으로 자동 이동 + alert. 시작 시에도 `installHotkey()` 에서 자동 정정.
- **단축키 자동 반복 무시**: `event.isARepeat` 인 키 이벤트는 무시. 디바운스 1.5 s 로 보호되긴 했지만 첫 한두 번이 통과해 결과 알림이 두 번 뜨는 케이스가 있었다.
- **결과 아이콘 자동 reset**: `setPersistentIcon` 으로 ✓ / ⚠ / ✗ 가 메뉴바에 영구 표시되어 며칠씩 거슬리던 문제. 5 분 후 자동으로 default 아이콘으로 복귀 (그 사이 다른 추출 / reset 일어나면 generation 토큰으로 무효화).

### 사용자 편의성 / UX

- **우클릭 = 즉시 모두 추출** 을 환경설정에서 끌 수 있게 했다 (`SettingsStore.rightClickEjectEnabled`, default ON 으로 기존 동작 유지). OFF 로 두면 우클릭 / ctrl+click 이 메뉴를 띄워 실수로 작업 중인 외장이 빠지는 사고를 막는다.
- **권한 누락 메뉴 안내**: Accessibility 권한이나 알림 권한이 거부 / 미허용 상태면 메뉴 상단에 ⚠ row 로 표시한다. 클릭하면 시스템 설정의 해당 페이지로 deeplink. 이전엔 silent 실패 (단축키 안 먹히거나 알림 안 뜨는데 왜 인지 알 길 없음) 였다.
- **About 탭 추가**: 환경설정 창에 정보 탭 신설 — 버전, 빌드 번호, copyright, "알림은 의도적으로 무음" 안내 한 줄. 사용자가 자기 버전 확인할 곳이 없던 문제 해결.
- **메뉴 vs 환경설정 토글 중복 정리**: 양쪽에 같은 토글이 떠 있어 어디서 켰는지 혼동되던 문제. 메뉴엔 자주 토글하는 *"잠자기 시 자동 추출"* 만 유지, *"화면 꺼질 때 자동 추출"* / *"Music·Photos 자동 종료"* / *"로그인 시 자동 실행"* 은 환경설정 전용으로 이동. 단 `SMAppService` 가 `.requiresApproval` 을 반환하면 메뉴에 ⚠ 경고 row 만 노출.
- **"추출하고 잠자기" 단축키 옵션 추가**: `SettingsStore.ejectAndSleepHotkey` (기본 Off). 환경설정 → Hotkeys 탭에서 4 개 preset 중 선택 가능. eject / mount 와 같은 preset 선택 시 alert 후 무시.
- **"Quit" → "Quit DiskOUT"** macOS 표준 라벨. 한국어 "DiskOUT 종료".

### 코드 위생 / 빌드 정합성

- **미사용 파일 archive 이동**: `Helper/`, `HelperClient.swift`, `Shared/HelperProtocol.swift`, `DiskArbitrationBackend.swift`, 구 `DiskOUT.entitlements` (sandbox=true) 를 `archive/` 디렉토리로 이동. `.gitignore` 에 `archive/` 추가. helper 시절 잔재가 빌드에 다시 포함되는 사고 방지.
- **`DiskOUT 2.xcodeproj` / `DiskOUT 3.xcodeproj` 삭제**: iCloud 동기화 충돌 잔재. `.gitignore` 패턴은 있었으나 디스크에 그대로였다. 동시에 `.gitignore` 의 sync conflict 패턴을 `* [0-9].xcodeproj/` 로 일반화.
- **dead code 삭제**: `UnmountedExternal.firstVolumeName(in:)` 정의는 있었으나 호출 0 회. 메뉴용 `toggleLoginItem`, `toggleDisplaySleepEject`, `toggleLibraryAppManagement` 핸들러도 메뉴 정리 후 dead 가 되어 함께 삭제.
- **`project.yml` 에 entitlements 명시**: 빈 dict (`properties: {}`) 로 명시해, 향후 누군가 helper / DA backend 를 다시 빌드할 때 entitlements 가 자동 생성되어 sandbox=true 가 묻어 들어가는 함정 방지. 새 `DiskOUT.entitlements` 는 빈 plist.
- **Settings window 닫힘 cleanup**: `windowWillClose` 시 controller 를 nil 로 해제. 다음번 ⌘, 시 fresh state 로 다시 띄움.

### 다국어

- 새 키 11 개 한 / 영 추가 (`About`, `Off`, `Quit DiskOUT`, `Right-click menu bar icon to eject all`, `Allow Accessibility for global hotkeys`, `Allow notifications to see eject results`, `Hotkey conflict`, 충돌 alert 본문 2 개, About 탭 hint, 우클릭 토글 tooltip).

### 검증

| 항목 | 결과 |
|---|---|
| `xcodegen generate` + Debug build (`/tmp/DiskOUT-review-build`) | 성공 |
| `jq empty Localizable.xcstrings` | 성공 |
| `~/Applications/DiskOUT.app` fresh install + launch | 성공 |
| 시작 로그 (`log show --predicate 'subsystem == "com.yongza.ejectdrives"'`) | `EjectDrives launched`, `IOKit power sleep observer registered`, `Accessibility trusted = true`, `globalKeyMonitor = REGISTERED`, `DiskMenuSnapshot.load 0.131s drives=["Extreme SSD","SYSJO"]` |

### 알려진 후속 작업

- **App Icon**: `Assets.xcassets/AppIcon.appiconset` + `project.yml` 연결 미완료. 사용자가 아이콘 자산 결정 후 별도 진행.
- **`sfltool dumpbtm` 잔재**: BTM 에 sandbox/helper 시절 등록 (`URL: file:///Applications/DiskOUT.app/`, `Embedded Item: 16.com.yongza.ejectdrives.helper`) 이 disallowed 상태로 남아 있어, 새 빌드의 `SMAppService.mainApp.status` 가 `.requiresApproval` 로 보고된다. 사용자가 시스템 설정 → 일반 → 로그인 항목에서 stale entry 를 직접 정리해야 한다 (`sudo sfltool resetbtm` 은 다른 백그라운드 앱 등록도 reset 되므로 권장 안 함).

---

## Unreleased — 2026-05-07~10: App Store/sandbox 포기, diskutil 직접 경로 복원, sleep 추출 안정화

**배경**: Mac App Store sandbox 안에서 `DADiskMount` / `DADiskUnmount` / `SMAppService.daemon` 조합으로 mount 안정성을 확보하지 못했다. 핵심 기능이 mount/eject 인 앱에서 sandbox 호환성보다 실제 동작 안정성이 우선이라 판단해 App Store 노선을 보류/포기했다.

### 결정 사항

- **App Sandbox OFF**: `project.yml` 과 `DiskOUT.xcodeproj` 모두 `ENABLE_APP_SANDBOX = NO`.
- **Helper daemon 제거**: `HelperClient`, `HelperDaemon`, helper target, LaunchDaemons copy phase 를 빌드에서 제거. 미추적 helper 파일은 남아있지만 현재 빌드 대상이 아니다.
- **DiskArbitrationBackend 빌드 제외**: DA/IOKit sandbox 실험 코드는 파일로 남아있지만 현재 target sources 에서 제외.
- **디스크 작업은 `diskutil` 직접 실행으로 복원**:
  - mount: `diskutil mountDisk <wholeDiskBSD>`
  - eject: `diskutil eject <volumePath>` 실패 시 `diskutil unmount force <volumePath>` fallback
  - unmounted 후보: `diskutil list -plist external`
  - enumerate 확인 / BusProtocol / VolumeUUID: `diskutil info -plist`
  - mounted DMG 필터: `hdiutil info -plist`
- **sleep 계열 추출은 volume-first(볼륨 우선) 경로 추가**:
  - sleep / display sleep / "추출하고 잠자기" 경로는 `Disk Arbitration API` 의 `DADiskCreateFromVolumePath` + `DADiskUnmount(force)` 를 각 volume(볼륨)에 병렬로 먼저 시도한다.
  - 실패하거나 1초 timeout(타임아웃) 이 나면 기존 `diskutil unmountDisk force` → `diskutil eject force` → normal eject 순서로 fallback 한다.
  - 수동 우클릭 / 단축키 / 개별 추출은 기존 `diskutil eject` 우선 경로를 유지한다. 사용자 명시 추출에서는 실패 원인 진단과 일반 eject 의미를 우선한다.
- **IOKit sleep delay(잠자기 지연) 추가**: `NSWorkspace.willSleepNotification` 만 의존하지 않고 IOKit power notification(전원 알림)으로 system sleep(시스템 잠자기)을 잠깐 붙잡은 뒤 자동 추출을 시도한다.
- **로그인 항목 UX 수정**: `SMAppService.mainApp.status == .requiresApproval` 인 경우에도 메뉴 체크 표시를 켜고, 제목에 "로그인 항목 허용 필요"를 붙인다.
- **메뉴 열림 지연 개선**: `DiskMenuSnapshotCache` 추가. 앱 시작 및 mount/unmount 변경 시 background 에서 snapshot 을 미리 만들고, `menuWillOpen` 은 cache(캐시)를 즉시 표시한 뒤 stale(오래된) 상태면 background refresh(백그라운드 갱신) 완료 후 열린 메뉴를 다시 채운다.
- **mounted/unmounted 정합성 개선**: mounted(마운트됨) 목록과 unmounted(마운트 안 됨) 후보를 `diskutil list -plist external` 한 snapshot(스냅샷)에서 같이 계산한다. 이전처럼 `FileManager.mountedVolumeURLs` 와 `diskutil list` 를 따로 읽으며 생기던 stale state(오래된 상태) 가능성을 줄였다.
- **refresh stuck recovery(갱신 고착 복구)**: SD card 추출 직후처럼 장치가 사라지는 race condition(경합 상태)에서 `Updating...` 이 풀리지 않던 문제를 막기 위해 snapshot 조회 timeout(타임아웃), EOF(파일 끝) 처리, 실패 복구 상태를 추가했다.
- **Developer ID 배포 상태 기록**: `Developer ID Application: roh yongwook (495S4FVMCB)` 인증서로 서명 가능한 것까지 확인했다. Notarization(공증)은 `notarytool` profile(프로필) / credential(자격 증명) 미설정으로 보류 상태다.

### 추가된 기능 / 변경

- **환경설정 창 추가**: 메뉴의 "환경설정..." 또는 `⌘,` 로 `SettingsWindowController` 를 열어 로그인 실행, sleep/display sleep 자동 추출, Music/Photos 자동 종료, 단축키, 알림, force fallback(강제 fallback)을 조정한다.
- **단축키 preset(프리셋) 설정 추가**: 추출/마운트 단축키를 E 키 기반 preset 중에서 선택한다. 기본값은 추출 `⌥⌘E`, 마운트 `⌃⌘E`.
- **알림 설정 분리**: 전체 알림, 성공 알림, 실패 알림을 `SettingsStore` 에서 따로 제어한다. 성공/실패 결과는 `AppNotificationKind` 로 분류한다.
- **force fallback toggle(강제 fallback 토글)**: `diskutil eject` 실패 후 `diskutil unmount force` 를 시도할지 환경설정에서 끌 수 있다. 기본값은 기존 동작 보존을 위해 ON.
- **디스크 종류 아이콘 적용**: SD card(카드) 로 판단되는 볼륨은 `sdcard`, 일반 외장은 `externaldrive` 계열 SF Symbol(시스템 심볼)을 사용한다.
- **`lsof` 실패 진단 복원**: App Store sandbox(샌드박스) 노선을 끄면서 `diskutil eject` 와 `unmount force` 가 모두 실패한 경우 `/usr/sbin/lsof -nP -w -Fpcfn -- <volumePath>` 로 점유 process(프로세스) / open file(열린 파일)을 알림에 붙인다. macOS privacy(개인정보 보호) 제한으로 Full Disk Access(전체 디스크 접근)가 필요할 수 있다.
- **`ProcessRunner` 개선**: stdout/stderr 를 `readabilityHandler` 로 drain(비우기)하고, timeout(타임아웃) 옵션을 추가했다. `lsof` 는 3초, `pmset sleepnow` 는 5초 timeout 을 사용한다.
- **`ProcessRunner` EOF 처리 수정**: `availableData` 가 빈 data(데이터)를 반환하면 `readabilityHandler` 를 즉시 해제해, 종료된 child process(자식 프로세스)의 pipe(파이프)에서 CPU 를 계속 쓰는 loop(루프)를 방지한다.
- **snapshot용 `diskutil` timeout 추가**: `diskutil list -plist external` 은 5초, `diskutil info -plist ...` 는 3초 timeout 을 둔다. 실패해도 `DiskMenuSnapshotCache.refreshing` 은 반드시 false 로 풀린다.
- **갱신 실패 표시 추가**: snapshot refresh(스냅샷 갱신)가 실패하면 기존 cache 를 유지하고 메뉴 상단에 "Disk status update failed" / "디스크 상태 갱신 실패" disabled row(비활성 행)를 표시한다.
- **"추출하고 잠자기" 추가**: 메뉴에서 전체 추출 후 실패가 없을 때만 `/usr/bin/pmset sleepnow` 로 sleep(잠자기)을 요청한다. 추출 실패가 있으면 sleep 은 시작하지 않고 알림을 남긴다.
- **"추출하고 잠자기" 경로 개선**: 일반 `diskutil eject` 대신 sleep 계열 `volume-first force unmount` 경로를 사용한다. 성공한 디스크만 wake/remount(깨움/재마운트) 대상으로 기록한다.
- **display sleep 자동 추출 경로 개선**: `pmset sleep=0` 환경 보호용 display sleep(화면 꺼짐) 자동 추출도 sleep 계열 `volume-first force unmount` 경로를 사용한다. system sleep 추출이 이미 진행 중이면 중복 실행하지 않는다.
- **remount target 기록 정정**: sleep / display sleep / "추출하고 잠자기" 모두 추출 성공한 whole disk BSD(전체 디스크 BSD) 만 `autoEjectedDisks` 에 기록한다. 실패한 디스크를 wake 후 재마운트 대상으로 보던 상태 혼선을 줄였다.
- **`hdiutil info -plist` timeout 추가**: mounted disk image(DMG/CoreSimulator) 필터링 중 `hdiutil` 이 멈추면 sleep 추출 task(작업)가 끝나지 않아 wake 후 재마운트 대상이 기록되지 않는 문제가 있었다. `hdiutil` 에 1초 timeout 을 추가하고, 실패 시 `diskutil info` 의 `BusProtocol == "Disk Image"` 및 CoreSimulator mount path(마운트 경로) 기반 fallback 으로 disk image 를 제외한다.
- **clamshell(뚜껑 닫힘) pre-eject 추가**: clamshell state change(뚜껑 상태 변경) 를 관찰해 lid close(뚜껑 닫기) 시 sleep 여부와 별개로 sleep 추출 task 를 먼저 시작한다. 이후 system sleep 알림이 오면 같은 task 에 join 한다.
- **logout/restart/shutdown 전 자동 추출은 default OFF**: 구현 코드는 남겨두되 `powerOffAutoEjectEnabled = false` 로 게이트(gate = 차단 조건)를 닫았다. macOS 종료 과정이 원래 볼륨 정리를 시도하고, 현재 제품 가치가 낮아 사용자 노출 기능으로 켜지 않는다.
- **다국어 키 증가**: `Localizable.xcstrings` 는 41개에서 73개 키로 증가했다.

### 검증

| 항목 | 결과 |
|---|---|
| Debug build | 성공 |
| Debug build (`/tmp/DiskOUT-lsof-build`) | 성공 |
| Debug build (`/tmp/DiskOUT-sleep-build`) | 성공 |
| Debug build (`/tmp/DiskOUT-docs-build`) | 성공 |
| Debug build (`/tmp/DiskOUT-async-menu`) | 성공 |
| Release build (`/tmp/DiskOUT-async-menu-release`) | 성공 |
| Debug build (`/tmp/DiskOUT-refresh-fix-debug`) | 성공 |
| Release build (`/tmp/DiskOUT-refresh-fix-release`) | 성공 |
| Debug build (2026-05-10 sleep/remount fixes) | 성공 |
| `codesign -d --entitlements` | sandbox entitlement 없음 (`get-task-allow` 만 존재) |
| Developer ID signing(개발자 ID 서명) | timestamp 포함 서명 zip 생성 가능 확인. `spctl` 은 notarization 미완료 상태라 `Unnotarized Developer ID` 로 reject |
| `diskutil list -plist external` | 정상 |
| `hdiutil info -plist` | 정상 |
| `sample <DiskOUT PID>` | sleep task 가 `hdiutil info -plist` 무제한 대기 중인 call stack 확인 후 timeout 수정 |
| `diskutil mountDisk disk7/disk8` | 이미 마운트된 상태에서 success |
| `lsof -Fpcfn` 출력 형태 | parser(파서) 입력 형식 확인 |
| `jq empty Localizable.xcstrings` | 성공 |
| `git diff --check -- AppDelegate.swift Localizable.xcstrings README.md CHANGELOG.md DiskOUT_*.md` | 성공 |
| 메뉴 생성 시간 | stale cache 상태에서도 먼저 `0.013~0.014s` 에 메뉴 표시, background refresh 완료 후 `0.008s` 로 재구성 |
| SD card 추출 후 stale cache 복구 | 기존 stuck 실행본에서 CPU 약 200% 및 `refreshing=true` 지속 확인. 수정 빌드 재시작 후 `DiskMenuSnapshot.load: 2.550s drives=["SSD_W", "SYSJO"] refreshError=-`, CPU `0.0%` 확인 |
| 로그인 항목 메뉴 상태 | `.requiresApproval` 상태에서 `✓ 로그인 시 자동 실행 (로그인 항목 허용 필요)` 표시 |
| 앱 재시작 후 디스크 인식 | `SYSJO` 정상 인식 (`DiskMenuSnapshot.load ... drives=["SYSJO"]`) |

### 남은 이슈

- 실제 `diskutil eject` / `unmount force` 는 사용자 디스크를 건드리므로 자동 검증하지 않았다.
- 실제 뚜껑 닫기 / display sleep / "추출하고 잠자기" 의 `DA volume force unmount first` 로그와 wake 후 `remount START` 는 실제 외장 디스크 연결 상태에서 반복 검증이 남아 있다.
- 실제 점유 앱이 있는 외장 디스크에서 `lsof` 진단 알림은 수동 검증이 남아 있다.
- "추출하고 잠자기"는 빌드 검증까지 완료. 실제 sleep 진입은 현재 작업 세션 보호를 위해 제한적으로만 확인했다.
- logout/restart/shutdown 전 자동 추출은 default OFF. 사용자 증거가 쌓일 때만 다시 켠다.
- App Store 재도전은 `diskutil` 없이 동등한 mount/eject 안정성을 확보할 때만 검토한다.
- Notarization(공증)은 Apple notary credential(공증 자격 증명) 등록 전까지 완료할 수 없다.
- SD card 를 다시 꽂고 추출하는 반복 실기 테스트는 남아 있다. 현재 수정은 stuck 상태 복구와 CPU loop 방지까지 검증했다.
- `Helper/`, `HelperClient.swift`, `Shared/` 는 미추적 파일로 남아있다. 현재 빌드에는 포함되지 않는다.

---

## Superseded — 2026-05-06: 배포 노선 결정: Mac App Store 단일

> 2026-05-07에 App Store/sandbox 노선을 포기하면서 아래 결정은 현재 유효하지 않다. 당시 판단과 실험 기록 보존용으로 남긴다.

**배경**: 한국 1인 개발자 + 사업자등록 미보유 + 해외 결제 인프라 부재 → Stripe / MoR 식 직접 판매 비현실적. App Store 의 결제·세무 인프라가 가장 합리적. 사용자 신뢰 측면에서도 App Store 라는 울타리가 유리.

### 결정 사항

- **Mac App Store 단일 노선**. Developer ID + GitHub Releases 노선은 폐기. 이중 SKU 운영 부담 (sandbox ON/OFF 두 빌드, 코드 분기) 이 1인 운영에 큼.
- **유료화 모델 확정**: 핵심 기능 전부 무료 (자세한 유료화 전략은 별도 문서).
- **App Sandbox ON 으로 복원**. App Store 가 강제하는 요건. 현재 `DiskOUT.entitlements` = `app-sandbox=true` + `device.usb` + `temporary-exception /Volumes/`.

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

## 안전 패키지 — Per-disk 제외 + Time Machine 보호 + 라이브러리 앱 quit (Unreleased)

Jettison 비교 분석에서 도출된 *진짜 위험* 3가지 — Time Machine 자동 추출 사고 / 외장 라이브러리 lock / 사용자별 디스크 정책 부재 — 를 v1.0 출시 전에 모두 처리.

### Phase 1 — Per-disk 자동 추출 제외 (Volume UUID 기반)

- 신규 `ExcludedVolumes` enum (`UserDefaults["excludedVolumeUUIDs"]`)
- `ExternalDrive` struct 에 `volumeUUID: String?` 필드 추가 (DA description 의 `kDADiskDescriptionVolumeUUIDKey` → `CFUUIDCreateString`)
- 메뉴의 각 디스크 항목에 submenu — *"자동 추출 제외"* 토글
- `ejectAllSilently(applyExcludeFilter:)` — 자동 path (sleep / display sleep) 만 filter 적용. 사용자 명시 추출 (메뉴 클릭 / `⌥⌘E` / 우클릭) 은 영향 X (사용자 의도 우선).
- 식별자로 BSD 가 아닌 **Volume UUID** 채택 — 케이블 / 슬롯 변경에도 유지.

### Phase 2 — Time Machine 자동 식별 + 기본 제외

- `ExternalDrive.isTimeMachineDisk(volumeURL:)` — sandbox 호환 (file 존재 검사):
  - APFS: `.com.apple.timemachine.donotpresent` 마커 파일
  - Legacy HFS+: `Backups.backupdb/` 디렉토리
- 처음 보는 Time Machine 디스크는 자동으로 `ExcludedVolumes` 에 추가 + 1회 알림 (*"Time Machine 디스크 자동 추출 제외"*)
- `TimeMachineNotified` enum — 같은 UUID 에 알림 반복 방지
- 메뉴에 *(Time Machine)* 접미사 + 시계 아이콘 (`clock.arrow.circlepath`) 으로 시각 구분
- 사용자가 의도적으로 토글 OFF 한 경우 그 의도 존중 (다시 자동 추가 안 함)

### Phase 3 — 외장 라이브러리 앱 자동 종료 (Music / Photos)

- 신규 `LibraryAppManagement` toggle (default OFF, 명시적 opt-in)
- `LibraryAppHandler.quitLibraryApps()` — `NSWorkspace.runningApplications` enumerate, `com.apple.Music` / `com.apple.Photos` graceful terminate
- `LibraryAppHandler.relaunchQuitApps()` — wake 시 `NSWorkspace.openApplication(at:configuration:)` 으로 백그라운드 재실행 (`activates: false, hides: true`)
- sleep 핸들러 (`systemWillSleep`, `screensDidSleep`) 에 quit 호출 추가
- wake 핸들러 (`systemDidWake`, `screensDidWake`) 에 relaunch 호출 추가
- 메뉴에 *"잠자기 전 Music / Photos 자동 종료"* 토글 추가 (자동 추출 토글 옆)

### 다국어 — 신규 5개 키

`Localizable.xcstrings` 에 추가 (총 41개):
- `Exclude from auto-eject` / "자동 추출에서 제외"
- `Time Machine drive protected` / "Time Machine 디스크 자동 추출 제외"
- `"%@" is excluded from auto-eject. ...` / 한국어 변형
- `Quit Music/Photos before sleep` / "잠자기 전 Music / Photos 자동 종료"
- 라이브러리 토글 tooltip

### Jettison 대비 잔여 갭 (의도적으로 v1.1+ 로 미룸)

- ❌ Time Machine 백업 *진행 중* detection — sandbox 에서 `tmutil`, `IOPMAssertion` 접근 어려움. v1.1+
- ❌ Dark wake 시 Time Machine 만 마운트 — sandbox + background process 영역 복합. v1.1+
- ❌ Disk type 별 필터 (HDD/SSD/DVD/CD/SD) — 우선순위 낮음. 사용자 피드백 보고 결정
- ✅ "Eject and Sleep" 메뉴 항목 — 2026-05-07 구현. 단축키는 아직 없음.

### 위험 매트릭스 (이전 → 이후)

| 시나리오 | 이전 | 이후 |
|---|---|---|
| Time Machine 디스크 자동 추출 사고 | **🔴 높음** — 첫 sleep 에 추출 → 백업 사이클 깨짐 → 부정 리뷰 | 🟢 자동 식별 + default 제외 |
| 외장 사진/음악 라이브러리 lock | 🟡 중 — 추출 실패 (graceful unmount declined) | 🟢 옵션으로 자동 quit/relaunch |
| 디스크별 다른 정책 (예: SSD 만 추출, HDD 는 유지) | 🔴 높음 — 일괄 ON/OFF 만 가능 | 🟢 디스크별 토글 |

---

## SMAppService 자동 실행 + 다국어 (ko + en) — 추가 (Unreleased)

### SMAppService — 로그인 시 자동 실행 토글

[AppDelegate.swift](AppDelegate.swift) 에 `LoginItem` enum 추가 (`SleepEject` 옆 패턴). 메뉴에 "로그인 시 자동 실행" 토글 노출.

- macOS 13+ `SMAppService.mainApp` 사용. 시스템 설정 → 일반 → 로그인 항목 에 자동 등록.
- `status == .requiresApproval` 케이스 (사용자가 시스템 설정에서 허용 안 한 상태) 처리:
  - 토글 상태에 따라 toolTip 으로 *"시스템 설정에서 허용 필요"* 안내
  - register 직후 status 가 requiresApproval 이면 알림 + `SMAppService.openSystemSettingsLoginItems()` 로 시스템 설정 자동 오픈
- **이전 README 의 수동 안내 폐기** — 사용자가 `~/Applications/DiskOUT.app` 을 직접 시스템 설정에 추가하던 절차 → 메뉴 토글 한 번으로 끝.

### 다국어 — `Localizable.xcstrings` (Xcode 15+ String Catalog)

신규 파일 [Localizable.xcstrings](Localizable.xcstrings) — 36개 사용자 텍스트의 영어 source + 한국어 번역. 메뉴 / 알림 / 토글 / tooltip 모든 표면.

- **Source 언어 영어** (`developmentLanguage: en` + `CFBundleDevelopmentRegion: en`)
- **지원 언어**: en, ko (`CFBundleLocalizations`)
- **API**: `String(localized: "...")` + string interpolation (`"Couldn't eject \(name)"`)
- **영어 톤**: 미니멀. *"Eject all"* / *"Mounted"* / *"Couldn't eject %@"* — 메뉴바 너비 의식.
- **한국어 톤**: 기존 어투 보존. *"모두 추출"* / *"마운트 완료"* / *"추출 실패: %@"*

빌드 결과:
- `DiskOUT.app/Contents/Resources/{en,ko}.lproj/Localizable.strings` 자동 컴파일
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
| **DiskOUT v0.3.0** | ✗ | ✗ | ✗ | 우리만 빠져있던 갭 |

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
- 화면이 꺼져도 (display sleep) 시스템은 awake → DiskOUT 동작 X
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
  - 기존 v0.2.0 (PID 67951) 종료 → `~/Applications/DiskOUT.app.v0.2.0.bak` 백업
  - DerivedData 의 Debug 빌드 (`23:02` 산출물) 를 `~/Applications/` 로 복사 + `xattr -cr` 로 provenance 정리
  - 새 PID 63837 으로 정상 실행, `globalKeyMonitor REGISTERED` / `Accessibility trusted = true` 확인
- **검증 환경** — macOS 26.4.1 (Apple Silicon), `pmset sleep = 0`, `displaysleep = 20` 분
- **알림 권한** — 여전히 denied (`authStatus=1`). 알림 매트릭스 검증 원하면 시스템 설정 → 알림 → DiskOUT 켜야 함
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

- **사용 중 프로세스 표기**: 2026-05-07 현재 `lsof -nP -w -Fpcfn -- /Volumes/X` 기반 best-effort 진단 구현. 실패 알림에 점유 process / open file 을 붙인다.
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
- **원인**: macOS 26 에서 Thunderbolt 외장 SSD 와 일부 USB 디바이스가 `ejectable/removable=false`. 풀버전 DiskOUT 의 원래 필터 (`isEjectable || isRemovable`) 가 깨짐
- **해결**: 필터 완화 — `!isInternal && isBrowsable && isLocal`. `isLocal` 가드로 네트워크 마운트만 제외, 외장 디스크는 전부 통과

#### 3. `com.apple.provenance` xattr 로 codesign 거부

- **증상**: codesign(코드사인 = 코드 서명) 시 "resource fork, Finder information, or similar detritus not allowed" 에러
- **원인**: macOS 의 fileprovider 서비스 (iCloud Drive 등) 가 `~/Documents/` 안 파일에 자동으로 `com.apple.provenance` extended attribute(확장 속성) 부착. `xattr -cr` 로 정리해도 곧 다시 붙음
- **해결**: 빌드를 `/tmp/` 등 fileprovider 영향 없는 곳에서 수행. `xcodebuild -derivedDataPath /tmp/DiskOUT-derived`

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

- **증상**: `log show --predicate 'eventMessage CONTAINS "[DiskOUT]"'` 검색 결과 0건. NSLog 호출은 했는데 unified logging(통합 로깅) 시스템에 흔적 없음
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

- GitHub: https://github.com/yooongZa/DiskOUT (private)
- 빌드 / 사용법: [README.md](README.md) 참조
