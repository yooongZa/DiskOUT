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
// 환경설정의 "언어" 드롭다운에서 사용자가 선택한 값을 AppleLanguages 키로 변환해 적용.
// "system" 이면 우리가 set 한 AppleLanguages 키를 제거 → macOS 가 시스템 언어를 따라감.
// xcstrings 는 en / ko / ja / zh-Hans 를 가짐. 사용자는 그 중 하나 또는 system 강제 선택 가능.
//
// 신규 설치자 smart default:
//   - Locale.preferredLanguages.first ("ko-KR", "ja", "zh-Hans-CN" 등) 의 base language 가 지원 언어면 → 그 언어로
//   - 지원 외 언어 사용자 (불어/스페인어 등) → "en" 으로 fallback
// 기존 사용자가 UserDefaults 에 저장해 둔 값은 그대로 존중 (key 없을 때만 smart default 작동).
//
// 🚨 Bundle.main 은 절대 건드리지 말 것. Bundle.main 을 한 번이라도 접근하면 *현재* AppleLanguages
// 값으로 localizations 가 캐시되고, 그 후 AppleLanguages 를 set 해도 무시됨 (UI 가 한 박자 늦게
// 바뀌는 증상). 그래서 시스템 우선 언어는 Locale.preferredLanguages 로 읽음 (Bundle 건드림 없음).
//
// SettingsStore.Key.appLanguage / SettingsStore.supportedLanguages 와 동기화 — 변경 시 양쪽 함께 수정.
let appLanguageKey = "settings.appLanguage"
let supportedLanguages = ["en", "ko", "ja", "zh-Hans"]
let systemPref = Locale.preferredLanguages.first ?? "en"
let smartDefault: String = {
    for lang in supportedLanguages {
        // 정확 매칭 ("ja" == "ja") 또는 prefix 매칭 ("ko-KR".hasPrefix("ko-"), "zh-Hans-CN".hasPrefix("zh-Hans-"))
        if systemPref == lang || systemPref.hasPrefix(lang + "-") {
            return lang
        }
    }
    return "en"
}()
let appLanguage = UserDefaults.standard.string(forKey: appLanguageKey) ?? smartDefault
if appLanguage == "system" {
    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
} else {
    UserDefaults.standard.set([appLanguage], forKey: "AppleLanguages")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // run() 전에 호출 — LSUIElement + open 조합 안정화
let delegate = AppDelegate()
app.delegate = delegate
app.run()
