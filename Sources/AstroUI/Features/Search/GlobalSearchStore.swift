import Foundation
import Observation

public enum GlobalSearchResultKind: String, Sendable {
    case project
    case night
    case series
}

public struct GlobalSearchResult: Identifiable, Equatable, Sendable {
    public var id: String { "\(kind.rawValue)|\(objectID.uuidString)" }
    public let kind: GlobalSearchResultKind
    public let objectID: UUID
    public let title: String
    public let subtitle: String
}

@MainActor
@Observable
public final class GlobalSearchStore {
    public private(set) var results: [GlobalSearchResult] = []
    public private(set) var isSearching = false

    public init() {}

    public func search(_ term: String, projects: ProjectsStore, nights: NightsStore) async {
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
        results = found
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains)
            .map(String.init).joined().lowercased()
    }
}
