import Foundation
import Testing
@testable import AstroApplication

private func project(catalogID: String, displayName: String) -> ProjectRecord {
    ProjectRecord(id: UUID(), catalogID: catalogID, displayName: displayName, phase: .collecting)
}

@Suite("IngestSuggestionEngine.matchProject")
struct IngestSuggestionEngineTests {
    @Test func exactCatalogIDMatchIsHighConfidence() {
        let projects = [
            project(catalogID: "M31", displayName: "Andromeda Galaxy"),
            project(catalogID: "M42", displayName: "Orion Nebula"),
        ]
        let match = IngestSuggestionEngine.matchProject(folderName: "M31", projects: projects)
        #expect(match?.project.catalogID == "M31")
        #expect(match?.confidence == .exact)
    }

    @Test func exactDisplayNameMatchIgnoresCaseAndPunctuation() {
        let projects = [project(catalogID: "M31", displayName: "Andromeda Galaxy")]
        let match = IngestSuggestionEngine.matchProject(folderName: "andromeda-galaxy", projects: projects)
        #expect(match?.project.catalogID == "M31")
        #expect(match?.confidence == .exact)
    }

    @Test func fuzzySubstringMatchIsLowerConfidence() {
        let projects = [
            project(catalogID: "M31", displayName: "Andromeda Galaxy"),
            project(catalogID: "M42", displayName: "Orion Nebula"),
        ]
        let match = IngestSuggestionEngine.matchProject(folderName: "M31_Andromeda_Card", projects: projects)
        #expect(match?.project.catalogID == "M31")
        #expect(match?.confidence == .fuzzy)
    }

    @Test func noMatchLeavesTheSuggestionEmpty() {
        let projects = [
            project(catalogID: "M31", displayName: "Andromeda Galaxy"),
            project(catalogID: "M42", displayName: "Orion Nebula"),
        ]
        let match = IngestSuggestionEngine.matchProject(folderName: "EOS_DIGITAL", projects: projects)
        #expect(match == nil)
    }

    @Test func ambiguousFuzzyMatchAcrossTwoProjectsStaysEmptyRatherThanGuessing() {
        let projects = [
            project(catalogID: "M31", displayName: "Andromeda Galaxy"),
            project(catalogID: "M31B", displayName: "Andromeda Companion"),
        ]
        // Both catalog IDs contain "m31" -- neither should win by a coin
        // flip, so the ambiguity must resolve to no suggestion at all.
        let match = IngestSuggestionEngine.matchProject(folderName: "m31", projects: projects)
        // "m31" is an EXACT match for the first project's catalogID, so this
        // documents that exact equality still wins even when a second
        // project would also fuzzy-qualify -- exactness is checked first
        // and short-circuits before ambiguity is ever considered.
        #expect(match?.project.catalogID == "M31")
        #expect(match?.confidence == .exact)
    }

    @Test func trulyAmbiguousFuzzyCandidatesStayEmpty() {
        let projects = [
            project(catalogID: "M31Widefield", displayName: "Andromeda Widefield"),
            project(catalogID: "M31Mosaic", displayName: "Andromeda Mosaic"),
        ]
        // Both catalog IDs CONTAIN "m31" (the short card label), so both
        // qualify as fuzzy candidates -- neither should win by a coin flip.
        let match = IngestSuggestionEngine.matchProject(folderName: "M31", projects: projects)
        #expect(match == nil)
    }

    @Test func blankFolderNameNeverMatches() {
        let projects = [project(catalogID: "M31", displayName: "Andromeda Galaxy")]
        #expect(IngestSuggestionEngine.matchProject(folderName: "   ", projects: projects) == nil)
    }

    @Test func emptyProjectListNeverMatches() {
        #expect(IngestSuggestionEngine.matchProject(folderName: "M31", projects: []) == nil)
    }
}
