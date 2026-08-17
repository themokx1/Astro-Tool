import AstroCore
import Foundation

public enum ArchiveTaskKind: String, CaseIterable, Sendable {
    case intermediateFiles
    /// W3-13 (owner screenshot): `.DS_Store` (and any other file matching
    /// `ArchiveTaskQuery.isSystemMetadataFile`) used to be grouped into
    /// `.intermediateFiles` ("Stacking leftovers") along with genuine
    /// stacking-tool byproducts (`.seq`/`.lst`/`_conv`/`_bkg`/`r_*`/`bkg_*`)
    /// -- both match `AstroCore`'s own single "residue" audit category (see
    /// `AstroConfig.residuePatterns`), but a Finder metadata file is not
    /// stacking output, and showing it as an EXAMPLE PATH under "Stacking
    /// leftovers" mischaracterized what the card was warning about. Split
    /// out as its own kind rather than reclassified at the audit-rule level:
    /// `ResidueRule` in `AstroCore` still emits one "residue" category for
    /// both (unchanged, so `CleanupReport`/quarantine mechanics keep their
    /// existing behavior), and `ArchiveTaskQuery.summary()`/`findings(for:)`
    /// route by filename within that one category, purely for CARD display.
    case osMetadata
    case duplicateContent
    case misplacedCalibration
    case brokenNames
    /// Silent corruption: the bytes changed while size and timestamp did
    /// not. The only finding here that means data may already be lost, and
    /// the only one for which "restore from a backup copy" is true advice.
    case corruption
    /// The verify pass could not confirm these files -- it read an error, or
    /// found an in-place rewrite. Not proof of loss, so it must not borrow
    /// corruption's language.
    case unverified
    /// Not a problem -- the honest "I have not looked yet" state, which
    /// still deserves a card because it has a real button.
    case auditNeverRun

    /// The raw `findings.category` values that roll up into this card.
    /// `public`: `ArchiveTaskDetailView` (AstroUI) reads this directly to
    /// build its own bulk quarantine-preview action's categories, keeping
    /// this mapping the single source of truth rather than a second copy
    /// re-derived at the UI layer.
    public var findingCategories: [String] {
        switch self {
        case .intermediateFiles: ["residue"]
        // Shares "residue" with `.intermediateFiles` on purpose -- see this
        // case's own doc comment. `ArchiveTaskQuery.summary()`/`findings(for:)`
        // never resolve a kind FROM a category via this property alone when
        // the category is "residue" (they route by filename first); this
        // value only feeds `ArchiveTaskDetailView`'s bulk quarantine-preview
        // action, which already previews by raw category, not by kind, on
        // both cards.
        case .osMetadata: ["residue"]
        case .duplicateContent: ["duplicate-content"]
        case .misplacedCalibration: ["calib-in-wrong-dir", "orphan-calib-dir"]
        case .brokenNames: ["placeholder-name", "duplicated-catalog-prefix",
                            "nested-session-tree", "noncanonical-subdir"]
        case .corruption: ["content-changed"]
        case .unverified: ["modified-in-place", "verify-read-error"]
        case .auditNeverRun: []
        }
    }

    /// Task 3 (wave 3): whether `ArchiveTaskDetailView`'s own "view all"
    /// list shows a bulk quarantine-preview action for this kind, in
    /// addition to each row's own reveal-in-Finder button. `true` only for
    /// the two reclaim kinds -- regenerable output and byte-identical
    /// copies -- where a quarantine-then-apply pass is a safe, reversible-
    /// until-applied action. `false` for every error kind: there is no
    /// honest bulk response to invent for a checksum mismatch or a broken
    /// folder name, whose only real answer is "go look at it" (see the
    /// plan's own instruction not to invent a destructive action here).
    public var supportsBulkQuarantinePreview: Bool {
        switch self {
        case .intermediateFiles, .osMetadata, .duplicateContent: true
        case .misplacedCalibration, .brokenNames, .corruption, .unverified, .auditNeverRun: false
        }
    }
}

