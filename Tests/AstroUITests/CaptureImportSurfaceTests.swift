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
}
