import Foundation
import Testing

/// Freeze diagnosis (build 20017, live-sampled): `Table` nested inside a
/// `ScrollView` gets an unbounded proposed height, so AppKit cannot
/// virtualize rows -- every layout pass materializes and lays out ALL rows
/// (up to 217 for Planning's catalog). `WorkspacePage` (see
/// `Sources/AstroUI/Features/Workspace/WorkspaceComponents.swift`) is a
/// `ScrollView`, so any view that puts a `Table` inside it reproduces this.
/// The fix is `WorkspaceTablePage`: a non-scrolling container whose table
/// region owns its own bounded height (`.frame(maxHeight: .infinity)`
/// inside a plain `VStack`, never a `ScrollView`), so `Table` virtualizes
/// normally. These are source-text assertions, in the same spirit as
/// `V2PolishSurfaceTests`/`V2NavigationSurfaceTests` -- they pin the
/// structural shape so this specific regression cannot silently return.
@Suite("V2 table-hosting workspaces never nest a Table inside a ScrollView")
struct V2LayoutGateTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The five feature views the freeze diagnosis named as table-hosting:
    /// Planning (worst offender, up to 217 catalog rows), Nights (2 tables),
    /// Calibration (2 tables), Projects (1 table), Library Health (1 table).
    private var tableHostingViewPaths: [String] {
        [
            "Sources/AstroUI/Features/Planning/PlanningView.swift",
            "Sources/AstroUI/Features/Nights/NightsView.swift",
            "Sources/AstroUI/Features/Library/CalibrationView.swift",
            "Sources/AstroUI/Features/Projects/ProjectsView.swift",
            "Sources/AstroUI/Features/Library/HealthView.swift",
        ]
    }

    private func source(at relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("None of the five table-hosting views puts a Table inside the scrolling WorkspacePage container")
    func noTableHostingViewNestsATableInsideWorkspacePage() throws {
        for path in tableHostingViewPaths {
            let source = try source(at: path)
            let hasTable = source.contains("Table(")
            let hasScrollingContainer = source.contains("WorkspacePage(")
            #expect(hasTable, "\(path) is expected to still host a Table -- update this gate if that's no longer true")
            #expect(
                !(hasTable && hasScrollingContainer),
                "\(path) contains both `Table(` and `WorkspacePage(` -- a Table must never sit inside the scrolling container"
            )
        }
    }

    @Test("Each table-hosting view uses the non-scrolling table page container")
    func eachTableHostingViewUsesTheNonScrollingContainer() throws {
        for path in tableHostingViewPaths {
            let source = try source(at: path)
            #expect(source.contains("WorkspaceTablePage("), "\(path) should render through WorkspaceTablePage")
        }
    }

    @Test("WorkspaceComponents defines the non-scrolling table page container")
    func workspaceComponentsDefinesTheNonScrollingContainer() throws {
        let components = try source(at: "Sources/AstroUI/Features/Workspace/WorkspaceComponents.swift")
        #expect(components.contains("struct WorkspaceTablePage"))
        // It must actually be non-scrolling -- no ScrollView anywhere in its
        // own definition (that would silently reintroduce the exact bug).
        let containerBody = try #require(components.components(separatedBy: "struct WorkspaceTablePage").last)
        #expect(!containerBody.contains("ScrollView"))
    }

    @Test("WorkspacePage itself is still available for genuinely scroll-shaped pages")
    func workspacePageStillExistsForScrollShapedPages() throws {
        let components = try source(at: "Sources/AstroUI/Features/Workspace/WorkspaceComponents.swift")
        #expect(components.contains("struct WorkspacePage"))
    }

    @Test("No Table anywhere in AstroUI is wrapped in a minHeight band-aid meant to give it height inside a ScrollView")
    func noTableCarriesAMinHeightBandAid() throws {
        let sourcesRoot = repositoryRoot.appendingPathComponent("Sources/AstroUI")
        let swiftFiles = try FileManager.default
            .enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }

        var offenders: [String] = []
        for file in swiftFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            if tableIsImmediatelyFollowedByMinHeightBandAid(in: contents) {
                offenders.append(file.lastPathComponent)
            }
        }

        #expect(offenders.isEmpty, "Table(s) with a minHeight band-aid found in: \(offenders.joined(separator: ", "))")
    }

    /// Walks `source` line by line: whenever a line contains `Table(`, tracks
    /// brace depth from that point until the Table's own trailing closure
    /// closes, then checks whether the very next non-blank line is a
    /// `.frame(minHeight:` modifier -- the exact shape the ScrollView-hosted
    /// tables used to need (and no longer should) to get any height at all.
    private func tableIsImmediatelyFollowedByMinHeightBandAid(in source: String) -> Bool {
        let lines = source.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            guard lines[index].contains("Table(") else {
                index += 1
                continue
            }

            var depth = 0
            var sawOpenBrace = false
            var closingLine = index
            while closingLine < lines.count {
                for character in lines[closingLine] {
                    if character == "{" {
                        depth += 1
                        sawOpenBrace = true
                    } else if character == "}" {
                        depth -= 1
                    }
                }
                if sawOpenBrace, depth <= 0 { break }
                closingLine += 1
            }

            var next = closingLine + 1
            while next < lines.count {
                let trimmed = lines[next].trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { next += 1; continue }
                if trimmed.hasPrefix(".frame(minHeight") { return true }
                break
            }

            index = closingLine + 1
        }
        return false
    }
}
