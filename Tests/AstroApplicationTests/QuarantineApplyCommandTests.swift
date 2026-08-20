@testable import AstroApplication
import AstroCore
import CryptoKit
import Foundation
import Testing

/// A minimal, isolated library root + real files + a temp `MetadataStore`,
/// so `QuarantineApplyCommand` can be exercised end to end (register, apply,
/// rollback) without touching `AppStoragePaths.production`'s real
/// Application Support/Caches directories. Mirrors
/// `LibraryMutationAuthorizerTests`' own `MutationFixture` for the
/// journal-directory permissions the authorizer requires.
@MainActor
private struct QuarantineFixture {
    let container: URL
    let root: URL
    let journal: URL
    let identity: LibraryIdentity
    let metadata: MetadataStore
    let relativePath: String
    let content: Data

    static func make() throws -> Self {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroQuarantineTests-\(UUID().uuidString)", isDirectory: true)
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
        let content = Data("residue bytes for quarantine".utf8)
        try content.write(to: fileURL)
        let metadata = try MetadataStore.temporary()
        return Self(
            container: container,
            root: root,
            journal: journal,
            identity: LibraryIdentity(rootURL: root),
            metadata: metadata,
            relativePath: relativePath,
            content: content
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }

    func command(accessMode: LibraryAccessMode) -> QuarantineApplyCommand {
        QuarantineApplyCommand(
            root: root, identity: identity, accessMode: accessMode,
            journalDirectory: journal, metadata: metadata
        )
    }

    func plan(confirmationToken: String = "confirm-\(UUID().uuidString)", timestamp: Date = Date(timeIntervalSince1970: 1_786_000_000)) -> LibraryMutationPlan {
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
            confirmationToken: confirmationToken
        )
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
    }
}

@MainActor
@Suite("Approved quarantine apply")
struct QuarantineApplyCommandTests {
    @Test("Safety clause 1+2: a registered plan with the correct confirmation and write access moves files into a timestamped quarantine folder, never deleting them")
    func successfulApplyMovesIntoQuarantine() async throws {
        let fixture = try QuarantineFixture.make()
        defer { fixture.remove() }
        let plan = fixture.plan()
        let command = fixture.command(accessMode: .mutationEnabled)

        let receipt = try await command.apply(plan, confirmation: plan.confirmationToken)

        #expect(!fixture.exists(fixture.relativePath))
        let quarantineURL = plan.entries[0].destination
        #expect(FileManager.default.fileExists(atPath: quarantineURL.path))
        #expect(try Data(contentsOf: quarantineURL) == fixture.content)
        #expect(receipt.planID == plan.id)
        #expect(receipt.entries == plan.entries)
        let journalRow = try await fixture.metadata.mutationJournal(id: plan.id)
        #expect(journalRow?.status == .applied)
    }