public enum ArchiveTaskSeverity: String, Sendable {
    case error
    case reclaim
    case attention
    case info

    var rank: Int {
        switch self {
        case .error: 0
        case .reclaim: 1
        case .attention: 2
        case .info: 3
        }
    }
}

public enum ArchiveTaskAction: Equatable, Sendable {
    /// Pushes the existing quarantine preview, pre-selected to these
    /// `CleanupPreviewGroup.category` values -- both the "Stacking
    /// leftovers" and "Byte-identical copies" cards resolve to this same
    /// action, each with its own correct categories, instead of the
    /// duplicate card promising a distinct comparison surface (`case
    /// compareDuplicates`, removed) this wave never built. See Task 10's
    /// own prerequisite note in the plan for why.
    case previewQuarantine(categories: [String])
    case revealInFinder(path: String)
    /// Task 3 (wave 3): more than one finding no longer hands back one
    /// arbitrary path -- this is the fix for the wave 1 design error
    /// `revealInFinder`'s own doc comment above describes ("33 kalibráció
    /// rossz mappában" opened whichever finding happened to sort first and
    /// silently ignored the other 32). Names its own `kind` so the UI can
    /// push `ArchiveTaskDetailView`, which loads every one of that kind's
    /// findings itself via `ArchiveTaskQuery.findings(for:)` rather than
    /// this action carrying them.
    case showFindings(kind: ArchiveTaskKind)
    case runAudit
    /// Only ever produced internally, and filtered out before `tasks()`
    /// returns -- a card with no action must not reach the UI. Deliberately
    /// NOT named `none`: `ArchiveTaskAction.none` collides with
    /// `Optional.none` at every `??` and comparison site.
    case unavailable
}

public struct ArchiveTask: Equatable, Sendable, Identifiable {
    public var id: String { kind.rawValue }
    public let kind: ArchiveTaskKind
    public let severity: ArchiveTaskSeverity
    public let affectedFileCount: Int
    public let bytes: Int64
    /// Up to three real paths from the underlying findings, so the card can
    /// show what it is talking about instead of only a count.
    public let evidencePaths: [String]
    public let action: ArchiveTaskAction

    /// The acknowledgement key this card is silenced by -- one key per
    /// KIND, so acknowledging survives a re-audit that renumbers every
    /// individual finding.
    public static let ackCategory = "archive-task"
    public var ackGroupKey: String { kind.rawValue }

    public init(
        kind: ArchiveTaskKind, severity: ArchiveTaskSeverity,
        affectedFileCount: Int, bytes: Int64,
        evidencePaths: [String], action: ArchiveTaskAction
    ) {
        self.kind = kind
        self.severity = severity
        self.affectedFileCount = affectedFileCount
        self.bytes = bytes
        self.evidencePaths = evidencePaths
        self.action = action
    }
}

/// What `ArchiveTaskQuery` intentionally does not turn into a card: findings
/// whose `category` maps to no `ArchiveTaskKind` at all. Replayed against the
/// real library this is 138 findings, 8.69 GB, across twelve categories
/// (`capture-unassigned-artifact`, `capture-legacy-folder`, `tool-output`,
/// `missing-counterpart`, and eight more). Dropping them is the right call --
/// they have no executable action -- but dropping them SILENTLY is not: four
/// cards and nothing else reads as complete coverage. The footer renders this
/// as a single quiet line so the page never implies it saw more than it did.
///
/// Deliberately distinct from a card that exists but is suppressed
/// (acknowledged, or dropped by the actionability gate in `action(for:entry:)`):
/// those findings' categories DID map to a kind, so they are not "uncovered" --
/// conflating the two would make an acknowledged finding look like a coverage
/// gap.
public struct UncoveredFindings: Equatable, Sendable {
    public let count: Int
    public let bytes: Int64
    /// Category name -> how many findings, for the footer's tooltip.
    public let categories: [String: Int]

