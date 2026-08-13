import AstroApplication
import Foundation
import Observation

public enum ReviewStoreError: LocalizedError, Equatable {
    case reviewNotOpen
    case seriesNotSelected

    public var errorDescription: String? {
        switch self {
        case .reviewNotOpen: "Open a project before reviewing its frames."
        case .seriesNotSelected: "Select a capture series first."
        }
    }
}

@MainActor
@Observable
public final class ReviewStore {
    public typealias MetadataFactory = ProjectsStore.MetadataFactory

    public private(set) var snapshot: ReviewProjectSnapshot?
    public private(set) var selectedSeriesID: UUID?
    public private(set) var isLoading = false
    public private(set) var isApplyingDecision = false
    public private(set) var errorMessage: String?

    public var selectedSeries: ReviewSeriesSnapshot? {
        guard let selectedSeriesID else { return nil }
        return snapshot?.series.first { $0.id == selectedSeriesID }
    }

    private let metadataFactory: MetadataFactory
    private var metadata: MetadataStore?
    private var projectID: UUID?

    public init(metadataFactory: @escaping MetadataFactory = ProjectsStore.productionMetadata) {
        self.metadataFactory = metadataFactory
    }

    public func open(rootURL: URL, projectID: UUID) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let metadata = try metadataFactory(rootURL.standardizedFileURL)
            self.metadata = metadata
            self.projectID = projectID
            let loaded = try await ReviewQuery(metadata: metadata).project(projectID)
            snapshot = loaded
            if selectedSeriesID == nil || !loaded.series.contains(where: { $0.id == selectedSeriesID }) {
                selectedSeriesID = loaded.series.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    public func selectSeries(_ id: UUID) {
        guard snapshot?.series.contains(where: { $0.id == id }) == true else { return }
        selectedSeriesID = id
    }

    public func setVerdict(
        relativePaths: [String],
        verdict: FrameVerdict
    ) async throws {
        guard let metadata, let projectID else { throw ReviewStoreError.reviewNotOpen }
        guard let selectedSeriesID else { throw ReviewStoreError.seriesNotSelected }
        guard !relativePaths.isEmpty else { return }
        isApplyingDecision = true
        errorMessage = nil
        defer { isApplyingDecision = false }
        do {
            _ = try await ReviewCommands(metadata: metadata).setVerdict(
                seriesID: selectedSeriesID,
                relativePaths: relativePaths,
                verdict: verdict
            )
            snapshot = try await ReviewQuery(metadata: metadata).project(projectID)
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    public func archivePlan(for decision: FrameDecisionRecord) throws -> ReviewArchivePlan {
        guard let metadata else { throw ReviewStoreError.reviewNotOpen }
        return try ReviewCommands(metadata: metadata).archivePlan(relativePath: decision.relativePath)
    }
}
