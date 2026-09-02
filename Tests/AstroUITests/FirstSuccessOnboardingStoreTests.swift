import Testing
@testable import AstroUI

@MainActor
@Suite("First-success onboarding navigation")
struct FirstSuccessOnboardingStoreTests {
    @Test("The three human choices enter their expected paths")
    func entryChoices() {
        let create = FirstSuccessOnboardingStore(mode: .firstRun)
        create.chooseEntry(.createLibrary)
        #expect(create.step == .createLibrary)

        let open = FirstSuccessOnboardingStore(mode: .firstRun)
        open.chooseEntry(.openLibrary)
        #expect(open.step == .openLibrary)

        let understand = FirstSuccessOnboardingStore(mode: .firstRun)
        understand.chooseEntry(.understand)
        #expect(understand.step == .understanding(0))
    }

    @Test("Understanding is read-only navigation and returns to the choices")
    func understandingReturnsHome() {
        let store = FirstSuccessOnboardingStore(mode: .firstRun)
        store.chooseEntry(.understand)
        store.advanceUnderstanding(pageCount: 5)
        #expect(store.step == .understanding(1))
        store.finishUnderstanding()
        #expect(store.step == .landing)
        #expect(!store.hasOpenedLibrary)
    }

    @Test("A ready library offers the combined optional import")
    func readyLibraryOffersImport() {
        let store = FirstSuccessOnboardingStore(mode: .firstRun)
        store.chooseEntry(.createLibrary)
        store.libraryBecameReady()
        #expect(store.step == .importOffer)
        #expect(store.hasOpenedLibrary)
        store.startImport()
        #expect(store.step == .importFlow)
    }

    @Test("Skipping import completes without claiming a project was created")
    func skipImport() {
        let store = FirstSuccessOnboardingStore(mode: .help)
        store.chooseEntry(.openLibrary)
        store.libraryBecameReady()
        store.skipImport()
        #expect(store.step == .completion)
        #expect(store.didSkipImport)
        #expect(!store.didCreateFirstProject)
    }

    @Test("Closing import early returns to the offer without claiming success")
    func cancelImport() {
        let store = FirstSuccessOnboardingStore(mode: .firstRun)
        store.chooseEntry(.createLibrary)
        store.libraryBecameReady()
        store.startImport()

        store.cancelImport()

        #expect(store.step == .importOffer)
        #expect(!store.didSkipImport)
        #expect(!store.didCreateFirstProject)
    }

    // MARK: - 2026-09-02 first-run audit, fix C: "I already have an
    // AstroTool library" used to skip the rest of the guided flow. The
    // picker round-trip destroyed this store, so the journey restarted as a
    // bare scan receipt: `libraryBecameReady()` never ran, the import offer
    // never appeared, and write operations were never enabled -- the
    // toolbar's Import from Card later dead-ended on "Requires write
    // access".

    @Test("Opening an existing library reaches the same import offer as creating one")
    func openExistingLibraryReachesTheImportOffer() {
        let store = FirstSuccessOnboardingStore(mode: .firstRun)
        store.chooseEntry(.openLibrary)
        #expect(store.step == .openLibrary)

        store.libraryBecameReady()

        #expect(store.step == .importOffer)
        #expect(store.hasOpenedLibrary)
    }

    @Test("Every path to a ready library requires write operations, not just the create path")
    func aReadyLibraryRequiresWriteOperations() {
        let created = FirstSuccessOnboardingStore(mode: .firstRun)
        #expect(!created.requiresWriteOperations)
        created.chooseEntry(.createLibrary)
        created.libraryBecameReady()
        #expect(created.requiresWriteOperations)

        let opened = FirstSuccessOnboardingStore(mode: .firstRun)
        opened.chooseEntry(.openLibrary)
        opened.libraryBecameReady()
        #expect(opened.requiresWriteOperations)
    }

    @Test("A picker round trip leaves the journey exactly where it was")
    func thePickerRoundTripPreservesTheStep() {
        // The store outlives the sheet now, so the step it was on when the
        // sheet closed for the native picker is still the step it resumes on.
        let store = FirstSuccessOnboardingStore(mode: .firstRun)
        store.chooseEntry(.openLibrary)
        #expect(store.step == .openLibrary)
        #expect(!store.hasOpenedLibrary)

        // ... sheet closes, NSOpenPanel runs, sheet reopens, scan lands ...
        store.libraryBecameReady()

        #expect(store.step == .importOffer)
        #expect(store.requiresWriteOperations)
    }

    @Test("Recoverable errors keep the current step")
    func recoverableError() {
        let store = FirstSuccessOnboardingStore(mode: .firstRun)
        store.chooseEntry(.createLibrary)
        store.reportError("A lemez nem érhető el.")
        #expect(store.step == .createLibrary)
        #expect(store.errorMessage == "A lemez nem érhető el.")
        store.clearError()
        #expect(store.errorMessage == nil)
    }

    // MARK: - 2026-09-02 v5 flow fixes, item 3: cancelling mid-import used
    // to leave real session/capture folders on disk while the completion
    // screen said "No project or capture was created" -- `CaptureImportStore`
    // is `@State` inside `CaptureImportView`, so it dies the moment the
    // user backs out to `.importOffer`; the coordinator has to remember the
    // fact itself.

    @Test("Cancelling after Create Structure remembers what was created, even after the wizard's own store dies")
    func cancelAfterCreateStructureRemembersWhatWasCreated() {
        let store = FirstSuccessOnboardingStore(mode: .firstRun)
        store.chooseEntry(.createLibrary)
        store.libraryBecameReady()
        store.startImport()

        store.recordCreatedStructure(targetFolder: "M31_Andromeda", date: "2026-08-20", captureSlug: "first-capture")
        store.cancelImport()
        #expect(store.step == .importOffer)
        #expect(store.createdStructure?.targetFolder == "M31_Andromeda")

        store.skipImport()
        #expect(store.step == .completion)
        #expect(store.didSkipImport)
        #expect(store.createdStructure != nil, "the structure fact must survive skipping the rest of the journey")
    }

    @Test("Undoing the structure clears the completion-facing fact")
    func undoingStructureClearsTheFact() {
        let store = FirstSuccessOnboardingStore(mode: .firstRun)
        store.chooseEntry(.createLibrary)
        store.libraryBecameReady()
        store.startImport()
        store.recordCreatedStructure(targetFolder: "M31_Andromeda", date: "2026-08-20", captureSlug: "first-capture")

        store.clearCreatedStructure()

        #expect(store.createdStructure == nil)
    }

    @Test("A fresh entry choice resets any structure fact left over from a previous attempt")
    func freshEntryChoiceResetsCreatedStructure() {
        let store = FirstSuccessOnboardingStore(mode: .firstRun)
        store.chooseEntry(.createLibrary)
        store.recordCreatedStructure(targetFolder: "M31_Andromeda", date: "2026-08-20", captureSlug: "first-capture")
        #expect(store.createdStructure != nil)

        store.chooseEntry(.openLibrary)

        #expect(store.createdStructure == nil)
    }
}
