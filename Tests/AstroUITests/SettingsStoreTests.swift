@testable import AstroUI
import Foundation
import Testing

@MainActor
@Suite("V2 Settings store")
struct SettingsStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("Filters default to manufacturer/model ascending and re-sort on demand")
    func sortsFiltersByColumn() throws {
        let store = SettingsStore(defaults: makeDefaults())
        try store.createFilter(manufacturer: "ZWO", model: "Duo-Band", passband: .dualBand)
        try store.createFilter(manufacturer: "Antlia", model: "Triband", passband: .narrowband)

        // V2 UI/UX audit (2026-08-14) systemic pattern S7: the filters
        // table's header used to look clickable and do nothing. Default is
        // manufacturer then model, both ascending.
        #expect(store.filters.map(\.manufacturer) == ["Antlia", "ZWO"])

        store.setSortOrder([KeyPathComparator(\EquipmentFilter.manufacturer, order: .reverse)])

        #expect(store.filters.map(\.manufacturer) == ["ZWO", "Antlia"])
    }
}
