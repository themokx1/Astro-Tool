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

    @Test("Global search finds result content by software name")
    func searchesResultContentBySoftware() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let nights = NightsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        try await projects.open(rootURL: root)
        try await nights.open(rootURL: root)
        let resultID = UUID()
        let projectID = UUID()
        let search = GlobalSearchStore(
            librarySearch: { _, _ in SearchResults() },
            resultsSearch: { selectedRoot in
                #expect(selectedRoot == root)
                return [ResultSearchEntry(
                    resultID: resultID, projectID: projectID, projectName: "Elephant's Trunk",
                    kind: .stack, role: .intermediate, relativePath: "stacks/master.fit",
                    softwareName: "Siril", softwareVersion: "1.4", createdAt: .now
                )]
            }
        )

        await search.search("Siril", rootURL: root, projects: projects, nights: nights)

        #expect(search.results.contains { $0.kind == .result && $0.objectID == resultID })
        #expect(search.results.contains { $0.kind == .result && $0.locator == projectID.uuidString })
    }

    @Test("Global search matches a result's project name without diacritics")
    func searchesResultContentByProjectNameIgnoringDiacritics() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let nights = NightsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        try await projects.open(rootURL: root)
        try await nights.open(rootURL: root)
        let resultID = UUID()
        let search = GlobalSearchStore(
            librarySearch: { _, _ in SearchResults() },
            resultsSearch: { _ in
                [ResultSearchEntry(
                    resultID: resultID, projectID: UUID(), projectName: "Elefántormány-köd",
                    kind: .processingVariant, role: .final, relativePath: "processed/final.fit",
                    softwareName: "PixInsight", softwareVersion: "1.9", createdAt: .now
                )]
            }
        )

        await search.search("elefantormany", rootURL: root, projects: projects, nights: nights)

        #expect(search.results.contains { $0.kind == .result && $0.objectID == resultID })
    }

    @Test("A result hit's source names the content route it routes to")
    func resultHitsRouteToResultContent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"), encoding: .utf8)
        #expect(shell.contains("case .result:"))
        #expect(shell.contains(".result(objectID.uuidString)"))
    }
}
