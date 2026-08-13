@testable import AstroUI
import AstroApplication
import Foundation
import Testing

@MainActor
struct V2SettingsTests {
    @Test("V2 support can preview and copy privacy-safe diagnostics")
    func supportDiagnosticsSurface() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Settings/V2SettingsView.swift"))
        #expect(source.contains("SupportDiagnostics"))
        #expect(source.contains("Generate Diagnostics"))
        #expect(source.contains("Copy Diagnostics"))
        #expect(source.contains("NSPasteboard.general"))
        #expect(source.contains("v2.settings.diagnostics"))
    }

    @Test("The Planning tab discloses that its preferences are not yet wired to planning calculations")
    func planningPreferencesDiscloseTheyAreNotApplied() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Settings/V2SettingsView.swift"))
        #expect(source.contains("Not yet applied to planning calculations"))
    }

    @Test("A filter created in settings is immediately available to inline selectors")
    func sharedFilterInventory() throws {
        let suite = "AstroTool-V2SettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)

        let filter = try store.createFilter(manufacturer: "SVBONY", model: "SV220", passband: .dualBand)

        #expect(store.filters == [filter])
        #expect(SettingsStore(defaults: defaults).filters == [filter])
        #expect(SeriesFilterChoices(settings: store).filters.contains(filter))
    }

    @Test("Blank or duplicate filters are rejected without changing inventory")
    func filterValidation() throws {
        let suite = "AstroTool-V2SettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        _ = try store.createFilter(manufacturer: "SVBONY", model: "SV220", passband: .dualBand)

        #expect(throws: SettingsStoreError.self) { try store.createFilter(manufacturer: "", model: "", passband: .unknown) }
        #expect(throws: SettingsStoreError.self) { try store.createFilter(manufacturer: "svbony", model: "sv220", passband: .dualBand) }
        #expect(store.filters.count == 1)
    }
}
