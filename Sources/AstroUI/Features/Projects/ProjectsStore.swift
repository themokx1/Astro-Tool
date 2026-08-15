import AstroApplication
import Foundation
import Observation

public enum ProjectsStoreError: LocalizedError, Equatable {
    case libraryNotOpen

    public var errorDescription: String? {
        "Open an image library before creating a project."
    }
}

public struct ProjectWorkspaceRow: Identifiable, Equatable, Sendable {
    public let project: ProjectRecord
    public let nightCount: Int
    public let integrationSeconds: Double
    public let usableFrames: Int
    public let excludedFrames: Int
    public let latestNight: String?
    public let nextAction: String
    public var id: UUID { project.id }
    /// `KeyPathComparator` needs a non-optional `Comparable` value --
    /// `latestNight` is `nil` for a project with no nights yet, which
    /// sorts first (as the "oldest") rather than crashing the column's sort.
    public var latestNightSortKey: String { latestNight ?? "" }
}

@MainActor
@Observable
public final class ProjectsStore {
    public typealias MetadataFactory = @MainActor @Sendable (URL) throws -> MetadataStore

    public private(set) var projects: [ProjectRecord] = []
    /// V2 UI/UX audit (2026-08-14) systemic pattern S7: the Projects
    /// table's header used to look clickable and do nothing. Default is
    /// project name ascending.
    public private(set) var sortOrder: [KeyPathComparator<ProjectWorkspaceRow>] = [
        KeyPathComparator(\ProjectWorkspaceRow.project.displayName, order: .forward)
    ]
    public private(set) var workspaceRows: [ProjectWorkspaceRow] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var rootURL: URL?
    public private(set) var selectedProjectID: UUID?
    public private(set) var selectedProject: ProjectSnapshot?
    public private(set) var selectedProjectAnnotation: ProjectAnnotationRecord?
    private var searchIndex: [UUID: String] = [:]

    private let metadataFactory: MetadataFactory
    private var metadata: MetadataStore?
    /// Wave 4 navigation-rework code-review fix: bumped at the start of
    /// EVERY `selectProject` call and captured into that call's own local
    /// `generation` -- if a later call has since bumped this past that
    /// captured value by the time this call's `await`ed queries return, this
    /// call's own completion is stale and must not overwrite whatever the
    /// later call already wrote. Guards against the "triple concurrent
    /// selectProject per project open" race: several push sites used to each
    /// fire their own proactive `selectProject` alongside the pushed
    /// destination's own recovery task, so on a fast A -> B re-navigation
    /// whichever call's queries happened to finish LAST won, regardless of
    /// which project was actually opened last.
    private var selectionGeneration = 0
    /// Test-only hook: when set, `selectProject` awaits this closure (keyed
    /// by the id about to be loaded) right before running its metadata
    /// queries -- lets `ProjectsStoreTests` deterministically pause one
    /// call's completion behind another's to exercise the generation guard
    /// above without needing a genuinely slow query. `nil` (the default, and
    /// the only value ever set in production) is a complete no-op.
    var testOnlySelectionDelay: ((UUID) async -> Void)?
    /// Exposes the already-open store for the current root so other V2
    /// surfaces (Settings' Support tab diagnostics) can query it directly
    /// instead of opening a second confined connection to the same
    /// metadata database -- `MetadataStore`'s confined-open path is meant
    /// to have a single owner at a time.
    public var metadataStore: MetadataStore? { metadata }

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
            workspaceRows = try await Self.makeWorkspaceRows(projects: projects, metadata: metadata)
            sortWorkspaceRows()
            searchIndex = try await Self.makeSearchIndex(projects: projects, metadata: metadata)
            if let selectedProjectID, projects.contains(where: { $0.id == selectedProjectID }) {
                selectedProject = try await ProjectsQuery(metadata: metadata).project(id: selectedProjectID)
                selectedProjectAnnotation = try await metadata.projectAnnotation(projectID: selectedProjectID)
            } else {
                selectedProjectID = nil
                selectedProject = nil
                selectedProjectAnnotation = nil
            }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    public func setSortOrder(_ newValue: [KeyPathComparator<ProjectWorkspaceRow>]) {
        guard newValue != sortOrder else { return }
        sortOrder = newValue
        sortWorkspaceRows()
    }

