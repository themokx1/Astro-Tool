@testable import AstroApplication
@testable import AstroUI
import CryptoKit
import Foundation
import Testing

/// A real library root + a real, isolated `MetadataStore`/journal directory,
/// so `MutationConfirmationStore` can drive an actual `QuarantineApplyCommand`
/// (via an injected factory, never `.production`, which would touch the
/// real user's Application Support/Caches) through apply and rollback.
@MainActor
private struct MutationConfirmationFixture {
    let container: URL
    let root: URL
    let journal: URL
    let metadata: MetadataStore
    let relativePath: String
    let content: Data
    let identity: LibraryIdentity

    static func make() throws -> Self {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroMutationConfirmationTests-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("Library", isDirectory: true)
        let journal = container.appendingPathComponent("Journal", isDirectory: true)
        let relativePath = "stacks/IC1396/process/r_light.fit"
        let fileURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: journal.path
        )
        let content = Data("residue bytes for the confirmation sheet".utf8)
        try content.write(to: fileURL)
        return Self(
            container: container,
            root: root,
            journal: journal,
            metadata: try MetadataStore.temporary(),
            relativePath: relativePath,
            content: content,
            identity: LibraryIdentity(rootURL: root)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
    }

    func plan() -> LibraryMutationPlan {
        let quarantinePath = ".astro_tool/cleanup_quarantine/20261204-000000/\(relativePath)"
        let fingerprint = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        return LibraryMutationPlan(
            libraryID: identity,
            revision: QuarantineApplyCommand.revision,
            entries: [.init(
                source: root.appendingPathComponent(relativePath),
                destination: root.appendingPathComponent(quarantinePath),
                fingerprint: fingerprint
            )],
            totalBytes: Int64(content.count),
            confirmationToken: "confirm-\(UUID().uuidString)"
        )
    }

    func commandFactory() -> MutationConfirmationStore.CommandFactory {
        let journal = journal
        let metadata = metadata
        return { rootURL, accessMode in
            QuarantineApplyCommand(
                root: rootURL, identity: LibraryIdentity(rootURL: rootURL), accessMode: accessMode,
                journalDirectory: journal, metadata: metadata
            )
        }
    }
}

@MainActor
@Suite("Mutation confirmation sheet state")
struct MutationConfirmationTests {
    @Test("Apply stays disabled until the exact confirmation token is typed")
    func tokenGatesApply() throws {
        let fixture = try MutationConfirmationFixture.make()
        defer { fixture.remove() }
        let plan = fixture.plan()
        let store = MutationConfirmationStore(
            plan: plan, rootURL: fixture.root, accessMode: .mutationEnabled,
            commandFactory: fixture.commandFactory()
        )

        #expect(!store.canApply)
        store.confirmationText = "not the token"
        #expect(!store.canApply)
        store.confirmationText = plan.confirmationToken
        #expect(store.canApply)
    }

    @Test("Apply stays disabled in read-only mode even with the correct token")
    func readOnlyModeDisablesApplyRegardlessOfToken() throws {
        let fixture = try MutationConfirmationFixture.make()
        defer { fixture.remove() }
        let plan = fixture.plan()
        let store = MutationConfirmationStore(
            plan: plan, rootURL: fixture.root, accessMode: .readOnly,
            commandFactory: fixture.commandFactory()
        )
        store.confirmationText = plan.confirmationToken

        #expect(!store.canApply)
    }

    @Test("Applying with the correct token moves the files and exposes a receipt")
    func applyingProducesReceiptAndMovesFiles() async throws {
        let fixture = try MutationConfirmationFixture.make()
        defer { fixture.remove() }
        let plan = fixture.plan()
        let store = MutationConfirmationStore(
            plan: plan, rootURL: fixture.root, accessMode: .mutationEnabled,
            commandFactory: fixture.commandFactory()
        )
        store.confirmationText = plan.confirmationToken

        await store.apply()

        #expect(store.receipt != nil)
        #expect(store.errorMessage == nil)
        #expect(!fixture.exists(fixture.relativePath))
    }

    @Test("Applying in read-only mode sets an explanatory error and links nothing")
    func applyingReadOnlySetsErrorAndMovesNothing() async throws {
        let fixture = try MutationConfirmationFixture.make()
        defer { fixture.remove() }
        let plan = fixture.plan()
        let store = MutationConfirmationStore(
            plan: plan, rootURL: fixture.root, accessMode: .readOnly,
            commandFactory: fixture.commandFactory()
        )
        store.confirmationText = plan.confirmationToken

        await store.apply()

        #expect(store.receipt == nil)
        #expect(store.errorMessage != nil)
        #expect(fixture.exists(fixture.relativePath))
    }

