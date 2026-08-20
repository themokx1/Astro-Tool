import Foundation
import Testing

/// Wave W6-A (static audit, rc.5), section B: four placeholders told the
/// reader to "configure it in Settings" with no way to actually get there --
/// Nights' 30-night calendar, Planning's no-library AND no-site states, and
/// Home's "nothing to shoot tonight" no-site state. This repo has no
/// rendering harness for `ContentUnavailableView`/placeholder bodies (see
/// `W3T12SilentFailureSurfaceTests`'s own doc comment), so -- same
/// convention as `W6ARetrySurfaceTests` -- this pins the fix with one
/// parameterized test over the whole list of sites rather than four
/// hardcoded per-file ones. Reverting any ONE site's action fails this same
/// test.
@Suite("W6-A Settings-pointer actions")
struct W6BSettingsPointerSurfaceTests {
    private struct PointerSite: Sendable {
        let path: String
        let snippet: String
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

    private static let sites: [PointerSite] = [
        // Nights' 30-night calendar: no site configured -> real Settings action.
        PointerSite(
            path: "Sources/AstroUI/Features/Nights/NightsView.swift",
            snippet: #"Button("Open Settings…") { openSettings() }"#
        ),
        // Planning's no-library state -> mirrors ArchiveView/HealthView's own chooseLibrary action.
        PointerSite(
            path: "Sources/AstroUI/Features/Planning/PlanningView.swift",
            snippet: #"Button("Choose Image Library…", action: chooseLibrary)"#
        ),
        // Planning's no-site state -> real Settings action.
        PointerSite(
            path: "Sources/AstroUI/Features/Planning/PlanningView.swift",
            snippet: #"Button("Open Settings…") { openSettings() }"#
        ),
        // Home's "nothing to shoot tonight" no-site branch -> real Settings action.
        PointerSite(
            path: "Sources/AstroUI/Features/Home/HomeView.swift",
            snippet: #"Button("Open Settings…") { openSettings() }"#
        ),
    ]

    @Test("every wave W6-A Settings-pointer placeholder wires a real action", arguments: sites)
    private func pointerHasRealAction(_ site: PointerSite) throws {
        let source = try contents(site.path)
        #expect(source.contains(site.snippet), "\(site.path) must contain \(site.snippet)")
    }

    @Test("PlanningView actually receives its own chooseLibrary closure from V2RootView, not just a dead default")
    func planningViewReceivesChooseLibraryFromRoot() throws {
        let planningSource = try contents("Sources/AstroUI/Features/Planning/PlanningView.swift")
        #expect(planningSource.contains("let chooseLibrary: () -> Void"), "PlanningView must declare its own chooseLibrary closure")

        let rootSource = try contents("Sources/AstroUI/App/V2RootView.swift")
        // The PlanningView(...) construction site must thread the shared
        // `chooseLibrary` through -- the same closure ArchiveView/HealthView
        // already receive -- not leave it at its default no-op.
        guard let planningCallRange = rootSource.range(of: "PlanningView(") else {
            Issue.record("V2RootView must construct PlanningView somewhere")
            return
        }
        let afterCall = rootSource[planningCallRange.lowerBound...]
        guard let closeParenRange = afterCall.range(of: "\n            )") else {
            Issue.record("Could not find the end of the PlanningView(...) call")
            return
        }
        let callSite = afterCall[afterCall.startIndex..<closeParenRange.upperBound]
        #expect(callSite.contains("chooseLibrary: chooseLibrary"), "V2RootView must pass its own chooseLibrary through to PlanningView")
    }
}
