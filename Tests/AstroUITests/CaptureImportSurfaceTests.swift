import Foundation
import Testing

/// Source-grep "surface" tests pinning `CaptureImportView`/`CaptureImportCommand`
/// wiring that is impractical to drive end-to-end in a unit test (a real
/// `NSOpenPanel`-free source scan, classify, and destination-create round
/// trip through `OperationHost`) -- same accepted style as
/// `FirstSuccessOnboardingSurfaceTests`.
@Suite("Capture import wizard surface")
struct CaptureImportSurfaceTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - v5 flow fixes, item 1: cancelling a copy used to discard the
    // whole receipt and claim outright failure even after real, verified
    // files had already landed in the library.

    @Test("A cancelled copy stops instead of throwing away what it already copied")
    func cancelKeepsAPartialReceiptInsteadOfThrowing() throws {
        let command = try source("Sources/AstroApplication/Features/Library/CaptureImportCommand.swift")
        #expect(!command.contains("if shouldCancel() { throw CancellationError() }"))
        #expect(command.contains("wasCancelled = true"))
        #expect(command.contains("public let wasCancelled: Bool"))
    }

    @Test("The receipt step renders the cancelled outcome honestly, not the ordinary success banner")
    func receiptStepHonorsWasCancelled() throws {
        let view = try source("Sources/AstroUI/Features/Library/CaptureImportView.swift")
        #expect(view.contains("if receipt.wasCancelled"))
        #expect(view.contains("Copy stopped — \\(receipt.copied.count) files already copied and verified, \\(notCopiedCount(receipt)) not copied."))
        // The old blanket "could not copy the files" message must no longer
        // be the only outcome a cancellation can produce -- `runCopy` still
        // uses it, but only when `receipt` is genuinely `nil` (a real
        // failure), not for a cancellation that already has a receipt.
        #expect(view.contains("AstroTool could not copy the files. The source card was not modified."))
    }

    // MARK: - v5 flow fixes, item 2: "Create Structure" used to be able to
    // fail with zero visible feedback -- the failure toast is mounted on a
    // layer behind this modal wizard's sheet.

    @Test("NewSessionStore.create awaits the operation's outcome and surfaces a failure via createErrorMessage")
    func createAwaitsOutcomeAndExposesFailure() throws {
        let store = try source("Sources/AstroUI/Features/Library/NewSessionView.swift")
        #expect(store.contains("public private(set) var createErrorMessage: String?"))
        #expect(store.contains("_ = await operationHost.outcome(of: id)"))
        #expect(store.contains("createErrorMessage = await operationHost.errorMessage(for: id)"))
    }

    @Test("The wizard's destination step renders createErrorMessage next to previewErrorKey")
    func destinationStepRendersCreateErrorMessage() throws {
        let view = try source("Sources/AstroUI/Features/Library/CaptureImportView.swift")
        #expect(view.contains("if let createErrorMessage = destination.createErrorMessage"))
        #expect(view.contains("v2.capture-import.create-structure-error"))
    }

    // MARK: - v5 flow fixes, item 3: cancelling mid-import used to leave
    // real session/capture folders on disk while the completion screen said
    // "No project or capture was created" -- `CaptureImportStore` is
    // `@State` inside `CaptureImportView`, so it dies the moment the
    // journey backs out to `.importOffer`.

    @Test("The wizard reports a successfully created structure to a caller that outlives its own store")
    func wizardReportsStructureCreationUpward() throws {
        let view = try source("Sources/AstroUI/Features/Library/CaptureImportView.swift")
        #expect(view.contains("var structureCreated: (_ targetFolder: String, _ date: String, _ captureSlug: String?) -> Void = { _, _, _ in }"))
        #expect(view.contains("structureCreated(receipt.targetFolder, receipt.date, slug)"))
    }

    @Test("The preview step offers Undo for a structure the wizard already created, before the user can back out")
    func previewStepOffersUndoBeforeLeaving() throws {
        let view = try source("Sources/AstroUI/Features/Library/CaptureImportView.swift")
        #expect(view.contains("v2.capture-import.undo-structure"))
        #expect(view.contains("await store.destinationStore.undo(operationHost: operationHost)"))
        #expect(view.contains("if store.destinationStore.isUndone { structureUndone() }"))
    }

    // MARK: - v5 flow fixes, item 6: a failed copy's reason used to render
    // a raw `String(describing: AstroError)` dump into the receipt (e.g.
    // `accessDenied(path: "/…")`), in neither English nor Hungarian.

    @Test("A failure's AstroError is carried alongside a readable English reason, not rendered via String(describing:)")
    func failedFileCarriesAstroErrorInsteadOfARawDump() throws {
        let command = try source("Sources/AstroApplication/Features/Library/CaptureImportCommand.swift")
        #expect(!command.contains("String.init(describing:)"))
        #expect(command.contains("public let astroError: AstroError?"))
        #expect(command.contains("astroError: error as? AstroError"))
    }

    @Test("The receipt step renders a translated reason when the failure's AstroError is known")
    func receiptStepTranslatesKnownFailureReasons() throws {
        let view = try source("Sources/AstroUI/Features/Library/CaptureImportView.swift")
        #expect(view.contains("private func failureReasonText(_ failure: CaptureImportReceipt.FailedFile) -> Text"))
        #expect(view.contains("LibraryWelcomeView.accessProblemText(for: astroError)"))
    }

    @Test("The onboarding journey wires structureCreated/structureUndone to the coordinator's own honest-completion facts")
    func onboardingWiresStructureCallbacksToTheCoordinator() throws {
        let onboarding = try source("Sources/AstroUI/Onboarding/FirstSuccessOnboardingView.swift")
        #expect(onboarding.contains("coordinator.recordCreatedStructure(targetFolder: targetFolder, date: date, captureSlug: captureSlug)"))
        #expect(onboarding.contains("structureUndone: { coordinator.clearCreatedStructure() }"))
        // The old unconditional "no project or capture was created" text
        // must no longer be the only message a skipped import can show.
        #expect(onboarding.contains("The project folders were created; no photos were copied."))
    }
}
