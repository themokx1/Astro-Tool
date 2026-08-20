@testable import AstroUI
import Foundation
import Testing

/// Wave 3 Task 7: menu bar, help layer, and sidebar-badge surface contracts.
/// Follows this repo's own convention for these "surface" suites
/// (`V2ShellSurfaceTests`): mostly literal source-text assertions rather
/// than rendering the view tree, since these are wiring/vocabulary
/// contracts (a menu item exists and is wired to the right action; a term
/// is present in the glossary), not layout contracts.
@Suite("V2 menus, help layer, and sidebar badges")
struct HelpSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("The glossary is searchable and every entry has a non-empty name and definition")
    func glossaryIsSearchableAndNonEmpty() {
        #expect(GlossaryView.terms.count > 20)
        for term in GlossaryView.terms {
            #expect(!term.name.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!term.definition.trimmingCharacters(in: .whitespaces).isEmpty)
        }

        let source = try? contents("Sources/AstroUI/Help/GlossaryView.swift")
        #expect(source?.contains(".searchable(text:") == true)
        #expect(source?.contains("v2.help.glossary") == true)
    }

    @Test("The Folder Structure and First Steps help views expose stable identifiers and real content")
    func folderStructureAndFirstStepsHaveContent() throws {
        let folderStructure = try contents("Sources/AstroUI/Help/FolderStructureHelpView.swift")
        #expect(folderStructure.contains("v2.help.folder-structure"))
        #expect(folderStructure.contains("sessions/"))
        #expect(folderStructure.contains("calibration_library/"))

        let firstSteps = try contents("Sources/AstroUI/Help/FirstStepsView.swift")
        #expect(firstSteps.contains("FirstSuccessOnboardingView("))
        #expect(firstSteps.contains("mode: .help"))
        #expect(firstSteps.contains("v2.help.first-steps"))
    }

    @Test("MetricInfoButton is wired onto Home, Planning, and Review")
    func metricInfoButtonIsWiredOntoTheThreeSurfaces() throws {
        let metricInfoButton = try contents("Sources/AstroUI/Help/MetricInfoButton.swift")
        #expect(metricInfoButton.contains("v2.help.metric-info"))
        #expect(metricInfoButton.contains("GlossaryView("))

        let home = try contents("Sources/AstroUI/Features/Home/HomeView.swift")
        #expect(home.contains("MetricInfoButton(metrics:"))

        let planning = try contents("Sources/AstroUI/Features/Planning/PlanningView.swift")
        #expect(planning.contains("MetricInfoButton(metrics:"))

        let review = try contents("Sources/AstroUI/Features/Review/ReviewWorkspace.swift")
        #expect(review.contains("MetricInfoButton(metrics:"))
    }

    @Test("The Actions menu exposes Measure Sensors and Rate Frames in Review, wired via focused values")
    func actionsMenuExposesSensorMeasureAndReviewRate() throws {
        let commands = try contents("Sources/AstroToolApp/Views/Commands.swift")
        let v2Commands = try #require(commands.components(separatedBy: "struct V2AstroToolCommands").last)

        #expect(v2Commands.contains("Measure Sensors"))
        #expect(v2Commands.contains("sensorMeasure?()"))
        #expect(v2Commands.contains("Rate Frames in Review"))
        #expect(v2Commands.contains("reviewRate?()"))

        let focusedValues = try contents("Sources/AstroUI/App/FocusedAppValues.swift")
        #expect(focusedValues.contains("var sensorMeasure: SensorMeasureCommand?"))
        #expect(focusedValues.contains("var reviewRate: ReviewRateCommand?"))

        let sensorProfiles = try contents("Sources/AstroUI/Features/Library/SensorProfilesView.swift")
        #expect(sensorProfiles.contains("\\.sensorMeasure"))
        #expect(sensorProfiles.contains("store.measure(operationHost:"))

        let review = try contents("Sources/AstroUI/Features/Review/ReviewWorkspace.swift")
        #expect(review.contains("\\.reviewRate"))
        #expect(review.contains("store.rateSelectedSeries(mode: .nativeOnly"))
    }

    @Test("The Help menu presents Glossary, Folder Structure, First Steps, and ProductInfo links")
    func helpMenuPresentsHelpSurfacesAndLinks() throws {
        let commands = try contents("Sources/AstroToolApp/Views/Commands.swift")
        let v2Commands = try #require(commands.components(separatedBy: "struct V2AstroToolCommands").last)

        #expect(v2Commands.contains("CommandGroup(replacing: .help)"))
        #expect(v2Commands.contains("router?.present(.glossary(nil))"))
        #expect(v2Commands.contains("router?.present(.folderStructure)"))
        #expect(v2Commands.contains("router?.present(.firstSteps)"))
        #expect(v2Commands.contains("ProductInfo.supportURL"))
        #expect(v2Commands.contains("ProductInfo.sourceURL"))

        let root = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(root.contains("GlossaryView(anchor:"))
        #expect(root.contains("FolderStructureHelpView(dismiss:"))
        #expect(root.contains("FirstStepsView("))
        #expect(root.contains("FirstSuccessOnboardingView("))
        #expect(root.contains("mode: .firstRun"))

        let appRoute = try contents("Sources/AstroUI/App/AppRoute.swift")
        #expect(appRoute.contains("case glossary(String?)"))
        #expect(appRoute.contains("case folderStructure"))
        #expect(appRoute.contains("case firstSteps"))
    }

    @Test("⌘F opens/focuses the shell's own global search, not a notification")
    func commandFOpensGlobalSearch() throws {
        let commands = try contents("Sources/AstroToolApp/Views/Commands.swift")
        let v2Commands = try #require(commands.components(separatedBy: "struct V2AstroToolCommands").last)

        #expect(v2Commands.contains("globalSearchFocus?()"))
        #expect(v2Commands.contains(".keyboardShortcut(\"f\", modifiers: .command)"))

        let focusedValues = try contents("Sources/AstroUI/App/FocusedAppValues.swift")
        #expect(focusedValues.contains("var globalSearchFocus: GlobalSearchFocusCommand?"))

        let root = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(root.contains("\\.globalSearchFocus"))
        #expect(root.contains("showsSearch = true"))
    }

    @Test("The sidebar exposes stable numeric badge identifiers for Nights and Library")
    func sidebarExposesBadgeIdentifiers() throws {
        let root = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(root.contains("v2.sidebar.badge.nights"))
        #expect(root.contains("v2.sidebar.badge.library"))
        #expect(root.contains(".badge(badgeCount(for: section))"))

        let store = try contents("Sources/AstroUI/App/SidebarBadgeStore.swift")
        #expect(store.contains("nightsNeedingAttention"))
        #expect(store.contains("libraryAttentionCount"))
    }
}
