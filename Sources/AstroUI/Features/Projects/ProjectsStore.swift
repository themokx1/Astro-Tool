import AstroApplication
import Foundation
import Observation
import SwiftUI

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
    // V2 UI/UX audit (2026-08-16): these two used to be a verbatim copy of
    // `ProjectNextAction.title`/`.explanation` -- the engine's English
    // sentence -- which never localized (`Text`/`.help` render a `String`
    // through their non-localizing overload). `ProjectWorkspaceRow` has to
    // stay `Sendable`, and `LocalizedStringKey` itself is not `Sendable`, so
    // this can't just change type to `LocalizedStringKey` the way
    // `MetricCard`'s properties did. Instead these are resolved eagerly
    // against `Bundle.main`'s `hu.lproj` table at row-construction time, via
    // `ProjectNextActionKind.localizedTitle`/`.localizedExplanation` --
    // keyed off the same finite case as `ProjectNextActionKind.titleKey`
    // (used everywhere else this value renders), never off the engine's
    // rendered sentence.
    public let nextAction: String
    /// The one-line "why" behind `nextAction`. Shown as the column's tooltip
    /// so the advice is explainable without a second panel.
    public let nextActionExplanation: String
    public let seriesCount: Int
    /// The project's integration goal in hours, if the user set one. Carried
    /// on the row so "how far is each project from done" is answerable while
    /// comparing projects — it used to live only in the inspector, one
    /// project at a time.
    public let goalHours: Double?
    public var id: UUID { project.id }

    /// 0...1 against the goal, or `nil` when no goal is set. Its own property
    /// so the column can sort on it.
    public var goalProgress: Double? {
        guard let goalHours, goalHours > 0 else { return nil }
        return min(1, (integrationSeconds / 3600) / goalHours)
    }

    /// Sorts goal-less projects last rather than mixing them into the middle.
    public var goalProgressSortKey: Double { goalProgress ?? -1 }
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
    /// table's header used to look clickable and do nothing.
    ///
    /// Task 5 (2026-08-17 owner-feedback wave 3): default used to be project
    /// name ascending -- the owner's own words: "rossz a sorrend, az kell
    /// előre kerüljön, amiben az utolsó gyűjtés van" (wrong order; whichever
    /// project has the most recent capture belongs at the top). Default is
    /// now most-recent-capture-first, i.e. `latestNightSortKey` descending;
    /// a project with no nights yet sorts last (`latestNightSortKey`'s own
    /// doc comment) rather than winning ties against projects that do.
    public private(set) var sortOrder: [KeyPathComparator<ProjectWorkspaceRow>] = [
        KeyPathComparator(\ProjectWorkspaceRow.latestNightSortKey, order: .reverse)
    ]
    public private(set) var workspaceRows: [ProjectWorkspaceRow] = []
    /// Whether any currently loaded project has an integration goal set --
    /// drives whether the "Goal" column is worth showing at all. W5-2
    /// finding 4 (owner pixel review): the real 13-project library has never
    /// set a goal on any project, so the column rendered "—" top to bottom
    /// for all 13 rows, spending a whole column's width on nothing. Set
    /// alongside `workspaceRows` itself, right after it is (re)built -- never
    /// a computed property re-scanning `workspaceRows` from `ProjectsView`'s
    /// `body`, matching this codebase's "no work in getters/body" rule.
    public private(set) var hasAnyGoal = false
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
            updateHasAnyGoal()
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

    /// Reuses `ProjectWorkspaceRow.goalProgress` verbatim -- the exact
    /// condition the "Goal" column itself already uses to decide between a
    /// progress bar and a bare "—" -- so `hasAnyGoal` can never drift from
    /// what the column would actually show.
    private func updateHasAnyGoal() {
        hasAnyGoal = workspaceRows.contains { $0.goalProgress != nil }
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
            updatedAt: .now,
            revision: selectedProjectAnnotation?.revision ?? 0
        )
        do {
            selectedProjectAnnotation = try await metadata.saveProjectAnnotation(
                annotation,
                expectedRevision: annotation.revision
            )
            errorMessage = nil
        } catch {
            if case MetadataStoreError.staleProjectAnnotation = error {
                selectedProjectAnnotation = try? await metadata.projectAnnotation(projectID: selectedProjectID)
                errorMessage = "This project note changed in another window. Reloaded the latest note before retrying."
            } else {
            errorMessage = error.localizedDescription
            }
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
            updateHasAnyGoal()
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
                nextAction: snapshot.nextAction.kind.localizedTitle,
                nextActionExplanation: snapshot.nextAction.kind.localizedExplanation,
                // W6-C (one count, one truth): was `snapshot.nights.reduce(0)
                // { $0 + $1.series.count }` -- the night-grouped sum, which
                // silently drops any series whose `nightID` doesn't resolve
                // to a real night (`ProjectsQuery.project(id:)`'s own
                // `orphanedSeries` doc comment). `snapshot.series.count` is
                // the flat, always-complete truth this same view's "Nights"
                // MetricCard detail (`ProjectsView.swift`'s "%@ capture
                // series") and `ProjectWorkspaceView`'s own header already
                // used -- routing the list's "Series" column through it too
                // means both can no longer disagree about the same project.
                seriesCount: snapshot.series.count,
                goalHours: try? await metadata.projectAnnotation(projectID: project.id)?.integrationGoalHours
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

/// V2 UI/UX audit (2026-08-16): `ProjectNextAction.title`/`.explanation` are
/// English sentences meant for non-UI consumers. The UI localizes by
/// switching on `ProjectNextActionKind` -- the finite case the engine
/// already derives the sentence from -- and mapping each case to a
/// `LocalizedStringKey` here, at the view layer. No Hungarian text lives in
/// `AstroApplication`.
extension ProjectNextActionKind {
    /// The `NSLocalizedString`/`hu.lproj` LOOKUP KEY for `localizedTitle` --
    /// deliberately the raw `%@`-templated sentence, never the already-
    /// substituted one. `.balanceMosaicPanels` carries a runtime panel
    /// label/deficit (W7-F item 2): baking those INTO the string before
    /// using it as a lookup key would mint one impossible-to-pre-translate
    /// key per numeric value instead of leaving them as substitution
    /// placeholders -- the exact bug this split avoids. Every static case
    /// still returns its own constant sentence unchanged.
    fileprivate var titleTemplate: String {
        switch self {
        case .planFirstNight: "Plan the first night"
        case .startCollecting: "Start collecting"
        case .keepCollecting: "Keep collecting"
        case .keepProcessing: "Keep processing"
        case .writeFinalReport: "Write the final report"
        case .archived: "Project archived"
        case .balanceMosaicPanels: "Balance the panels: %@ panel +%@ h"
        }
    }

    /// See `titleTemplate`'s own doc comment -- same split, for the
    /// explanation sentence.
    fileprivate var explanationTemplate: String {
        switch self {
        case .planFirstNight, .startCollecting: "Choose a setup, a filter and an exposure series."
        case .keepCollecting: "Add the missing series on the next good night."
        case .keepProcessing: "Check the stacks and the results' lineage."
        case .writeFinalReport: "The project is done; export the shareable summary."
        case .archived: "Nothing to do."
        case .balanceMosaicPanels: "%@ panel has the biggest integration gap in this mosaic -- capture more of it next."
        }
    }

    /// Substitution values for `titleTemplate`'s `%@` placeholders, in
    /// order -- `[]` for every static-text case (`String(format:arguments:)`
    /// with no placeholders and no arguments is just the template itself).
    fileprivate var titleArguments: [String] {
        switch self {
        case let .balanceMosaicPanels(worstPanelLabel, deficitHours):
            [worstPanelLabel, deficitHours.formatted(.number.precision(.fractionLength(1)))]
        default:
            []
        }
    }

    fileprivate var explanationArguments: [String] {
        switch self {
        case let .balanceMosaicPanels(worstPanelLabel, _): [worstPanelLabel]
        default: []
        }
    }

    /// For direct use in view bodies (`Text`/`Label`) -- resolved lazily by
    /// SwiftUI against `Bundle.main` at render time, like any other
    /// `LocalizedStringKey` literal in this codebase. `.balanceMosaicPanels`
    /// is built via Swift's own `LocalizedStringKey` string-interpolation
    /// conformance directly (the SAME mechanism any `Text("... \(x) ...")`
    /// literal uses) rather than wrapping `titleTemplate`, so the panel
    /// label/deficit stay real interpolation placeholders instead of text
    /// baked into the lookup key.
    var titleKey: LocalizedStringKey {
        switch self {
        case .planFirstNight: "Plan the first night"
        case .startCollecting: "Start collecting"
        case .keepCollecting: "Keep collecting"
        case .keepProcessing: "Keep processing"
        case .writeFinalReport: "Write the final report"
        case .archived: "Project archived"
        case let .balanceMosaicPanels(worstPanelLabel, deficitHours):
            "Balance the panels: \(worstPanelLabel) panel +\(deficitHours.formatted(.number.precision(.fractionLength(1)))) h"
        }
    }

    var explanationKey: LocalizedStringKey {
        switch self {
        case .planFirstNight, .startCollecting: "Choose a setup, a filter and an exposure series."
        case .keepCollecting: "Add the missing series on the next good night."
        case .keepProcessing: "Check the stacks and the results' lineage."
        case .writeFinalReport: "The project is done; export the shareable summary."
        case .archived: "Nothing to do."
        case let .balanceMosaicPanels(worstPanelLabel, _):
            "\(worstPanelLabel) panel has the biggest integration gap in this mosaic -- capture more of it next."
        }
    }

    /// Same `%@` substitution `String(format:arguments:)` would perform, by
    /// hand -- `V2PolishSurfaceTests.noHandRolledFormatting` bans
    /// `String(format:` anywhere under `Sources/AstroUI` (a second format
    /// for a unit `AstroFormat` already owns is a second truth), and this
    /// case's arguments are already fully-formatted `String`s (see
    /// `titleArguments`/`explanationArguments`'s own docs), so a plain
    /// sequential `%@` replace is exactly equivalent here -- there is no
    /// numeric specifier to interpret.
    private static func substituting(_ template: String, with arguments: [String]) -> String {
        var result = template
        for argument in arguments {
            guard let range = result.range(of: "%@") else { break }
            result.replaceSubrange(range, with: argument)
        }
        return result
    }

    /// For `Sendable`-constrained storage (`ProjectWorkspaceRow`) that can't
    /// hold a `LocalizedStringKey` -- resolves eagerly against the same
    /// `Bundle.main`/`hu.lproj` table `titleKey`/`explanationKey` resolve
    /// lazily, so both paths render identically. Looks up `titleTemplate`
    /// (the `%@`-templated key), then substitutes `titleArguments` -- a
    /// no-op substitution for every static-text case.
    var localizedTitle: String {
        let format = NSLocalizedString(titleTemplate, bundle: .main, comment: "")
        return Self.substituting(format, with: titleArguments)
    }

    var localizedExplanation: String {
        let format = NSLocalizedString(explanationTemplate, bundle: .main, comment: "")
        return Self.substituting(format, with: explanationArguments)
    }
}

/// V2 UI/UX audit (2026-08-16): `project.phase.rawValue.capitalized`
/// (`InspectorView.swift`, `ProjectsView.swift`'s "Phase" column) rendered a
/// plain `String`, so it stayed English -- same fix as `PlanningFit` above:
/// map the case, not a rendered/capitalized rawValue, to a
/// `LocalizedStringKey`.
extension ProjectWorkflowPhase {
    fileprivate var titleText: String {
        switch self {
        case .planned: "Planned"
        case .collecting: "Collecting"
        case .processing: "Processing"
        case .complete: "Complete"
        case .archived: "Archived"
        }
    }

    var displayLabel: LocalizedStringKey { LocalizedStringKey(titleText) }

    /// W6-D fix: `GlobalSearchStore.search`'s project-result `detail` field
    /// is a plain, eagerly-built `String` (interpolated once per search,
    /// not re-rendered as a view), so it cannot hold `displayLabel` itself
    /// -- it used to fall back to `phase.rawValue.capitalized` instead,
    /// which stayed English ("Collecting") regardless of `hu.lproj`. Same
    /// "resolve the same titleText eagerly, for Sendable/String-constrained
    /// storage" shape as `ProjectNextActionKind.localizedTitle`.
    var localizedText: String { NSLocalizedString(titleText, bundle: .main, comment: "") }
}