    @Test("Safety clause 1: apply is rejected without the correct confirmation token, and nothing moves")
    func wrongConfirmationTokenIsRejected() async throws {
        let fixture = try QuarantineFixture.make()
        defer { fixture.remove() }
        let plan = fixture.plan()
        let command = fixture.command(accessMode: .mutationEnabled)

        await #expect(throws: LibraryMutationError.invalidConfirmation) {
            try await command.apply(plan, confirmation: "wrong-token")
        }
        #expect(fixture.exists(fixture.relativePath))
    }

    @Test("Safety clause 5: read-only mode makes apply unreachable before any filesystem access")
    func readOnlyModeRejectsApplyBeforeTouchingDisk() async throws {
        let fixture = try QuarantineFixture.make()
        defer { fixture.remove() }
        let plan = fixture.plan()
        let missingJournal = fixture.container.appendingPathComponent("never-created-journal", isDirectory: true)
        let command = QuarantineApplyCommand(
            root: fixture.root, identity: fixture.identity, accessMode: .readOnly,
            journalDirectory: missingJournal, metadata: fixture.metadata
        )

        await #expect(throws: LibraryMutationError.readOnly) {
            try await command.apply(plan, confirmation: plan.confirmationToken)
        }

        #expect(fixture.exists(fixture.relativePath))
        #expect(!FileManager.default.fileExists(atPath: missingJournal.path))
        let journalRow = try await fixture.metadata.mutationJournal(id: plan.id)
        #expect(journalRow == nil)
    }

    @Test("Safety clause 3+4: rollback restores the moved files and the journal reflects the full lifecycle")
    func rollbackRestoresFiles() async throws {
        let fixture = try QuarantineFixture.make()
        defer { fixture.remove() }
        let plan = fixture.plan()
        let command = fixture.command(accessMode: .mutationEnabled)
        let receipt = try await command.apply(plan, confirmation: plan.confirmationToken)
        #expect(!fixture.exists(fixture.relativePath))

        try await command.rollback(receiptID: receipt.id)

        #expect(fixture.exists(fixture.relativePath))
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(fixture.relativePath)) == fixture.content)
        #expect(!FileManager.default.fileExists(atPath: plan.entries[0].destination.path))
        let journalRow = try await fixture.metadata.mutationJournal(id: receipt.id)
        #expect(journalRow?.status == .rolledBack)
    }

    @Test("Safety clause 6: a used plan cannot be applied twice, even from a freshly constructed command")
    func usedPlanCannotBeAppliedTwice() async throws {
        let fixture = try QuarantineFixture.make()
        defer { fixture.remove() }
        let plan = fixture.plan()
        try await fixture.command(accessMode: .mutationEnabled).apply(plan, confirmation: plan.confirmationToken)

        // A fresh command opens a fresh authorizer, which reloads `usedPlans`
        // from the on-disk journal before `register` runs -- so re-applying
        // the same plan fails closed at registration (`.planAlreadyRegistered`)
        // rather than ever reaching a second, in-memory-only apply attempt.
        let freshCommand = fixture.command(accessMode: .mutationEnabled)
        await #expect(throws: LibraryMutationError.planAlreadyRegistered) {
            try await freshCommand.apply(plan, confirmation: plan.confirmationToken)
        }
    }

    @Test("End to end: a plan built by CleanupPreviewQuery applies cleanly through QuarantineApplyCommand")
    func queryBuiltPlanAppliesThroughCommand() async throws {
        let fixture = try QuarantineFixture.make()
        defer { fixture.remove() }
        let index = fixture.container.appendingPathComponent("index.sqlite")
        let database = try Database(path: index.path)
        try database.upsertFile(FileRecord(
            path: fixture.relativePath, size: Int64(fixture.content.count), mtime: 0,
            ext: "fit", kind: "other", area: .stacks, role: .other, scannedAt: 0
        ))
        let query = CleanupPreviewQuery(
            indexDatabaseForTesting: index, rootURL: fixture.root, accessMode: .mutationEnabled
        )
        let snapshot = try await query.snapshot()
        let category = try #require(snapshot.groups.first?.category)
        let plan = try query.plan(selecting: [category], confirmationToken: "confirm-end-to-end")

        let receipt = try await fixture.command(accessMode: .mutationEnabled).apply(
            plan, confirmation: plan.confirmationToken
        )

        #expect(!fixture.exists(fixture.relativePath))
        #expect(receipt.entries.count == 1)
    }

    @Test("Rollback in read-only mode is rejected before touching the filesystem")
    func readOnlyModeRejectsRollback() async throws {
        let fixture = try QuarantineFixture.make()
        defer { fixture.remove() }
        let plan = fixture.plan()
        let receipt = try await fixture.command(accessMode: .mutationEnabled).apply(plan, confirmation: plan.confirmationToken)

        let readOnlyCommand = fixture.command(accessMode: .readOnly)
        await #expect(throws: LibraryMutationError.readOnly) {
            try await readOnlyCommand.rollback(receiptID: receipt.id)
        }
        #expect(!fixture.exists(fixture.relativePath))
    }
}
