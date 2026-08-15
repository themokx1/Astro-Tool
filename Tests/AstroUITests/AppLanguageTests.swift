@testable import AstroUI
import Foundation
import Testing

struct AppLanguageTests {
    private func isolatedDefaults() -> UserDefaults {
        let (defaults, _) = isolatedDefaultsWithSuiteName()
        return defaults
    }

    /// `UserDefaults`'s search list always includes `NSGlobalDomain` --
    /// standard *or* suite-based -- and `NSGlobalDomain` is exactly where
    /// macOS keeps the system's own `AppleLanguages` (the Language & Region
    /// preference order). On a machine where that list happens to be set
    /// (routine for anyone running a non-English system language), a merged
    /// read like `defaults.object(forKey:)` never actually goes `nil` after
    /// removing our own suite's value -- it just falls through to the
    /// global list underneath. `persistentDomain(forName:)` reads a single
    /// domain directly, bypassing that merge, so it is the only way to
    /// assert our own write/removal in isolation.
    private func isolatedDefaultsWithSuiteName() -> (UserDefaults, String) {
        let suite = "AstroTool-AppLanguageTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test("system, hungarian, english are the three cases")
    func threeCases() {
        #expect(AppLanguage.allCases == [.system, .hungarian, .english])
    }

    @Test(".system removes the AppleLanguages key rather than writing an empty array")
    func systemRemovesTheKey() {
        let (defaults, suite) = isolatedDefaultsWithSuiteName()
        // Seed a prior override so we can prove `.system` actually clears it,
        // rather than merely never having written anything.
        defaults.set(["hu"], forKey: "AppleLanguages")
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] != nil)

        AppLanguage.system.apply(to: defaults)

        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
    }

    @Test(".hungarian writes [\"hu\"] to the AppleLanguages key")
    func hungarianWritesHu() {
        let defaults = isolatedDefaults()

        AppLanguage.hungarian.apply(to: defaults)

        #expect(defaults.array(forKey: "AppleLanguages") as? [String] == ["hu"])
    }

    @Test(".english writes [\"en\"] to the AppleLanguages key")
    func englishWritesEn() {
        let defaults = isolatedDefaults()

        AppLanguage.english.apply(to: defaults)

        #expect(defaults.array(forKey: "AppleLanguages") as? [String] == ["en"])
    }

    @Test("current(defaults:) reads back a saved override")
    func currentReadsBackHungarian() {
        let defaults = isolatedDefaults()
        AppLanguage.hungarian.apply(to: defaults)

        #expect(AppLanguage.current(defaults: defaults) == .hungarian)
    }

    @Test("current(defaults:) reads back english")
    func currentReadsBackEnglish() {
        let defaults = isolatedDefaults()
        AppLanguage.english.apply(to: defaults)

        #expect(AppLanguage.current(defaults: defaults) == .english)
    }

    @Test("current(defaults:) is .system when nothing has been saved")
    func currentDefaultsToSystemWhenUnset() {
        let defaults = isolatedDefaults()

        #expect(AppLanguage.current(defaults: defaults) == .system)
    }

    @Test("current(defaults:) is .system again after applying .system over a prior override")
    func currentRoundTripsBackToSystem() {
        let defaults = isolatedDefaults()
        AppLanguage.hungarian.apply(to: defaults)
        #expect(AppLanguage.current(defaults: defaults) == .hungarian)

        AppLanguage.system.apply(to: defaults)

        #expect(AppLanguage.current(defaults: defaults) == .system)
    }
}
