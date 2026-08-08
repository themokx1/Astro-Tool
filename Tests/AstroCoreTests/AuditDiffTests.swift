import Foundation
import Testing
@testable import AstroCore

/// `AuditDiff.compute` is a pure function of two `Finding` arrays -- no DB,
/// no filesystem -- so every test here just builds `Finding`s directly, the
/// same way `FindingGrouperTests` (if one existed) would. `category:
/// "placeholder-name"` is used throughout since its `groupKey` is simply the
/// finding's own `path` (`FindingGrouper.groupKey`'s default case), the
/// simplest case to reason about.
private func finding(
    severity: Severity = .sureError,
    category: String = "placeholder-name",
    path: String,
    message: String = "test finding"
) -> Finding {
    Finding(severity: severity, category: category, path: path, message: message)
}

private let config = AstroConfig()

@Test func auditDiffFlagsAFindingAbsentFromThePreviousRunAsNew() throws {
    let previous: [Finding] = []
    let current = [finding(path: "stacks/Foo")]

    let diff = AuditDiff.compute(previous: previous, current: current, config: config)

    #expect(diff.newCount == 1)
    #expect(diff.resolvedCount == 0)
    #expect(diff.unchangedCount == 0)
    #expect(diff.newGroups.first?.key.groupKey == "stacks/Foo")
}

@Test func auditDiffFlagsAFindingAbsentFromTheCurrentRunAsResolved() throws {
    let previous = [finding(path: "stacks/Foo")]
    let current: [Finding] = []

    let diff = AuditDiff.compute(previous: previous, current: current, config: config)

    #expect(diff.newCount == 0)
    #expect(diff.resolvedCount == 1)
    #expect(diff.unchangedCount == 0)
    #expect(diff.resolvedGroups.first?.key.groupKey == "stacks/Foo")
}

@Test func auditDiffFlagsASurvivingGroupAsUnchangedEvenWithADifferentMessage() throws {
    // The comparison unit is `(severity, category, groupKey)` -- NOT the
    // finding's own message/text, which can legitimately reword itself
    // between runs (e.g. a duplicate-content group listing a different
    // example path) without that meaning anything actually changed.
    let previous = [finding(path: "stacks/Foo", message: "old wording")]
    let current = [finding(path: "stacks/Foo", message: "new wording, still the same problem")]

    let diff = AuditDiff.compute(previous: previous, current: current, config: config)

    #expect(diff.newCount == 0)
    #expect(diff.resolvedCount == 0)
    #expect(diff.unchangedCount == 1)
}

@Test func auditDiffComparesAtSeverityCategoryAndGroupKeyGranularity() throws {
    // Same path (same `groupKey`), same category, but a DIFFERENT severity
    // -- a distinct group on each side, so it shows as both new (the
    // suspicious one) and resolved (the sure-error one), never "unchanged".
    let previous = [finding(severity: .sureError, path: "stacks/Foo")]
    let current = [finding(severity: .suspicious, path: "stacks/Foo")]

    let diff = AuditDiff.compute(previous: previous, current: current, config: config)

    #expect(diff.newCount == 1)
    #expect(diff.resolvedCount == 1)
    #expect(diff.unchangedCount == 0)
    #expect(diff.newGroups.first?.key.severity == .suspicious)
    #expect(diff.resolvedGroups.first?.key.severity == .sureError)
}

@Test func auditDiffComparesAtCategoryGranularityToo() throws {
    // Same path, same severity, but a DIFFERENT category -- again two
    // distinct groups, not one "unchanged" match.
    let previous = [finding(category: "placeholder-name", path: "stacks/Foo")]
    let current = [finding(category: "similar-target-names", path: "stacks/Foo")]

    let diff = AuditDiff.compute(previous: previous, current: current, config: config)

    #expect(diff.newCount == 1)
    #expect(diff.resolvedCount == 1)
    #expect(diff.unchangedCount == 0)
}

