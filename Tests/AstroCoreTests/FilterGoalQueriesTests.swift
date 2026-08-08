import Foundation
import Testing
@testable import AstroCore

/// `FilterGoalQueries` is pure (no `Database` access) -- these tests build
/// `[FilterIntegration]`/`tags` by hand, no fixture library/scan needed.

// MARK: - merge

@Test func mergeAttachesGoalOntoMatchingBreakdownRow() throws {
    let breakdown = [
        FilterIntegration(filter: "Ha", usableFrameCount: 10, integrationSeconds: 3600 * 8),
    ]
    let merged = FilterGoalQueries.merge(breakdown: breakdown, tags: ["goal:Ha=12h"])
    #expect(merged.count == 1)
    #expect(merged[0].goalSeconds == 12 * 3600.0)
    #expect(merged[0].missingSeconds == 4 * 3600.0)
}

@Test func mergeMatchesFilterNameCaseInsensitively() throws {
    let breakdown = [FilterIntegration(filter: "OIII", usableFrameCount: 5, integrationSeconds: 3600 * 2)]
    let merged = FilterGoalQueries.merge(breakdown: breakdown, tags: ["goal:oiii=5h"])
    #expect(merged[0].goalSeconds == 5 * 3600.0)
    #expect(merged[0].missingSeconds == 3 * 3600.0)
}

@Test func mergeLeavesRowsWithoutAGoalUntouched() throws {
    let breakdown = [
        FilterIntegration(filter: "Ha", usableFrameCount: 10, integrationSeconds: 3600 * 8),
        FilterIntegration(filter: "OIII", usableFrameCount: 4, integrationSeconds: 3600 * 3),
    ]
    let merged = FilterGoalQueries.merge(breakdown: breakdown, tags: ["goal:Ha=12h"])
    let oiii = try #require(merged.first { $0.filter == "OIII" })
    #expect(oiii.goalSeconds == nil)
    #expect(oiii.missingSeconds == nil)
}

@Test func mergeReturnsBreakdownUnchangedWhenNoFilterGoalTagsExist() throws {
    let breakdown = [FilterIntegration(filter: "Ha", usableFrameCount: 10, integrationSeconds: 3600 * 8)]
    let merged = FilterGoalQueries.merge(breakdown: breakdown, tags: ["goal:30h", "favorite"])
    #expect(merged == breakdown)
}

@Test func mergeCapsMissingAtZeroWhenGoalIsAlreadyMet() throws {
    let breakdown = [FilterIntegration(filter: "Ha", usableFrameCount: 20, integrationSeconds: 3600 * 15)]
    let merged = FilterGoalQueries.merge(breakdown: breakdown, tags: ["goal:Ha=12h"])
    #expect(merged[0].goalSeconds == 12 * 3600.0)
    #expect(merged[0].missingSeconds == 0)
}

/// A filter that's been tagged with a goal but never actually shot yet at
/// all still needs to appear -- as a synthetic zero-usable row -- so the
/// UI can show "SII: 0h megvan, cél 6h, hiányzik 6h" rather than silently
/// omitting it.
@Test func mergeAppendsASyntheticRowForAGoalOnlyFilterNotInBreakdown() throws {
    let breakdown = [FilterIntegration(filter: "Ha", usableFrameCount: 10, integrationSeconds: 3600 * 8)]
    let merged = FilterGoalQueries.merge(breakdown: breakdown, tags: ["goal:Ha=12h", "goal:SII=6h"])
    #expect(merged.count == 2)
    let sii = try #require(merged.first { $0.filter == "SII" })
    #expect(sii.usableFrameCount == 0)
    #expect(sii.integrationSeconds == 0)
    #expect(sii.goalSeconds == 6 * 3600.0)
    #expect(sii.missingSeconds == 6 * 3600.0)
}

@Test func mergePreservesBreakdownOrderAndAppendsGoalOnlyRowsSortedByName() throws {
    let breakdown = [
        FilterIntegration(filter: "OIII", usableFrameCount: 5, integrationSeconds: 3600 * 3),
        FilterIntegration(filter: "Ha", usableFrameCount: 10, integrationSeconds: 3600 * 8),
    ]
    let merged = FilterGoalQueries.merge(breakdown: breakdown, tags: ["goal:Zeta=1h", "goal:Alpha=1h"])
    #expect(merged.map(\.filter) == ["OIII", "Ha", "Alpha", "Zeta"])
}

@Test func mergeIgnoresTheOverallGoalTagEntirely() throws {
    let breakdown = [FilterIntegration(filter: "Ha", usableFrameCount: 10, integrationSeconds: 3600 * 8)]
    let merged = FilterGoalQueries.merge(breakdown: breakdown, tags: ["goal:30h"])
    #expect(merged == breakdown)
}

// MARK: - biggestDeficit

@Test func biggestDeficitReturnsTheLargestMissingRow() throws {
    let merged = [
        FilterIntegration(filter: "Ha", usableFrameCount: 10, integrationSeconds: 3600 * 8, goalSeconds: 12 * 3600, missingSeconds: 4 * 3600),
        FilterIntegration(filter: "SII", usableFrameCount: 0, integrationSeconds: 0, goalSeconds: 6 * 3600, missingSeconds: 6 * 3600),
    ]
    let biggest = FilterGoalQueries.biggestDeficit(merged)
    #expect(biggest?.filter == "SII")
}

@Test func biggestDeficitReturnsNilWhenNoRowHasAnOutstandingDeficit() throws {
    let merged = [
        FilterIntegration(filter: "Ha", usableFrameCount: 20, integrationSeconds: 12 * 3600, goalSeconds: 12 * 3600, missingSeconds: 0),
    ]
    #expect(FilterGoalQueries.biggestDeficit(merged) == nil)
}

@Test func biggestDeficitReturnsNilWhenThereAreNoFilterGoalsAtAll() throws {
    let merged = [FilterIntegration(filter: "Ha", usableFrameCount: 10, integrationSeconds: 3600 * 8)]
    #expect(FilterGoalQueries.biggestDeficit(merged) == nil)
}
