import AstroApplication
import AstroUI
import AppKit
import Foundation
import PDFKit
import Testing

@MainActor
@Suite("Night briefing PDF and PNG export", .serialized)
struct NightBriefingExportTests {
    @Test("WebKit creates a readable A4 PDF with selectable briefing text")
    func createsReadablePDF() async throws {
        let html = NightBriefingHTMLRenderer().render(fixtureDocument())

        let data = try await NightBriefingPDFExporter().pdfData(html: html)
        let pdf = try #require(PDFDocument(data: data))

        #expect(data.starts(with: Data("%PDF".utf8)))
        #expect(pdf.pageCount == 8)
        #expect(pdf.string?.contains("Éjszakai briefing") == true)
        let first = try #require(pdf.page(at: 0))
        let size = first.bounds(for: .mediaBox).size
        #expect(abs(size.width - 595.28) < 3)
        #expect(abs(size.height - 841.89) < 3)

        if let outputPath = ProcessInfo.processInfo.environment["ASTROTOOL_BRIEFING_QA_OUTPUT"] {
            let output = URL(fileURLWithPath: outputPath)
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: output, options: .atomic)
        }
    }

    @Test("Every PDF page becomes one non-empty 144 DPI PNG")
    func createsMatchingPNGPages() async throws {
        let pdfData = try await NightBriefingPDFExporter().pdfData(
            html: NightBriefingHTMLRenderer().render(fixtureDocument())
        )
        let pdf = try #require(PDFDocument(data: pdfData))

        let pages = try NightBriefingPNGExporter().pages(from: pdfData, dpi: 144)

        #expect(pages.count == pdf.pageCount)
        #expect(pages.allSatisfy { $0.count > 10_000 })
        let image = try #require(NSBitmapImageRep(data: pages[0]))
        #expect(abs(image.size.width - 595.28) < 3)
        #expect(image.pixelsWide >= 1_188 && image.pixelsWide <= 1_194)
    }

    @Test("Export refuses an existing PDF and leaves its bytes unchanged")
    func refusesOverwrite() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroToolExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let output = fixture.appendingPathComponent("briefing.pdf")
        let sentinel = Data("existing user file".utf8)
        try sentinel.write(to: output, options: .withoutOverwriting)

        await #expect(throws: NightBriefingExportError.outputAlreadyExists(output)) {
            try await NightBriefingExportCommand().export(document: fixtureDocument(), to: output, format: .pdf)
        }
        #expect(try Data(contentsOf: output) == sentinel)
    }

    @Test("Combined export keeps one PDF and matching PNG folder")
    func exportsPDFAndPNG() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroToolExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let output = fixture.appendingPathComponent("m42-night.pdf")

        let result = try await NightBriefingExportCommand().export(
            document: fixtureDocument(), to: output, format: .pdfAndPNG
        )

        #expect(result.pdfURL == output)
        #expect(result.pngURLs.count >= 5)
        #expect(result.pngURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(result.pngURLs.map(\.lastPathComponent) == result.pngURLs.indices.map { "page-\($0 + 1).png" })
    }

    private func fixtureDocument() -> NightBriefingDocument {
        let start = Date(timeIntervalSince1970: 1_786_738_400)
        var draft = NightBriefingDraft(
            savedAt: start,
            nightDate: start,
            arrival: start,
            departure: start.addingTimeInterval(10_800),
            site: .init(id: "garden", name: "Kert"),
            setup: .init(id: "rig", name: "RedCat 51 + ASI 2600MC"),
            weather: .known(.init(summary: "Derült", source: "Open-Meteo", updatedAt: start)),
            targets: [
                .init(name: "M 42", role: .primary, start: start, end: start.addingTimeInterval(3_600), capturePlan: .init(filterName: "L-eXtreme", exposureSeconds: 180, frameCount: 20, gain: 100)),
                .init(name: "M 31", role: .backup, start: start.addingTimeInterval(3_600), end: start.addingTimeInterval(7_200)),
            ],
            language: .hu
        )
        draft.checklist = NightBriefingChecklistTemplate().sections(language: .hu)
        return NightBriefingComposer().compose(draft: draft, context: .init(calibrationGaps: ["flat"] ))
    }
}
