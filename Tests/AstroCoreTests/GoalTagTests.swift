import Foundation
import Testing
@testable import AstroCore

// MARK: - Overall goal tag (unchanged, existing coverage lived only inside
// PlannerTests/CLISmokeTests before R11-T5) -- a few direct unit tests here
// too, since `GoalTag` is now the shared home for BOTH tag conventions.

@Test func goalTagParseFindsOverallGoalTagAmongOtherTags() throws {
    #expect(GoalTag.parse(tags: ["favorite", "goal:6h"]) == 6 * 3600.0)
}

@Test func goalTagParseReturnsNilWithoutAnOverallGoalTag() throws {
    #expect(GoalTag.parse(tags: ["favorite", "wide"]) == nil)
}

@Test func goalTagFormatPrintsIntegralHoursWithoutDecimal() throws {
    #expect(GoalTag.format(hours: 6) == "goal:6h")
}

@Test func goalTagFormatPrintsFractionalHoursWithOneDecimal() throws {
    #expect(GoalTag.format(hours: 6.5) == "goal:6.5h")
}

// MARK: - Per-filter goal tag: parse

@Test func parseFilterGoalsParsesASingleFilterGoalTag() throws {
    let goals = GoalTag.parseFilterGoals(tags: ["goal:Ha=12h"])
    #expect(goals.count == 1)
    #expect(goals[0].filter == "Ha")
    #expect(goals[0].seconds == 12 * 3600.0)
}

@Test func parseFilterGoalsParsesMultipleFilterGoalTags() throws {
    let goals = GoalTag.parseFilterGoals(tags: ["goal:Ha=12h", "goal:OIII=6.5h"])
    #expect(goals.count == 2)
    #expect(goals.first { $0.filter == "Ha" }?.seconds == 12 * 3600.0)
    #expect(goals.first { $0.filter == "OIII" }?.seconds == 6.5 * 3600.0)
}

@Test func parseFilterGoalsAcceptsATrailingHOptionally() throws {
    let goals = GoalTag.parseFilterGoals(tags: ["goal:Ha=12"])
    #expect(goals.count == 1)
    #expect(goals[0].seconds == 12 * 3600.0)
}

@Test func parseFilterGoalsPreservesTheFilterNamesOriginalCasing() throws {
    let goals = GoalTag.parseFilterGoals(tags: ["goal:OIII=3h"])
    #expect(goals.first?.filter == "OIII")
}

/// The overall `goal:30h` tag has no `=` at all -- must never be mistaken
/// for a filter goal.
@Test func parseFilterGoalsIgnoresTheOverallGoalTag() throws {
    let goals = GoalTag.parseFilterGoals(tags: ["goal:30h"])
    #expect(goals.isEmpty)
}

/// The two conventions coexist on the same target -- neither parser should
/// pick up the other's tag.
@Test func overallAndFilterGoalTagsCoexistWithoutInterference() throws {
    let tags = ["goal:30h", "goal:Ha=12h"]
    #expect(GoalTag.parse(tags: tags) == 30 * 3600.0)
    let filterGoals = GoalTag.parseFilterGoals(tags: tags)
    #expect(filterGoals.count == 1)
    #expect(filterGoals[0].filter == "Ha")
}

@Test func parseFilterGoalsSkipsATagWithAnEmptyFilterName() throws {
    let goals = GoalTag.parseFilterGoals(tags: ["goal:=12h"])
    #expect(goals.isEmpty)
}

@Test func parseFilterGoalsSkipsATagWithNoEqualsSeparator() throws {
    // No "=" at all -- not distinguishable from a plain overall goal tag,
    // so this must be skipped (never guessed at as a filter goal).
    let goals = GoalTag.parseFilterGoals(tags: ["goal:Ha12h"])
    #expect(goals.isEmpty)
}

