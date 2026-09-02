import Foundation
import Testing

@Suite("First-success onboarding surface")
struct FirstSuccessOnboardingSurfaceTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("Landing offers the three approved human choices")
    func threeChoices() throws {
        let view = try source("Sources/AstroUI/Onboarding/FirstSuccessOnboardingView.swift")
        #expect(view.contains("Create a new image library"))
        #expect(view.contains("I already have an AstroTool library"))
        #expect(view.contains("I want to understand it first"))
        #expect(view.contains("v3.onboarding.create-library"))
        #expect(view.contains("v3.onboarding.open-library"))
        #expect(view.contains("v3.onboarding.understand"))
    }

    @Test("Copy-only promise remains visible through the import path")
    func copyOnlyPromise() throws {
        let view = try source("Sources/AstroUI/Onboarding/FirstSuccessOnboardingView.swift")
        #expect(view.contains("Your source files stay unchanged"))
        #expect(view.contains("AstroTool only creates verified copies in your library"))
        #expect(view.contains("What will be created on my Mac?"))
        #expect(!view.contains("Move from source"))
        #expect(!view.contains("Delete source"))
    }

    @Test("The visual map explains the hierarchy without requiring paths")
    func libraryMap() throws {
        let map = try source("Sources/AstroUI/Onboarding/LibraryMapView.swift")
        for label in ["Library", "Project", "Night", "Capture", "Light", "Flat", "Dark", "Bias"] {
            #expect(map.contains("\"\(label)\""), Comment(rawValue: label))
        }
        #expect(map.contains("accessibilityIdentifier(\"v3.onboarding.library-map\")"))
    }

    @Test("Closing import and completing a verified import use separate callbacks")
    func honestImportCompletion() throws {
        let importView = try source("Sources/AstroUI/Features/Library/CaptureImportView.swift")
        let onboarding = try source("Sources/AstroUI/Onboarding/FirstSuccessOnboardingView.swift")
        #expect(importView.contains("importCompleted: @escaping () -> Void"))
        #expect(importView.contains("importCompleted()"))
        #expect(onboarding.contains("dismiss: { coordinator.cancelImport() }"))
        #expect(onboarding.contains("importCompleted: { coordinator.importCompleted(createdFirstProject: true) }"))
        #expect(!onboarding.contains("dismiss: { coordinator.importCompleted(createdFirstProject: true) }"))
    }

    @Test("Production gets the first-success flow while the injected UI fixture keeps its scan summary")
    func fixtureCompatibility() throws {
        let root = try source("Sources/AstroUI/App/V2RootView.swift")
        #expect(root.contains("if libraryRootFallback != nil"))
        #expect(root.contains("LibraryWelcomeView("))
        #expect(root.contains("FirstSuccessOnboardingView("))
        #expect(root.contains("uiTestFixture != nil"))
    }

    // MARK: - 2026-09-02 first-run audit, fix E: a scan that found nothing
    // used to announce "Your library is ready" over 0 / 0 / 0.

    @Test("A first scan that found nothing says so instead of claiming the library is ready")
    func zeroResultScanHasItsOwnState() throws {
        let summary = try source("Sources/AstroUI/Onboarding/FirstScanSummaryView.swift")
        #expect(summary.contains("No astrophotos found in"))
        #expect(summary.contains("Choose a Different Folder…"))
        #expect(summary.contains("Continue anyway"))
        // The zero branch must be a real branch on the counts, not copy that
        // merely sits next to the tiles.
        #expect(summary.contains("private var foundNothing: Bool"))
        #expect(summary.contains("if foundNothing"))
        // Identifiers existing automation waits for stay on both branches.
        #expect(summary.contains("v2.onboarding.summary"))
        #expect(summary.contains("v2.onboarding.continue"))
        #expect(summary.contains("v2.onboarding.choose-different-folder"))
        // The welcome view must supply a way back to the picker, otherwise
        // the primary action would be a dead end.
        let welcome = try source("Sources/AstroUI/Onboarding/LibraryWelcomeView.swift")
        #expect(welcome.contains("chooseAnotherFolder: chooseAnotherLibrary"))
    }

    @Test("The native folder picker starts only after the onboarding sheet has closed")
    func folderPickerDoesNotNestModalPresentation() throws {
        let root = try source("Sources/AstroUI/App/V2RootView.swift")
        let welcome = try source("Sources/AstroUI/Onboarding/LibraryWelcomeView.swift")

        #expect(root.contains("onDismiss: finishOnboardingDismissal"))
        #expect(root.contains("pendingLibraryPicker = true"))
        #expect(root.contains("panel.runModal()"))
        #expect(welcome.contains("requestLibraryPicker()"))
    }
}
