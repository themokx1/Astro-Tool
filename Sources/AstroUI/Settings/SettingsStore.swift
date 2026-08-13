import Foundation
import Observation

public enum EquipmentFilterPassband: String, Codable, CaseIterable, Sendable {
    case broadband
    case dualBand = "dual_band"
    case narrowband
    case unknown

    public var title: String {
        switch self {
        case .broadband: "Broadband"
        case .dualBand: "Dual-band"
        case .narrowband: "Narrowband"
        case .unknown: "Not specified"
        }
    }
}

public struct EquipmentFilter: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let manufacturer: String
    public let model: String
    public let passband: EquipmentFilterPassband
}

public enum SettingsStoreError: LocalizedError, Equatable {
    case incompleteFilter
    case duplicateFilter

    public var errorDescription: String? {
        switch self {
        case .incompleteFilter: "Enter at least a manufacturer or model."
        case .duplicateFilter: "This filter is already in your equipment list."
        }
    }
}

@MainActor
@Observable
public final class SettingsStore {
    public private(set) var filters: [EquipmentFilter]
    private let defaults: UserDefaults
    private static let filtersKey = "v2.equipment.filters"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        filters = defaults.data(forKey: Self.filtersKey)
            .flatMap { try? JSONDecoder().decode([EquipmentFilter].self, from: $0) } ?? []
    }

    @discardableResult
    public func createFilter(
        manufacturer: String,
        model: String,
        passband: EquipmentFilterPassband
    ) throws -> EquipmentFilter {
        let manufacturer = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !manufacturer.isEmpty || !model.isEmpty else { throw SettingsStoreError.incompleteFilter }
        let identity = "\(manufacturer)|\(model)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !filters.contains(where: {
            "\($0.manufacturer)|\($0.model)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == identity
        }) else { throw SettingsStoreError.duplicateFilter }
        let filter = EquipmentFilter(id: UUID(), manufacturer: manufacturer, model: model, passband: passband)
        filters.append(filter)
        persist()
        return filter
    }

    public func removeFilter(id: UUID) {
        filters.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(filters), forKey: Self.filtersKey)
    }
}

@MainActor
public struct SeriesFilterChoices {
    private let settings: SettingsStore
    public init(settings: SettingsStore) { self.settings = settings }
    public var filters: [EquipmentFilter] { settings.filters }
}
