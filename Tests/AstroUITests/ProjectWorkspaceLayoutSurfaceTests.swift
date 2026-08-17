import Foundation
import Testing

/// W4-4 item 4 (owner review): "The project header floats mid-page" -- with
/// little content (the Sorozat/Series tab's 5 rows) `ProjectWorkspaceView`'s
/// top-level `VStack` used to have no `.frame(maxHeight:)` of its own, so a
/// hugging `VStack` proposed more height than it needed centered vertically
/// in the leftover space instead of pinning its header to the top. Follows
/// this repo's established "surface" suite convention (`V2PolishSurfaceTests`,
/// `V2ShellSurfaceTests`): a literal source-text assertion, since this is a
/// layout-modifier-presence contract, not something worth standing up a
/// rendered view hierarchy to check.
@Suite("Project workspace header layout (W4-4 item 4)")
struct ProjectWorkspaceLayoutSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("ProjectWorkspaceView's body pins its content to the top instead of letting it center in leftover height")
    func bodyPinsContentToTop() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        #expect(source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)"))
    }
}
