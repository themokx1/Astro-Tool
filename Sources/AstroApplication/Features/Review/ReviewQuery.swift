import Foundation

public struct ReviewSeriesSnapshot: Equatable, Sendable, Identifiable {
    public let series: SeriesRecord
    public let decisions: [FrameDecisionRecord]
    public var id: UUID { series.id }
    public var acceptedCount: Int { decisions.count { $0.verdict == .accepted } }
    public var rejectedCount: Int { decisions.count { $0.verdict == .rejected } }
    public var undecidedCount: Int { decisions.count { $0.verdict == .undecided } }
}

public struct ReviewProjectSnapshot: Equatable, Sendable, Identifiable {
    public let project: ProjectRecord
    public let series: [ReviewSeriesSnapshot]
    public var id: UUID { project.id }
}

public enum ReviewQueryError: Error, Equatable, Sendable {
    case projectNotFound
}

public struct ReviewQuery: Sendable {
    private let metadata: MetadataStore

    public init(metadata: MetadataStore) {
        self.metadata = metadata
    }

    public func project(_ id: UUID) async throws -> ReviewProjectSnapshot {
        guard let project = try await metadata.project(id: id) else {
            throw ReviewQueryError.projectNotFound
        }
        var snapshots: [ReviewSeriesSnapshot] = []
        for series in try await metadata.series(projectID: id) {
            snapshots.append(ReviewSeriesSnapshot(
                series: series,
                decisions: try await metadata.frameDecisions(seriesID: series.id)
            ))
        }
        snapshots.sort { lhs, rhs in
            if lhs.series.exposureSeconds != rhs.series.exposureSeconds {
                return lhs.series.exposureSeconds < rhs.series.exposureSeconds
            }
            return lhs.series.id.uuidString < rhs.series.id.uuidString
        }
        return ReviewProjectSnapshot(project: project, series: snapshots)
    }
}
