import Foundation
import Observation
import SwiftUI
import AstroApplication
import AstroCore

public enum GlobalSearchResultKind: String, Sendable {
    case project
    case night
    case series
    case file
    case note

    /// The translatable category word shown alongside `GlobalSearchResult
    /// .detail` (e.g. "Project", "Night"). Task 5c (2026-08-17): this used
    /// to be baked as a literal English prefix into `subtitle` itself
    /// (`"Project · \(catalogID) · ..."`), which never localized -- but it
    /// turns out to be entirely redundant with this enum's own case, one
    /// per `GlobalSearchResult.kind`. Computed here rather than stored,
    /// since `GlobalSearchResult` stays `Sendable` and `LocalizedStringKey`
    /// itself is not: a computed `LocalizedStringKey` property on this
    /// plain `Sendable` enum costs nothing, unlike a stored one on the
    /// result struct would.
    public var searchLabel: LocalizedStringKey {
        switch self {
        case .project: "Project"
        case .night: "Night"
        case .series: "Series"
        case .file: "File"
        case .note: "Note"
        }
    }
}

public struct GlobalSearchResult: Identifiable, Equatable, Sendable {
    public var id: String { "\(kind.rawValue)|\(objectID?.uuidString ?? locator ?? title)" }
    public let kind: GlobalSearchResultKind
    public let objectID: UUID?
    // Task 5b (2026-08-17) classification -- see
    // `V2PolishSurfaceTests.uiPropertyAllowlist`'s entry for this file:
    // `title` is DATA (the underlying record's own name/date/filename).
    public let title: String
    /// The record's own dynamic detail -- a catalog ID, a date, a byte
    /// count, a filter/setup descriptor -- never authored prose. DATA, same
    /// reasoning as `title` above. Task 5c (2026-08-17) split this out of
    /// what used to be `subtitle` (a `"Category · detail"` `String` that
    /// mixed a literal, translatable category word into the same field as
    /// this data): the category word now lives on `kind.searchLabel`
    /// instead, and this holds only what is left. `GlobalSearchPanel`
    /// draws the two as separate `Text`s rather than recombining them into
    /// one formatted string, so the category word stays independently
    /// translatable.
    public let detail: String
    public let locator: String?

    public init(
        kind: GlobalSearchResultKind,
        objectID: UUID? = nil,
        title: String,
        detail: String,
        locator: String? = nil
    ) {
        self.kind = kind
        self.objectID = objectID
        self.title = title
        self.detail = detail
        self.locator = locator
    }
}

@MainActor
@Observable
public final class GlobalSearchStore {
    public typealias LibrarySearch = @Sendable (String, URL) async throws -> SearchResults
    public private(set) var results: [GlobalSearchResult] = []
    public private(set) var isSearching = false
    private let librarySearch: LibrarySearch

    /// `librarySearch` is `Optional`/`nil` rather than defaulted directly to
    /// `productionSearch`, and must stay that way: an `async` default
    /// argument is re-emitted as a `weak`/`linkonce_odr` async function
    /// pointer record in every module that uses it, with a different context
    /// size in the declaring module than in a client -- a link that pairs
    /// the big body with the small record corrupts the task allocator.
    /// Resolving in the body keeps the closure private to this module.
    /// `AsyncContextSizeGateTests` gates this and carries the full account.
    public init(librarySearch: LibrarySearch? = nil) {
        self.librarySearch = librarySearch ?? GlobalSearchStore.productionSearch
    }

    public func search(
        _ term: String,
        rootURL: URL? = nil,
        projects: ProjectsStore,
        nights: NightsStore
    ) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        let projectMatches = (try? await projects.search(trimmed)) ?? []
        var found = projectMatches.map {
            GlobalSearchResult(
                kind: .project, objectID: $0.id, title: $0.displayName,
                detail: "\($0.catalogID) · \($0.phase.rawValue.capitalized)"
            )
        }
        let normalized = Self.normalized(trimmed)
        found.append(contentsOf: nights.nights.filter { row in
            Self.normalized([
                row.date, row.projectSummary, row.filterSummary,
                row.exposureSummary,
                row.snapshot.series.map(\.setupDescriptor).joined(separator: " ")
            ].joined(separator: " ")).contains(normalized)
        }.map {
            GlobalSearchResult(
                kind: .night, objectID: $0.id, title: $0.date,
                detail: "\($0.projectSummary) · \($0.integrationSummary)"
            )
        })
        for night in nights.nights {
            for series in night.snapshot.series {
                let project = night.snapshot.projects.first { $0.id == series.projectID }
                let haystack = Self.normalized([
                    project?.displayName, project?.catalogID, series.filterName,
                    series.setupDescriptor,
                    "\(AstroFormat.exposureSeconds(series.exposureSeconds)) seconds"
                ].compactMap { $0 }.joined(separator: " "))
                guard haystack.contains(normalized) else { continue }
                found.append(GlobalSearchResult(
                    kind: .series,
                    objectID: series.id,
                    title: project?.displayName ?? "Capture series",
                    detail: "\([series.filterName, AstroFormat.exposureSeconds(series.exposureSeconds), series.setupDescriptor].compactMap { $0 }.joined(separator: " · "))"
                ))
            }
        }
        if let rootURL, let indexed = try? await librarySearch(trimmed, rootURL) {
            found.append(contentsOf: indexed.files.map { hit in
                GlobalSearchResult(
                    kind: .file,
                    title: URL(fileURLWithPath: hit.path).lastPathComponent,
                    detail: "\(hit.kind.uppercased()) · \(ByteCountFormatter.string(fromByteCount: hit.sizeBytes, countStyle: .file))",
                    locator: hit.path
                )
            })
            found.append(contentsOf: indexed.notes.map { hit in
                let projectID = Self.projectID(for: hit.target, in: projects.projects)
                return GlobalSearchResult(
                    kind: .note,
                    objectID: projectID,
                    title: "\(hit.key): \(hit.value)",
                    detail: "\(hit.target) · \(hit.date)",
                    locator: "\(hit.target)|\(hit.date)|\(hit.key)"
                )
            })
        }
        results = found
    }

    public static func productionSearch(_ term: String, rootURL: URL) async throws -> SearchResults {
        try await Task.detached(priority: .userInitiated) {
            let identity = LibraryIdentity(rootURL: rootURL)
            let paths = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
            let database = try Database(path: paths.indexDatabase.path)
            var result = try database.searchAll(query: term)
            let stored = SessionNoteStore.search(
                query: term,
                root: rootURL,
                sessions: try database.allSessionPairs()
            )
            var seen = Set(result.notes.map { "\($0.target)|\($0.date)|\($0.key)" })
            result.notes.append(contentsOf: stored.filter {
                seen.insert("\($0.target)|\($0.date)|\($0.key)").inserted
            })
            return result
        }.value
    }

    private static func projectID(for target: String, in projects: [ProjectRecord]) -> UUID? {
        let targetKey = normalized(target)
        return projects.first {
            normalized($0.catalogID) == targetKey || normalized($0.displayName) == targetKey
        }?.id
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains)
            .map(String.init).joined().lowercased()
    }
}
