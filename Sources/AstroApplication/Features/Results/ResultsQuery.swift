import Foundation

public struct ResultLineageSnapshot: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let parentResultID: UUID?
    public let kind: ResultKind
    public let role: ResultRole
    public let relativePath: String?
    public let createdAt: Date
    public let softwareName: String?
    public let softwareVersion: String?
    public let inputSeriesIDs: [UUID]
    public let sourceFrameIDs: [UUID]
    public let sourceResultIDs: [UUID]
    public let calibrationAssets: [String]
}

public struct ResultsSnapshot: Equatable, Sendable {
    public let projectID: UUID
    public let results: [ResultLineageSnapshot]
    public let publishableResultID: UUID?
}

/// A library-wide (cross-project) searchable projection of one result,
/// naming the project it belongs to so callers -- notably global search --
/// don't need a project already selected to find or route to it.
public struct ResultSearchEntry: Equatable, Sendable, Identifiable {
    public var id: UUID { resultID }
    public let resultID: UUID
    public let projectID: UUID
    public let projectName: String
    public let kind: ResultKind
    public let role: ResultRole
    public let relativePath: String?
    public let softwareName: String?
    public let softwareVersion: String?
    public let createdAt: Date

    public init(
        resultID: UUID,
        projectID: UUID,
        projectName: String,
        kind: ResultKind,
        role: ResultRole,
        relativePath: String?,
        softwareName: String?,
        softwareVersion: String?,
        createdAt: Date
    ) {
        self.resultID = resultID
        self.projectID = projectID
        self.projectName = projectName
        self.kind = kind
        self.role = role
        self.relativePath = relativePath
        self.softwareName = softwareName
        self.softwareVersion = softwareVersion
        self.createdAt = createdAt
    }
}

public struct ResultsQuery: Sendable {
    private let metadata: MetadataStore?
    private let fixtureSnapshot: ResultsSnapshot?

    public init(metadata: MetadataStore) {
        self.metadata = metadata
        fixtureSnapshot = nil
    }

    private init(fixtureSnapshot: ResultsSnapshot) {
        metadata = nil
        self.fixtureSnapshot = fixtureSnapshot
    }

    public static func fixture() -> Self {
        let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000801")!
        let seriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000802")!
        let stackID = UUID(uuidString: "00000000-0000-0000-0000-000000000803")!
        let finalID = UUID(uuidString: "00000000-0000-0000-0000-000000000804")!
        let created = Date(timeIntervalSince1970: 1_786_147_200)
        return Self(fixtureSnapshot: .init(projectID: projectID, results: [
            .init(
                id: stackID, parentResultID: nil, kind: .stack, role: .intermediate,
                relativePath: "stacks/IC_1396/master.fit", createdAt: created,
                softwareName: "Siril", softwareVersion: "1.4",
                inputSeriesIDs: [seriesID], sourceFrameIDs: [], sourceResultIDs: [],
                calibrationAssets: ["master-dark-300s", "master-flat-SV220"]
            ),
            .init(
                id: finalID, parentResultID: stackID, kind: .processingVariant, role: .final,
                relativePath: "processed/IC_1396/final.fit", createdAt: created.addingTimeInterval(3600),
                softwareName: "PixInsight", softwareVersion: "1.9",
                inputSeriesIDs: [seriesID], sourceFrameIDs: [], sourceResultIDs: [stackID],
                calibrationAssets: ["master-dark-300s", "master-flat-SV220"]
            ),
        ], publishableResultID: finalID))
    }

    public func snapshot(projectID: UUID) async throws -> ResultsSnapshot {
        if let fixtureSnapshot { return fixtureSnapshot }
        guard let metadata else { return .init(projectID: projectID, results: [], publishableResultID: nil) }
        let records = try await metadata.results(projectID: projectID)
        var details: [ResultLineageSnapshot] = []
        for record in records {
            let edges = try await metadata.lineageEdges(resultID: record.id)
            details.append(.init(
                id: record.id, parentResultID: record.parentResultID, kind: record.kind,
                role: record.role, relativePath: record.relativePath, createdAt: record.createdAt,
                softwareName: record.softwareName, softwareVersion: record.softwareVersion,
                inputSeriesIDs: edges.filter { $0.sourceKind == .series }.map(\.sourceID),
                sourceFrameIDs: edges.filter { $0.sourceKind == .frame }.map(\.sourceID),
                sourceResultIDs: edges.filter { $0.sourceKind == .result }.map(\.sourceID),
                calibrationAssets: []
            ))
        }
        let publishable = details.filter { $0.role == .final }.max { $0.createdAt < $1.createdAt }?.id
        return .init(projectID: projectID, results: details, publishableResultID: publishable)
    }

    /// Every result across every project, for library-wide search. Fixture
    /// instances (used by previews) have no metadata store and report no
    /// entries; production instances join through `MetadataStore.allResults()`.
    public func librarySearchEntries() async throws -> [ResultSearchEntry] {
        guard let metadata else { return [] }
        return try await metadata.allResults().map { summary in
            ResultSearchEntry(
                resultID: summary.result.id,
                projectID: summary.result.projectID,
                projectName: summary.projectName,
                kind: summary.result.kind,
                role: summary.result.role,
                relativePath: summary.result.relativePath,
                softwareName: summary.result.softwareName,
                softwareVersion: summary.result.softwareVersion,
                createdAt: summary.result.createdAt
            )
        }
    }
}
