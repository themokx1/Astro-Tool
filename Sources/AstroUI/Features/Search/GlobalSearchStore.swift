import Foundation
import Observation
import AstroApplication
import AstroCore

public enum GlobalSearchResultKind: String, Sendable {
    case project
    case night
    case series
    case file
    case note
    case result
}

public struct GlobalSearchResult: Identifiable, Equatable, Sendable {
    public var id: String { "\(kind.rawValue)|\(objectID?.uuidString ?? locator ?? title)" }
    public let kind: GlobalSearchResultKind
    public let objectID: UUID?
    public let title: String
    public let subtitle: String
    public let locator: String?

    public init(
        kind: GlobalSearchResultKind,
        objectID: UUID? = nil,
        title: String,
        subtitle: String,
        locator: String? = nil
    ) {
        self.kind = kind
        self.objectID = objectID
        self.title = title
        self.subtitle = subtitle
        self.locator = locator
    }
}

@MainActor
@Observable
public final class GlobalSearchStore {
    public typealias LibrarySearch = @Sendable (String, URL) async throws -> SearchResults
    public typealias ResultsSearch = @Sendable (URL) async throws -> [ResultSearchEntry]
    public private(set) var results: [GlobalSearchResult] = []
    public private(set) var isSearching = false
    private let librarySearch: LibrarySearch
    private let resultsSearch: ResultsSearch

    public init(
        librarySearch: @escaping LibrarySearch = GlobalSearchStore.productionSearch,
        resultsSearch: @escaping ResultsSearch = GlobalSearchStore.productionResultsSearch
    ) {
        self.librarySearch = librarySearch
        self.resultsSearch = resultsSearch
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
                subtitle: "Project · \($0.catalogID) · \($0.phase.rawValue.capitalized)"
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
                subtitle: "Night · \($0.projectSummary) · \($0.integrationSummary)"
            )
        })
        for night in nights.nights {
            for series in night.snapshot.series {
                let project = night.snapshot.projects.first { $0.id == series.projectID }
                let haystack = Self.normalized([
                    project?.displayName, project?.catalogID, series.filterName,
                    series.setupDescriptor,
                    "\(series.exposureSeconds.formatted(.number.precision(.fractionLength(0...1)))) seconds"
                ].compactMap { $0 }.joined(separator: " "))
                guard haystack.contains(normalized) else { continue }
                found.append(GlobalSearchResult(
                    kind: .series,
                    objectID: series.id,
                    title: project?.displayName ?? "Capture series",
                    subtitle: "Series · \([series.filterName, "\(series.exposureSeconds.formatted(.number.precision(.fractionLength(0...1)))) s", series.setupDescriptor].compactMap { $0 }.joined(separator: " · "))"
                ))
            }
        }
        if let rootURL, let indexed = try? await librarySearch(trimmed, rootURL) {
            found.append(contentsOf: indexed.files.map { hit in
                GlobalSearchResult(
                    kind: .file,
                    title: URL(fileURLWithPath: hit.path).lastPathComponent,
                    subtitle: "File · \(hit.kind.uppercased()) · \(ByteCountFormatter.string(fromByteCount: hit.sizeBytes, countStyle: .file))",
                    locator: hit.path
                )
            })
            found.append(contentsOf: indexed.notes.map { hit in
                let projectID = Self.projectID(for: hit.target, in: projects.projects)
                return GlobalSearchResult(
                    kind: .note,
                    objectID: projectID,
                    title: "\(hit.key): \(hit.value)",
                    subtitle: "Note · \(hit.target) · \(hit.date)",
                    locator: "\(hit.target)|\(hit.date)|\(hit.key)"
                )
            })
        }
        if let rootURL, let resultEntries = try? await resultsSearch(rootURL) {
            found.append(contentsOf: resultEntries.filter { entry in
                let haystack = Self.normalized([
                    entry.softwareName, entry.softwareVersion, entry.role.rawValue,
                    entry.kind.rawValue, entry.relativePath, entry.projectName,
                ].compactMap { $0 }.joined(separator: " "))
                return haystack.contains(normalized)
            }.map { entry in
                let softwareLabel = [entry.softwareName, entry.softwareVersion]
                    .compactMap { $0 }.joined(separator: " ")
                let title = softwareLabel.isEmpty
                    ? (entry.relativePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Result")
                    : softwareLabel
                return GlobalSearchResult(
                    kind: .result,
                    objectID: entry.resultID,
                    title: title,
                    subtitle: "Result · \(entry.projectName) · \(entry.role.rawValue.capitalized)",
                    locator: entry.projectID.uuidString
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

    /// Every result across every project in the library, unfiltered --
    /// `search(_:)` applies the same normalized, diacritic-insensitive match
    /// it already uses for nights and series.
    public static func productionResultsSearch(_ rootURL: URL) async throws -> [ResultSearchEntry] {
        try await Task.detached(priority: .userInitiated) {
            let metadata = try await ProjectsStore.productionMetadata(rootURL: rootURL)
            return try await ResultsQuery(metadata: metadata).librarySearchEntries()
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
