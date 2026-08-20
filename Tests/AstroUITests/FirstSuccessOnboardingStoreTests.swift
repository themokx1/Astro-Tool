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
}
