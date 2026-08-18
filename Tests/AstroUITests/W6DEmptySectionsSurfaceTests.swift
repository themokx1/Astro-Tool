import Foundation
import Testing

/// Wave W6-A (static audit, rc.5), section D: three sections rendered as a
/// bare header with nothing underneath them once their own data was empty --
/// `NightWorkspaceView`'s Capture Groups grid, `ProjectWorkspaceView`'s
/// Calibration grid, and `ArchiveView`'s Targets section under an
/// all-excluding strip filter. This repo has no rendering harness for these
/// bodies (see `W3T12SilentFailureSurfaceTests`'s own doc comment), so --
/// same convention as the rest of this wave -- these pin the state-dependent
/// copy each fix introduced.
@Suite("W6-A empty-section guards")
struct W6DEmptySectionsSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("NightWorkspaceView's Capture Groups grid gets a ReportEmptyNote, mirroring the Filters section right above it")
    func nightCaptureGroupsHasEmptyNote() throws {
        let source = try contents("Sources/AstroUI/Features/Nights/NightWorkspaceView.swift")
        guard let range = source.range(of: "ReportSection(title: \"Capture Groups\")") else {
            Issue.record("Capture Groups section not found")
            return
        }
        let section = source[range.lowerBound...]
        #expect(section.contains("report.captureGroups.isEmpty"), "the grid must be guarded on the same collection it renders")
        #expect(section.contains(#"ReportEmptyNote(text: "No capture groups for this session.")"#), "an empty result must explain itself, not render a bare header")
    }

    @Test("ProjectWorkspaceView's Calibration grid gets a ReportEmptyNote, mirroring the Sessions section's own guard")
    func projectCalibrationHasEmptyNote() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        guard let range = source.range(of: "ReportSection(title: \"Calibration\")") else {
            Issue.record("Calibration section not found")
            return
        }
        let section = source[range.lowerBound...]
        #expect(section.contains("report.sessions.isEmpty"), "Calibration is keyed off the same report.sessions the Sessions section already guards")
        #expect(section.contains(#"ReportEmptyNote(text: "No recorded session, so no calibration data for this target.")"#), "an empty result must explain itself, not render a bare header")
    }

    @Test("ArchiveView's Targets section names the active strip filter and offers a real way to clear it")
    func archiveTargetsExplainsAnExcludingFilter() throws {
        let source = try contents("Sources/AstroUI/Features/Archive/ArchiveView.swift")
        guard let range = source.range(of: "Section(\"Targets\")") else {
            Issue.record("Targets section not found")
            return
        }
        let section = source[range.lowerBound...]
        #expect(section.contains("store.selectedClass"), "the message must be conditioned on the active filter, not just an empty row count")
        #expect(section.contains(#"Text("No targets match the “\(selectedClass.displayName)” filter.")"#), "the message must name which filter is active")
        #expect(section.contains(#"Button("Clear Filter") { store.selectedClass = nil }"#), "clearing the filter must be a real action, not just advice -- ArchiveStripView's own tap gesture never calls onSelect(nil)")
    }

    @Test("ArchiveClass.displayName is reusable outside ArchiveStripView, not file-private")
    func archiveClassDisplayNameIsNotFilePrivate() throws {
        let source = try contents("Sources/AstroUI/Features/Archive/ArchiveStripView.swift")
        #expect(!source.contains("private extension ArchiveClass"), "ArchiveView's own empty-filter message needs this vocabulary too")
        #expect(source.contains("extension ArchiveClass"), "the extension must still exist, just not file-private")
    }
}