@Test func parseFilterGoalsSkipsATagWithAnUnparseableNumber() throws {
    let goals = GoalTag.parseFilterGoals(tags: ["goal:Ha=notanumber"])
    #expect(goals.isEmpty)
}

@Test func parseFilterGoalsIgnoresUnrelatedTags() throws {
    let goals = GoalTag.parseFilterGoals(tags: ["favorite", "wide", "name:M42"])
    #expect(goals.isEmpty)
}

@Test func parseFilterGoalsReturnsEmptyForEmptyTags() throws {
    #expect(GoalTag.parseFilterGoals(tags: []).isEmpty)
}

/// Defensive edge case the spec explicitly calls out: a stray extra "="
/// inside whatever follows the filter name must not crash the parser --
/// it's expected to just fail the `Double(...)` parse and skip the tag.
@Test func parseFilterGoalsSkipsATagWithAnExtraEqualsSignInTheNumberPart() throws {
    let goals = GoalTag.parseFilterGoals(tags: ["goal:H=a=12h"])
    #expect(goals.isEmpty)
}

// MARK: - Per-filter goal tag: format + roundtrip

@Test func formatFilterPrintsIntegralHoursWithoutDecimal() throws {
    #expect(GoalTag.formatFilter(filter: "Ha", hours: 12) == "goal:Ha=12h")
}

@Test func formatFilterPrintsFractionalHoursWithOneDecimal() throws {
    #expect(GoalTag.formatFilter(filter: "OIII", hours: 6.5) == "goal:OIII=6.5h")
}

@Test func formatFilterRoundTripsThroughParseFilterGoals() throws {
    let tag = GoalTag.formatFilter(filter: "SII", hours: 4.5)
    let goals = GoalTag.parseFilterGoals(tags: [tag])
    #expect(goals.count == 1)
    #expect(goals[0].filter == "SII")
    #expect(goals[0].seconds == 4.5 * 3600.0)
}

// MARK: - Filter-goal draft validation

@Test func filterGoalValidationRejectsBlankName() {
    #expect(
        GoalTag.validateFilterGoal(name: "   ", hours: 2, otherNames: []) == .blankName
    )
}

@Test func filterGoalValidationRejectsCaseInsensitiveDuplicate() {
    #expect(
        GoalTag.validateFilterGoal(name: "ha", hours: 2, otherNames: ["Ha"]) == .duplicateName
    )
}

@Test func filterGoalValidationRejectsNonpositiveHours() {
    #expect(
        GoalTag.validateFilterGoal(name: "SII", hours: 0, otherNames: []) == .nonpositiveHours
    )
}

@Test func filterGoalValidationAcceptsAndNormalizesNewFilter() {
    #expect(GoalTag.normalizedFilterGoalName("  SII  ") == "SII")
    #expect(GoalTag.validateFilterGoal(name: "  SII  ", hours: 4.5, otherNames: ["Ha"]) == nil)
}

// MARK: - isFilterGoalTag / isOverallGoalTag

@Test func isFilterGoalTagMatchesCaseInsensitively() throws {
    #expect(GoalTag.isFilterGoalTag("goal:Ha=12h", filter: "ha"))
    #expect(GoalTag.isFilterGoalTag("goal:HA=12h", filter: "Ha"))
}

@Test func isFilterGoalTagDoesNotMatchADifferentFilter() throws {
    #expect(!GoalTag.isFilterGoalTag("goal:Ha=12h", filter: "OIII"))
}

@Test func isFilterGoalTagDoesNotMatchTheOverallGoalTag() throws {
    #expect(!GoalTag.isFilterGoalTag("goal:30h", filter: "Ha"))
}

@Test func isOverallGoalTagMatchesOnlyThePlainGoalShape() throws {
    #expect(GoalTag.isOverallGoalTag("goal:30h"))
    #expect(!GoalTag.isOverallGoalTag("goal:Ha=12h"))
    #expect(!GoalTag.isOverallGoalTag("favorite"))
}
