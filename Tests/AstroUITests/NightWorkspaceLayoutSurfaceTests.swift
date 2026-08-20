import Foundation
import Testing

/// Owner review (2026-08-19): "ahogy váltok a tabok között, a tabsor elugrál
/// a tartalom függvényében" -- the IDENTICAL defect `ProjectWorkspaceView`
/// fixed in `4fc3993` ("stop the header floating mid-page"), pinned there by
/// `ProjectWorkspaceLayoutSurfaceTests`. `NightWorkspaceView`'s Series tab
/// renders its `Table` directly (row-count-capped height, deliberately
/// outside the Overview/Frames/Notes tabs' shared `ScrollView`), so without a
/// `.frame(maxHeight:)` of its own the top-level `VStack` centered in
/// whatever extra height the pane proposed instead of pinning its header to
/// the top. Follows the same "surface" suite convention as
/// `ProjectWorkspaceLayoutSurfaceTests`/`V2PolishSurfaceTests`/
/// `V2ShellSurfaceTests`: a literal source-text assertion, since this is a
/// layout-modifier-presence contract, not something worth standing up a
/// rendered view hierarchy to check.
@Suite("Night workspace header layout")
struct NightWorkspaceLayoutSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("NightWorkspaceView's body pins its content to the top instead of letting it center in leftover height")
    func bodyPinsContentToTop() throws {
        let source = try contents("Sources/AstroUI/Features/Nights/NightWorkspaceView.swift")
        #expect(source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)"))
    }
}
