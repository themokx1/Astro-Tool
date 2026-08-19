import Foundation
import Testing

/// Morning Triage Digest (expert ideation spec #1): pins the digest card's
/// wiring inside `ReviewWorkspace.swift` -- it is built from `qualityRows`'
/// own `rows` (no second query), hidden entirely when there are zero
/// outliers, and its per-cause button only ever changes `selectedDecisionIDs`
/// (selection, never a verdict write). This repo has no rendering harness
/// for verifying an actual live card (see `W3T12SilentFailureSurfaceTests`'s
/// own doc comment for the established literal-source-text convention this
/// follows instead, also used by `W6EReviewActionBarSurfaceTests`).
@Suite("Morning Triage Digest banner")
struct TriageDigestBannerSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source() throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/Features/Review/ReviewWorkspace.swift"),
            encoding: .utf8
        )
    }

    @Test("The digest card is built from the table's own already-loaded rows, hidden when there are zero outliers")
    func digestBuiltFromExistingRowsAndHiddenWhenEmpty() throws {
        let text = try source()
        #expect(text.contains("let digest = triageDigest(for: rows)"))
        #expect(text.contains("if !digest.isEmpty {"), "must not render a zero-outlier card")
        #expect(text.contains("TriageDigestBanner(digest: digest)"))
        #expect(text.contains(#"accessibilityIdentifier("v2.review.triage-digest")"#))
    }

    @Test("Each cause button only changes the table's existing selection, never writes a verdict")
    func causeButtonOnlySetsSelection() throws {
        let text = try source()
        #expect(text.contains("selectedDecisionIDs = Set(digest.selectFrames(forCause: metric))"))
        #expect(text.contains(#"accessibilityIdentifier("v2.review.triage-digest.select.\(cause.metric.rawValue)")"#))
        // Never a new write path: `apply(...)` is this file's own single
        // verdict-writing entry point (see `apply(_:decisionIDs:in:)`) --
        // the digest banner's own source slice must never call it.
        let bannerRange = try #require(text.range(of: "private struct TriageDigestBanner"))
        let extensionRange = try #require(text.range(of: "extension OutlierBreakdown.Metric"))
        let bannerBody = text[bannerRange.lowerBound..<extensionRange.lowerBound]
        #expect(!bannerBody.contains("apply("), "the digest banner must only select frames, never call the accept/reject apply(...) path")
    }

    @Test("Cause labels go through LocalizedStringKey, never OutlierBreakdown's own raw-Hungarian likelyCauseText/displayName")
    func causeLabelsAreLocalized() throws {
        let text = try source()
        #expect(text.contains("var triageCauseLabel: LocalizedStringKey"))
        #expect(text.contains("var triageSelectButtonLabel: LocalizedStringKey"))
        #expect(!text.contains("cause.metric.likelyCauseText"))
        #expect(!text.contains("cause.metric.displayName"))
    }
}
