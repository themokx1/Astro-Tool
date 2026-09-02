@testable import AstroUI
import AstroApplication
import AstroCore
import Foundation
import Testing

@MainActor
struct GlobalSearchStoreTests {
    @Test("Global search returns projects and nights with stable destinations")
    func searchesAcrossWorkflowObjects() async throws {
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting)
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let series = SeriesRecord(
            id: UUID(), projectID: project.id, nightID: night.id, setupID: nil,
            setupDescriptor: "ASI2600MC", sensorMode: .osc, passband: .dualBand,
            exposureSeconds: 300, filterName: "SV220", filterID: nil, gain: 100, offset: 50, binning: "1x1"
        )
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night], series: [series]))
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let nights = NightsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        try await projects.open(rootURL: root)
        try await nights.open(rootURL: root)
        let search = GlobalSearchStore()

        await search.search("SV220", projects: projects, nights: nights)
        #expect(search.results.contains { $0.kind == .project && $0.objectID == project.id })
        #expect(search.results.contains { $0.kind == .night && $0.objectID == night.id })
        #expect(search.results.contains { $0.kind == .series && $0.objectID == series.id })
    }

    @Test("Global search includes indexed files and session notes")
    func searchesIndexedLibraryContent() async throws {
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        let search = GlobalSearchStore(librarySearch: { query, selectedRoot in
            #expect(query == "elephant")
            #expect(selectedRoot == root)
            return SearchResults(
                files: [("sessions/IC_1396/2026-08-08/lights/frame-001.fit", "fits", 42)],
                totalFileMatches: 1,
                notes: [("IC_1396", "2026-08-08", "filter", "SV220 elephant run")]
            )
        })
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let nights = NightsStore(metadataFactory: { _ in metadata })
        try await projects.open(rootURL: root)
        try await nights.open(rootURL: root)

        await search.search("elephant", rootURL: root, projects: projects, nights: nights)

        #expect(search.results.contains {
            $0.kind == .file && $0.locator == "sessions/IC_1396/2026-08-08/lights/frame-001.fit"
        })
        #expect(search.results.contains {
            $0.kind == .note && $0.locator == "IC_1396|2026-08-08|filter"
        })
    }

    // MARK: - Overlapping keystrokes

    @Test("A slower, earlier search never publishes its results over a newer one")
    func staleSearchNeverOverwritesTheNewerResults() async throws {
        // The search field calls `search` on every keystroke and never
        // waited for the previous call, so whichever query's index read
        // finished LAST used to win regardless of what was typed last.
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        let gate = SearchGate()
        let search = GlobalSearchStore(
            librarySearch: { query, _ in
                if query == "stale" { await gate.enterAndWaitToProceed() }
                return SearchResults(
                    files: [("sessions/\(query).fit", "fits", 42)], totalFileMatches: 1, notes: []
                )
            },
            debounce: .zero
        )
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let nights = NightsStore(metadataFactory: { _ in metadata })
        try await projects.open(rootURL: root)
        try await nights.open(rootURL: root)

        let staleSearch = Task { await search.search("stale", rootURL: root, projects: projects, nights: nights) }
        await gate.waitForEntry()
        await search.search("current", rootURL: root, projects: projects, nights: nights)
        #expect(search.results.map(\.locator) == ["sessions/current.fit"])
        #expect(!search.isSearching)

        await gate.proceed()
        await staleSearch.value

        #expect(
            search.results.map(\.locator) == ["sessions/current.fit"],
            "the stale completion must not replace what the newer search published"
        )
        #expect(!search.isSearching, "and must not restart the newer search's spinner")
    }

    @Test("A superseded keystroke never reaches the library index at all")
    func debounceDropsSupersededKeystrokes() async throws {
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        let recorder = SearchQueryRecorder()
        let search = GlobalSearchStore(
            librarySearch: { query, _ in
                recorder.record(query)
                return SearchResults(files: [], totalFileMatches: 0, notes: [])
            },
            debounce: .milliseconds(300)
        )
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let nights = NightsStore(metadataFactory: { _ in metadata })
        try await projects.open(rootURL: root)
        try await nights.open(rootURL: root)

        let firstKeystroke = Task { await search.search("i", rootURL: root, projects: projects, nights: nights) }
        // Hands the main actor over so the first call reaches its debounce
        // sleep, without waiting the debounce out.
        await Task.yield()
        await search.search("ic", rootURL: root, projects: projects, nights: nights)
        await firstKeystroke.value

        #expect(recorder.queries == ["ic"], "only the keystroke that stood still may open the index")
    }

    @Test("Clearing the field drops the results and stops the spinner")
    func emptyTermClearsEverything() async throws {
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        let search = GlobalSearchStore(
            librarySearch: { query, _ in
                SearchResults(files: [("sessions/\(query).fit", "fits", 42)], totalFileMatches: 1, notes: [])
            },
            debounce: .zero
        )
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let nights = NightsStore(metadataFactory: { _ in metadata })
        try await projects.open(rootURL: root)
        try await nights.open(rootURL: root)
        await search.search("ic", rootURL: root, projects: projects, nights: nights)
        #expect(!search.results.isEmpty)

        await search.search("   ", rootURL: root, projects: projects, nights: nights)

        #expect(search.results.isEmpty)
        #expect(!search.isSearching)
    }
}

/// Same continuation-based rendezvous as `ProjectsStoreTests`' own
/// `SelectionRace`: holds one search paused inside its injected index read
/// while a newer one runs to completion.
private actor SearchGate {
    private var hasEntered = false
    private var canProceed = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var proceedContinuation: CheckedContinuation<Void, Never>?

    func waitForEntry() async {
        if hasEntered { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func enterAndWaitToProceed() async {
        hasEntered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        if canProceed { return }
        await withCheckedContinuation { proceedContinuation = $0 }
    }

    func proceed() {
        canProceed = true
        proceedContinuation?.resume()
        proceedContinuation = nil
    }
}

/// Records which queries actually reached the injected library search --
/// lock-protected because that closure is `@Sendable`.
private final class SearchQueryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ query: String) {
        lock.withLock { recorded.append(query) }
    }

    var queries: [String] { lock.withLock { recorded } }
}