@Test func auditDiffOnTwoEmptyRunsIsEmpty() throws {
    let diff = AuditDiff.compute(previous: [], current: [], config: config)

    #expect(diff.newCount == 0)
    #expect(diff.resolvedCount == 0)
    #expect(diff.unchangedCount == 0)
}

@Test func auditDiffHandlesAMixOfNewResolvedAndUnchangedInOneComparison() throws {
    let previous = [
        finding(path: "stacks/StillThere"),
        finding(path: "stacks/NowFixed"),
    ]
    let current = [
        finding(path: "stacks/StillThere"),
        finding(path: "stacks/BrandNew"),
    ]

    let diff = AuditDiff.compute(previous: previous, current: current, config: config)

    #expect(diff.newCount == 1)
    #expect(diff.resolvedCount == 1)
    #expect(diff.unchangedCount == 1)
    #expect(Set(diff.newGroups.map(\.key.groupKey)) == ["stacks/BrandNew"])
    #expect(Set(diff.resolvedGroups.map(\.key.groupKey)) == ["stacks/NowFixed"])
    #expect(Set(diff.unchangedGroups.map(\.key.groupKey)) == ["stacks/StillThere"])
}

/// `FindingGrouper`'s own residue grouping (extension-class groupKey) still
/// applies here unchanged -- two `.seq` files in different directories both
/// group under the SAME `*.seq` key, so a residue category is genuinely
/// "unchanged" across runs even if the individual offending files moved.
@Test func auditDiffGroupsResidueByExtensionClassNotByExactPath() throws {
    let previous = [finding(severity: .suspicious, category: "residue", path: "stacks/A/x.seq")]
    let current = [finding(severity: .suspicious, category: "residue", path: "stacks/B/y.seq")]

    let diff = AuditDiff.compute(previous: previous, current: current, config: config)

    #expect(diff.newCount == 0)
    #expect(diff.resolvedCount == 0)
    #expect(diff.unchangedCount == 1)
}

/// `AuditDiff` never looks at ack state at all -- there's no ack parameter,
/// no `Database` access, nothing to configure. This test is really just
/// documentation-by-example: an "acked" group (represented here by nothing
/// more than existing in both runs) is still reported as unchanged exactly
/// like any other surviving group, proving ack status can never change
/// which bucket a group falls into.
@Test func auditDiffTreatsEveryGroupIdenticallyRegardlessOfAckStatus() throws {
    let previous = [finding(severity: .suspicious, category: "residue", path: "stacks/A/.DS_Store")]
    let current = [finding(severity: .suspicious, category: "residue", path: "stacks/A/.DS_Store")]

    let diff = AuditDiff.compute(previous: previous, current: current, config: config)

    #expect(diff.unchangedCount == 1)
    #expect(diff.newCount == 0)
    #expect(diff.resolvedCount == 0)
}

@Test func auditDiffOmitsDuplicateCategoriesWhenRunSettingsDiffer() throws {
    let previous = [
        finding(severity: .suspicious, category: "duplicate-content", path: "sessions/A/a.fit"),
        finding(path: "stacks/StillThere"),
    ]
    let current = [finding(path: "stacks/StillThere")]

    let diff = AuditDiff.compute(
        previous: previous,
        current: current,
        config: config,
        previousIncludedDuplicates: true,
        currentIncludedDuplicates: false
    )

    #expect(diff.omittedCategories == ["duplicate-content"])
    #expect(diff.newCount == 0)
    #expect(diff.resolvedCount == 0)
    #expect(diff.unchangedCount == 1)
}

@Test func auditDiffIncludesDuplicateCategoriesWhenBothRunsUsedThem() throws {
    let previous = [
        finding(severity: .suspicious, category: "duplicate-content", path: "sessions/A/a.fit"),
    ]

    let diff = AuditDiff.compute(
        previous: previous,
        current: [],
        config: config,
        previousIncludedDuplicates: true,
        currentIncludedDuplicates: true
    )

    #expect(diff.omittedCategories.isEmpty)
    #expect(diff.resolvedCount == 1)
}
