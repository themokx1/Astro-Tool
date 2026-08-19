import Foundation
import Testing

/// Ideation #4 ("Célpont-történet idővonal"): `TargetHistoryTimeline`
/// (`AstroApplication`) has no UI consumer of its own before this ticket --
/// same "no rendering harness for a SwiftUI body" situation
/// `NightRibbonSurfaceTests`'s own doc comment explains, so this pins the
/// wiring itself: `ProjectWorkspaceView` actually loads and mounts the
/// timeline as its own Overview-tab section, its row cap/disclosure exists,
/// and its own row-text call sites never fall into the ternary trap
/// `LocalizationCoverageTests.saveTargetLocalizesDespiteTernary` already
/// pins down for a sibling call site.
@Suite("Target history timeline mount")
struct TargetHistoryTimelineSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("ProjectWorkspaceView loads TargetHistoryTimeline off its own rootURL/target, and mounts a History section")
    func projectWorkspaceLoadsAndMountsTheTimeline() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")

        #expect(source.contains("@State private var historyEvents: [TargetHistoryEvent]?"))
        #expect(source.contains("TargetHistoryTimeline.production(rootURL: rootURL, target: target)"))
        #expect(source.contains("ReportSection(title: \"History\")"))
        #expect(source.contains("historySection"))
    }

    @Test("The History section renders as its own section on the Overview tab, below the report sections -- not a sixth tab")
    func historySectionIsPlacedBelowReportSections() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        let route = try contents("Sources/AstroUI/App/AppRoute.swift")

        // The spec explicitly offered "a sixth tab if Overview is already
        // heavy" as the alternative -- this pins the decision actually
        // taken: `ProjectWorkspaceTab` still has exactly its original five
        // cases, and the timeline is a `ReportSection` sibling appended
        // after `reportSections`' own `if`/`else if` chain, not a new tab
        // case.
        #expect(route.contains("case overview = \"Overview\""))
        #expect(route.contains("case nights = \"Nights\""))
        #expect(route.contains("case series = \"Series\""))
        #expect(route.contains("case results = \"Results\""))
        #expect(route.contains("case notes = \"Notes\""))
        #expect(!route.contains("case history"))
        guard let anchor = source.range(of: "historySection\n    }") else {
            Issue.record("reportSections no longer ends with a trailing `historySection` sibling statement -- update this test's landmark")
            return
        }
        #expect(source[..<anchor.lowerBound].contains("ReportSection(title: \"Planning\")"))
    }

    @Test("The History section caps visible rows and offers a disclosure to reveal the rest")
    func historySectionCapsVisibleRows() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")

        #expect(source.contains("private static let historyVisibleCap = 12"))
        #expect(source.contains("events.count > Self.historyVisibleCap"))
        #expect(source.contains("v2.project.history.disclosure"))
    }

    @Test("The 'more'/'fewer' disclosure label uses two separate Text(_:) branches, never a ternary of two string literals")
    func disclosureLabelAvoidsTheTernaryTrap() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")

        // The exact bug `LocalizationCoverageTests.saveTargetLocalizesDespiteTernary`
        // documents for a sibling call site: `Text(cond ? "A" : "\(x) B")`
        // infers as plain `String` (never `LocalizedStringKey`) the moment
        // either ternary arm interpolates, silently rendering BOTH arms in
        // English forever regardless of `hu.lproj`. This call site must use
        // an `if`/`else` with two independent `Text(_:)` literal call
        // sites instead.
        #expect(!source.contains(#"Text(isHistoryExpanded ? "#))
        #expect(source.contains(#"Text("Show fewer")"#))
        #expect(source.contains(#"Text("\(AstroFormat.count(events.count - Self.historyVisibleCap)) more")"#))
    }

    @Test("Every History row's text is built from a pre-formatted String interpolated directly at its own Text(_:) call site")
    func historyRowTextUsesPreformattedInterpolationLiterals() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")

        #expect(source.contains(#"Text("First light")"#))
        #expect(source.contains(#"Text("\(durationText) collected · FWHM \(AstroFormat.fwhmArcsec(fwhmArcsec))")"#))
        #expect(source.contains(#"Text("\(durationText) collected · FWHM \(AstroFormat.fwhmPixels(fwhmPixels))")"#))
        #expect(source.contains(#"Text("\(durationText) collected")"#))
        #expect(source.contains(#"Text("\(AstroFormat.count(fileNames.count)) stack produced: \(namesText)")"#))
    }
}
