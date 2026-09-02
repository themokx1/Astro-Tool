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

    // MARK: - v5 flow fixes, item 4: the create-library step used to show
    // three static sentences no matter what name/location were typed, and
    // its button said only "Create Library" even though clicking it also
    // enables writing to the library right away.

    @Test("The create-library disclosure renders the real, computed preview instead of static sentences")
    func createLibraryDisclosureRendersRealPreview() throws {
        let view = try source("Sources/AstroUI/Onboarding/FirstSuccessOnboardingView.swift")
        #expect(view.contains("@State private var libraryPreview: LibraryCreationPreview?"))
        #expect(view.contains("libraryPreview.missingRelativePaths"))
        #expect(view.contains("libraryPreview.existingRelativePaths"))
        #expect(view.contains("libraryPreview = try? LibraryCreationCommand(root: root, accessMode: .readOnly).preview()"))
        #expect(view.contains(".onChange(of: chosenParent)"))
        #expect(view.contains(".onChange(of: libraryName)"))
    }

    // MARK: - v5 flow fixes, item 6: makeLibrary()'s catch block used to
    // pass error.localizedDescription (AstroError.errorDescription,
    // deliberately untranslated English) straight into coordinator
    // .reportError(_:), leaking English into an otherwise-Hungarian alert.

    @Test("A failed library creation routes through the same translated classification LibraryWelcomeView uses")
    func failedLibraryCreationRoutesThroughAccessProblemMessage() throws {
        let view = try source("Sources/AstroUI/Onboarding/FirstSuccessOnboardingView.swift")
        #expect(view.contains(
            "coordinator.reportError(LibraryWelcomeView.accessProblemMessage(for: LibraryAccessProblem(catching: error)))"
        ))
        #expect(!view.contains("coordinator.reportError(error.localizedDescription)"))
    }

    @Test("The Create Library button states plainly that it also enables writing")
    func createLibraryButtonStatesItEnablesWriting() throws {
        let view = try source("Sources/AstroUI/Onboarding/FirstSuccessOnboardingView.swift")
        #expect(view.contains(#"Button("Create Library and Allow Writing")"#))
        #expect(view.contains("AstroTool will create the folders above now and allow writing to this library."))
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

    // MARK: - 2026-09-02 first-run audit, fix C

    @Test("The guided journey is owned by the shell, so the folder picker cannot restart it")
    func journeyOutlivesTheSheetItIsRenderedIn() throws {
        let view = try source("Sources/AstroUI/Onboarding/FirstSuccessOnboardingView.swift")
        let root = try source("Sources/AstroUI/App/V2RootView.swift")
        let firstSteps = try source("Sources/AstroUI/Help/FirstStepsView.swift")

        // The coordinator must be injected, never `@State` inside the sheet
        // -- closing the sheet for the picker destroys `@State`.
        #expect(view.contains("coordinator: FirstSuccessOnboardingStore"))
        #expect(!view.contains("State(initialValue: FirstSuccessOnboardingStore("))
        #expect(root.contains("@State private var firstRunJourney = FirstSuccessOnboardingStore(mode: .firstRun)"))
        #expect(root.contains("@State private var helpJourney = FirstSuccessOnboardingStore(mode: .help)"))
        #expect(root.contains("coordinator: firstRunJourney"))
        #expect(root.contains("coordinator: helpJourney"))
        #expect(firstSteps.contains("coordinator: coordinator"))
    }

    @Test("Opening an existing library runs the same write-enabling completion as creating one")
    func openExistingLibraryRunsLibraryReady() throws {
        let view = try source("Sources/AstroUI/Onboarding/FirstSuccessOnboardingView.swift")
        // Both of `LibraryWelcomeView`'s exits from the scan receipt must go
        // through `libraryReady`, which is the single place writes are
        // enabled and the import offer is entered.
        #expect(view.contains("onContinue: libraryReady"))
        #expect(view.contains("onPersonalize: libraryReady"))
        #expect(view.contains("private func libraryReady() {\n        onEnableWrites()\n        coordinator.libraryBecameReady()"))
    }

    @Test("Only the deterministic UI-test picker route lands on the bare scan receipt")
    func realUsersStayInsideTheFirstSuccessJourneyAfterThePicker() throws {
        let root = try source("Sources/AstroUI/App/V2RootView.swift")
        // Before this fix a real pick set `directLibraryWelcome: true`,
        // which replaced the guided journey with a bare `LibraryWelcomeView`
        // whose Continue completed onboarding outright -- skipping the
        // import offer and never enabling writes.
        #expect(root.contains("directLibraryWelcome: Self.uiTestLibraryPickerResult() != nil"))
        #expect(!root.contains("presentOnboardingAfterDismissal(directLibraryWelcome: true, scanning: root)"))
    }

    @Test("The native folder picker starts only after the presenting sheet has closed")
    func folderPickerDoesNotNestModalPresentation() throws {
        let root = try source("Sources/AstroUI/App/V2RootView.swift")
        let welcome = try source("Sources/AstroUI/Onboarding/LibraryWelcomeView.swift")

        #expect(root.contains("onDismiss: finishOnboardingDismissal"))
        #expect(root.contains("pendingLibraryPickerOrigin = .onboarding"))
        #expect(root.contains("panel.runModal()"))
        #expect(welcome.contains("requestLibraryPicker()"))

        // 2026-09-02 audit, fix H: Help ▸ First Steps lives in the
        // `.sheet(item: $router.presentation)` sheet, not the onboarding
        // one, so it needs the same close-run-reopen round trip -- otherwise
        // its "open a library" branch fell back to `NSOpenPanel.begin` from
        // inside a sheet.
        #expect(root.contains("onDismiss: finishPresentationDismissal"))
        #expect(root.contains("pendingLibraryPickerOrigin = .firstSteps"))
        #expect(root.contains("requestLibraryPicker: requestLibraryPickerFromFirstSteps"))
        let firstSteps = try source("Sources/AstroUI/Help/FirstStepsView.swift")
        #expect(firstSteps.contains("let requestLibraryPicker: (() -> Void)?"))
        #expect(firstSteps.contains("requestLibraryPicker: requestLibraryPicker"))
    }

    @Test("The folder picker's own prompt and message are localizable, not hardcoded Hungarian")
    func folderPickerPromptIsLocalizable() throws {
        let root = try source("Sources/AstroUI/App/V2RootView.swift")
        #expect(!root.contains("Kiválasztás"))
        #expect(!root.contains("Válaszd ki a képkönyvtár gyökerét"))
        #expect(root.contains("panel.prompt = String(localized:"))
        #expect(root.contains("panel.message = String(localized:"))
    }

    // MARK: - v5 flow review, M8: the storage-inside-library dialog and the
    // zero-result scan summary carried two different English labels for the
    // very same action, and both had been translated to the identical
    // Hungarian string.

    @Test("Both ways back to the folder picker share one label instead of two keys with one translation")
    func rechooseFolderLabelIsUnified() throws {
        let welcome = try source("Sources/AstroUI/Onboarding/LibraryWelcomeView.swift")
        let summary = try source("Sources/AstroUI/Onboarding/FirstScanSummaryView.swift")
        #expect(welcome.contains(#"Button("Choose a Different Folder…")"#))
        #expect(!welcome.contains("Choose Another Folder…"))
        #expect(summary.contains("Choose a Different Folder…"))

        let strings = try source("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        #expect(strings.contains(#""Choose a Different Folder…" = "#))
        #expect(!strings.contains(#""Choose Another Folder…" = "#), "the orphaned duplicate hu entry is still there")
    }

    @Test("The rating-in-progress notice for a scope reads as a selection, not a round")
    func frameRatingScopeNoticeIsTranslatedForASelection() throws {
        let strings = try source("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        #expect(strings.contains(#""Frame rating is already running for this scope." = "A képkocka-értékelés már fut ehhez a kijelöléshez.";"#))
        // "kör" reads as a lap/round in Hungarian -- never what a scope is.
        #expect(!strings.contains("már fut erre a körre"))
    }

    // MARK: - v5 flow fixes, item 7: "Not chosen yet" had no hu.lproj entry.

    @Test("The create-library location placeholder has a Hungarian translation")
    func notChosenYetIsTranslated() throws {
        let view = try source("Sources/AstroUI/Onboarding/FirstSuccessOnboardingView.swift")
        #expect(view.contains(#"String(localized: "Not chosen yet")"#))
        let strings = try source("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings")
        #expect(strings.contains(#""Not chosen yet" = "#), "\"Not chosen yet\" has no Hungarian translation in hu.lproj")
    }
}
