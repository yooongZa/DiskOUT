//
//  LanguageRuntime.swift
//  DiskOUT
//
//  앱 생성 전 언어 선택과 설정 UI가 같은 정책을 사용하도록 하는 단일 출처.
//

import Foundation

enum AppLanguagePolicy {
    static let settingsKey = "settings.appLanguage"
    static let appleLanguagesKey = "AppleLanguages"
    static let systemSelection = "system"
    static let supportedLanguages = ["en", "ko", "ja", "zh-Hans"]

    /// 시스템 선호 언어를 우선순위대로 모두 확인해 앱이 지원하는 첫 언어를 선택한다.
    /// 하나도 지원하지 않으면 development language 인 English 로 안전하게 돌아간다.
    static func preferredSupportedLanguage(in preferredLanguages: [String]) -> String {
        for preferred in preferredLanguages {
            let normalizedPreferred = normalize(preferred)
            if let match = supportedLanguages.first(where: {
                let normalizedSupported = normalize($0)
                return normalizedPreferred == normalizedSupported
                    || normalizedPreferred.hasPrefix(normalizedSupported + "-")
            }) {
                return match
            }

            // 일부 macOS/마이그레이션 환경은 script 없이 zh-CN/zh-SG 형태를 돌려준다.
            // CN/SG/MY는 Simplified Chinese로 매핑하되 zh-TW/HK/MO는 en fallback을 유지한다.
            let components = normalizedPreferred.split(separator: "-").map(String.init)
            if components.first == "zh",
               !components.contains("hant"),
               (components.contains("hans") || !Set(components).isDisjoint(with: ["cn", "sg", "my"])) {
                return "zh-Hans"
            }
        }
        return "en"
    }

    /// 저장값은 명시적 지원 언어만 허용한다. legacy `system` 과 손상값은 제거해
    /// "키 없음 = 시스템 따라가기"라는 한 가지 표현으로 정규화한다.
    static func storedExplicitLanguage(in defaults: UserDefaults) -> String? {
        guard let object = defaults.object(forKey: settingsKey) else { return nil }
        guard let value = object as? String,
              supportedLanguages.contains(value) else {
            defaults.removeObject(forKey: settingsKey)
            return nil
        }
        return value
    }

    /// 설정 popup 용 값. 미저장/정리된 값은 실제 의미와 같은 System default 로 표시한다.
    static func settingsSelection(in defaults: UserDefaults) -> String {
        storedExplicitLanguage(in: defaults) ?? systemSelection
    }

    static func setSettingsSelection(_ selection: String, in defaults: UserDefaults) {
        if supportedLanguages.contains(selection) {
            defaults.set(selection, forKey: settingsKey)
        } else {
            // `system` 또는 UI 밖에서 들어온 잘못된 값 모두 안전한 시스템 추종으로 복귀.
            defaults.removeObject(forKey: settingsKey)
        }
    }

    /// launch 시 적용할 실제 언어. 명시 선택이 없으면 매 launch 마다 시스템 설정을 다시 따른다.
    static func effectiveLanguage(in defaults: UserDefaults,
                                  preferredLanguages: [String]) -> String {
        storedExplicitLanguage(in: defaults)
            ?? preferredSupportedLanguage(in: preferredLanguages)
    }

    /// main.swift 전용 launch 적용. 시스템 추종 상태에서는 이전 launch 가 남긴
    /// app-domain AppleLanguages 를 먼저 제거한 뒤 실제 시스템 선호 언어를 읽어야 한다.
    /// provider 를 closure 로 받는 이유는 제거보다 먼저 Locale 값이 평가되는 순서 회귀를 막기 위함이다.
    @discardableResult
    static func applyAtLaunch(in defaults: UserDefaults,
                              preferredLanguagesProvider: () -> [String]) -> String {
        let language: String
        if let explicit = storedExplicitLanguage(in: defaults) {
            language = explicit
        } else {
            defaults.removeObject(forKey: appleLanguagesKey)
            language = preferredSupportedLanguage(in: preferredLanguagesProvider())
        }
        defaults.set([language], forKey: appleLanguagesKey)
        return language
    }

    private static func normalize(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}

enum AppLanguageRelaunch {
    static let tokenArgument = "--diskout-language-relaunch-token"
    static let readyNotification = Notification.Name("com.yongza.ejectdrives.language-relaunch-ready")

    static func token(in arguments: [String]) -> String? {
        guard let argumentIndex = arguments.firstIndex(of: tokenArgument),
              arguments.indices.contains(argumentIndex + 1) else { return nil }
        let raw = arguments[argumentIndex + 1]
        guard UUID(uuidString: raw) != nil else { return nil }
        return raw
    }
}

/// ready/실패/timeout callback 순서가 뒤섞여도 현재 시도와 같은 token 만 완료시킨다.
/// AppDelegate 는 이 값을 main queue 에서만 변경한다.
struct AppLanguageRelaunchAttempt {
    private(set) var activeToken: String?

    var isInProgress: Bool { activeToken != nil }

    func isCurrent(token: String) -> Bool {
        activeToken == token
    }

    mutating func begin(token: String) -> Bool {
        guard activeToken == nil else { return false }
        activeToken = token
        return true
    }

    mutating func finishIfCurrent(token: String) -> Bool {
        guard activeToken == token else { return false }
        activeToken = nil
        return true
    }

    mutating func clear() {
        activeToken = nil
    }
}
