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
    public private(set) var selectedProjectID: UUID?
    public private(set) var selectedProject: ProjectSnapshot?
    private var searchIndex: [UUID: String] = [:]

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
            searchIndex = try await Self.makeSearchIndex(projects: projects, metadata: metadata)
            if let selectedProjectID, projects.contains(where: { $0.id == selectedProjectID }) {
                selectedProject = try await ProjectsQuery(metadata: metadata).project(id: selectedProjectID)
            } else {
                selectedProjectID = nil
                selectedProject = nil
            }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    public func search(_ term: String) async throws -> [ProjectRecord] {
        let needle = Self.normalized(term)
        guard !needle.isEmpty else { return projects }
        return projects.filter { searchIndex[$0.id, default: ""].contains(needle) }
    }

    public func selectProject(_ id: UUID?) async throws {
        selectedProjectID = id
        guard let id else {
            selectedProject = nil
            return
        }
        guard let metadata else { throw ProjectsStoreError.libraryNotOpen }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            selectedProject = try await ProjectsQuery(metadata: metadata).project(id: id)
        } catch {
            selectedProject = nil
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

    private static func makeSearchIndex(
        projects: [ProjectRecord], metadata: MetadataStore
    ) async throws -> [UUID: String] {
        var result: [UUID: String] = [:]
        for project in projects {
            let series = try await metadata.series(projectID: project.id)
            let terms = [project.catalogID, project.displayName, project.phase.rawValue]
                + series.flatMap { [$0.filterName, Optional($0.setupDescriptor)] }.compactMap { $0 }
            result[project.id] = normalized(terms.joined(separator: " "))
        }
        return result
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains)
            .map(String.init).joined().lowercased()
    }
}
