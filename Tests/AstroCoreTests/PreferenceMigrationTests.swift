import Foundation
import Testing
@testable import AstroCore

@Suite("PreferenceMigration") struct PreferenceMigrationTests {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func defaults(_ suffix: String) -> UserDefaults {
        let name = "io.github.themokx1.AstroTool.tests.\(suffix).\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test func copiesOnlyAllowlistedValuesAndMarksCompletion() {
        let target = defaults("allowlist")
        let bookmark = Data([1, 2, 3])
        let result = PreferenceMigration.migrate(
            legacyValues: [
                "rootBookmark": bookmark,
                "autoScanOnMount": true,
                "secretToken": "must-not-migrate",
            ],
            into: target,
            allowedKeys: ["rootBookmark", "autoScanOnMount"],
            markerKey: "legacyMigrationComplete"
        )

        #expect(result.copiedKeys == ["autoScanOnMount", "rootBookmark"])
        #expect(target.data(forKey: "rootBookmark") == bookmark)
        #expect(target.bool(forKey: "autoScanOnMount"))
        #expect(target.object(forKey: "secretToken") == nil)
        #expect(target.bool(forKey: "legacyMigrationComplete"))
    }

    @Test func neverOverwritesCurrentValues() {
        let target = defaults("preserve")
        target.set("new", forKey: "selectedSiteName")

        let result = PreferenceMigration.migrate(
            legacyValues: ["selectedSiteName": "old"],
            into: target,
            allowedKeys: ["selectedSiteName"],
            markerKey: "done"
        )

        #expect(result.copiedKeys.isEmpty)
        #expect(result.preservedKeys == ["selectedSiteName"])
        #expect(target.string(forKey: "selectedSiteName") == "new")
    }

    @Test func migrationIsIdempotentAndDoesNotMutateTheSource() {
        let target = defaults("idempotent")
        let source: [String: Any] = ["rootBookmark": Data([9, 8, 7])]

        let first = PreferenceMigration.migrate(
            legacyValues: source,
            into: target,
            allowedKeys: ["rootBookmark"],
            markerKey: "done"
        )
        target.set(Data([4, 5, 6]), forKey: "rootBookmark")
        let second = PreferenceMigration.migrate(
            legacyValues: source,
            into: target,
            allowedKeys: ["rootBookmark"],
            markerKey: "done"
        )

        #expect(first.copiedKeys == ["rootBookmark"])
        #expect(second.alreadyCompleted)
        #expect(second.copiedKeys.isEmpty)
        #expect(target.data(forKey: "rootBookmark") == Data([4, 5, 6]))
        #expect(source["rootBookmark"] as? Data == Data([9, 8, 7]))
    }

    @Test func ignoresValuesThatCannotBeStoredInUserDefaults() {
        let target = defaults("invalid")
        let result = PreferenceMigration.migrate(
            legacyValues: ["rootBookmark": URL(fileURLWithPath: "/private/tmp/example")],
            into: target,
            allowedKeys: ["rootBookmark"],
            markerKey: "done"
        )

        #expect(result.copiedKeys.isEmpty)
        #expect(result.rejectedKeys == ["rootBookmark"])
        #expect(target.object(forKey: "rootBookmark") == nil)
    }

    @Test func appStartupMigratesBeforeResolvingAndHasAnExplicitNoRootState() throws {
        let appState = try source("Sources/AstroToolApp/AppState.swift")

        #expect(appState.contains("Self.migrateLegacyPreferences(into: resolvedPreferences)"))
        #expect(appState.contains("ProductInfo.legacyBundleIdentifier"))
        #expect(appState.contains("rootStatus = .noRoot"))
        #expect(!appState.contains("openRoot(at: URL(fileURLWithPath: AstroConfig().rootPath"))
        #expect(!appState.contains("UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)"))
    }
}