    public static let none = UncoveredFindings(count: 0, bytes: 0, categories: [:])
    public var isEmpty: Bool { count == 0 }

    public init(count: Int, bytes: Int64, categories: [String: Int]) {
        self.count = count
        self.bytes = bytes
        self.categories = categories
    }
}

/// One raw finding behind a task card, carrying its own real path -- what
/// `ArchiveTask.evidencePaths` deliberately could not, since that array is
/// capped at `ArchiveTaskQuery.evidenceLimit` (built to illustrate a card,
/// not to back a list). Fetched only by `ArchiveTaskQuery.findings(for:)`,
/// on demand when a card's own "view all" route is actually pushed -- never
/// as part of `summary()` itself, so a 3 231-finding card costs nothing
/// extra until its own detail page is opened.
public struct ArchiveFinding: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let path: String
    public let bytes: Int64

    public init(id: Int64, path: String, bytes: Int64) {
        self.id = id
        self.path = path
        self.bytes = bytes
    }
}

/// `ArchiveTaskQuery.summary()`'s full result: the cards the page can act on,
/// plus what it could not cover. Kept as one struct rather than two return
/// values so a caller can never read one half without the other.
public struct ArchiveTaskSummary: Equatable, Sendable {
    public let tasks: [ArchiveTask]
    public let uncovered: UncoveredFindings

    public init(tasks: [ArchiveTask], uncovered: UncoveredFindings) {
        self.tasks = tasks
        self.uncovered = uncovered
    }
}

/// Turns the latest audit run's and the latest verify run's findings into at
/// most seven cards -- one per non-`auditNeverRun` `ArchiveTaskKind` -- instead
/// of one row per finding. The 3 228 residue findings on the reference
/// library split into (at most) two cards by filename -- see
/// `ArchiveTaskKind.osMetadata`'s own doc comment -- not 3 228 rows.
///
/// Hard rule, gated by `ArchiveTaskQueryTests.everyCardIsActionable`: a card
/// only exists if its `action` can actually run. Titles and explanatory
/// sentences are NOT built here -- they are localized UI strings keyed off
/// `kind`, so this type stays free of presentation text.
public struct ArchiveTaskQuery: Sendable {
    public static let evidenceLimit = 3

    private let indexDatabase: URL
    private let metadata: MetadataStore?

    init(indexDatabaseForTesting: URL, metadata: MetadataStore? = nil) {
        self.indexDatabase = indexDatabaseForTesting
        self.metadata = metadata
    }

