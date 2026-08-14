@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// Pads a FITS card line to 80 characters, block-pads to 2880 -- mirrors
/// `Tests/AstroCoreTests/FITSTestBuilder.swift`'s helper of the same shape;
/// duplicated here because AstroApplicationTests cannot import
/// AstroCoreTests' file-private test target (same note
/// `CalibrationQueryTests.swift` already carries for itself).
private func exportCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func exportHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(exportCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

/// A fresh fixture library + fresh sqlite-backed `Database` -- same spirit as
/// `AcquisitionExportFixture` in `Tests/AstroCoreTests/AcquisitionExportTests.swift`,
/// kept minimal to exactly what `ExportService`'s own methods need.
private struct ExportServiceFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> ExportServiceFixture {
        let libraryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-service-tests-lib-\(UUID().uuidString)", isDirectory: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-service-tests-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return ExportServiceFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    @discardableResult
    func writeFITSLight(
        _ relativePath: String,
        exptime: Double = 300,
        filter: String? = nil,
        gain: Double? = nil,
        setTemp: Double? = nil
    ) throws -> URL {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        cards.append("EXPTIME =                \(exptime)")
        if let filter { cards.append("FILTER  = '\(filter)'") }
        if let gain { cards.append("GAIN    =                \(gain)") }
        if let setTemp { cards.append("SET-TEMP=                \(setTemp)") }
        cards.append("END")
        try exportHeaderData(cards).write(to: url)
        return url
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }

    func exportService() throws -> ExportService {
        ExportService(db: db, config: config, rootURL: libraryDir)
    }
}

@Suite("ExportService")
struct ExportServiceTests {
    // MARK: - Acquisition export

    @Test("Astrobin acquisition export renders through AcquisitionExport, unchanged")
    func astrobinAcquisitionExportMatchesEngine() throws {
        let fixture = try ExportServiceFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSLight(
            "sessions/T1/2026-01-10/lights/a.fit", exptime: 300, filter: "L-eXtreme", gain: 100, setTemp: -10
        )
        try fixture.scan()

        let expected = try AcquisitionExport.render(target: "T1", format: .astrobin, db: fixture.db, config: fixture.config)
        let result = try fixture.exportService().acquisitionExport(target: "T1", format: .astrobin)

        #expect(result.content == expected)
        #expect(result.suggestedFilename.hasSuffix(".csv"))
        #expect(result.suggestedFilename.contains("T1"))
    }

    @Test("CSV acquisition export renders through AcquisitionExport, unchanged")
    func csvAcquisitionExportMatchesEngine() throws {
        let fixture = try ExportServiceFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/a.fit", exptime: 300)
        try fixture.scan()

        let expected = try AcquisitionExport.render(target: "T1", format: .csv, db: fixture.db, config: fixture.config)
        let result = try fixture.exportService().acquisitionExport(target: "T1", format: .csv)

        #expect(result.content == expected)
        #expect(result.unmappedFilters.isEmpty)
    }

    @Test("Markdown acquisition export renders through AcquisitionExport, unchanged")
    func markdownAcquisitionExportMatchesEngine() throws {
        let fixture = try ExportServiceFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/a.fit", exptime: 300)
        try fixture.scan()

        let expected = try AcquisitionExport.render(target: "T1", format: .md, db: fixture.db, config: fixture.config)
        let result = try fixture.exportService().acquisitionExport(target: "T1", format: .md)

        #expect(result.content == expected)
        #expect(result.suggestedFilename.hasSuffix(".md"))
    }

    @Test("An astrobin export with no filter-ID mapping returns the warning, not a silent omission")
    func astrobinExportSurfacesUnmappedFilters() throws {
        let fixture = try ExportServiceFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/a.fit", exptime: 300, filter: "Ha")
        try fixture.scan()

        let result = try fixture.exportService().acquisitionExport(target: "T1", format: .astrobin)
        #expect(result.unmappedFilters == ["Ha"])
    }

    // MARK: - Target / night report

    @Test("Target report renders through TargetReport, unchanged")
    func targetReportMatchesEngine() throws {
        let fixture = try ExportServiceFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/a.fit", exptime: 300)
        try fixture.scan()

        let expected = try TargetReport.render(target: "T1", db: fixture.db, config: fixture.config)
        let result = try fixture.exportService().targetReport(target: "T1")

        #expect(result.content == expected)
        #expect(result.suggestedFilename == "target-T1.html")
    }

    @Test("Night report renders through NightReport, unchanged")
    func nightReportMatchesEngine() throws {
        let fixture = try ExportServiceFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/a.fit", exptime: 300)
        try fixture.scan()

        let expected = try NightReport.render(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)
        let result = try fixture.exportService().nightReport(target: "T1", date: "2026-01-10")

        #expect(result.content == expected)
        #expect(result.suggestedFilename == "T1-2026-01-10.html")
    }

    @Test("Night report throws for a session that was never scanned")
    func nightReportThrowsForUnknownSession() throws {
        let fixture = try ExportServiceFixture.make()
        defer { fixture.cleanup() }
        try fixture.scan()

        #expect(throws: (any Error).self) {
            _ = try fixture.exportService().nightReport(target: "Ghost", date: "2026-01-10")
        }
    }

    // MARK: - Stack list

    @Test("Stack list renders the same manifest a physical StackList.export would write")
    func stackListMatchesManifestEngine() throws {
        let fixture = try ExportServiceFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/a.fit", exptime: 300)
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/b.fit", exptime: 300)
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/c.fit", exptime: 300)
        try fixture.scan()

        let selection = try StackList.select(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)
        let expected = StackList.renderManifest(selection, libraryRoot: fixture.libraryDir)

        let result = try fixture.exportService().stackList(target: "T1", date: "2026-01-10")

        #expect(result.content == expected)
        #expect(result.content.contains("file,filter,score,fwhm_px,session_date,verdict,linked_name"))
        #expect(result.suggestedFilename.contains("T1-2026-01-10"))
    }

    @Test("Stack list's keepFraction is forwarded to StackList.select")
    func stackListForwardsKeepFraction() throws {
        let fixture = try ExportServiceFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/a.fit", exptime: 300)
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/b.fit", exptime: 300)
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/c.fit", exptime: 300)
        try fixture.scan()

        let expectedSelection = try StackList.select(
            target: "T1", date: "2026-01-10", keepFraction: 0.34, db: fixture.db, config: fixture.config
        )
        let expected = StackList.renderManifest(expectedSelection, libraryRoot: fixture.libraryDir)

        let result = try fixture.exportService().stackList(target: "T1", date: "2026-01-10", keepFraction: 0.34)
        #expect(result.content == expected)
    }

    // MARK: - Tonight's plan

    @Test("Plan CSV renders through PlanExport, unchanged")
    func planCSVMatchesEngine() throws {
        let fixture = try ExportServiceFixture.make()
        defer { fixture.cleanup() }

        let plans = [
            TargetPlan(target: "M31", usableIntegrationSeconds: 3600, verdict: "ma jó", score: 1)
        ]
        let expected = PlanExport.renderCSV(plans, night: "2026-01-10")
        let result = try fixture.exportService().planCSV(plans: plans, night: "2026-01-10")

        #expect(result.content == expected)
        #expect(result.suggestedFilename == "plan-2026-01-10.csv")
    }

    @Test("Plan clipboard text renders through PlanExport, unchanged")
    func planClipboardTextMatchesEngine() throws {
        let fixture = try ExportServiceFixture.make()
        defer { fixture.cleanup() }

        let plans = [
            TargetPlan(target: "M31", usableIntegrationSeconds: 3600, verdict: "ma jó", score: 1)
        ]
        let expected = PlanExport.renderClipboardText(plans)
        let result = try fixture.exportService().planClipboardText(plans: plans)

        #expect(result == expected)
    }

    // MARK: - Calibration shopping list

    @Test("Calibration shopping-list markdown renders through CalibShoppingList, unchanged")
    func calibShoppingListMarkdownMatchesEngine() throws {
        let fixture = try ExportServiceFixture.make()
        defer { fixture.cleanup() }

        let items = [
            CalibShoppingList.Item(
                kind: .dark, exposureSeconds: 300, tempC: -10, targets: ["M31"], isStale: false, todo: "300s dark hiányzik"
            )
        ]
        let expected = CalibShoppingList.markdown(items)
        let result = try fixture.exportService().calibShoppingListMarkdown(items: items)

        #expect(result == expected)
        #expect(result.contains("- [ ]"))
    }
}
