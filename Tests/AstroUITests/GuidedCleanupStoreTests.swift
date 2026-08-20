@testable import AstroApplication
@testable import AstroUI
import AstroCore
import CryptoKit
import Foundation
import Testing

/// A real library root + a real, isolated index database and quarantine
/// journal, mirroring `MutationConfirmationTests`' own fixture -- so
/// `GuidedCleanupStore` can drive a REAL `CleanupPreviewQuery.plan` and a
/// REAL `QuarantineApplyCommand.apply`/`rollback` through injected
/// factories, never `.production` (which would touch the real user's
/// Application Support/Caches).
///
/// Deliberately built around a DUPLICATE-CONTENT pair, not a bare residue
/// file: `ArchiveTaskKind.duplicateContent.findingCategories` is
/// `["duplicate-content"]`, the exact same literal `CleanupReport
/// .duplicateGroup` (AstroCore) uses for its own category -- the one finding
/// class where the audit engine's coarse category and `CleanupPreviewQuery`'s
/// own fine-grained `CleanupGroup.category` genuinely agree. (`.intermediate
/// Files`/`.osMetadata` both collapse to the audit's own single "residue"
/// category, but `CleanupReport`/`ResidueMatcher.category(forPath:)` splits
/// residue into `residue-process-dir`/`residue-seq`/`residue-other`/etc by a
/// DIFFERENT axis than the filename-based `.intermediateFiles`/`.osMetadata`
/// split -- so `"residue"` alone never matches any real
/// `CleanupPreviewGroup.category` there. That mismatch already exists in
/// production, on `ArchiveTaskDetailView`'s/`ArchiveView`'s own
/// `openQuarantinePreview(Set(kind.findingCategories))` pre-check today --
/// out of scope for this feature to fix, and orthogonal to it: this wizard
/// calls the exact same `CleanupPreviewQuery.plan(selecting:)` with the exact
/// same `kind.findingCategories` those call sites already use, so it can
/// never be less correct than the screen it replaces. Picking the one
/// category where the mismatch does not apply keeps this suite's "happy
/// path" tests honestly green rather than papering over the gap with a
/// category translation this feature was never asked to build.)
@MainActor
private struct GuidedCleanupFixture {
    let container: URL
    let root: URL
    let journal: URL
    let metadata: MetadataStore
    let index: URL
    /// The wasted (non-keeper) copy of the duplicate pair -- the one
    /// `CleanupReport.duplicateGroup` reports as reclaimable, and so the one
    /// a successful apply actually moves.
    let relativePath: String
    let content: Data