    private func sortWorkspaceRows() {
        guard !sortOrder.isEmpty else { return }
        workspaceRows.sort(using: sortOrder)
    }

    public func search(_ term: String) async throws -> [ProjectRecord] {
        let needle = Self.normalized(term)
        guard !needle.isEmpty else { return projects }
        return projects.filter { searchIndex[$0.id, default: ""].contains(needle) }
    }

    public func projectSnapshot(id: UUID) async throws -> ProjectSnapshot? {
        guard let metadata else { throw ProjectsStoreError.libraryNotOpen }
        return try await ProjectsQuery(metadata: metadata).project(id: id)
    }

    public func selectProject(_ id: UUID?) async throws {
        guard let id else {
            selectedProjectID = nil
            selectedProject = nil
            selectedProjectAnnotation = nil
            return
        }
        guard let metadata else { throw ProjectsStoreError.libraryNotOpen }
        selectionGeneration += 1
        let generation = selectionGeneration
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        if let testOnlySelectionDelay { await testOnlySelectionDelay(id) }
        do {
            // Wave 4 Task 1 data-bug fix: both queries are `await`ed into
            // locals FIRST, then `selectedProjectID`/`selectedProject`/
            // `selectedProjectAnnotation` are all assigned back-to-back with
            // no `await` between them. The previous version assigned
            // `selectedProject` and then `await`ed the annotation query
            // separately -- a suspension point sat between the two writes,
            // so a view reading both `@Observable` properties (like
            // `ProjectWorkspaceView`) could observe the new project's
            // snapshot alongside the PREVIOUS project's (or no) annotation,
            // blanking out real notes for a frame. Assigning every published
            // property in one synchronous block makes that combination
            // unobservable.
            let snapshot = try await ProjectsQuery(metadata: metadata).project(id: id)
            let annotation = try await metadata.projectAnnotation(projectID: id)
            // Wave 4 navigation-rework code-review fix: a NEWER call may
            // have already bumped `selectionGeneration` while this call's
            // queries were in flight -- if so, this completion is stale and
            // must not clobber whatever that newer call already wrote.
            guard generation == selectionGeneration else { return }
            selectedProjectID = id
            selectedProject = snapshot
            selectedProjectAnnotation = annotation
        } catch {
            guard generation == selectionGeneration else { throw error }
            selectedProjectID = id
            selectedProject = nil
            selectedProjectAnnotation = nil
            errorMessage = error.localizedDescription
            throw error
        }
    }

    public func saveSelectedProjectAnnotation(goalHours: Double?, notes: String) async throws {
        guard let metadata, let selectedProjectID else { throw ProjectsStoreError.libraryNotOpen }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let annotation = ProjectAnnotationRecord(
            projectID: selectedProjectID,
            integrationGoalHours: goalHours,
            notes: trimmedNotes,
            updatedAt: .now
        )
        do {
            try await metadata.save(annotation)
            selectedProjectAnnotation = try await metadata.projectAnnotation(projectID: selectedProjectID)
            errorMessage = nil
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
            workspaceRows = try await Self.makeWorkspaceRows(projects: projects, metadata: metadata)
            sortWorkspaceRows()
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

    private static func makeWorkspaceRows(
        projects: [ProjectRecord], metadata: MetadataStore
    ) async throws -> [ProjectWorkspaceRow] {
        let query = ProjectsQuery(metadata: metadata)
        var rows: [ProjectWorkspaceRow] = []
        for project in projects {
            guard let snapshot = try await query.project(id: project.id) else { continue }
            rows.append(ProjectWorkspaceRow(
                project: project,
                nightCount: snapshot.nights.count,
                integrationSeconds: snapshot.integrationSeconds,
                usableFrames: snapshot.usableFrames,
                excludedFrames: snapshot.totalFrames - snapshot.usableFrames,
                latestNight: snapshot.nights.map(\.night.localDate).max(),
                nextAction: snapshot.nextAction.title
            ))
        }
        return rows
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains)
            .map(String.init).joined().lowercased()
    }
}
