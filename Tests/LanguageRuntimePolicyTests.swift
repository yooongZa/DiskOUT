import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum LanguageRuntimePolicyTests {
    static func main() {
        expect(AppLanguagePolicy.preferredSupportedLanguage(in: ["ko-KR"]) == "ko", "normal supported preference")
        expect(AppLanguagePolicy.preferredSupportedLanguage(in: ["fr-FR", "ko-KR"]) == "ko", "second supported preference")
        expect(AppLanguagePolicy.preferredSupportedLanguage(in: ["fr-FR", "es-ES"]) == "en", "unsupported fallback")
        expect(AppLanguagePolicy.preferredSupportedLanguage(in: ["zh_Hans_CN"]) == "zh-Hans", "normalized identifier")
        expect(AppLanguagePolicy.preferredSupportedLanguage(in: ["zh-CN"]) == "zh-Hans", "China region implies Simplified Chinese")
        expect(AppLanguagePolicy.preferredSupportedLanguage(in: ["zh_SG"]) == "zh-Hans", "Singapore region implies Simplified Chinese")
        expect(AppLanguagePolicy.preferredSupportedLanguage(in: ["zh-TW"]) == "en", "Traditional Chinese is not mislabeled as Simplified")

        let suite = "com.yongza.diskout.language-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        expect(AppLanguagePolicy.settingsSelection(in: defaults) == "system", "missing value displays system")
        expect(AppLanguagePolicy.effectiveLanguage(in: defaults, preferredLanguages: ["fr", "ja-JP"]) == "ja", "missing value follows system")

        defaults.set(["en"], forKey: AppLanguagePolicy.appleLanguagesKey)
        var staleOverrideWasRemoved = false
        let launchLanguage = AppLanguagePolicy.applyAtLaunch(in: defaults) {
            staleOverrideWasRemoved = defaults.persistentDomain(forName: suite)?[AppLanguagePolicy.appleLanguagesKey] == nil
            return ["fr-FR", "ko-KR"]
        }
        expect(staleOverrideWasRemoved, "system preferences read after stale AppleLanguages removal")
        expect(launchLanguage == "ko", "launch uses first supported system language")
        expect((defaults.array(forKey: AppLanguagePolicy.appleLanguagesKey) as? [String]) == ["ko"], "launch applies selected language")

        AppLanguagePolicy.setSettingsSelection("ko", in: defaults)
        expect(AppLanguagePolicy.settingsSelection(in: defaults) == "ko", "explicit selection preserved")
        expect(AppLanguagePolicy.effectiveLanguage(in: defaults, preferredLanguages: ["ja"]) == "ko", "explicit selection overrides system")
        var explicitLanguageReadSystem = false
        expect(AppLanguagePolicy.applyAtLaunch(in: defaults) {
            explicitLanguageReadSystem = true
            return ["ja"]
        } == "ko", "launch preserves explicit selection")
        expect(!explicitLanguageReadSystem, "explicit launch does not consult system preferences")

        defaults.set("broken", forKey: AppLanguagePolicy.settingsKey)
        expect(AppLanguagePolicy.settingsSelection(in: defaults) == "system", "corrupt string falls back to system")
        expect(defaults.object(forKey: AppLanguagePolicy.settingsKey) == nil, "corrupt string removed")

        defaults.set(42, forKey: AppLanguagePolicy.settingsKey)
        expect(AppLanguagePolicy.settingsSelection(in: defaults) == "system", "corrupt type falls back to system")
        expect(defaults.object(forKey: AppLanguagePolicy.settingsKey) == nil, "corrupt type removed")

        defaults.set("system", forKey: AppLanguagePolicy.settingsKey)
        expect(AppLanguagePolicy.settingsSelection(in: defaults) == "system", "legacy system remains system behavior")
        expect(defaults.object(forKey: AppLanguagePolicy.settingsKey) == nil, "legacy system normalized to missing")

        AppLanguagePolicy.setSettingsSelection("en", in: defaults)
        AppLanguagePolicy.setSettingsSelection("system", in: defaults)
        expect(defaults.object(forKey: AppLanguagePolicy.settingsKey) == nil, "system selection clears explicit value")

        let token = UUID().uuidString
        expect(AppLanguageRelaunch.token(in: ["DiskOUT", AppLanguageRelaunch.tokenArgument, token]) == token, "valid relaunch token")
        expect(AppLanguageRelaunch.token(in: ["DiskOUT", AppLanguageRelaunch.tokenArgument, "bad"]) == nil, "invalid relaunch token rejected")

        var attempt = AppLanguageRelaunchAttempt()
        expect(attempt.begin(token: "current"), "first restart begins")
        expect(!attempt.begin(token: "duplicate"), "duplicate restart rejected")
        expect(!attempt.finishIfCurrent(token: "stale"), "stale callback ignored")
        expect(attempt.isInProgress, "stale callback keeps current attempt")
        expect(attempt.finishIfCurrent(token: "current"), "current ready/failure completes")
        expect(!attempt.isInProgress, "completion clears attempt for retry")
        expect(!attempt.finishIfCurrent(token: "current"), "late ready after timeout/failure is ignored")
        expect(attempt.begin(token: "retry"), "retry can begin")
        expect(!attempt.isCurrent(token: "current"), "late launch cannot attach to retry")
        expect(attempt.isCurrent(token: "retry"), "retry remains current")

        print("LanguageRuntimePolicyTests: PASS")
    }
}
