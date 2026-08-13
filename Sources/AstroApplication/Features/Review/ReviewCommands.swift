import Foundation

public struct ReviewCommands: Sendable {
    private let metadata: MetadataStore

    public init(metadata: MetadataStore) {
        self.metadata = metadata
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
}
