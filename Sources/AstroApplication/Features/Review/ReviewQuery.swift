import Foundation

public struct ReviewSeriesSnapshot: Equatable, Sendable, Identifiable {
    public let series: SeriesRecord
    public let decisions: [FrameDecisionRecord]
    /// The night this series belongs to (`NightRecord.localDate`), e.g.
    /// `"2026-08-08"` -- lets a project spanning many nights filter its
    /// series list down to one session without a second round trip per
    /// series. `"Unknown"` only for the structurally-impossible case of a
    /// `nightID` with no matching `NightRecord` on record at all.
    public let nightLocalDate: String
    public var id: UUID { series.id }
    public var acceptedCount: Int { decisions.count { $0.verdict == .accepted } }
    public var rejectedCount: Int { decisions.count { $0.verdict == .rejected } }
    public var undecidedCount: Int { decisions.count { $0.verdict == .undecided } }

    public init(series: SeriesRecord, decisions: [FrameDecisionRecord], nightLocalDate: String) {
        self.series = series
        self.decisions = decisions
        self.nightLocalDate = nightLocalDate
    }
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
        // One `night(id:)` lookup per distinct night, not per series -- a
        // project's series routinely share the same night (same setup shot
        // across several exposure times in one sitting).
        var nightDatesByID: [UUID: String] = [:]
        for series in try await metadata.series(projectID: id) {
            let nightLocalDate: String
            if let cached = nightDatesByID[series.nightID] {
                nightLocalDate = cached
            } else {
                nightLocalDate = try await metadata.night(id: series.nightID)?.localDate ?? "Unknown"
                nightDatesByID[series.nightID] = nightLocalDate
            }
            snapshots.append(ReviewSeriesSnapshot(
                series: series,
                decisions: try await metadata.frameDecisions(seriesID: series.id),
                nightLocalDate: nightLocalDate
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