    @Test("Undo (rollback) after a successful apply restores the original files")
    func rollbackRestoresFiles() async throws {
        let fixture = try MutationConfirmationFixture.make()
        defer { fixture.remove() }
        let plan = fixture.plan()
        let store = MutationConfirmationStore(
            plan: plan, rootURL: fixture.root, accessMode: .mutationEnabled,
            commandFactory: fixture.commandFactory()
        )
        store.confirmationText = plan.confirmationToken
        await store.apply()
        #expect(!fixture.exists(fixture.relativePath))

        await store.rollback()

        #expect(store.isRolledBack)
        #expect(fixture.exists(fixture.relativePath))
    }

    @Test("A successful apply and a successful rollback each fire onLibraryFindingsChanged so the sidebar badge can refresh")
    func applyAndRollbackFireLibraryFindingsChanged() async throws {
        let fixture = try MutationConfirmationFixture.make()
        defer { fixture.remove() }
        let plan = fixture.plan()
        let store = MutationConfirmationStore(
            plan: plan, rootURL: fixture.root, accessMode: .mutationEnabled,
            commandFactory: fixture.commandFactory()
        )
        store.confirmationText = plan.confirmationToken
        var changeCount = 0
        store.onLibraryFindingsChanged = { changeCount += 1 }

        await store.apply()
        #expect(changeCount == 1)

        await store.rollback()
        #expect(changeCount == 2)
    }

    @Test("A failed apply (read-only mode) does not fire onLibraryFindingsChanged")
    func failedApplyDoesNotFireLibraryFindingsChanged() async throws {
        let fixture = try MutationConfirmationFixture.make()
        defer { fixture.remove() }
        let plan = fixture.plan()
        let store = MutationConfirmationStore(
            plan: plan, rootURL: fixture.root, accessMode: .readOnly,
            commandFactory: fixture.commandFactory()
        )
        store.confirmationText = plan.confirmationToken
        var changeCount = 0
        store.onLibraryFindingsChanged = { changeCount += 1 }

        await store.apply()

        #expect(changeCount == 0)
    }

    @Test("A failed Undo records an error instead of silently leaving the files in quarantine")
    func failedRollbackRecordsAnError() async throws {
        let fixture = try MutationConfirmationFixture.make()
        defer { fixture.remove() }
        let plan = fixture.plan()
        let store = MutationConfirmationStore(
            plan: plan, rootURL: fixture.root, accessMode: .mutationEnabled,
            commandFactory: fixture.commandFactory()
        )
        store.confirmationText = plan.confirmationToken
        await store.apply()
        #expect(store.receipt != nil)

        // Removing the journal takes the receipt the rollback has to read
        // with it -- a real failure, not a synthetic one.
        try FileManager.default.removeItem(at: fixture.journal)

        await store.rollback()

        #expect(!store.isRolledBack)
        #expect(store.errorMessage != nil, "a failed rollback must record why")
        #expect(!fixture.exists(fixture.relativePath), "the file is still in quarantine")
    }

    /// The sheet used to render `store.errorMessage` only inside its
    /// `receipt == nil` branch, so the one error a receipt can produce -- a
    /// failed Undo (`rollback()`) -- had nowhere to appear: the button just
    /// did nothing. Source-text checks (this repo's "surface test"
    /// convention) that the error line is present on both sides.
    @Test("The sheet renders the store's error in both the receipt and the pre-apply branch")
    func errorIsRenderedInBothBranches() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AstroUI/Features/Library/MutationConfirmationSheet.swift"),
            encoding: .utf8
        )
        let body = try #require(source.range(of: "if let receipt = store.receipt {"))
        let tokenField = try #require(source.range(of: "TextField(\"Confirmation token\""))
        var errorLines: [Range<String.Index>] = []
        var searchFrom = body.upperBound
        while let found = source.range(of: "errorLine", range: searchFrom..<source.endIndex) {
            errorLines.append(found)
            searchFrom = found.upperBound
        }
        #expect(
            errorLines.contains { $0.upperBound < tokenField.lowerBound },
            "the applied/receipt branch must be able to show a failed Undo's error"
        )
        #expect(
            errorLines.contains { $0.lowerBound > tokenField.upperBound },
            "the pre-apply branch keeps showing a failed apply's error"
        )
    }
}
