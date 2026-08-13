import Foundation

public struct NightSnapshot: Equatable, Sendable, Identifiable {
    public let night: NightRecord
    public let projects: [ProjectRecord]
    public let series: [SeriesRecord]
    public let totalFrames: Int
    public let usableFrames: Int
    public let integrationSeconds: Double
    public var id: UUID { night.id }
}

public struct NightsQuery: Sendable {
    private let metadata: MetadataStore

    public init(metadata: MetadataStore) {
        self.metadata = metadata
    }

    public func nights() async throws -> [NightSnapshot] {
        let projects = try await metadata.projects()
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var snapshots: [NightSnapshot] = []
        for night in try await metadata.nights() {
            let series = try await metadata.series(nightID: night.id)
            var totalFrames = 0
            var usableFrames = 0
            var integrationSeconds = 0.0
            for record in series {
                let decisions = try await metadata.frameDecisions(seriesID: record.id)
                let usable = decisions.filter { !$0.logicallyExcluded && $0.verdict != .rejected }.count
                totalFrames += decisions.count
                usableFrames += usable
                integrationSeconds += Double(usable) * record.exposureSeconds
            }
            let nightProjects = Set(series.map(\.projectID)).compactMap { projectsByID[$0] }
                .sorted { $0.catalogID < $1.catalogID }
            snapshots.append(NightSnapshot(
                night: night, projects: nightProjects, series: series,
                totalFrames: totalFrames, usableFrames: usableFrames,
                integrationSeconds: integrationSeconds
            ))
        }
        return snapshots.sorted { $0.night.localDate > $1.night.localDate }
    }
}
