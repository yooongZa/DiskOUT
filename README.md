# EjectDrives — 혼자 쓰는 초간단 버전

**v0.1.0** · 자세한 변경사항 / 발생했던 이슈 / 기술 배경 → [CHANGELOG.md](CHANGELOG.md)

맥북 외장 드라이브를 한방에 안전하게 추출하는 메뉴바 앱.
**Swift 2 파일, ~450줄.** 환경설정 창·다중 단축키 프리셋·로그인 자동실행 코드 없음. 본질만.

## 현재 상태 (2026-05-05 기준)

✅ **v0.1.0 동작 중**. `~/Applications/EjectDrives.app` 에 설치됨. macOS 26.4.1 (Apple Silicon) 에서 검증.

| 항목 | 값 |
|---|---|
| Bundle ID | `com.yongza.ejectdrives` |
| 사인 | `Apple Development: sukmack@gmail.com` (자동, Personal Team) |
| Hardened Runtime | YES |
| App Sandbox | NO (혼자 쓰는 앱, App Store 무관) |
| 빌드 시스템 | Xcodegen + xcodebuild |
| 진입점 | `main.swift` (명시적 `NSApplication.shared.run()`) |

## 기능

| 기능 | 설명 |
|---|---|
| 메뉴바 드롭다운 | 연결된 외장 드라이브 목록 |
| 개별 추출 | 드라이브 이름 클릭 |
| 모두 추출 | 메뉴 항목 또는 단축키 |
| 전역 단축키 | `⌃⇧₩` (한글 키보드 `\` 자리) |
| **뚜껑 닫을 때만** 자동 추출 | 메뉴에서 토글. 시간 지난 자동 sleep·메뉴→잠자기 는 추출 안 함 (IOKit `AppleClamshellState` 분기) |
| 결과 알림 | **무음** banner (도서관·회의실 고려) |
| 병렬 추출 | `DispatchQueue.concurrentPerform` 으로 N개 드라이브 동시 추출 |

## 파일 구성

```
diskOUT/
├── AppDelegate.swift            # 메인 로직 (~180줄)
├── main.swift                   # 명시적 entry point (NSApp.run)
├── Info.plist                   # bundle metadata (xcodegen 자동 생성)
├── EjectDrives.entitlements     # sandbox + USB + Volumes 권한
├── project.yml                  # xcodegen 설정
├── EjectDrives.xcodeproj/       # Xcode 프로젝트 (xcodegen 으로 재생성 가능)
├── README.md                    # 이 파일
└── EjectDrives_*.md             # 풀버전 기획 문서들 (보존)
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

## 사용법

- 메뉴바 좌측의 **⏏ 추출 아이콘** 클릭 → 드라이브 목록
- 드라이브 이름 클릭 → 개별 추출
- "모두 추출" → 전체 추출
- `⌃⇧₩` → 어디서든 전체 추출
- "뚜껑 닫을 때 자동 추출" 토글 → ON 이면 뚜껑 닫는 순간만 자동 추출. 시간 지나서 자동 sleep 들어가거나 메뉴→잠자기 한 경우엔 추출 안 함

## 로그인 시 자동 실행

시스템 설정 → 일반 → 로그인 항목 → `+` → `~/Applications/EjectDrives.app` 추가.

## 옵션 바꾸고 싶을 때

코드 한 번 고치고 재빌드:

| 바꿀 것 | 위치 |
|---|---|
| 단축키 | `AppDelegate.swift` 의 `installHotkey()` — `controlKey \| shiftKey`, `kVK_ANSI_Backslash` 부분 수정 |
| 자동추출 기본값 | `LidEject.enabled` 의 `?? true` 를 `?? false` 로 |
| 뚜껑 체크 비활성화 (모든 sleep 에서 추출) | `systemWillSleep()` 의 `guard Self.isLidClosed()` 가드 제거 |
| 메뉴 텍스트 | `menuWillOpen(_:)` 의 문자열 |

키 코드는 Carbon `Events.h` 의 `kVK_ANSI_*` 상수 참조.

## 알려진 제한

- **클램쉘 모드 (외장 모니터 + 전원 + 뚜껑 닫음)**: macOS 가 sleep 자체를 안 들어감 → `willSleep` 노티 발생 X → 자동 추출 트리거도 안 됨. **자동으로 안전하게 보호됨**.
- **사용 중 드라이브**: Finder 에서 파일 열려있거나 백업 진행 중이면 추출 거부됨. 알림에 원인 표시.
- **재마운트 없음**: USB 추출 후 재인식하려면 물리적으로 다시 연결.
- **데스크탑 맥 (Mini, Studio, iMac)**: 뚜껑 자체가 없어 `AppleClamshellState` 키 없음 → 자동 추출 트리거 안 됨. 토글을 끄거나 단축키만 사용.

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

---

# 풀버전 기획

원래는 마스코트(Tako)·IAP·App Store 출시까지 포함한 풀 제품 계획이었음. 관련 문서 (`EjectDrives_개발기획서.md` 등) 는 보존됨. 이 README 는 그중 코어만 남긴 1인용 버전.