    static func make() throws -> Self {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroGuidedCleanupTests-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("Library", isDirectory: true)
        let journal = container.appendingPathComponent("Journal", isDirectory: true)
        // The keeper: `CleanupReport.keeperPath` always keeps the
        // `sessions/`-area copy when one exists, so only the `stacks/` copy
        // below is ever reported as wasted/reclaimable.
        let keeperRelativePath = "sessions/IC1396/2026-01-01/lights/frame1.fit"
        let relativePath = "stacks/IC1396/process/frame1_copy.fit"
        let content = Data("duplicate frame bytes for the guided cleanup wizard".utf8)
        for path in [keeperRelativePath, relativePath] {
            let fileURL = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: fileURL)
        }
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: journal.path
        )
        let index = container.appendingPathComponent("index.sqlite")
        let database = try Database(path: index.path)
        let sharedHash = "same-content-hash-for-both-copies"
        try database.upsertFile(FileRecord(
            path: keeperRelativePath, size: Int64(content.count), mtime: 0,
            ext: "fit", kind: "other", area: .sessions, role: .light,
            contentHash: sharedHash, scannedAt: 0
        ))
        try database.upsertFile(FileRecord(
            path: relativePath, size: Int64(content.count), mtime: 0,
            ext: "fit", kind: "other", area: .stacks, role: .other,
            contentHash: sharedHash, scannedAt: 0
        ))
        return Self(
            container: container, root: root, journal: journal,
            metadata: try MetadataStore.temporary(), index: index,
            relativePath: relativePath, content: content
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }

    func exists() -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    func queryFactory() -> GuidedCleanupStore.QueryFactory {
        let index = index
        return { _, accessMode in
            CleanupPreviewQuery(indexDatabaseForTesting: index, rootURL: self.root, accessMode: accessMode)
        }
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

private func stubTask(
    kind: ArchiveTaskKind, affectedFileCount: Int = 1, bytes: Int64 = 100, evidencePaths: [String] = []
) -> ArchiveTask {
    ArchiveTask(
        kind: kind, severity: .reclaim, affectedFileCount: affectedFileCount,
        bytes: bytes, evidencePaths: evidencePaths, action: .previewQuarantine(categories: kind.findingCategories)
    )
}

@MainActor
@Suite("Guided cleanup store")
struct GuidedCleanupStoreTests {
    @Test("The queue only includes kinds a bulk quarantine action can honestly apply to, and only when they have findings")
    func queueFiltersToBulkEligibleNonEmptyKinds() {
        let tasks: [ArchiveTask] = [
            stubTask(kind: .intermediateFiles, affectedFileCount: 3),
            stubTask(kind: .misplacedCalibration, affectedFileCount: 5), // no bulk support
            stubTask(kind: .auditNeverRun, affectedFileCount: 0), // no bulk support and empty
            stubTask(kind: .duplicateContent, affectedFileCount: 0), // bulk-eligible kind, but empty
        ]
        let store = GuidedCleanupStore(
            rootURL: URL(fileURLWithPath: NSTemporaryDirectory()), accessMode: .readOnly, tasks: tasks
        )

        #expect(store.queue.map(\.kind) == [.intermediateFiles])
    }

    @Test("An empty queue reports the wizard finished immediately -- the honest 'nothing to do' state")
    func emptyQueueIsFinishedImmediately() {
        let store = GuidedCleanupStore(
            rootURL: URL(fileURLWithPath: NSTemporaryDirectory()), accessMode: .readOnly,
            tasks: [stubTask(kind: .misplacedCalibration, affectedFileCount: 5)]
        )

        #expect(store.queue.isEmpty)
        #expect(store.isFinished)
    }

    @Test("Beginning review loads the current category's findings and advances the step")
    func beginReviewLoadsFindingsAndAdvances() async {
        let expectedFindings = [ArchiveFinding(id: 1, path: "sessions/x/stacks/r_light.fit", bytes: 10)]
        let store = GuidedCleanupStore(
            rootURL: URL(fileURLWithPath: NSTemporaryDirectory()), accessMode: .readOnly,
            tasks: [stubTask(kind: .intermediateFiles, affectedFileCount: 1)],
            findingsFactory: { _, kind in
                #expect(kind == .intermediateFiles)
                return expectedFindings
            }
        )

        await store.beginReview()

        #expect(store.step == .reviewFinding)
        #expect(store.findings == expectedFindings)
        #expect(store.findingCursor == 0)
    }

    @Test("Finding navigation is bounded at both ends")
    func findingNavigationIsBounded() async {
        let findings = (0..<3).map { ArchiveFinding(id: Int64($0), path: "f\($0)", bytes: 1) }
        let store = GuidedCleanupStore(
            rootURL: URL(fileURLWithPath: NSTemporaryDirectory()), accessMode: .readOnly,
            tasks: [stubTask(kind: .intermediateFiles)],
            findingsFactory: { _, _ in findings }
        )
        await store.beginReview()

        store.previousFinding()
        #expect(store.findingCursor == 0, "must not go negative")

        store.nextFinding()
        store.nextFinding()
        #expect(store.findingCursor == 2)
        store.nextFinding()
        #expect(store.findingCursor == 2, "must not exceed the last index")
    }

    @Test("Deciding to skip advances to the next category without ever building a plan")
    func decideSkipAdvancesWithoutPlanning() {
        let store = GuidedCleanupStore(
            rootURL: URL(fileURLWithPath: NSTemporaryDirectory()), accessMode: .mutationEnabled,
            tasks: [
                stubTask(kind: .intermediateFiles, affectedFileCount: 1),
                stubTask(kind: .osMetadata, affectedFileCount: 1),
            ],
            queryFactory: { _, _ in
                Issue.record("decideSkip must never build a plan")
                return CleanupPreviewQuery(indexDatabaseForTesting: URL(fileURLWithPath: "/dev/null"))
            }
        )

        store.decideSkip()

        #expect(store.skippedCategories == [.intermediateFiles])
        #expect(store.mutationStore == nil)
        #expect(store.currentIndex == 1)
        #expect(store.currentCandidate?.kind == .osMetadata)
        #expect(!store.isFinished)
    }

    @Test("Skipping the last queued category finishes the wizard")
    func decideSkipOnLastCategoryFinishes() {
        let store = GuidedCleanupStore(
            rootURL: URL(fileURLWithPath: NSTemporaryDirectory()), accessMode: .mutationEnabled,
            tasks: [stubTask(kind: .intermediateFiles, affectedFileCount: 1)]
        )

        store.decideSkip()

        #expect(store.isFinished)
    }

    @Test("Deciding to quarantine builds the exact CleanupPreviewQuery plan for the current category alone and creates a confirm store")
    func decideQuarantineBuildsPlanForCurrentCategoryOnly() throws {
        let fixture = try GuidedCleanupFixture.make()
        defer { fixture.remove() }
        let store = GuidedCleanupStore(
            rootURL: fixture.root, accessMode: .mutationEnabled,
            tasks: [stubTask(kind: .duplicateContent, affectedFileCount: 1)],
            queryFactory: fixture.queryFactory(),
            commandFactory: fixture.commandFactory()
        )

        store.decideQuarantine()

        let mutationStore = try #require(store.mutationStore)
        #expect(store.step == .confirmBatch)
        #expect(mutationStore.plan.entries.count == 1)
        #expect(mutationStore.plan.entries.first?.source == fixture.root.appendingPathComponent(fixture.relativePath).standardizedFileURL)
        #expect(store.planErrorMessage == nil)
    }

    @Test("Planning never gates on access mode -- a read-only session can still build a plan, matching CleanupPreviewStore.buildPlan")
    func decideQuarantinePlansEvenInReadOnlyMode() throws {
        let fixture = try GuidedCleanupFixture.make()
        defer { fixture.remove() }
        let store = GuidedCleanupStore(
            rootURL: fixture.root, accessMode: .readOnly,
            tasks: [stubTask(kind: .duplicateContent, affectedFileCount: 1)],
            queryFactory: fixture.queryFactory(),
            commandFactory: fixture.commandFactory()
        )

        store.decideQuarantine()

        #expect(store.mutationStore != nil)
        #expect(store.step == .confirmBatch)
    }

    @Test("A successful apply moves the real file, records the category as completed, and advances to the receipt step")
    func successfulApplyMovesFileAndAdvancesToReceipt() async throws {
        let fixture = try GuidedCleanupFixture.make()
        defer { fixture.remove() }
        let store = GuidedCleanupStore(
            rootURL: fixture.root, accessMode: .mutationEnabled,
            tasks: [stubTask(kind: .duplicateContent, affectedFileCount: 1)],
            queryFactory: fixture.queryFactory(),
            commandFactory: fixture.commandFactory()
        )
        store.decideQuarantine()
        let mutationStore = try #require(store.mutationStore)
        mutationStore.confirmationText = mutationStore.plan.confirmationToken

        await store.beginApply()

        #expect(store.step == .receipt)
        #expect(store.completedCategories == [.duplicateContent])
        #expect(!fixture.exists())
        #expect(mutationStore.receipt != nil)
    }

    @Test("A failed apply (read-only mode) leaves the wizard on confirmBatch with the store's own error, never silently advancing")
    func failedApplyStaysOnConfirmBatch() async throws {
        let fixture = try GuidedCleanupFixture.make()
        defer { fixture.remove() }
        let store = GuidedCleanupStore(
            rootURL: fixture.root, accessMode: .readOnly,
            tasks: [stubTask(kind: .duplicateContent, affectedFileCount: 1)],
            queryFactory: fixture.queryFactory(),
            commandFactory: fixture.commandFactory()
        )
        store.decideQuarantine()
        let mutationStore = try #require(store.mutationStore)
        mutationStore.confirmationText = mutationStore.plan.confirmationToken

        await store.beginApply()

        #expect(store.step == .confirmBatch)
        #expect(store.completedCategories.isEmpty)
        #expect(fixture.exists(), "the real-only-mode gate must prevent any file from moving")
        #expect(mutationStore.errorMessage != nil)
    }

    @Test("Continuing after a receipt advances the queue and clears per-category state")
    func continueAfterReceiptAdvancesAndResets() async throws {
        let fixture = try GuidedCleanupFixture.make()
        defer { fixture.remove() }
        let store = GuidedCleanupStore(
            rootURL: fixture.root, accessMode: .mutationEnabled,
            tasks: [
                stubTask(kind: .duplicateContent, affectedFileCount: 1),
                stubTask(kind: .osMetadata, affectedFileCount: 1),
            ],
            queryFactory: fixture.queryFactory(),
            findingsFactory: { _, _ in [] },
            commandFactory: fixture.commandFactory()
        )
        store.decideQuarantine()
        let mutationStore = try #require(store.mutationStore)
        mutationStore.confirmationText = mutationStore.plan.confirmationToken
        await store.beginApply()
        await store.beginReview() // populate some per-category state to prove it resets

        store.continueToNextCategory()

        #expect(store.currentIndex == 1)
        #expect(store.currentCandidate?.kind == .osMetadata)
        #expect(store.mutationStore == nil)
        #expect(store.findings.isEmpty)
        #expect(store.step == .selectCategory)
        #expect(!store.isFinished)
    }

    @Test("Finishing the only queued category via apply leaves the wizard finished after Continue")
    func finishingOnlyCategoryFinishesWizard() async throws {
        let fixture = try GuidedCleanupFixture.make()
        defer { fixture.remove() }
        let store = GuidedCleanupStore(
            rootURL: fixture.root, accessMode: .mutationEnabled,
            tasks: [stubTask(kind: .duplicateContent, affectedFileCount: 1)],
            queryFactory: fixture.queryFactory(),
            commandFactory: fixture.commandFactory()
        )
        store.decideQuarantine()
        let mutationStore = try #require(store.mutationStore)
        mutationStore.confirmationText = mutationStore.plan.confirmationToken
        await store.beginApply()

        store.continueToNextCategory()

        #expect(store.isFinished)
    }

    @Test("onLibraryFindingsChanged fires when the embedded mutation store's own apply succeeds -- the same hook the plain Cleanup Preview sheet already fires")
    func onLibraryFindingsChangedFiresThroughTheEmbeddedStore() async throws {
        let fixture = try GuidedCleanupFixture.make()
        defer { fixture.remove() }
        let store = GuidedCleanupStore(
            rootURL: fixture.root, accessMode: .mutationEnabled,
            tasks: [stubTask(kind: .duplicateContent, affectedFileCount: 1)],
            queryFactory: fixture.queryFactory(),
            commandFactory: fixture.commandFactory()
        )
        var changeCount = 0
        store.onLibraryFindingsChanged = { changeCount += 1 }
        store.decideQuarantine()
        let mutationStore = try #require(store.mutationStore)
        mutationStore.confirmationText = mutationStore.plan.confirmationToken

        await store.beginApply()

        #expect(changeCount == 1)
    }

    @Test("Rollback after a successful apply restores the file, using the same MutationConfirmationStore.rollback the plain sheet uses")
    func rollbackRestoresFile() async throws {
        let fixture = try GuidedCleanupFixture.make()
        defer { fixture.remove() }
        let store = GuidedCleanupStore(
            rootURL: fixture.root, accessMode: .mutationEnabled,
            tasks: [stubTask(kind: .duplicateContent, affectedFileCount: 1)],
            queryFactory: fixture.queryFactory(),
            commandFactory: fixture.commandFactory()
        )
        store.decideQuarantine()
        let mutationStore = try #require(store.mutationStore)
        mutationStore.confirmationText = mutationStore.plan.confirmationToken
        await store.beginApply()
        #expect(!fixture.exists())

        await store.rollbackCurrent()

        #expect(mutationStore.isRolledBack)
        #expect(fixture.exists())
    }
}
