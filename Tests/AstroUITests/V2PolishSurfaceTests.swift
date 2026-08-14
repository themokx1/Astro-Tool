import Foundation
import Testing

/// Wave 3 Task 8: the Apple-HIG polish sweep's own gate. Follows this
/// repo's established "surface" suite convention (`HelpSurfaceTests`,
/// `V2ShellSurfaceTests`): literal source-text assertions rather than
/// rendering the view tree, since these are wiring/vocabulary/consistency
/// contracts, not layout contracts.
@Suite("V2 Apple-HIG polish sweep")
struct V2PolishSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private var featureViewPaths: [(name: String, path: String)] {
        [
            ("HomeView", "Sources/AstroUI/Features/Home/HomeView.swift"),
            ("ProjectsView", "Sources/AstroUI/Features/Projects/ProjectsView.swift"),
            ("NightsView", "Sources/AstroUI/Features/Nights/NightsView.swift"),
            ("PlanningView", "Sources/AstroUI/Features/Planning/PlanningView.swift"),
            ("LibraryView", "Sources/AstroUI/Features/Library/LibraryView.swift"),
            ("InsightsView", "Sources/AstroUI/Features/Insights/InsightsView.swift"),
            ("ResultsView", "Sources/AstroUI/Features/Results/ResultsView.swift"),
            ("HealthView", "Sources/AstroUI/Features/Library/HealthView.swift"),
            ("SensorProfilesView", "Sources/AstroUI/Features/Library/SensorProfilesView.swift"),
            ("CalibrationView", "Sources/AstroUI/Features/Library/CalibrationView.swift"),
        ]
    }

    // MARK: (a) The Inspector is contextual, not a Type/Identifier stub.

    @Test("InspectorView no longer shows the flat Type/Identifier stub")
    func inspectorIsNotAStub() throws {
        let source = try contents("Sources/AstroUI/Inspector/InspectorView.swift")
        // The old stub rendered exactly these two rows and nothing else for
        // every selection kind -- if both literal rows are still here
        // (still reachable from `selectionDetails`), the stub survived.
        let hasStubTypeRow = source.contains(#"LabeledContent("Type", value: kind(for: selection))"#)
        let hasStubIdentifierRow = source.contains(#"LabeledContent("Identifier", value: identifier(for: selection))"#)
        #expect(!(hasStubTypeRow && hasStubIdentifierRow))
    }

    @Test("InspectorView renders real, distinct content for project, night, series, and result selections")
    func inspectorHasContextualContentForEverySelectionKind() throws {
        let source = try contents("Sources/AstroUI/Inspector/InspectorView.swift")

        // project: a real project summary, not just its raw identifier.
        #expect(source.contains("case .project"))
        #expect(source.contains("projectsStore.selectedProject"))

        // night: a real night summary from the already-loaded NightRow.
        #expect(source.contains("case .night"))
        #expect(source.contains("nightsStore.nights"))

        // series: reuses the existing SeriesInspector when review data is
        // loaded, and otherwise a lean summary built from already-loaded
        // project data -- either way, real capture data, not an identifier.
        #expect(source.contains("case .series"))
        #expect(source.contains("SeriesInspector("))

        // result: a provenance summary (the Results workspace's own
        // lineage vocabulary), not just the raw result identifier.
        #expect(source.contains("case .result"))
        #expect(source.contains("ResultsQuery("))
        #expect(source.contains("Lineage"))

        // Nothing selected still gets a quiet, honest empty state.
        #expect(source.contains("ContentUnavailableView"))
    }

    // MARK: (b) Every main feature view has a ContentUnavailableView empty state.

    @Test("Every main feature view expresses its empty state through ContentUnavailableView")
    func everyFeatureViewHasAContentUnavailableEmptyState() throws {
        for (name, path) in featureViewPaths {
            let source = try contents(path)
            #expect(source.contains("ContentUnavailableView"), "\(name) has no ContentUnavailableView")
        }
    }

    // MARK: (c) No hardcoded colors under Features/ or Settings/.

    @Test("No file under Features/ or Settings/ hardcodes a color literal")
    func noHardcodedColorLiterals() throws {
        let root = repositoryRoot.appendingPathComponent("Sources/AstroUI")
        let directories = ["Features", "Settings"]
        var offenders: [String] = []
        for directory in directories {
            let base = root.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if text.contains("Color(red:") || text.contains("Color(#colorLiteral") {
                    offenders.append(url.lastPathComponent)
                }
            }
        }
        #expect(offenders.isEmpty, "Hardcoded color literals in: \(offenders.joined(separator: ", "))")
    }

    // MARK: (d) Primary toolbar buttons carry `.help(` tooltips.

    @Test("Primary toolbar controls in the main workspaces carry .help( tooltips")
    func primaryToolbarControlsHaveTooltips() throws {
        // Wave 4 Task 2: `ProjectWorkspaceView`'s own Review Frames/Results
        // buttons moved out of its body into structured `WorkspaceAction`
        // values (a plain `help: String?` data field, not a `.help(`
        // modifier call) -- the shell's own toolbar (`V2RootView`, already
        // in this list) is what actually calls `.help(action.help ?? "")`
        // to render their tooltips now, so that's where this gate reads
        // them from for that workspace. `HealthView`/`ReviewWorkspace`
        // still wrap their own menu-shaped actions (Run Audit, Rate Frames)
        // as literal inline view code passed to the toolbar, so their
        // `.help(` calls stay put in their own files untouched.
        let toolbarFiles = [
            "Sources/AstroUI/Features/Review/ReviewWorkspace.swift",
            "Sources/AstroUI/Features/Library/HealthView.swift",
            "Sources/AstroUI/Features/Library/CalibrationView.swift",
            "Sources/AstroUI/Features/Results/ResultsView.swift",
            "Sources/AstroUI/App/V2RootView.swift",
        ]
        for path in toolbarFiles {
            let source = try contents(path)
            #expect(source.contains(".help("), "\(path) has no .help( tooltip")
        }
    }
}
