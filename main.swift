//
//  main.swift
//  DiskOUT — 명시적 entry point (구 EjectDrives)
//
//  @main attribute 가 swiftc 단독 빌드 + macOS 26 환경에서 안정적이지 않아
//  명시적으로 NSApplication 라이프사이클을 시작한다.
//

import Cocoa

// ─── 사용자 강제 언어 적용 (NSApplication 생성 전 — Bundle.main 의 localized resource 가
//     launch 시점에 캐시되므로 그 이전이어야 함) ──────────────────────────────
//
// 환경설정의 "언어" 드롭다운에서 사용자가 명시 선택한 값을 AppleLanguages 키로 변환해 적용.
// 키가 없으면 시스템 선호 언어 전체에서 앱이 지원하는 첫 언어를 매 launch 다시 선택한다.
// xcstrings 는 en / ko / ja / zh-Hans 를 가짐. 지원 언어가 하나도 없으면 en 으로 fallback.
//
// 🚨 Bundle.main 은 절대 건드리지 말 것. Bundle.main 을 한 번이라도 접근하면 *현재* AppleLanguages
// 값으로 localizations 가 캐시되고, 그 후 AppleLanguages 를 set 해도 무시됨 (UI 가 한 박자 늦게
// 바뀌는 증상). 그래서 시스템 우선 언어는 Locale.preferredLanguages 로 읽음 (Bundle 건드림 없음).
//
AppLanguagePolicy.applyAtLaunch(in: .standard) {
    Locale.preferredLanguages
}

// ─── macOS 26 (Tahoe) 자동 메뉴 아이콘 끄기 ──────────────────────────────────
// Tahoe 는 표준 selector 메뉴 항목 (terminate: 등) 에 시스템 아이콘을 자동 주입한다 —
// 종료 행에만 아이콘이 생겨 "유틸리티 행은 텍스트만" 컨벤션과 메뉴 안 일관성이 깨진다.
// NSMenuEnableActionImages 를 앱의 registration domain 에 등록해 이 앱만 끈다
// (사용자가 NSGlobalDomain 에 직접 설정한 값이 있으면 그쪽이 우선 — defaults 검색 순서).
// 우리가 명시적으로 넣는 아이콘 (디스크 행 / 경고 ⚠) 은 action image 가 아니라 영향 없음.
// register() 는 휘발성이라 사용자 plist 에 흔적이 안 남는다. AppKit 이 읽기 전이도록
// NSApplication 생성 전에 등록.
UserDefaults.standard.register(defaults: ["NSMenuEnableActionImages": false])

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // run() 전에 호출 — LSUIElement + open 조합 안정화
let delegate = AppDelegate()
app.delegate = delegate
app.run()
