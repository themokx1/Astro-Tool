import AstroCore
import Foundation
import Testing

@testable import AstroUI

/// Expert ideation spec #4 ("Session Summary Card -- shareable PNG"):
/// `SessionCardAssembler`'s data-layer tests. `ImageRenderer`-driven PNG
/// snapshot testing isn't practical in a headless test target (same
/// constraint `ExportMenu`'s own `NSSavePanel` call has -- see
/// `ExportFileWriter`'s doc comment), so this suite tests the pure
/// content-assembly function directly and pins the view/export wiring with
/// the same source-scan convention `V2SettingsTests`/
/// `W53NightReportFindingsSurfaceTests` already establish for an
/// `NSSavePanel` call site.
@Suite("Session card (expert ideation spec #4)")
struct SessionCardTests {
    private func quality(
        frameCount: Int = 12,
        medianFWHMPixels: Double? = nil,
        medianFWHMArcsec: Double? = nil,
        backgroundEPerSecPerArcsec2: Double? = nil
    ) -> SessionQualitySummary {
        SessionQualitySummary(
            target: "IC_4604",
            date: "2026-08-17",
            frameCount: frameCount,
            medianFWHMPixels: medianFWHMPixels,
            medianFWHMArcsec: medianFWHMArcsec,
            backgroundEPerSecPerArcsec2: backgroundEPerSecPerArcsec2
        )
    }

    @Test("Every displayed field equals the source data it was assembled from")
    func everyFieldEqualsSourceData() {
        let content = SessionCardAssembler.content(
            targetName: "IC 4604 Rho Ophiuchi",
            dateText: "2026-08-17",
            integrationText: "3:12 h",
            quality: quality(frameCount: 42, medianFWHMArcsec: 2.345, backgroundEPerSecPerArcsec2: 0.00231),
            thumbnailRelativePath: "sessions/IC_4604/2026-08-17/frame_012.fits"
        )

        #expect(content.targetName == "IC 4604 Rho Ophiuchi")
        #expect(content.dateText == "2026-08-17")
        #expect(content.integrationText == "3:12 h")
        #expect(content.ratedFrameCount == 42)
        #expect(content.fwhmText == AstroFormat.fwhmArcsec(2.345))
        #expect(content.backgroundText == AstroFormat.backgroundEPerSecArcsec2(0.00231))
        #expect(content.thumbnailRelativePath == "sessions/IC_4604/2026-08-17/frame_012.fits")
        #expect(content.appName == "AstroTool")
    }

    @Test("FWHM falls back from arcsec to pixels when no pixel scale resolved")
    func fwhmFallsBackToPixels() {
        let content = SessionCardAssembler.content(
            targetName: "M 31",
            dateText: "2026-08-01",
            integrationText: "1:00 h",
            quality: quality(medianFWHMPixels: 3.1, medianFWHMArcsec: nil),
            thumbnailRelativePath: nil
        )
        #expect(content.fwhmText == AstroFormat.fwhmPixels(3.1))
    }

    @Test("A nil-FWHM session renders the honest placeholder, never 0")
    func nilFWHMRendersPlaceholderNeverZero() {
        let content = SessionCardAssembler.content(
            targetName: "M 42",
            dateText: "2026-07-04",
            integrationText: "0:00 h",
            quality: quality(medianFWHMPixels: nil, medianFWHMArcsec: nil),
            thumbnailRelativePath: nil
        )
        #expect(content.fwhmText == SessionCardAssembler.unmeasuredText)
        #expect(!content.fwhmText.contains("0"))
    }

    @Test("A nil background renders the honest placeholder, never 0")
    func nilBackgroundRendersPlaceholder() {
        let content = SessionCardAssembler.content(
            targetName: "M 42",
            dateText: "2026-07-04",
            integrationText: "0:00 h",
            quality: quality(backgroundEPerSecPerArcsec2: nil),
            thumbnailRelativePath: nil
        )
        #expect(content.backgroundText == SessionCardAssembler.unmeasuredText)
    }

    @Test("A completely unrated session (nil quality) also renders both placeholders")
    func nilQualityRendersBothPlaceholders() {
        let content = SessionCardAssembler.content(
            targetName: "M 42",
            dateText: "2026-07-04",
            integrationText: "0:00 h",
            quality: nil,
            thumbnailRelativePath: nil
        )
        #expect(content.fwhmText == SessionCardAssembler.unmeasuredText)
        #expect(content.backgroundText == SessionCardAssembler.unmeasuredText)
        #expect(content.ratedFrameCount == 0)
    }

    @Test("Export is gated on the same 'has at least one rated frame' predicate the Overview tab already uses")
    func exportGatingMatchesOverviewTabPredicate() {
        #expect(!SessionCardAssembler.isExportable(quality: nil))
        #expect(!SessionCardAssembler.isExportable(quality: quality(frameCount: 0)))
        #expect(SessionCardAssembler.isExportable(quality: quality(frameCount: 1)))
    }

    @Test("The suggested filename is filesystem-safe and carries the target and date")
    func suggestedFilenameIsFilesystemSafe() {
        let filename = SessionCardAssembler.suggestedFilename(targetName: "IC 4604 Rho Ophiuchi", dateText: "2026-08-17")
        #expect(filename == "IC_4604_Rho_Ophiuchi_2026-08-17_session-card.png")
    }

    // MARK: - Wiring pins (ImageRenderer/NSSavePanel cannot run headlessly)

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("SessionCardExport writes PNG bytes through NSSavePanel, never a self-chosen destination")
    func exportWritesThroughSavePanelOnly() throws {
        let source = try contents("Sources/AstroUI/Features/Reports/SessionCardExport.swift")
        #expect(source.contains("NSBitmapImageRep"))
        #expect(source.contains("public static func write(pngData: Data, to url: URL) throws"))
    }

    @Test("NightWorkspaceView wires the session-card export through ImageRenderer and NSSavePanel")
    func nightWorkspaceWiresSessionCardExport() throws {
        let source = try contents("Sources/AstroUI/Features/Nights/NightWorkspaceView.swift")
        #expect(source.contains("ImageRenderer(content: SessionCardView(content: content, rootURL: rootURL))"))
        #expect(source.contains("NSSavePanel()"))
        #expect(source.contains("v2.night.page.export-session-card"))
        #expect(source.contains("isSessionCardExportable"))
    }
}
