import Foundation

/// Applies (and rolls back) a `CleanupPreviewQuery`-built `LibraryMutationPlan`
/// through `LibraryMutationAuthorizer` -- the only place a quarantine
/// operation actually touches the filesystem. This command never
/// re-implements the authorizer's move/rollback/staleness/journal logic; it
/// only opens the authorizer against this library's root and journal
/// directory, and records a lifecycle summary of each operation into the
/// metadata store's own `mutation_journal` table (distinct from --
/// additional to -- the authorizer's internal, HMAC-authenticated file
/// journal, which alone is what makes an interrupted apply/rollback safely
/// recoverable).
///
/// `register` + `apply` happen against a single, freshly-opened authorizer
/// instance per call, rather than a long-lived one: the authorizer's
/// in-memory `plans` dictionary only needs to survive from `register` to
/// `apply` within that one call, and everything that must survive *across*
/// calls (used plans, issued receipts, rolled-back receipts) is reloaded
/// from the on-disk journal every time a fresh authorizer opens -- exactly
/// the behavior the 22 `LibraryMutationAuthorizerTests` already exercise via
/// `MutationFixture.restartedAuthorizer()`.
public struct QuarantineApplyCommand: Sendable {
    /// Fixed revision stamp every cleanup-quarantine plan and every
    /// authorizer session this command opens agree on. Cleanup has no
    /// independent revision-tracking source (unlike, say, a live scan
    /// counter) -- `LibraryMutationAuthorizer`'s own revision check still
    /// enforces "this plan matches the identity this command was opened
    /// against", it just never has a reason to disagree for cleanup plans.
    public static let revision: UInt64 = 1

    private let root: URL
    private let identity: LibraryIdentity
    private let accessMode: LibraryAccessMode
    private let journalDirectory: URL
    private let metadata: MetadataStore

    init(
        root: URL,
        identity: LibraryIdentity,
        accessMode: LibraryAccessMode,
        journalDirectory: URL,
        metadata: MetadataStore
    ) {
        self.root = root
        self.identity = identity
        self.accessMode = accessMode
        self.journalDirectory = journalDirectory
        self.metadata = metadata
    }

    public static func production(
        rootURL: URL,
        accessMode: LibraryAccessMode,
        metadata: MetadataStore? = nil
    ) throws -> Self {
        let root = rootURL.standardizedFileURL
        let identity = LibraryIdentity(rootURL: root)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: root)
        let resolvedMetadata = try metadata ?? MetadataStore(storagePaths: storage)
        let journalDirectory = storage.migration
            .deletingLastPathComponent()
            .appendingPathComponent("mutation_journal", isDirectory: true)
        try Self.ensureSecureJournalDirectory(at: journalDirectory)
        return Self(
            root: root,
            identity: identity,
            accessMode: accessMode,
            journalDirectory: journalDirectory,
            metadata: resolvedMetadata
        )
    }

    /// Registers `plan` with a freshly-opened authorizer and immediately
    /// applies it with `confirmation`. Throws `LibraryMutationError.readOnly`
    /// before opening the library root, the journal directory, or writing
    /// anything -- including the `mutation_journal` audit row -- unless
    /// `accessMode == .mutationEnabled`; this is the "the entire path is
    /// unreachable in read-only mode" half of the safety contract.
    @discardableResult
    public func apply(_ plan: LibraryMutationPlan, confirmation: String) async throws -> MutationReceipt {
        guard accessMode == .mutationEnabled else { throw LibraryMutationError.readOnly }
        await record(operationID: plan.id, status: .planned, plan: plan)
        do {
            try Self.ensureDestinationDirectories(for: plan, root: root)
        } catch {
            await record(operationID: plan.id, status: .failed, plan: plan)
            throw error
        }
        let authorizer = try makeAuthorizer()
        do {
            try await authorizer.register(plan)
            await record(operationID: plan.id, status: .applying, plan: plan)
            let receipt = try await authorizer.apply(planID: plan.id, confirmation: confirmation)
            await record(operationID: plan.id, status: .applied, plan: plan)
            return receipt
        } catch {
            await record(operationID: plan.id, status: .failed, plan: plan)
            throw error
        }
    }

    /// Restores every file a previously-applied `receiptID` moved, back to
    /// its original location. Same read-only gate as `apply`.
    public func rollback(receiptID: UUID) async throws {
        guard accessMode == .mutationEnabled else { throw LibraryMutationError.readOnly }
        await record(operationID: receiptID, status: .rollingBack, plan: nil)
        let authorizer = try makeAuthorizer()
        do {
            try await authorizer.rollback(receiptID: receiptID)
            await record(operationID: receiptID, status: .rolledBack, plan: nil)
        } catch {
            await record(operationID: receiptID, status: .failed, plan: nil)
            throw error
        }
    }

    private func makeAuthorizer() throws -> LibraryMutationAuthorizer {
        try LibraryMutationAuthorizer(
            root: root,
            identity: identity,
            currentRevision: Self.revision,
            accessMode: accessMode,
            journalDirectory: journalDirectory
        )
    }

    /// One upserted row per operation -- `id` is deliberately the
    /// operation's own id, so repeated calls for the same plan/receipt
    /// update that single row's `status` in place (`planned` ->
    /// `applying` -> `applied`/`failed`, or `rollingBack` ->
    /// `rolledBack`/`failed`) rather than appending an unbounded trail.
    /// Best-effort: a `mutation_journal` write failure never blocks or
    /// unwinds the actual (already-safe, already-journaled-by-the-
    /// authorizer) filesystem operation.
    private func record(operationID: UUID, status: MutationJournalStatus, plan: LibraryMutationPlan?) async {
        let record = MutationJournalRecord(
            id: operationID,
            operationID: operationID,
            status: status,
            createdAt: Date(),
            payloadJSON: Self.payloadJSON(for: plan)
        )
        try? await metadata.save(record)
    }

    private static func payloadJSON(for plan: LibraryMutationPlan?) -> String {
        guard let plan else { return "{\"kind\":\"cleanup-quarantine-rollback\"}" }
        return "{\"kind\":\"cleanup-quarantine\",\"entryCount\":\(plan.entries.count),\"totalBytes\":\(plan.totalBytes)}"
    }

    /// `LibraryMutationAuthorizer.register`/`apply` both preflight-open the
    /// destination's parent directory chain and never create it themselves
    /// (a plain POSIX rename requires the destination directory to already
    /// exist) -- so every entry's destination directory must exist before
    /// the authorizer ever sees the plan. Each candidate directory is
    /// string-validated as contained within `root` before creation, the
    /// same containment rule the authorizer itself enforces on every entry;
    /// the authorizer's own fd-based, symlink-refusing checks remain the
    /// actual safety gate for the move itself, this is only satisfying its
    /// precondition.
    private static func ensureDestinationDirectories(for plan: LibraryMutationPlan, root: URL) throws {
        let standardizedRoot = root.standardizedFileURL
        let rootPrefix = standardizedRoot.path == "/" ? "/" : standardizedRoot.path + "/"
        for entry in plan.entries {
            let directory = entry.destination.deletingLastPathComponent().standardizedFileURL
            guard directory.path == standardizedRoot.path || directory.path.hasPrefix(rootPrefix) else {
                throw LibraryMutationError.destinationOutsideLibrary
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private static func ensureSecureJournalDirectory(at url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }
}
