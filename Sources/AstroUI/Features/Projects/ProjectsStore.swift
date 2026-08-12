import AstroApplication
import Foundation
import Observation

public enum ProjectsStoreError: LocalizedError, Equatable {
    case libraryNotOpen

    public var errorDescription: String? {
        "Open an image library before creating a project."
    }
}

@MainActor
@Observable
public final class ProjectsStore {
    public typealias MetadataFactory = @MainActor @Sendable (URL) throws -> MetadataStore

    public private(set) var projects: [ProjectRecord] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var rootURL: URL?

    private let metadataFactory: MetadataFactory
    private var metadata: MetadataStore?

    public init(metadataFactory: @escaping MetadataFactory = ProjectsStore.productionMetadata) {
        self.metadataFactory = metadataFactory
    }

    public func open(rootURL: URL) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let metadata = try metadataFactory(rootURL.standardizedFileURL)
            self.metadata = metadata
            self.rootURL = rootURL.standardizedFileURL
            projects = try await metadata.projects()
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    public func createProject(from match: ProjectCatalogMatch) async throws -> ProjectRecord {
        guard let metadata else { throw ProjectsStoreError.libraryNotOpen }
        if let existing = projects.first(where: { $0.catalogID == match.catalogID }) {
            return existing
        }
        let project = ProjectRecord(
            id: UUID(),
            catalogID: match.catalogID,
            displayName: match.displayName,
            phase: .planned
        )
        do {
            try await metadata.save(project)
            projects = try await metadata.projects()
            errorMessage = nil
            return project
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    public static func productionMetadata(rootURL: URL) throws -> MetadataStore {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(
            libraryID: identity,
            libraryRoot: rootURL
        )
        return try MetadataStore(storagePaths: storage)
    }

    public static func previewMetadata(rootURL: URL) throws -> MetadataStore {
        try MetadataStore.temporary()
    }
}
