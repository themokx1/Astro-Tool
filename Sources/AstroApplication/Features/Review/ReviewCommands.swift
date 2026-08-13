import AstroCore
import Foundation

public enum ReviewArchiveMode: String, Equatable, Sendable {
    case archive
    case restore
}

public struct ReviewArchivePlan: Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceRelative: String
    public let destinationRelative: String
    public let mode: ReviewArchiveMode

    public init(sourceRelative: String, destinationRelative: String, mode: ReviewArchiveMode) {
        self.id = "\(mode.rawValue)|\(sourceRelative)|\(destinationRelative)"
        self.sourceRelative = sourceRelative
        self.destinationRelative = destinationRelative
        self.mode = mode
    }
}

public struct ReviewCommands: Sendable {
    private let metadata: MetadataStore

    public init(metadata: MetadataStore) {
        self.metadata = metadata
    }

    public func archivePlan(relativePath: String) throws -> ReviewArchivePlan {
        let plan = try FrameArchivePlanner.plan(sourceRelative: relativePath, mode: .archive)
        return ReviewArchivePlan(
            sourceRelative: plan.sourceRelative,
            destinationRelative: plan.destinationRelative,
            mode: .archive
        )
    }

    @discardableResult
    public func setVerdict(
        seriesID: UUID,
        relativePath: String,
        verdict: FrameVerdict
    ) async throws -> FrameDecisionRecord {
        let existing = try await metadata.frameDecisions(seriesID: seriesID)
            .first { $0.relativePath == relativePath }
        let record = FrameDecisionRecord(
            id: existing?.id ?? UUID(),
            seriesID: seriesID,
            relativePath: relativePath,
            verdict: verdict,
            logicallyExcluded: verdict == .rejected
        )
        try await metadata.save(record)
        return record
    }

    @discardableResult
    public func setVerdict(
        seriesID: UUID,
        relativePaths: [String],
        verdict: FrameVerdict
    ) async throws -> [FrameDecisionRecord] {
        let existing = Dictionary(
            uniqueKeysWithValues: try await metadata.frameDecisions(seriesID: seriesID)
                .map { ($0.relativePath, $0) }
        )
        let records = relativePaths.map { path in
            FrameDecisionRecord(
                id: existing[path]?.id ?? UUID(),
                seriesID: seriesID,
                relativePath: path,
                verdict: verdict,
                logicallyExcluded: verdict == .rejected
            )
        }
        try await metadata.save(MetadataWriteBatch(frameDecisions: records))
        return records
    }
}
