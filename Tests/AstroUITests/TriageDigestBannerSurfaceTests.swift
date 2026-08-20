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
///
/// Also pins the "esetleg műholdcsík -- ellenőrizd" hedge row (expert
/// ideation #8): its own select callback, own accessibility identifier,
/// and never folded into `causes`' own confident-verdict selection path.
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

    @Test("The digest card is built from the table's own already-loaded rows, hidden when there are zero outliers and no low-altitude insight")
    func digestBuiltFromExistingRowsAndHiddenWhenEmpty() throws {
        let text = try source()
        #expect(text.contains("let digest = triageDigest(for: rows)"))
        #expect(
            text.contains("if !digest.isEmpty || lowAltitudeInsight != nil {"),
            "must not render a card with zero outliers AND no low-altitude insight"
        )
        #expect(text.contains("TriageDigestBanner("))
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

    @Test("The possible-streak hedge row has its own selection callback, own identifier, and its own (never auto-reject) selection path")
    func possibleStreakHasOwnSelectionPath() throws {
        let text = try source()
        #expect(text.contains("onSelectPossibleStreak: {"), "the call site must wire a dedicated closure, not reuse onSelectCause")
        #expect(text.contains("selectedDecisionIDs = Set(digest.selectPossibleStreakFrames())"))
        #expect(text.contains(#"accessibilityIdentifier("v2.review.triage-digest.select.possible-streak")"#))

        let bannerRange = try #require(text.range(of: "private struct TriageDigestBanner"))
        let extensionRange = try #require(text.range(of: "extension OutlierBreakdown.Metric"))
        let bannerBody = text[bannerRange.lowerBound..<extensionRange.lowerBound]
        #expect(!bannerBody.contains("apply("), "the possible-streak row must only select frames, never call apply(...)")
        #expect(bannerBody.contains("if digest.hasPossibleStreak {"), "absent entirely at zero hits")
    }

    @Test("The possible-streak row is visually distinct (secondary/hedged styling) from the confident cause rows")
    func possibleStreakRowIsVisuallyDistinct() throws {
        let text = try source()
        let bannerRange = try #require(text.range(of: "private struct TriageDigestBanner"))
        let extensionRange = try #require(text.range(of: "extension OutlierBreakdown.Metric"))
        let bannerBody = text[bannerRange.lowerBound..<extensionRange.lowerBound]
        let hedgeRange = try #require(bannerBody.range(of: "if digest.hasPossibleStreak {"))
        let hedgeBody = bannerBody[hedgeRange.lowerBound...]
        #expect(hedgeBody.contains(".foregroundStyle(.tertiary)"), "quieter than the causes' own .secondary rows")
        #expect(hedgeBody.contains(".italic()"))
        #expect(hedgeBody.contains("possible satellite trail"), "the English key must carry the hedge, never a bare 'satellite trail'")
    }

    /// Ideation #10 ("A leggyengébb kereteid mind alacsonyan készültek" --
    /// `FrameAirmassQuery.lowAltitudeQC`): pins the digest card's third
    /// insight line -- a CONFIDENT sky-geometry signal (never re-derived from
    /// `TriageDigestQuery`'s own causes, and never merged into the hedged
    /// possible-streak row below it), with its own accessibility identifier
    /// and no per-row "select frames" button (unlike `causes`, this names a
    /// whole-session pattern, not one specific set of frames to act on now).
    @Test("The low-altitude insight is its own confident line, distinct from both causes and the hedged streak row")
    func lowAltitudeInsightIsOwnConfidentLine() throws {
        let text = try source()
        #expect(text.contains("let lowAltitudeInsight: LowAltitudeQC?"))
        #expect(text.contains("if let lowAltitudeInsight {"))
        #expect(text.contains(#"accessibilityIdentifier("v2.review.triage-digest.low-altitude")"#))
        #expect(text.contains("lowAltitudeInsight.worstQuartileFrameCount"))

        let bannerRange = try #require(text.range(of: "private struct TriageDigestBanner"))
        let extensionRange = try #require(text.range(of: "extension OutlierBreakdown.Metric"))
        let bannerBody = text[bannerRange.lowerBound..<extensionRange.lowerBound]
        #expect(!bannerBody.contains("apply("), "the low-altitude line must never write a verdict")

        let lowAltitudeRange = try #require(bannerBody.range(of: "if let lowAltitudeInsight {"))
        let hedgeRange = try #require(bannerBody.range(of: "if digest.hasPossibleStreak {"))
        #expect(lowAltitudeRange.lowerBound < hedgeRange.lowerBound, "the confident low-altitude line renders above the hedged streak row")
        let lowAltitudeBody = bannerBody[lowAltitudeRange.lowerBound..<hedgeRange.lowerBound]
        #expect(lowAltitudeBody.contains(".foregroundStyle(.secondary)"), "same weight as a confident cause row, not the hedge's .tertiary/.italic")
        #expect(!lowAltitudeBody.contains(".italic()"), "a confident signal, never rendered like the hedge")
    }

    /// The DB-backed query behind this line must never run straight from
    /// `body`/a computed getter -- `refreshLowAltitudeInsight()` only ever
    /// fires from `.onChange` handlers, matching the codebase's own
    /// documented "heavy query in a computed getter can crash this app"
    /// lesson.
    @Test("The low-altitude insight is refreshed imperatively from onChange, never computed straight in body")
    func lowAltitudeInsightRefreshedImperatively() throws {
        let text = try source()
        #expect(text.contains("private func refreshLowAltitudeInsight()"))
        #expect(text.contains(".onChange(of: store.selectedSeriesID) { _, _ in"))
        #expect(text.contains("refreshLowAltitudeInsight()"))
        #expect(text.contains(".onChange(of: store.qualityByPath) { _, _ in refreshLowAltitudeInsight() }"))
    }
}
