import Foundation
import Testing

@Suite("V4 night briefing surface")
struct NightBriefingSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var source: String {
        get throws {
            return try String(
                contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/Features/Briefing/NightBriefingView.swift"),
                encoding: .utf8
            )
        }
    }

    @Test("The opening screen offers the three approved human choices")
    func approvedStartChoices() throws {
        let source = try source
        #expect(source.contains("A ma estét szeretném megtervezni"))
        #expect(source.contains("Másik dátumra készülök"))
        #expect(source.contains("Egy korábbi briefinget folytatok"))
    }

    @Test("The night ribbon exposes every part of the five-step workflow")
    func fiveStepRibbon() throws {
        let source = try source
        for label in ["Alapok", "Célpontok", "Capture-terv", "Checklist és B terv", "Ellenőrzés és export"] {
            #expect(source.contains(label))
        }
        #expect(source.contains("AZ ÉJSZAKA ÚTVONALA"))
    }

    @Test("Export and draft-removal copy clearly state the no-delete no-overwrite boundary")
    func safetyBoundaryIsVisible() throws {
        let source = try source
        #expect(source.contains("Nem töröl, nem mozgat és nem ír felül semmit."))
        #expect(source.contains("Meglévő fájlt az AstroTool nem ír felül."))
        #expect(source.contains("fotót nem töröl"))
    }

    @Test("The complete briefing workspace has real English localization")
    func englishLocalization() throws {
        let english = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroToolApp/Resources/en.lproj/Localizable.strings"
            ),
            encoding: .utf8
        )
        for translation in [
            "I want to plan tonight",
            "I am planning another date",
            "Continue an earlier briefing",
            "Basics",
            "Targets",
            "Capture plan",
            "Checklist and backup plan",
            "Review and export",
            "Save PDF…",
        ] {
            #expect(english.contains(translation), Comment(rawValue: translation))
        }
        #expect(try source.contains("detail: LocalizedStringKey"))
        #expect(try source.contains("Text(detail)"))
    }

    @Test("Planning hands its selected date, setup, site, target, and sky path into briefing")
    func planningContextIsPreserved() throws {
        let planningView = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Features/Planning/PlanningView.swift"
            ),
            encoding: .utf8
        )
        let planningStore = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Features/Planning/PlanningStore.swift"
            ),
            encoding: .utf8
        )
        #expect(planningView.contains("Add to Night Briefing"))
        #expect(planningView.contains("await store.pendingSkyPathRefresh?.value"))
        #expect(planningStore.contains("makeBriefingSeed(for recommendation:"))
        #expect(planningStore.contains("altitudePoints: path.samples.map"))
        #expect(planningStore.contains("equipment: equipment"))
        #expect(planningStore.contains("weather: weather"))
    }

    @Test("The primary briefing action stays above and independent of library-only Home content")
    func briefingActionIsImmediatelyVisibleOnHome() throws {
        let home = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/Features/Home/HomeView.swift"
            ),
            encoding: .utf8
        )
        let bodyStart = try #require(home.range(of: "public var body: some View"))
        let cardDeclaration = try #require(
            home.range(of: "private var briefingCard", range: bodyStart.upperBound..<home.endIndex)
        )
        let body = String(home[bodyStart.lowerBound..<cardDeclaration.lowerBound])
        let action = try #require(body.range(of: "briefingCard"))
        let libraryBranch = try #require(body.range(of: "if store.snapshot.libraryName == nil"))
        #expect(action.lowerBound < libraryBranch.lowerBound)
        #expect(home.contains("v2.home.open-briefing"))
    }

    @Test("Home lets the Planning root settle before pushing briefing")
    func homeBriefingNavigationIsStaged() throws {
        let root = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/AstroUI/App/V2RootView.swift"
            ),
            encoding: .utf8
        )
        #expect(root.contains("router.navigate(to: .planning)\n                    Task { @MainActor in\n                        await Task.yield()\n                        router.push(.briefing)"))
    }

    @Test("Export actions stay above the tall PDF preview")
    func exportActionsStayVisible() throws {
        let source = try source
        let export = try #require(source.range(of: "v2.briefing.export.pdf-png"))
        let preview = try #require(source.range(of: "BriefingPDFPreview(data: data)"))
        #expect(export.lowerBound < preview.lowerBound)
    }
}
