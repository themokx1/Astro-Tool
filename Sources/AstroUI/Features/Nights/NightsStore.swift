import AstroApplication
import Foundation
import Observation

public struct NightRow: Equatable, Sendable, Identifiable {
    public let snapshot: NightSnapshot
    public var id: UUID { snapshot.id }
    public var date: String { snapshot.night.localDate }
    public var seriesCount: Int { snapshot.series.count }
    public var projectSummary: String {
        snapshot.projects.map(\.catalogID).joined(separator: ", ")
    }
    public var exposureSummary: String {
        Array(Set(snapshot.series.map { Int($0.exposureSeconds.rounded()) }))
            .sorted().map { "\($0) s" }.joined(separator: ", ")
    }
    public var filterSummary: String {
        let filters = Array(Set(snapshot.series.compactMap(\.filterName))).sorted()
        return filters.isEmpty ? "No filter metadata" : filters.joined(separator: ", ")
    }
    public var integrationSummary: String {
        let minutes = Int(snapshot.integrationSeconds.rounded()) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

@MainActor
@Observable
public final class NightsStore {
    public typealias MetadataFactory = @MainActor @Sendable (URL) throws -> MetadataStore
    public private(set) var nights: [NightRow] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var selectedMonth: String?
    public private(set) var selectedNightID: UUID?
    private let metadataFactory: MetadataFactory

    public init(metadataFactory: @escaping MetadataFactory = ProjectsStore.productionMetadata) {
        self.metadataFactory = metadataFactory
    }

    public var availableMonths: [String] {
        Array(Set(nights.map { String($0.date.prefix(7)) })).sorted(by: >)
    }

    public var visibleNights: [NightRow] {
        guard let selectedMonth else { return nights }
        return nights.filter { $0.date.hasPrefix(selectedMonth) }
    }

    public var selectedNight: NightRow? {
        nights.first { $0.id == selectedNightID }
    }

    public func selectMonth(_ month: String?) {
        selectedMonth = month
        if let selectedNightID, !visibleNights.contains(where: { $0.id == selectedNightID }) {
            self.selectedNightID = nil
        }
    }

    public func selectNight(_ id: UUID?) { selectedNightID = id }

    public func open(rootURL: URL) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let metadata = try metadataFactory(rootURL.standardizedFileURL)
            nights = try await NightsQuery(metadata: metadata).nights().map(NightRow.init)
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }
}
