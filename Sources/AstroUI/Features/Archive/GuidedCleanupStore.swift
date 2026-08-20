import AstroApplication
import Foundation
import Observation

/// The guided-cleanup wizard's own steps, in order -- the same `CaseIterable`
/// step-enum shape `CaptureImportStep` already uses, one `@Observable` store
/// owning every step's data. Feature 5.3 (V3 prestack program spec, section
/// 5.3): "the owner often doesn't want to pick through a 33-row table -- he'd
/// rather go one at a time, 'quarantine this / leave this' decisions, with
/// the exact same safety ritual as today." This type is that presentation
/// layer ONLY -- it never re-implements `CleanupPreviewQuery.plan`,
/// `QuarantineApplyCommand.apply/rollback`, or `LibraryMutationAuthorizer`;
/// it drives the exact same `MutationConfirmationStore` the plain,
/// table-based Cleanup Preview screen already drives (see
/// `decideQuarantine()`/`beginApply()` below), just one CATEGORY at a time
/// instead of a multi-select table.
///
/// Granularity note: the underlying `CleanupPreviewQuery.plan(selecting:)`
/// only ever selects whole `ArchiveTaskKind` categories, never individual
/// findings -- there is no per-file selection anywhere in the existing
/// quarantine engine, and this wizard does not invent one (the spec's own
/// iron rule: "never a second mutation path"). So "review one at a time" is
/// real (the `.reviewFinding` step pages through every real finding a
/// category has, exactly what the file will show once it moves), but the
/// actual "quarantine this / leave this" decision in `.decide` is made once
/// per CATEGORY, not once per individual file.
public enum GuidedCleanupStep: Int, CaseIterable, Sendable {
    case selectCategory
    case reviewFinding
    case decide
    case confirmBatch
    case quarantine
    case receipt
}

/// One category queued for a guided pass. The queue is built once, from an
/// already-loaded `[ArchiveTask]` -- the exact same list `ArchiveView`'s own
/// "Needs you" section already renders -- filtered to only the kinds a bulk
/// quarantine action can honestly apply to
/// (`ArchiveTaskKind.supportsBulkQuarantinePreview`). A kind without one
/// (`.misplacedCalibration`, `.brokenNames`, `.corruption`, `.unverified`,
/// `.auditNeverRun`) never reaches this queue at all -- the guided flow does
/// not fabricate a quarantine step for a finding class whose only honest
/// answer is "go look at it by hand" (`ArchiveTaskDetailView.noQuarantine
/// ActionRow`'s own rule, applied here too).
public struct GuidedCleanupCandidate: Equatable, Sendable, Identifiable {
    public var id: String { kind.rawValue }
    public let kind: ArchiveTaskKind
    public let affectedFileCount: Int
    public let bytes: Int64
    public let evidencePaths: [String]

    public init(kind: ArchiveTaskKind, affectedFileCount: Int, bytes: Int64, evidencePaths: [String]) {
        self.kind = kind
        self.affectedFileCount = affectedFileCount
        self.bytes = bytes
        self.evidencePaths = evidencePaths
    }
}

/// Backs `GuidedCleanupView`. Every write this store ever causes goes through
/// `MutationConfirmationStore.apply()`/`.rollback()` -- the SAME store type
/// `MutationConfirmationSheet` uses -- which in turn calls the SAME
/// `QuarantineApplyCommand`/`LibraryMutationAuthorizer` chain the plain
/// Cleanup Preview screen already uses. This store owns none of that logic;
/// it only sequences which category is "current", which finding is being
/// reviewed, and which step of the per-category ritual is showing.
@MainActor
@Observable
public final class GuidedCleanupStore {
    public typealias QueryFactory = @Sendable (URL, LibraryAccessMode) throws -> CleanupPreviewQuery
    public typealias FindingsFactory = @Sendable (URL, ArchiveTaskKind) async throws -> [ArchiveFinding]

    public let rootURL: URL
    public let accessMode: LibraryAccessMode
    public let queue: [GuidedCleanupCandidate]

    public private(set) var currentIndex = 0
    public private(set) var step: GuidedCleanupStep = .selectCategory
    public private(set) var findings: [ArchiveFinding] = []
    public private(set) var findingCursor = 0
    public private(set) var isLoadingFindings = false
    public private(set) var findingsErrorMessage: String?
    public private(set) var planErrorMessage: String?
    public private(set) var mutationStore: MutationConfirmationStore?
    /// Categories the user actually chose "Quarantine" for and applied
    /// successfully, in the order they finished -- the wizard's own tally
    /// for its final "all done" screen. Never a second source of truth for
    /// what moved: each category's own `MutationReceipt`, held by that
    /// category's `MutationConfirmationStore` at the moment it applied,
    /// remains the only record that matters for undo/audit.
    public private(set) var completedCategories: [ArchiveTaskKind] = []
    public private(set) var skippedCategories: [ArchiveTaskKind] = []

    /// Fired whenever the embedded `MutationConfirmationStore` fires its own
    /// `onLibraryFindingsChanged` -- lets the host view keep the sidebar
    /// badge fresh, mirroring `MutationConfirmationStore`'s own doc comment.
    public var onLibraryFindingsChanged: (() -> Void)?

    private let queryFactory: QueryFactory
    private let findingsFactory: FindingsFactory
    private let commandFactory: MutationConfirmationStore.CommandFactory

