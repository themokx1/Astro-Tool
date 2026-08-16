import Foundation
import Testing

/// V2 UI/UX audit (2026-08-14) section 6: this app's two most important
/// interactions -- the three workspace tab pickers and Review's Accept/
/// Reset/Reject buttons -- had no `accessibilityIdentifier` at all, so no
/// UI test could drive them. Separately, five identifiers repeated per row
/// (`v2.frame.thumbnail`, `v2.review.quality-columns`, `v2.projects.night`,
/// `v2.toast-layer.toast`, `v2.nights.action-menu`), matching ambiguously in
/// any query. Follows this repo's established "surface" suite convention:
/// literal source-text assertions, since these are wiring contracts.
@Suite("V2 accessibility identifiers -- missing controls and de-duplicated rows")
struct V2AccessibilityIdentifierSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: Missing identifiers

    @Test("The three workspace tab pickers each carry their own identifier")
    func workspaceTabPickersHaveIdentifiers() throws {
        let project = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        #expect(project.contains(#"accessibilityIdentifier("v2.project.workspace.tab")"#))

        let night = try contents("Sources/AstroUI/Features/Nights/NightWorkspaceView.swift")
        #expect(night.contains(#"accessibilityIdentifier("v2.night.workspace.tab")"#))

        let series = try contents("Sources/AstroUI/Features/Projects/SeriesWorkspaceView.swift")
        #expect(series.contains(#"accessibilityIdentifier("v2.series.workspace.tab")"#))
    }

    @Test("Review's Accept/Reset/Reject toolbar buttons each carry an identifier")
    func reviewDecisionButtonsHaveIdentifiers() throws {
        let source = try contents("Sources/AstroUI/Features/Review/ReviewWorkspace.swift")
        #expect(source.contains(#"accessibilityIdentifier("v2.review.accept")"#))
        #expect(source.contains(#"accessibilityIdentifier("v2.review.reset")"#))
        #expect(source.contains(#"accessibilityIdentifier("v2.review.reject")"#))
    }

    @Test("The New Project toolbar button carries an identifier")
    func newProjectToolbarButtonHasIdentifier() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(source.contains(#"accessibilityIdentifier("v2.toolbar.new-project")"#))
    }

    @Test("HealthView's Calibration… button carries an identifier")
    func healthCalibrationButtonHasIdentifier() throws {
        let source = try contents("Sources/AstroUI/Features/Library/HealthView.swift")
        #expect(source.contains(#"accessibilityIdentifier("v2.health.open-calibration")"#))
    }

    @Test("ArchiveView's Choose/Organize/Change buttons each carry an identifier")
    func libraryViewButtonsHaveIdentifiers() throws {
        // Task 10: `LibraryView` (and its `v2.library.*` identifiers) is
        // gone -- its three buttons survive as `ArchiveView`'s own toolbar
        // actions instead. "Choose" is a plain in-body button (a literal
        // `.accessibilityIdentifier(...)` call); "Organize"/"Change" are
        // `WorkspaceAction`s whose own `id` is what `V2RootView`'s shared
        // toolbar rendering later applies as the identifier -- both shapes
        // are covered by checking each id string is declared at all, the
        // same convention `ArchiveViewSurfaceTests` already uses.
        let source = try contents("Sources/AstroUI/Features/Archive/ArchiveView.swift")
        #expect(source.contains(#"accessibilityIdentifier("v2.archive.choose")"#))
        #expect(source.contains(#""v2.archive.organize""#))
        #expect(source.contains(#""v2.archive.change""#))
    }

    @Test("HomeView's per-recommendation Open button is uniquely identified per row")
    func homeOpenButtonIsUniquePerRow() throws {
        let source = try contents("Sources/AstroUI/Features/Home/HomeView.swift")
        #expect(source.contains(#"accessibilityIdentifier("v2.home.open-recommendation.\(recommendation.id)")"#))
    }

    @Test("ProjectWorkspaceView's Save Project Details button carries an identifier")
    func saveProjectDetailsButtonHasIdentifier() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        #expect(source.contains(#"accessibilityIdentifier("v2.project.save-details")"#))
    }

    @Test("The Conversion wizard's Back/Continue buttons each carry an identifier")
    func conversionWizardBackContinueHaveIdentifiers() throws {
        let source = try contents("Sources/AstroUI/Features/Library/ConversionWorkspace.swift")
        #expect(source.contains(#"accessibilityIdentifier("v2.conversion.back")"#))
        #expect(source.contains(#"accessibilityIdentifier("v2.conversion.continue")"#))
    }

    // MARK: De-duplicated per-row identifiers

    @Test("FrameThumbnailCell's identifier is suffixed by its own relativePath")
    func frameThumbnailIdentifierIsUniquePerRow() throws {
        let source = try contents("Sources/AstroUI/Features/Review/FrameThumbnailCell.swift")
        #expect(!source.contains(#"accessibilityIdentifier("v2.frame.thumbnail")"#))
        #expect(source.contains(#"accessibilityIdentifier("v2.frame.thumbnail.\(relativePath)")"#))
    }

    @Test("ReviewWorkspace's quality-columns identifier is suffixed by the row's own id")
    func reviewQualityColumnsIdentifierIsUniquePerRow() throws {
        let source = try contents("Sources/AstroUI/Features/Review/ReviewWorkspace.swift")
        #expect(!source.contains(#"accessibilityIdentifier("v2.review.quality-columns")"#))
        #expect(source.contains("v2.review.quality-columns.\\(row.id"))
    }

    @Test("ProjectsView's per-night identifier is suffixed by the night's own id")
    func projectsNightIdentifierIsUniquePerRow() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectsView.swift")
        #expect(!source.contains(#"accessibilityIdentifier("v2.projects.night")"#))
        #expect(source.contains("v2.projects.night.\\(snapshot.id"))
    }

    @Test("ToastOverlay's toast identifier is suffixed by the toast's own id")
    func toastIdentifierIsUniquePerToast() throws {
        let source = try contents("Sources/AstroUI/Operations/ToastOverlay.swift")
        #expect(!source.contains(#"accessibilityIdentifier("v2.toast-layer.toast")"#))
        #expect(source.contains("v2.toast-layer.toast.\\(toast.id"))
    }

    @Test("NightActionMenu's identifier is suffixed by the night's own id")
    func nightActionMenuIdentifierIsUniquePerNight() throws {
        let source = try contents("Sources/AstroUI/Features/Nights/NightActionMenu.swift")
        #expect(!source.contains(#"accessibilityIdentifier("v2.nights.action-menu")"#))
        #expect(source.contains("v2.nights.action-menu.\\(nightID"))
    }
}