    public static func production(rootURL: URL, metadata: MetadataStore? = nil) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        let resolvedMetadata = try metadata ?? MetadataStore(storagePaths: storage)
        return Self(indexDatabaseForTesting: storage.indexDatabase, metadata: resolvedMetadata)
    }

    public func summary() async throws -> ArchiveTaskSummary {
        let db = try SQLiteDB(readOnlyPath: indexDatabase.standardizedFileURL.path)

        guard try Self.hasAuditRun(db: db) else {
            return ArchiveTaskSummary(
                tasks: [ArchiveTask(
                    kind: .auditNeverRun, severity: .info,
                    affectedFileCount: 0, bytes: 0, evidencePaths: [], action: .runAudit
                )],
                uncovered: .none
            )
        }

        var grouped: [ArchiveTaskKind: (files: Int, bytes: Int64, paths: [String])] = [:]
        // Categories with no ArchiveTaskKind at all -- see UncoveredFindings'
        // doc comment. Kept separate from `grouped` because a finding here
        // never had a chance to become a card, unlike one that is grouped
        // and later suppressed by an acknowledgement or the actionability gate.
        var uncoveredByCategory: [String: (files: Int, bytes: Int64)] = [:]
        try db.query(
            """
            SELECT d.category, d.path, COALESCE(f.size, 0)
            FROM findings d LEFT JOIN files f ON f.path = d.path
            WHERE d.run_id IN (
                    (SELECT MAX(id) FROM runs WHERE kind = 'audit'),
                    (SELECT MAX(id) FROM runs WHERE kind = 'verify')
                  )
            ORDER BY d.id;
            """
        ) { row in
            let category = row.string(0) ?? ""
            let path = row.string(1) ?? ""
            let size = row.int64(2) ?? 0
            guard let kind = Self.taskKind(forCategory: category, path: path) else {
                var entry = uncoveredByCategory[category] ?? (files: 0, bytes: 0)
                entry.files += 1
                entry.bytes += size
                uncoveredByCategory[category] = entry
                return
            }
            var entry = grouped[kind] ?? (files: 0, bytes: 0, paths: [])
            entry.files += 1
            entry.bytes += size
            if entry.paths.count < Self.evidenceLimit, !path.isEmpty { entry.paths.append(path) }
            grouped[kind] = entry
        }

        let ackedKeys: Set<String>
        if let metadata {
            ackedKeys = Set(try await metadata.acknowledgements().map(\.ackKey))
        } else {
            ackedKeys = []
        }

        let tasks = grouped.compactMap { kind, entry -> ArchiveTask? in
            let ackKey = MetadataStore.ackKey(category: ArchiveTask.ackCategory, groupKey: kind.rawValue)
            guard !ackedKeys.contains(ackKey) else { return nil }
            let action = Self.action(for: kind, entry: entry)
            guard action != .unavailable else { return nil }
            return ArchiveTask(
                kind: kind, severity: Self.severity(for: kind),
                affectedFileCount: entry.files, bytes: entry.bytes,
                evidencePaths: entry.paths, action: action
            )
        }
        .sorted {
            ($0.severity.rank, -$0.bytes, $0.kind.rawValue)
                < ($1.severity.rank, -$1.bytes, $1.kind.rawValue)
        }

        let uncovered = UncoveredFindings(
            count: uncoveredByCategory.values.reduce(0) { $0 + $1.files },
            bytes: uncoveredByCategory.values.reduce(0) { $0 + $1.bytes },
            categories: uncoveredByCategory.mapValues(\.files)
        )
        return ArchiveTaskSummary(tasks: tasks, uncovered: uncovered)
    }

    /// W3-13 (owner screenshot): resolves a raw finding row to the card it
    /// belongs to. Every category except "residue" still maps to exactly one
    /// kind via `findingCategories` (unchanged); "residue" itself now splits
    /// by filename between `.osMetadata` (Finder junk like `.DS_Store`) and
    /// `.intermediateFiles` (genuine stacking-tool byproducts), since both
    /// kinds declare the SAME `findingCategories` and the generic
    /// contains-based lookup could not tell them apart -- see
    /// `ArchiveTaskKind.osMetadata`'s own doc comment for why the split
    /// lives here rather than in `AstroCore`'s audit rule.
    private static func taskKind(forCategory category: String, path: String) -> ArchiveTaskKind? {
        guard category == "residue" else {
            return ArchiveTaskKind.allCases.first { $0.findingCategories.contains(category) }
        }
        return Self.isSystemMetadataFile(path) ? .osMetadata : .intermediateFiles
    }

    /// The one place a "residue" finding's filename decides whether it is
    /// Finder/OS junk or genuine stacking-tool output. Deliberately narrow
    /// (an exact, case-sensitive match on the real macOS filename) rather
    /// than a broader "looks like OS metadata" heuristic -- the owner's own
    /// screenshot named `.DS_Store` specifically, and a pattern loose enough
    /// to catch more risks silently reclassifying an actual stacking
    /// byproduct that happens to share a naming quirk.
    static func isSystemMetadataFile(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == ".DS_Store"
    }

    private static func severity(for kind: ArchiveTaskKind) -> ArchiveTaskSeverity {
        switch kind {
        case .misplacedCalibration, .brokenNames, .corruption: .error
        case .intermediateFiles, .osMetadata, .duplicateContent: .reclaim
        case .unverified: .attention
        case .auditNeverRun: .info
        }
    }

    private static func action(
        for kind: ArchiveTaskKind, entry: (files: Int, bytes: Int64, paths: [String])
    ) -> ArchiveTaskAction {
        switch kind {
        case .auditNeverRun:
            return .runAudit
        case .intermediateFiles, .osMetadata, .duplicateContent, .misplacedCalibration, .brokenNames, .corruption, .unverified:
            // Task 3 (wave 3): more than one finding routes to this kind's
            // own "view all" list instead of handing back one arbitrary
            // path -- see `ArchiveTaskAction.showFindings`'s own doc
            // comment. Exactly one finding keeps the direct, one-hop Finder
            // reveal: a detour through a one-row list would be worse, not
            // better. Honest gate either way: with no concrete path at all
            // there is nothing to open, so no card is produced at all (see
            // this type's own doc comment).
            if entry.files > 1 { return .showFindings(kind: kind) }
            return entry.paths.first.map { ArchiveTaskAction.revealInFinder(path: $0) } ?? .unavailable
        }
    }

    /// Every one of `kind`'s own findings from the latest audit and verify
    /// runs -- unlike `summary()`'s own `ArchiveTask.evidencePaths`, this is
    /// never capped at `evidenceLimit`. Backs `ArchiveTaskDetailView`, the
    /// route `ArchiveTaskAction.showFindings` pushes to. Findings with no
    /// usable path are dropped, same honesty gate `summary()` applies before
    /// ever handing a path to Finder.
    public func findings(for kind: ArchiveTaskKind) async throws -> [ArchiveFinding] {
        let categories = kind.findingCategories
        guard !categories.isEmpty else { return [] }

        let db = try SQLiteDB(readOnlyPath: indexDatabase.standardizedFileURL.path)
        guard try Self.hasAuditRun(db: db) else { return [] }

        let placeholders = categories.map { _ in "?" }.joined(separator: ", ")
        var results: [ArchiveFinding] = []
        try db.query(
            """
            SELECT d.id, d.path, COALESCE(f.size, 0)
            FROM findings d LEFT JOIN files f ON f.path = d.path
            WHERE d.category IN (\(placeholders))
              AND d.run_id IN (
                    (SELECT MAX(id) FROM runs WHERE kind = 'audit'),
                    (SELECT MAX(id) FROM runs WHERE kind = 'verify')
                  )
            ORDER BY d.id;
            """,
            bind: categories.map { SQLiteValue.text($0) }
        ) { row in
            let path = row.string(1) ?? ""
            guard !path.isEmpty else { return }
            results.append(ArchiveFinding(
                id: row.int64(0) ?? 0,
                path: path,
                bytes: row.int64(2) ?? 0
            ))
        }
        // W3-13 (owner screenshot): `.intermediateFiles` and `.osMetadata`
        // both query the same "residue" category (see
        // `ArchiveTaskKind.osMetadata`'s own doc comment), so the SQL above
        // cannot tell them apart on its own -- the same filename split
        // `taskKind(forCategory:path:)` applies in `summary()` is applied
        // again here, in Swift, so each kind's own "view all" list only ever
        // shows the findings that kind's own card actually counted.
        switch kind {
        case .intermediateFiles:
            results.removeAll { Self.isSystemMetadataFile($0.path) }
        case .osMetadata:
            results.removeAll { !Self.isSystemMetadataFile($0.path) }
        default:
            break
        }
        return results
    }

    private static func hasAuditRun(db: SQLiteDB) throws -> Bool {
        var found = false
        try db.query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'runs';"
        ) { _ in found = true }
        guard found else { return false }
        var hasRun = false
        try db.query("SELECT COUNT(*) FROM runs WHERE kind = 'audit';") { row in
            hasRun = (row.int64(0) ?? 0) > 0
        }
        return hasRun
    }
}
