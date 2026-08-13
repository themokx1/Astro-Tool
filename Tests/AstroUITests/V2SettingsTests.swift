@testable import AstroUI
import AstroApplication
import Foundation
import Testing

@MainActor
struct V2SettingsTests {
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
