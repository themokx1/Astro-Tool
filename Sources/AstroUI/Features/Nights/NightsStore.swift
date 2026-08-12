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
}

@MainActor
@Observable
public final class NightsStore {
    public typealias MetadataFactory = @MainActor @Sendable (URL) throws -> MetadataStore
    public private(set) var nights: [NightRow] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    private let metadataFactory: MetadataFactory

    public init(metadataFactory: @escaping MetadataFactory = ProjectsStore.productionMetadata) {
        self.metadataFactory = metadataFactory
    }

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
