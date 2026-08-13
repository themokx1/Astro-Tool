import Foundation
import Testing

@Suite("V2 workspace parity")
struct V2WorkspaceParitySurfaceTests {
    @Test("Projects is a native selectable work table")
    func projectsTableContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectsView.swift"))
        #expect(source.contains("Table("))
        #expect(source.contains("selection:"))
        #expect(source.contains("TableColumn(\"Integration\""))
        #expect(source.contains("contextMenu"))
        #expect(source.contains("onTapGesture(count: 2)"))
    }
}