    public init(
        rootURL: URL,
        accessMode: LibraryAccessMode,
        tasks: [ArchiveTask],
        queryFactory: @escaping QueryFactory = { rootURL, accessMode in
            try CleanupPreviewQuery.production(rootURL: rootURL, accessMode: accessMode)
        },
        /// `Optional`/`nil` rather than defaulted directly to
        /// `Self.productionFindings`, and MUST stay that way -- an `async`
        /// default argument is emitted as a `weak`/`linkonce_odr` closure
        /// plus an async function pointer record into every module that uses
        /// the default, and Swift 6.3.3 gives those copies different async
        /// context sizes across translation units (the exact 80-bytes-here/
        /// 64-in-a-client-module split `NightsStore.calendarProvider`'s own
        /// doc comment documents, and `AsyncContextSizeGateTests` gates
        /// against by name). Resolving the production closure inside the
        /// init body instead means only THIS module ever emits that record.
        findingsFactory: FindingsFactory? = nil,
        commandFactory: @escaping MutationConfirmationStore.CommandFactory = { rootURL, accessMode in
            try QuarantineApplyCommand.production(rootURL: rootURL, accessMode: accessMode)
        }
    ) {
        self.rootURL = rootURL
        self.accessMode = accessMode
        self.queue = Self.buildQueue(from: tasks)
        self.queryFactory = queryFactory
        self.findingsFactory = findingsFactory ?? Self.productionFindings
        self.commandFactory = commandFactory
    }

    private static func productionFindings(rootURL: URL, kind: ArchiveTaskKind) async throws -> [ArchiveFinding] {
        try await ArchiveTaskQuery.production(rootURL: rootURL).findings(for: kind)
    }

    static func buildQueue(from tasks: [ArchiveTask]) -> [GuidedCleanupCandidate] {
        tasks
            .filter { $0.kind.supportsBulkQuarantinePreview && $0.affectedFileCount > 0 }
            .map {
                GuidedCleanupCandidate(
                    kind: $0.kind, affectedFileCount: $0.affectedFileCount,
                    bytes: $0.bytes, evidencePaths: $0.evidencePaths
                )
            }
    }

    /// `true` once every queued category has been either quarantined or
    /// skipped -- including immediately at construction when the queue was
    /// empty to begin with (the spec's own required honest state: "no
    /// finding -> an immediate 'done' screen", never a wizard stuck showing
    /// steps for nothing).
    public var isFinished: Bool { currentIndex >= queue.count }

    public var currentCandidate: GuidedCleanupCandidate? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    public var currentFinding: ArchiveFinding? {
        findings.indices.contains(findingCursor) ? findings[findingCursor] : nil
    }

    // MARK: - selectCategory -> reviewFinding

    public func beginReview() async {
        guard let candidate = currentCandidate else { return }
        isLoadingFindings = true
        findingsErrorMessage = nil
        findingCursor = 0
        do {
            findings = try await findingsFactory(rootURL, candidate.kind)
        } catch {
            findings = []
            findingsErrorMessage = error.localizedDescription
        }
        isLoadingFindings = false
        step = .reviewFinding
    }

    public func nextFinding() {
        guard findingCursor + 1 < findings.count else { return }
        findingCursor += 1
    }

    public func previousFinding() {
        guard findingCursor > 0 else { return }
        findingCursor -= 1
    }

    public func proceedToDecide() {
        step = .decide
    }

    // MARK: - decide

    /// Builds the exact same `LibraryMutationPlan`
    /// `CleanupPreviewView.buildPlan()` builds, selecting only the CURRENT
    /// category -- never a hand-rolled plan, never a new selection
    /// mechanism. Available regardless of `accessMode` (planning never
    /// writes anything); the honest read-only refusal happens downstream, in
    /// `beginApply()`, exactly where `MutationConfirmationStore.apply()`
    /// already enforces it for the plain table screen.
    public func decideQuarantine() {
        guard let candidate = currentCandidate else { return }
        planErrorMessage = nil
        do {
            let plan = try queryFactory(rootURL, accessMode).plan(
                selecting: Set(candidate.kind.findingCategories),
                confirmationToken: UUID().uuidString
            )
            let store = MutationConfirmationStore(
                plan: plan, rootURL: rootURL, accessMode: accessMode, commandFactory: commandFactory
            )
            store.onLibraryFindingsChanged = { [weak self] in self?.onLibraryFindingsChanged?() }
            mutationStore = store
            step = .confirmBatch
        } catch {
            planErrorMessage = error.localizedDescription
        }
    }

    /// "Leave this" -- the category is left exactly as it is (nothing
    /// planned, nothing built) and the wizard moves on. Always available,
    /// including in read-only mode: skipping is never gated, only applying
    /// is.
    public func decideSkip() {
        guard let candidate = currentCandidate else { return }
        skippedCategories.append(candidate.kind)
        advanceToNextCategory()
    }

    // MARK: - confirmBatch / quarantine -- the actual apply, via
    // MutationConfirmationStore, never re-implemented here

    public func beginApply() async {
        guard let mutationStore else { return }
        step = .quarantine
        await mutationStore.apply()
        if mutationStore.receipt != nil {
            if let candidate = currentCandidate { completedCategories.append(candidate.kind) }
            step = .receipt
        } else {
            // Apply failed (read-only mode, or a real I/O error) -- back to
            // confirmBatch, where `mutationStore.errorMessage` is already
            // shown, never left stuck on an indefinite spinner.
            step = .confirmBatch
        }
    }

    public func rollbackCurrent() async {
        await mutationStore?.rollback()
    }

    // MARK: - receipt -> next category

    public func continueToNextCategory() {
        advanceToNextCategory()
    }

    private func advanceToNextCategory() {
        currentIndex += 1
        mutationStore = nil
        findings = []
        findingCursor = 0
        step = .selectCategory
    }
}
