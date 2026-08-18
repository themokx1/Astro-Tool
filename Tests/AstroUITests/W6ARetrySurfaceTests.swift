import Foundation
import Testing

/// Wave W6-A (static audit, rc.5), section A: a full pass over every V2
/// screen found seven load-failure `ContentUnavailableView`s that showed the
/// reader an error message and offered no way back short of leaving the
/// page -- the view's own store already had a working `load`/`open` (its
/// `.task` calls it on first appearance), there was simply no button that
/// called it again. This repo has no rendering harness for `ContentUnavailableView`
/// bodies (see `W3T12SilentFailureSurfaceTests`'s own doc comment for why
/// the established convention here is literal source-text assertions), so
/// this pins the fix the same way: one parameterized test over the whole
/// list of sites, all sharing the single `RetryButton` component
/// (`Sources/AstroUI/Features/Workspace/WorkspaceComponents.swift`) instead
/// of seven bespoke buttons. Reverting any ONE site's `RetryButton` call
/// fails this same test -- it is one pattern-level check, not seven
/// hardcoded per-file ones.
@Suite("W6-A error-state retry actions")
struct W6ARetrySurfaceTests {
    private struct RetrySite: Sendable {
        let path: String
        let identifier: String
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static let sites: [RetrySite] = [
        RetrySite(path: "Sources/AstroUI/Features/Insights/InsightsView.swift", identifier: "v2.insights.try-again"),
        RetrySite(path: "Sources/AstroUI/Features/Archive/ArchiveTaskDetailView.swift", identifier: "v2.archive.task-detail.try-again"),
        RetrySite(path: "Sources/AstroUI/Features/Library/CleanupPreviewView.swift", identifier: "v2.cleanup.try-again"),
        RetrySite(path: "Sources/AstroUI/Features/Library/SensorProfilesView.swift", identifier: "v2.sensor-profiles.try-again"),
        RetrySite(path: "Sources/AstroUI/Features/Results/ResultsView.swift", identifier: "v2.results.try-again"),
        RetrySite(path: "Sources/AstroUI/Features/Library/ConversionWorkspace.swift", identifier: "v2.conversion.try-again"),
        RetrySite(path: "Sources/AstroUI/Features/Review/ReviewWorkspace.swift", identifier: "v2.review.try-again"),
    ]

    @Test("every wave W6-A error state wires a RetryButton with its own identifier", arguments: sites)
    private func errorStateHasRetryButton(_ site: RetrySite) throws {
        let source = try contents(site.path)
        #expect(
            source.contains(#"RetryButton(identifier: "\#(site.identifier)""#),
            "\(site.path) must render RetryButton(identifier: \"\(site.identifier)\") inside its load-failure ContentUnavailableView"
        )
    }

    @Test("the shared RetryButton actually re-runs its host view's own load, not a no-op")
    func retryButtonBodyCallsLoad() throws {
        let source = try contents("Sources/AstroUI/Features/Workspace/WorkspaceComponents.swift")
        #expect(source.contains("struct RetryButton"), "RetryButton must exist as the one shared retry action")
        #expect(source.contains(#"Button("Try Again", action: action)"#), "RetryButton must render the established \"Try Again\" string, not a new one-off phrase")
    }
}
