import Foundation
import Testing

@Suite("CaptureWorkflowSurface") struct CaptureWorkflowSurfaceTests {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func everySessionSurfaceExposesCaptureAndConversionSheets() throws {
        let pages = [
            "Sources/AstroToolApp/Views/AllTargetsPage.swift",
            "Sources/AstroToolApp/Views/NightsPage.swift",
            "Sources/AstroToolApp/Views/PreviousNightPage.swift",
            "Sources/AstroToolApp/Views/TargetDetail/SessionsSegment.swift",
        ]
        for page in pages {
            let text = try source(page)
            #expect(text.contains("onCreateCapture:"), Comment(rawValue: page))
            #expect(text.contains("onConvertSession:"), Comment(rawValue: page))
            #expect(text.contains("CaptureGroupSheet("), Comment(rawValue: page))
            #expect(text.contains("SessionConversionSheet("), Comment(rawValue: page))
        }
        let shared = try source("Sources/AstroToolApp/Views/SharedComponents.swift")
        #expect(shared.components(separatedBy: "Új capture-gyűjtés…").count == 2)
        #expect(shared.components(separatedBy: "Session átalakítása gyűjtésekre…").count == 2)
    }

    @Test func conversionPreviewDistinguishesNewAndUpdatedCaptureGroups() throws {
        let sheet = try source("Sources/AstroToolApp/Views/CaptureWorkflowSheets.swift")
        #expect(sheet.contains("Meglévő gyűjtés frissítése"))
        #expect(sheet.contains("Új gyűjtés"))
        #expect(sheet.contains("új és meglévő gyűjtések adatai"))
    }

    @Test func appStateOwnsTheFilterInventoryLifecycle() throws {
        let appState = try source("Sources/AstroToolApp/AppState.swift")

        #expect(appState.contains("var filterProfiles: [FilterProfileRecord]"))
        #expect(appState.contains("var discoveredFilterProfiles: [FilterProfileRecord]"))
        #expect(appState.contains("func loadFilterProfiles()"))
        #expect(appState.contains("func saveFilterProfile("))
        #expect(appState.contains("func deleteFilterProfile("))
        #expect(appState.contains("try db.discoveredFilterProfiles()"))
    }

    @Test func reusableFilterPickerSupportsSavedNoneAndInlineCreation() throws {
        let controls = try source("Sources/AstroToolApp/Views/FilterProfileControls.swift")

        #expect(controls.contains("struct FilterProfilePicker"))
        #expect(controls.contains("struct FilterProfileEditorSheet"))
        #expect(controls.contains("Szűrő nélkül"))
        #expect(controls.contains("Új szűrő…"))
        #expect(controls.contains("appState.filterProfiles"))
        #expect(controls.contains("appState.lastSavedFilterProfile"))
    }

    @Test func filterInventoryHasDedicatedNavigationAndDiscoveryImport() throws {
        let appState = try source("Sources/AstroToolApp/AppState.swift")
        let sidebar = try source("Sources/AstroToolApp/Views/SidebarView.swift")
        let shell = try source("Sources/AstroToolApp/Views/MainShellView.swift")
        let page = try source("Sources/AstroToolApp/Views/FilterProfilesPage.swift")

        #expect(appState.contains("case filters"))
        #expect(sidebar.contains("navRow(\"Szűrők\""))
        #expect(shell.contains("case .filters: FilterProfilesPage()"))
        #expect(page.contains("Első szűrő hozzáadása"))
        #expect(page.contains("Már használt, még nincs a saját listában"))
        #expect(page.contains("Importálás"))
        #expect(page.contains("FilterProfileEditorSheet("))
    }

    @Test func everyCaptureEditorUsesTheSharedFilterInventoryPicker() throws {
        let sheets = try source("Sources/AstroToolApp/Views/CaptureWorkflowSheets.swift")

        #expect(sheets.components(separatedBy: "FilterProfilePicker(").count - 1 == 3)
        #expect(!sheets.contains("TextField(\"Szűrő gyártója"))
        #expect(!sheets.contains("TextField(\"Szűrő gyártó/modell"))
        #expect(!sheets.contains("TextField(\"Gyártó\", text: $filterManufacturer)"))
    }

    @Test func missingFilterStateOffersDirectAssignmentAction() throws {
        let overview = try source("Sources/AstroToolApp/Views/TargetDetail/OverviewSegment.swift")
        let detail = try source("Sources/AstroToolApp/Views/TargetDetailPage.swift")

        #expect(overview.contains("Szűrő hozzárendelése…"))
        #expect(overview.contains("assignFilter()"))
        #expect(detail.contains("filterEditingSession"))
        #expect(detail.contains("CaptureGroupSheet(target: session.target, date: session.date)"))
    }
}
