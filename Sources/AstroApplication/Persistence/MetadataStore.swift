import AstroCore
import AstroMobileDomain
import Darwin
import Foundation

/// One Planning-saved target (wave 5 Task 4, schema v6) -- a bookmarked
/// catalog designation with an optional free-text note. Lives here rather
/// than alongside `AuditAcknowledgementRecord` in `Domain/LibraryObjects.swift`
/// since that file is owned by concurrent work on this branch; this type has
/// no dependents outside `MetadataStore`/`SavedTargetsStore` anyway, the same
/// way `MetadataWriteBatch` just below lives in this file rather than
/// `Domain`.
public struct SavedTargetRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let designation: String
    public let savedAt: Date
    public let note: String?

    public init(id: UUID, designation: String, savedAt: Date, note: String?) {
        self.id = id
        self.designation = designation
        self.savedAt = savedAt
        self.note = note
    }
}

public struct MetadataWriteBatch: Sendable {
    public var projects: [ProjectRecord]
    public var nights: [NightRecord]
    public var series: [SeriesRecord]
    public var frameDecisions: [FrameDecisionRecord]
    public var reviewStates: [ReviewStateRecord]
    public var mutationJournal: [MutationJournalRecord]
    /// W7-G: series rows a rescan's relink pass has determined are fully
    /// emptied orphans -- every frame decision and review state that used
    /// to point at them has already been relinked (elsewhere in this same
    /// batch) onto the series id that now actually contains their frames.
    /// Processed LAST, after every upsert above, so the relinking upserts
    /// have already moved any children off these ids by the time the
    /// deletes run -- `series.id`'s `ON DELETE RESTRICT` referents
    /// (`frame_decisions.series_id`, `review_states.series_id`) are the
    /// safety net if that precondition is ever violated: the delete fails
    /// and the whole batch (including the new series/relinks) rolls back
    /// together, rather than leaving a half-migrated store.
    public var deletedSeriesIDs: [UUID]

    public init(
        projects: [ProjectRecord] = [],
        nights: [NightRecord] = [],
        series: [SeriesRecord] = [],
        frameDecisions: [FrameDecisionRecord] = [],
        reviewStates: [ReviewStateRecord] = [],
        mutationJournal: [MutationJournalRecord] = [],
        deletedSeriesIDs: [UUID] = []
    ) {
        self.projects = projects
        self.nights = nights
        self.series = series
        self.frameDecisions = frameDecisions
        self.reviewStates = reviewStates
        self.mutationJournal = mutationJournal
        self.deletedSeriesIDs = deletedSeriesIDs
    }
}

public actor MetadataStore {
    public nonisolated let databaseURL: URL
    private let database: SQLiteDB

    public init(storagePaths: AppStoragePaths) throws {
        try self.init(
            storagePaths: storagePaths,
            beforeMetadataParentOpen: {},
            beforeDatabaseOpen: {}
        )
    }

    init(
        storagePaths: AppStoragePaths,
        beforeMetadataParentOpen: @Sendable () throws -> Void,
        beforeDatabaseOpen: @Sendable () throws -> Void
    ) throws {
        let opened = try Self.openConfinedDatabase(
            storagePaths: storagePaths,
            beforeMetadataParentOpen: beforeMetadataParentOpen,
            beforeDatabaseOpen: beforeDatabaseOpen
        )
        self.databaseURL = opened.url
        self.database = opened.database
    }

    init(databaseURL: URL) throws {
        let standardizedURL = databaseURL.standardizedFileURL
        try MetadataSchema.rejectUnsupportedSchema(at: standardizedURL)
        try FileManager.default.createDirectory(
            at: standardizedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let database = try SQLiteDB(path: standardizedURL.path)
        try database.exec("PRAGMA foreign_keys = ON;")
        try database.exec("PRAGMA busy_timeout = 5000;")
        try MetadataSchema.migrate(database)
        self.databaseURL = standardizedURL
        self.database = database
    }

    public static func temporary(fileManager: FileManager = .default) throws -> MetadataStore {
        let container = fileManager.temporaryDirectory.appendingPathComponent(
            "AstroTool-MetadataStore-\(UUID().uuidString)",
            isDirectory: true
        )
        return try MetadataStore(
            databaseURL: container.appendingPathComponent("metadata.sqlite")
        )
    }

    public func save(_ project: ProjectRecord) throws {
        try transaction { try upsert(project) }
    }

    /// Creation-only entrypoint. Existing annotations must use the explicit
    /// compare-and-set editor below.
    ///
    /// Public writer: an annotation carrying nonempty mobile evidence
    /// (`mobileChangeIDs` / `mobileChangeMarkers`) is rejected before
    /// anything is written. Only the internal mobile domain bridge
    /// (`applyMobileProjectAnnotationBatch`) may author new mobile evidence.
    public func createProjectAnnotation(_ annotation: ProjectAnnotationRecord) throws {
        guard annotation.mobileChangeIDs.isEmpty, annotation.mobileChangeMarkers.isEmpty else {
            throw MetadataStoreError.mobileEvidenceNotWritable(annotation.projectID)
        }
        try transaction {
            let existing = try projectAnnotation(projectID: annotation.projectID)
            guard existing == nil else {
                throw MetadataStoreError.staleProjectAnnotation(annotation.projectID)
            }
            try upsert(annotation)
        }
    }

    /// Normal project-note editors must compare the revision they loaded in
    /// the same SQLite transaction as their update.  This prevents a stale
    /// window from overwriting a newer mobile (or second-window) note while
    /// silently carrying only its old marker set forward.
    @discardableResult
    public func saveProjectAnnotation(
        _ annotation: ProjectAnnotationRecord,
        expectedRevision: Int
    ) throws -> ProjectAnnotationRecord {
        var saved: ProjectAnnotationRecord?
        try transaction {
            let existing = try projectAnnotation(projectID: annotation.projectID)
            if let existing {
                guard existing.revision == expectedRevision else {
                    throw MetadataStoreError.staleProjectAnnotation(annotation.projectID)
                }
                let next = ProjectAnnotationRecord(
                    projectID: annotation.projectID,
                    integrationGoalHours: annotation.integrationGoalHours,
                    notes: annotation.notes,
                    updatedAt: max(existing.updatedAt, annotation.updatedAt),
                    revision: existing.revision + 1,
                    mobileChangeIDs: existing.mobileChangeIDs,
                    mobileChangeMarkers: existing.mobileChangeMarkers
                )
                try upsert(next)
                saved = try projectAnnotation(projectID: annotation.projectID)
            } else {
                guard expectedRevision == 0 else {
                    throw MetadataStoreError.staleProjectAnnotation(annotation.projectID)
                }
                // Creation branch of a public writer: caller-supplied mobile
                // evidence is never trusted here either. Only the internal
                // mobile domain bridge may author new mobile evidence.
                guard annotation.mobileChangeIDs.isEmpty, annotation.mobileChangeMarkers.isEmpty else {
                    throw MetadataStoreError.mobileEvidenceNotWritable(annotation.projectID)
                }
                let initial = ProjectAnnotationRecord(
                    projectID: annotation.projectID,
                    integrationGoalHours: annotation.integrationGoalHours,
                    notes: annotation.notes,
                    updatedAt: annotation.updatedAt,
                    revision: 0,
                    mobileChangeIDs: [],
                    mobileChangeMarkers: []
                )
                try upsert(initial)
                saved = try projectAnnotation(projectID: annotation.projectID)
            }
        }
        guard let saved else { throw MetadataStoreError.staleProjectAnnotation(annotation.projectID) }
        return saved
    }

    /// Applies one closed, typed mobile annotation batch in the same SQLite
    /// transaction as its content and idempotency markers. A retry of any
    /// included change returns the exact stored revision without duplicating a
    /// field note.
    /// Internal production bridge only. Public callers apply authenticated
    /// returns through `MobileReturnApplicationCoordinator`; exposing this
    /// raw batch would bypass its live-capability and sent-base checks.
    func applyMobileProjectAnnotationBatch(_ batch: MobileProjectAnnotationChangeBatch) throws -> MobileChangeDomainBatchResult {
        var result: MobileChangeDomainBatchResult?
        try transaction {
            guard let existing = try projectAnnotation(projectID: batch.projectID) else {
                throw MobileChangeImportError.commandFailed(batch.mutations.first?.0.changeID ?? UUID())
            }
            let requestedIDs = batch.mutations.map { $0.0.changeID }
            guard Set(requestedIDs).count == requestedIDs.count else {
                throw MobileChangeImportError.commandFailed(requestedIDs.first ?? UUID())
            }
            let existingIDs = Set(existing.mobileChangeIDs)
            let ownerID = "project:\(existing.projectID.uuidString.lowercased())"
            let requestedMarkers = batch.mutations.map { command, mode in
                MobileChangeMarker(
                    changeID: command.changeID,
                    ownerID: ownerID,
                    payloadFingerprint: MobileChangeMarkerFingerprint.note(command, mode: mode),
                    resultingRevision: existing.revision + 1
                )
            }
            let existingMarkers = try Self.validatedMobileMarkers(
                existing.mobileChangeMarkers,
                ids: existing.mobileChangeIDs,
                ownerID: ownerID,
                maximumRevision: existing.revision
            )
            // A legacy bare ID or a payload/owner disagreement is corrupt
            // replay authority, not a reason to guess. Fail closed.
            guard existingIDs.isSubset(of: Set(existingMarkers.keys)),
                  requestedMarkers.allSatisfy({ marker in
                      existingMarkers[marker.changeID].map { $0.ownerID == marker.ownerID && $0.payloadFingerprint == marker.payloadFingerprint } ?? true
                  })
            else { throw MobileChangeImportError.commandFailed(requestedIDs.first ?? UUID()) }
            if Set(requestedIDs).isSubset(of: existingIDs) {
                result = MobileChangeDomainBatchResult(
                    appliedChangeIDs: requestedIDs,
                    resultingRevisions: Dictionary(uniqueKeysWithValues: requestedIDs.compactMap { id in
                        existingMarkers[id].map { (id.uuidString, $0.resultingRevision) }
                    })
                )
                return
            }
            guard existing.revision == batch.expectedRevision,
                  existing.mobileChangeIDs.count + requestedIDs.filter({ !existingIDs.contains($0) }).count <= 10_000 else {
                throw MobileChangeImportError.commandFailed(requestedIDs.first ?? UUID())
            }
            var notes = existing.notes
            var savedAt = existing.updatedAt
            for (command, mode) in batch.mutations where !existingIDs.contains(command.changeID) {
                switch mode {
                case .replace: notes = command.text
                case .appendFieldNote:
                    notes += "\n\n— Phone field note —\n" + command.createdAt.formatted(date: .abbreviated, time: .shortened) + "\n" + command.text
                }
                savedAt = max(savedAt, command.createdAt)
            }
            // Per-mutation text is already bounded by
            // `MobileChangeImporter.Limits.maxTextBytes`, but
            // `.appendFieldNote` accumulates onto `notes` across up to
            // 10,000 phone changes, so the resulting string needs its own
            // cap. This must run before the upsert below.
            guard notes.utf8.count <= MobileChangeImporter.Limits.maxAccumulatedNotesBytes else {
                throw MobileChangeImportError.limitsExceeded
            }
            let nextRevision = existing.revision + 1
            try upsert(ProjectAnnotationRecord(
                projectID: existing.projectID,
                integrationGoalHours: existing.integrationGoalHours,
                notes: notes,
                updatedAt: savedAt,
                revision: nextRevision,
                mobileChangeIDs: existing.mobileChangeIDs + requestedIDs,
                mobileChangeMarkers: existing.mobileChangeMarkers + requestedMarkers.filter { existingMarkers[$0.changeID] == nil }
            ))
            result = MobileChangeDomainBatchResult(
                appliedChangeIDs: requestedIDs,
                resultingRevisions: Dictionary(uniqueKeysWithValues: requestedIDs.map { ($0.uuidString, nextRevision) })
            )
        }
        guard let result else { throw MobileChangeImportError.receiptFailed }
        return result
    }

    public func save(_ night: NightRecord) throws {
        try transaction { try upsert(night) }
    }

    public func save(_ series: SeriesRecord) throws {
        try transaction { try upsert(series) }
    }

    public func save(_ frameDecision: FrameDecisionRecord) throws {
        try transaction { try upsert(frameDecision) }
    }

    public func save(_ reviewState: ReviewStateRecord) throws {
        try transaction { try upsert(reviewState) }
    }

    public func save(_ mutation: MutationJournalRecord) throws {
        try transaction { try upsert(mutation) }
    }

    public func save(_ batch: MetadataWriteBatch) throws {
        try transaction {
            for record in batch.projects { try upsert(record) }
            for record in batch.nights { try upsert(record) }
            for record in batch.series { try upsert(record) }
            for record in batch.frameDecisions { try upsert(record) }
            for record in batch.reviewStates { try upsert(record) }
            for record in batch.mutationJournal { try upsert(record) }
            for id in batch.deletedSeriesIDs { try deleteOrphanSeries(id) }
        }
    }

    /// Deletes one series row that W7-G's relink pass has determined is a
    /// fully emptied orphan (see `MetadataWriteBatch.deletedSeriesIDs`).
    /// Deletes the child table first, the parent second -- the same
    /// RESTRICT-then-drop ordering `MetadataSchema.versionEightSQL`'s doc
    /// comment explains for its own two dropped tables -- so a still-
    /// attached row (the relink determination was wrong) fails this delete
    /// loudly via `ON DELETE RESTRICT` instead of silently leaving a
    /// dangling reference.
    private func deleteOrphanSeries(_ id: UUID) throws {
        try database.run("DELETE FROM review_states WHERE series_id = ?;", bind: [.text(id.databaseText)])
        try database.run("DELETE FROM series WHERE id = ?;", bind: [.text(id.databaseText)])
    }

    /// Inserts a lossless V1 staging batch atomically. Existing source keys
    /// are left untouched, making a repeated import a true no-op.
    public func importLegacyRecords(_ records: [LegacyImportRecord]) throws -> Int {
        var inserted = 0
        try transaction {
            for record in records {
                try database.run(
                    """
                    INSERT INTO legacy_imports(id, source_key, kind, payload_json)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(source_key) DO NOTHING;
                    """,
                    bind: [
                        .text(record.id.databaseText),
                        .text(record.sourceKey),
                        .text(record.kind.rawValue),
                        .text(record.payloadJSON),
                    ]
                )
                var changes = 0
                try database.query("SELECT changes();") { row in
                    changes = Int(row.int64(0) ?? 0)
                }
                inserted += changes
            }
        }
        return inserted
    }

    public func legacyImportCount() throws -> Int {
        var count = 0
        try database.query("SELECT COUNT(*) FROM legacy_imports;") { row in
            count = Int(row.int64(0) ?? 0)
        }
        return count
    }

    public func legacyImports(kind: LegacyImportKind? = nil) throws -> [LegacyImportRecord] {
        var records: [LegacyImportRecord] = []
        let sql: String
        let bind: [SQLiteValue]
        if let kind {
            sql = "SELECT id, source_key, kind, payload_json FROM legacy_imports WHERE kind = ? ORDER BY source_key;"
            bind = [.text(kind.rawValue)]
        } else {
            sql = "SELECT id, source_key, kind, payload_json FROM legacy_imports ORDER BY source_key;"
            bind = []
        }
        try database.query(sql, bind: bind) { row in
            let idText = row.string(0) ?? ""
            let kindText = row.string(2) ?? ""
            guard let id = UUID(uuidString: idText),
                  let sourceKey = row.string(1),
                  let recordKind = LegacyImportKind(rawValue: kindText),
                  let payload = row.string(3)
            else { throw MetadataStoreError.invalidRecord(table: "legacy_imports", id: idText) }
            records.append(LegacyImportRecord(
                id: id,
                sourceKey: sourceKey,
                kind: recordKind,
                payloadJSON: payload
            ))
        }
        return records
    }

    public func project(id: UUID) throws -> ProjectRecord? {
        var record: ProjectRecord?
        try database.query(
            "SELECT id, catalog_id, display_name, phase FROM projects WHERE id = ?;",
            bind: [.text(id.databaseText)]
        ) { row in record = try Self.project(from: row) }
        return record
    }

    public func projects() throws -> [ProjectRecord] {
        var records: [ProjectRecord] = []
        try database.query(
            "SELECT id, catalog_id, display_name, phase FROM projects ORDER BY display_name, id;"
        ) { row in records.append(try Self.project(from: row)) }
        return records
    }

    public func projectAnnotation(projectID: UUID) throws -> ProjectAnnotationRecord? {
        var record: ProjectAnnotationRecord?
        try database.query(
            "SELECT project_id, integration_goal_hours, notes, updated_at, revision, mobile_change_ids, mobile_change_markers FROM project_annotations WHERE project_id = ?;",
            bind: [.text(projectID.databaseText)]
        ) { row in
            guard let id = row.string(0).flatMap(UUID.init(uuidString:)),
                  let notes = row.string(2),
                  let updatedAt = row.double(3)
            else { throw MetadataStoreError.invalidRecord(table: "project_annotations", id: projectID.databaseText) }
            record = ProjectAnnotationRecord(
                projectID: id,
                integrationGoalHours: row.double(1),
                notes: notes,
                updatedAt: Date(timeIntervalSince1970: updatedAt),
                revision: Int(row.int64(4) ?? 0),
                mobileChangeIDs: try Self.decodeMobileChangeIDs(row.string(5), projectID: projectID),
                mobileChangeMarkers: try Self.decodeMobileChangeMarkers(row.string(6), projectID: projectID)
            )
        }
        return record
    }

    /// Internal bridge support for global change-ID authority validation.
    /// Decoding failures propagate as corruption; they are never converted to
    /// an empty marker list.
    func allProjectAnnotationMarkers() throws -> [MobileChangeMarker] {
        var markers: [MobileChangeMarker] = []
        try database.query("SELECT project_id, revision, mobile_change_ids, mobile_change_markers FROM project_annotations;") { row in
            guard let rawID = row.string(0), let projectID = UUID(uuidString: rawID) else {
                throw MetadataStoreError.invalidRecord(table: "project_annotations", id: row.string(0) ?? "unknown")
            }
            let revision = Int(row.int64(1) ?? -1)
            let ids = try Self.decodeMobileChangeIDs(row.string(2), projectID: projectID)
            let decoded = try Self.decodeMobileChangeMarkers(row.string(3), projectID: projectID)
            let validated = try Self.validatedMobileMarkers(
                decoded,
                ids: ids,
                ownerID: "project:\(projectID.uuidString.lowercased())",
                maximumRevision: revision
            )
            markers.append(contentsOf: validated.values)
        }
        return markers
    }

    public func night(id: UUID) throws -> NightRecord? {
        var record: NightRecord?
        try database.query(
            "SELECT id, local_date, time_zone_id FROM nights WHERE id = ?;",
            bind: [.text(id.databaseText)]
        ) { row in record = try Self.night(from: row) }
        return record
    }

    public func nights() throws -> [NightRecord] {
        var records: [NightRecord] = []
        try database.query(
            "SELECT id, local_date, time_zone_id FROM nights ORDER BY local_date DESC, id;"
        ) { row in records.append(try Self.night(from: row)) }
        return records
    }

    public func series(nightID: UUID) throws -> [SeriesRecord] {
        var records: [SeriesRecord] = []
        try database.query(
            """
            SELECT id, project_id, night_id, setup_id, setup_descriptor, sensor_mode,
                   passband, exposure_seconds, filter_name, filter_id, gain, offset, binning
            FROM series WHERE night_id = ? ORDER BY exposure_seconds, id;
            """,
            bind: [.text(nightID.databaseText)]
        ) { row in records.append(try Self.series(from: row)) }
        return records
    }

    public func series(id: UUID) throws -> SeriesRecord? {
        var record: SeriesRecord?
        try database.query(
            """
            SELECT id, project_id, night_id, setup_id, setup_descriptor, sensor_mode,
                   passband, exposure_seconds, filter_name, filter_id, gain, offset, binning
            FROM series WHERE id = ?;
            """,
            bind: [.text(id.databaseText)]
        ) { row in record = try Self.series(from: row) }
        return record
    }

    public func series(projectID: UUID) throws -> [SeriesRecord] {
        var records: [SeriesRecord] = []
        try database.query(
            """
            SELECT id, project_id, night_id, setup_id, setup_descriptor, sensor_mode,
                   passband, exposure_seconds, filter_name, filter_id, gain, offset, binning
            FROM series WHERE project_id = ? ORDER BY id;
            """,
            bind: [.text(projectID.databaseText)]
        ) { row in records.append(try Self.series(from: row)) }
        return records
    }

    /// Every series row currently on record, across every project/night --
    /// W7-G's rescan relink pass (`ScanWorkflowMaterializer.materialize`)
    /// needs the FULL prior universe of series ids (not scoped to one
    /// project or night) to tell which ones this run's fresh grouping no
    /// longer produces, i.e. which ones a descriptor/passband derivation
    /// change just orphaned.
    public func allSeries() throws -> [SeriesRecord] {
        var records: [SeriesRecord] = []
        try database.query(
            """
            SELECT id, project_id, night_id, setup_id, setup_descriptor, sensor_mode,
                   passband, exposure_seconds, filter_name, filter_id, gain, offset, binning
            FROM series ORDER BY id;
            """
        ) { row in records.append(try Self.series(from: row)) }
        return records
    }

    /// Every frame decision on record, across every series -- W7-G's relink
    /// pass needs this keyed by `relativePath` (globally `UNIQUE`, see the
    /// `frame_decisions` schema) rather than scoped to one series id, since
    /// the whole point is finding a decision that is currently attached to a
    /// series id THIS run's fresh grouping no longer produces.
    public func allFrameDecisions() throws -> [FrameDecisionRecord] {
        var records: [FrameDecisionRecord] = []
        try database.query(
            "SELECT id, series_id, relative_path, verdict, logically_excluded FROM frame_decisions ORDER BY relative_path;"
        ) { row in records.append(try Self.frameDecision(from: row)) }
        return records
    }

    /// Every review state on record, across every series -- same rationale
    /// as `allFrameDecisions()`: W7-G's relink pass needs the full prior set
    /// to find rows still attached to a series id that just got orphaned.
    public func allReviewStates() throws -> [ReviewStateRecord] {
        var records: [ReviewStateRecord] = []
        try database.query(
            "SELECT id, series_id, status, updated_at FROM review_states ORDER BY series_id;"
        ) { row in records.append(try Self.reviewState(from: row)) }
        return records
    }

    public func frameDecision(id: UUID) throws -> FrameDecisionRecord? {
        var record: FrameDecisionRecord?
        try database.query(
            "SELECT id, series_id, relative_path, verdict, logically_excluded FROM frame_decisions WHERE id = ?;",
            bind: [.text(id.databaseText)]
        ) { row in record = try Self.frameDecision(from: row) }
        return record
    }

    public func frameDecisions(seriesID: UUID) throws -> [FrameDecisionRecord] {
        var records: [FrameDecisionRecord] = []
        try database.query(
            """
            SELECT id, series_id, relative_path, verdict, logically_excluded
            FROM frame_decisions WHERE series_id = ? ORDER BY relative_path, id;
            """,
            bind: [.text(seriesID.databaseText)]
        ) { row in records.append(try Self.frameDecision(from: row)) }
        return records
    }

    public func reviewState(id: UUID) throws -> ReviewStateRecord? {
        var record: ReviewStateRecord?
        try database.query(
            "SELECT id, series_id, status, updated_at FROM review_states WHERE id = ?;",
            bind: [.text(id.databaseText)]
        ) { row in record = try Self.reviewState(from: row) }
        return record
    }

    public func mutationJournal(id: UUID) throws -> MutationJournalRecord? {
        var record: MutationJournalRecord?
        try database.query(
            "SELECT id, operation_id, status, created_at, payload_json FROM mutation_journal WHERE id = ?;",
            bind: [.text(id.databaseText)]
        ) { row in record = try Self.mutationJournal(from: row) }
        return record
    }

    public func projectCount() throws -> Int {
        var count = 0
        try database.query("SELECT COUNT(*) FROM projects;") { row in
            count = Int(row.int64(0) ?? 0)
        }
        return count
    }

    public func schemaVersion() throws -> Int {
        try MetadataSchema.readVersion(in: database)
    }

    public func foreignKeysEnabled() throws -> Bool {
        var enabled = false
        try database.query("PRAGMA foreign_keys;") { row in
            enabled = row.int64(0) == 1
        }
        return enabled
    }

    // MARK: - Audit acknowledgements + run history (schema v5)

    /// The stable key one ack row is addressed by: `(category, groupKey)`,
    /// the exact `"\(category)|\(groupKey)"` format V1's
    /// `Database.ackKey(category:groupKey:)` used -- so a legacy ack
    /// imported by `V1MetadataImporter` and a native V2 ack land in the same
    /// keyspace and never accidentally collide or double up.
    public static func ackKey(category: String, groupKey: String) -> String {
        "\(category)|\(groupKey)"
    }

    /// Marks one finding group as acknowledged -- upserts on `ack_key` so
    /// re-acking (e.g. to change `note`) never duplicates the row. `at`
    /// defaults to now for a user-triggered ack; `V1MetadataImporter` passes
    /// the legacy `acked_at` explicitly so a re-import stays idempotent.
    public func acknowledgeFindingGroup(
        category: String,
        groupKey: String,
        note: String? = nil,
        at ackedAt: Date = .now
    ) throws {
        let key = Self.ackKey(category: category, groupKey: groupKey)
        try transaction {
            try database.run(
                """
                INSERT INTO audit_acknowledgements(id, ack_key, category, group_key, acked_at, note)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(ack_key) DO UPDATE SET acked_at = excluded.acked_at, note = excluded.note;
                """,
                bind: [
                    .text(UUID().databaseText),
                    .text(key),
                    .text(category),
                    .text(groupKey),
                    .text(ackedAt.ISO8601Format()),
                    note.map(SQLiteValue.text) ?? .null,
                ]
            )
        }
    }

    /// Reverses `acknowledgeFindingGroup` -- a no-op if the group was never acked.
    public func revokeAcknowledgement(ackKey: String) throws {
        try transaction {
            try database.run("DELETE FROM audit_acknowledgements WHERE ack_key = ?;", bind: [.text(ackKey)])
        }
    }

    /// Every currently-acknowledged finding group, newest ack first.
    public func acknowledgements() throws -> [AuditAcknowledgementRecord] {
        var records: [AuditAcknowledgementRecord] = []
        try database.query(
            "SELECT ack_key, category, group_key, acked_at, note FROM audit_acknowledgements ORDER BY acked_at DESC;"
        ) { row in
            guard let ackKey = row.string(0), let category = row.string(1), let groupKey = row.string(2),
                  let ackedAtText = row.string(3), let ackedAt = try? Date(ackedAtText, strategy: .iso8601)
            else { return }
            records.append(AuditAcknowledgementRecord(
                ackKey: ackKey, category: category, groupKey: groupKey, ackedAt: ackedAt, note: row.string(4)
            ))
        }
        return records
    }

    /// Records one completed audit run's headline facts so a later run can
    /// be diffed against it (`auditRunDiff()`).
    @discardableResult
    public func recordAuditRun(
        findingCount: Int,
        groupKeys: [String],
        at ranAt: Date = .now
    ) throws -> AuditRunRecord {
        let id = UUID()
        let data = try JSONEncoder().encode(groupKeys)
        guard let groupKeysJSON = String(data: data, encoding: .utf8) else {
            throw MetadataStoreError.invalidField(record: "audit_run_history", field: "group_keys")
        }
        try transaction {
            try database.run(
                "INSERT INTO audit_run_history(id, ran_at, finding_count, group_keys) VALUES (?, ?, ?, ?);",
                bind: [
                    .text(id.databaseText),
                    .text(ranAt.ISO8601Format()),
                    .int(Int64(findingCount)),
                    .text(groupKeysJSON),
                ]
            )
        }
        return AuditRunRecord(id: id, ranAt: ranAt, findingCount: findingCount, groupKeys: groupKeys)
    }

    /// The most recent audit runs, newest first.
    public func auditRunHistory(limit: Int = 20) throws -> [AuditRunRecord] {
        var records: [AuditRunRecord] = []
        try database.query(
            "SELECT id, ran_at, finding_count, group_keys FROM audit_run_history ORDER BY ran_at DESC LIMIT ?;",
            bind: [.int(Int64(limit))]
        ) { row in
            guard let idText = row.string(0), let id = UUID(uuidString: idText),
                  let ranAtText = row.string(1), let ranAt = try? Date(ranAtText, strategy: .iso8601),
                  let findingCount = row.int64(2), let groupKeysJSON = row.string(3),
                  let groupKeys = try? JSONDecoder().decode([String].self, from: Data(groupKeysJSON.utf8))
            else { return }
            records.append(AuditRunRecord(
                id: id, ranAt: ranAt, findingCount: Int(findingCount), groupKeys: groupKeys
            ))
        }
        return records
    }

    /// Compares the two most recent audit runs (V1 `AuditDiff` semantics):
    /// new = present in the latest run but not the previous one, resolved =
    /// the other way around. `nil` when fewer than two runs are on record.
    public func auditRunDiff() throws -> AuditRunDiff? {
        let recent = try auditRunHistory(limit: 2)
        guard recent.count == 2 else { return nil }
        let latest = recent[0]
        let previous = recent[1]
        let previousKeys = Set(previous.groupKeys)
        let latestKeys = Set(latest.groupKeys)
        return AuditRunDiff(
            newGroupKeys: latest.groupKeys.filter { !previousKeys.contains($0) },
            resolvedGroupKeys: previous.groupKeys.filter { !latestKeys.contains($0) }
        )
    }

    // MARK: - Planning saved targets (schema v6)

    /// Bookmarks `designation`, or updates its note if it's already saved --
    /// upserts on `designation` (`UNIQUE`) so re-saving the same target never
    /// duplicates the row, mirroring `acknowledgeFindingGroup`'s own
    /// upsert-on-key contract. `savedAt`/`id` are left untouched on an
    /// existing row: only the note field can change here, since re-saving an
    /// already-saved target shouldn't bump it back to the top of a
    /// newest-first list.
    @discardableResult
    public func saveTarget(
        designation: String,
        note: String? = nil,
        at savedAt: Date = .now
    ) throws -> SavedTargetRecord {
        try transaction {
            try database.run(
                """
                INSERT INTO planning_saved_targets(id, designation, saved_at, note)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(designation) DO UPDATE SET note = excluded.note;
                """,
                bind: [
                    .text(UUID().databaseText),
                    .text(designation),
                    .text(savedAt.ISO8601Format()),
                    note.map(SQLiteValue.text) ?? .null,
                ]
            )
        }
        guard let record = try savedTarget(designation: designation) else {
            throw MetadataStoreError.invalidRecord(table: "planning_saved_targets", id: designation)
        }
        return record
    }

    /// Updates just the note on an already-saved target -- a no-op if
    /// `designation` was never saved (mirrors `revokeAcknowledgement`'s own
    /// no-op contract for a missing key), since there is no saved row here
    /// for a bare note to attach to.
    public func updateNote(designation: String, note: String?) throws {
        try transaction {
            try database.run(
                "UPDATE planning_saved_targets SET note = ? WHERE designation = ?;",
                bind: [note.map(SQLiteValue.text) ?? .null, .text(designation)]
            )
        }
    }

    /// Reverses `saveTarget` -- a no-op if the designation was never saved.
    public func removeSavedTarget(designation: String) throws {
        try transaction {
            try database.run(
                "DELETE FROM planning_saved_targets WHERE designation = ?;",
                bind: [.text(designation)]
            )
        }
    }

    /// One saved target's record, or `nil` if it isn't saved.
    public func savedTarget(designation: String) throws -> SavedTargetRecord? {
        var record: SavedTargetRecord?
        try database.query(
            "SELECT id, designation, saved_at, note FROM planning_saved_targets WHERE designation = ? LIMIT 1;",
            bind: [.text(designation)]
        ) { row in
            record = Self.savedTargetRecord(from: row)
        }
        return record
    }

    /// Every saved target, newest-saved first.
    public func savedTargets() throws -> [SavedTargetRecord] {
        var records: [SavedTargetRecord] = []
        try database.query(
            "SELECT id, designation, saved_at, note FROM planning_saved_targets ORDER BY saved_at DESC;"
        ) { row in
            if let record = Self.savedTargetRecord(from: row) {
                records.append(record)
            }
        }
        return records
    }

    private static func savedTargetRecord(from row: SQLiteRow) -> SavedTargetRecord? {
        guard let idText = row.string(0), let id = UUID(uuidString: idText),
              let designation = row.string(1),
              let savedAtText = row.string(2), let savedAt = try? Date(savedAtText, strategy: .iso8601)
        else { return nil }
        return SavedTargetRecord(id: id, designation: designation, savedAt: savedAt, note: row.string(3))
    }

    // MARK: - Scan completion (schema v7)

    /// Records that V2's own scan pipeline just finished successfully --
    /// call this only from a caller that has actually observed success
    /// (`ScanWorkflowMaterializer.materialize` returning without throwing),
    /// never speculatively. Upserts the single `singleton = 1` row, so
    /// calling this twice keeps only the newer `completedAt`; there is no
    /// history here, only "when did we last look".
    public func recordScanCompleted(at completedAt: Date = .now) throws {
        try transaction {
            try database.run(
                """
                INSERT INTO scan_completions(singleton, completed_at) VALUES (1, ?)
                ON CONFLICT(singleton) DO UPDATE SET completed_at = excluded.completed_at;
                """,
                bind: [.text(completedAt.ISO8601Format())]
            )
        }
    }

    /// When V2 last recorded a successful scan completion, or `nil` if it
    /// never has -- a fresh store, or one that has only ever seen failed or
    /// cancelled scans.
    public func lastScanCompletedAt() throws -> Date? {
        var result: Date?
        try database.query(
            "SELECT completed_at FROM scan_completions WHERE singleton = 1;"
        ) { row in
            guard let text = row.string(0) else { return }
            result = try? Date(text, strategy: .iso8601)
        }
        return result
    }

    private func transaction(_ body: () throws -> Void) throws {
        try database.exec("BEGIN IMMEDIATE;")
        do {
            try body()
            try database.exec("COMMIT;")
        } catch {
            try? database.exec("ROLLBACK;")
            throw error
        }
    }

    private struct FileState: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let owner: UInt32
        let linkCount: UInt64

        var fileType: UInt32 { mode & UInt32(S_IFMT) }
        var isGroupOrWorldWritable: Bool {
            mode & UInt32(S_IWGRP | S_IWOTH) != 0
        }

        init(_ status: stat) {
            self.device = UInt64(status.st_dev)
            self.inode = UInt64(status.st_ino)
            self.mode = UInt32(status.st_mode)
            self.owner = UInt32(status.st_uid)
            self.linkCount = UInt64(status.st_nlink)
        }
    }

    private static func openConfinedDatabase(
        storagePaths: AppStoragePaths,
        beforeMetadataParentOpen: @Sendable () throws -> Void,
        beforeDatabaseOpen: @Sendable () throws -> Void
    ) throws -> (url: URL, database: SQLiteDB) {
        let databaseURL = storagePaths.metadataDatabase.standardizedFileURL
        let libraryRoot = storagePaths.libraryRoot
        try validateMetadataDestination(databaseURL, relativeTo: libraryRoot)
        let canonicalParent = try canonicalIntendedPath(
            databaseURL.deletingLastPathComponent()
        )
        guard !isContained(canonicalParent, in: canonicalPath(libraryRoot)) else {
            throw MetadataStoreError.metadataDestinationInsideLibrary
        }
        try beforeMetadataParentOpen()

        let parentDescriptor = try openMetadataParent(canonicalParent)
        defer { Darwin.close(parentDescriptor) }
        try validateMetadataDestination(databaseURL, relativeTo: libraryRoot)
        _ = try safeParentState(descriptor: parentDescriptor)
        let databaseDescriptor = try openMetadataDatabase(
            named: databaseURL.lastPathComponent,
            relativeTo: parentDescriptor
        )
        defer { Darwin.close(databaseDescriptor) }
        let parentState = try safeParentState(descriptor: parentDescriptor)
        let databaseState = try safeDatabaseState(descriptor: databaseDescriptor)
        let canonicalDatabase = canonicalParent.appendingPathComponent(databaseURL.lastPathComponent)

        try validatePinnedDestination(
            databaseURL,
            relativeTo: libraryRoot,
            parentDescriptor: parentDescriptor,
            expectedParent: parentState,
            databaseDescriptor: databaseDescriptor,
            expectedDatabase: databaseState
        )
        try MetadataSchema.rejectUnsupportedSchema(at: canonicalDatabase)

        let database = try SQLiteDB(
            confinedIndexPath: canonicalDatabase.path,
            beforeOpen: beforeDatabaseOpen,
            validateBeforeUse: {
                try validatePinnedDestination(
                    databaseURL,
                    relativeTo: libraryRoot,
                    parentDescriptor: parentDescriptor,
                    expectedParent: parentState,
                    databaseDescriptor: databaseDescriptor,
                    expectedDatabase: databaseState
                )
            }
        )
        try database.exec("PRAGMA foreign_keys = ON;")
        try database.exec("PRAGMA busy_timeout = 5000;")
        try MetadataSchema.migrate(database)
        return (canonicalDatabase, database)
    }

    private static func validateMetadataDestination(
        _ databaseURL: URL,
        relativeTo libraryRoot: URL
    ) throws {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: databaseURL.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw MetadataStoreError.invalidMetadataDestination
            }
        }
        guard !isContained(canonicalPath(databaseURL), in: canonicalPath(libraryRoot)) else {
            throw MetadataStoreError.metadataDestinationInsideLibrary
        }
        let parent = databaseURL.deletingLastPathComponent()
        if let attributes = try? FileManager.default.attributesOfItem(atPath: parent.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw MetadataStoreError.invalidMetadataDestination
            }
        }
    }

    private static func openMetadataParent(_ parent: URL) throws -> Int32 {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw MetadataStoreError.unsafeMetadataParent }
        do {
            for component in parent.standardizedFileURL.pathComponents.dropFirst() {
                let nextDescriptor = try component.withCString { name -> Int32 in
                    var opened = Darwin.openat(
                        descriptor,
                        name,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                    if opened < 0, errno == ENOENT {
                        let created = Darwin.mkdirat(descriptor, name, mode_t(S_IRWXU))
                        guard created == 0 || errno == EEXIST else {
                            throw MetadataStoreError.cannotCreateMetadataParent
                        }
                        opened = Darwin.openat(
                            descriptor,
                            name,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                    }
                    guard opened >= 0 else {
                        throw MetadataStoreError.unsafeMetadataParent
                    }
                    return opened
                }
                Darwin.close(descriptor)
                descriptor = nextDescriptor
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openMetadataDatabase(named name: String, relativeTo parent: Int32) throws -> Int32 {
        let descriptor = name.withCString { path in
            Darwin.openat(
                parent,
                path,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw MetadataStoreError.unsafeMetadataDatabase
        }
        return descriptor
    }

    private static func safeParentState(descriptor: Int32) throws -> FileState {
        let state = try fileState(descriptor: descriptor)
        guard
            state.fileType == UInt32(S_IFDIR),
            state.owner == UInt32(Darwin.geteuid()),
            !state.isGroupOrWorldWritable
        else {
            throw MetadataStoreError.unsafeMetadataParent
        }
        return state
    }

    private static func safeDatabaseState(descriptor: Int32) throws -> FileState {
        let state = try fileState(descriptor: descriptor)
        guard
            state.fileType == UInt32(S_IFREG),
            state.owner == UInt32(Darwin.geteuid()),
            state.linkCount == 1,
            !state.isGroupOrWorldWritable
        else {
            throw MetadataStoreError.unsafeMetadataDatabase
        }
        return state
    }

    private static func validatePinnedDestination(
        _ databaseURL: URL,
        relativeTo libraryRoot: URL,
        parentDescriptor: Int32,
        expectedParent: FileState,
        databaseDescriptor: Int32,
        expectedDatabase: FileState
    ) throws {
        try validateMetadataDestination(databaseURL, relativeTo: libraryRoot)
        guard try fileState(descriptor: parentDescriptor) == expectedParent else {
            throw MetadataStoreError.unsafeMetadataParent
        }
        guard try fileState(at: databaseURL.deletingLastPathComponent()) == expectedParent else {
            throw MetadataStoreError.metadataDestinationChanged
        }
        guard try fileState(descriptor: databaseDescriptor) == expectedDatabase else {
            throw MetadataStoreError.unsafeMetadataDatabase
        }
        guard try fileState(at: databaseURL) == expectedDatabase else {
            throw MetadataStoreError.metadataDestinationChanged
        }
    }

    private static func canonicalIntendedPath(_ url: URL) throws -> URL {
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while true {
            if let resolved = Darwin.realpath(existingAncestor.path, nil) {
                defer { Darwin.free(resolved) }
                return missingComponents.reversed().reduce(
                    URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                ) { partial, component in
                    partial.appendingPathComponent(component, isDirectory: true)
                }
            }
            guard existingAncestor.path != "/" else {
                throw MetadataStoreError.unsafeMetadataParent
            }
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor.deleteLastPathComponent()
        }
    }

    private static func fileState(descriptor: Int32) throws -> FileState {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw MetadataStoreError.metadataDestinationChanged
        }
        return FileState(status)
    }

    private static func fileState(at url: URL) throws -> FileState {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        guard result == 0 else {
            throw MetadataStoreError.metadataDestinationChanged
        }
        return FileState(status)
    }

    private static func canonicalPath(_ url: URL) -> URL {
        url.standardizedFileURL.pathComponents.dropFirst().reduce(
            URL(fileURLWithPath: "/", isDirectory: true)
        ) { resolvedPrefix, component in
            resolvedPrefix.appendingPathComponent(component).resolvingSymlinksInPath()
        }
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        if candidate.path == root.path { return true }
        let prefix = root.path == "/" ? root.path : root.path + "/"
        return candidate.path.hasPrefix(prefix)
    }

    private func upsert(_ record: ProjectRecord) throws {
        try database.run(
            """
            INSERT INTO projects(id, catalog_id, display_name, phase)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              catalog_id = excluded.catalog_id,
              display_name = excluded.display_name,
              phase = excluded.phase;
            """,
            bind: [
                .text(record.id.databaseText),
                .text(record.catalogID),
                .text(record.displayName),
                .text(record.phase.rawValue),
            ]
        )
    }

    private func upsert(_ record: ProjectAnnotationRecord) throws {
        if let goal = record.integrationGoalHours {
            try Self.validateFinite(goal, record: "project_annotations", field: "integration_goal_hours")
            guard goal > 0 else {
                throw MetadataStoreError.invalidField(record: "project_annotations", field: "integration_goal_hours")
            }
        }
        try Self.validateFinite(record.updatedAt.timeIntervalSince1970, record: "project_annotations", field: "updated_at")
        try database.run(
            """
            INSERT INTO project_annotations(project_id, integration_goal_hours, notes, updated_at, revision, mobile_change_ids, mobile_change_markers)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(project_id) DO UPDATE SET
              integration_goal_hours = excluded.integration_goal_hours,
              notes = excluded.notes,
              updated_at = excluded.updated_at,
              revision = excluded.revision,
              mobile_change_ids = excluded.mobile_change_ids,
              mobile_change_markers = excluded.mobile_change_markers;
            """,
            bind: [
                .text(record.projectID.databaseText),
                record.integrationGoalHours.map(SQLiteValue.real) ?? .null,
                .text(record.notes),
                .real(record.updatedAt.timeIntervalSince1970),
                .int(Int64(record.revision)),
                .text(String(decoding: try MobileJSON.encoder.encode(record.mobileChangeIDs), as: UTF8.self)),
                .text(String(decoding: try MobileJSON.encoder.encode(record.mobileChangeMarkers), as: UTF8.self)),
            ]
        )
    }

    private static func decodeMobileChangeIDs(_ value: String?, projectID: UUID) throws -> [UUID] {
        guard let value else { throw MetadataStoreError.invalidRecord(table: "project_annotations", id: projectID.databaseText) }
        do { return try MobileJSON.decoder.decode([UUID].self, from: Data(value.utf8)) }
        catch { throw MetadataStoreError.invalidRecord(table: "project_annotations", id: projectID.databaseText) }
    }

    private static func decodeMobileChangeMarkers(_ value: String?, projectID: UUID) throws -> [MobileChangeMarker] {
        guard let value else { throw MetadataStoreError.invalidRecord(table: "project_annotations", id: projectID.databaseText) }
        do { return try MobileJSON.decoder.decode([MobileChangeMarker].self, from: Data(value.utf8)) }
        catch { throw MetadataStoreError.invalidRecord(table: "project_annotations", id: projectID.databaseText) }
    }

    private static func validatedMobileMarkers(
        _ markers: [MobileChangeMarker],
        ids: [UUID],
        ownerID: String,
        maximumRevision: Int
    ) throws -> [UUID: MobileChangeMarker] {
        let markerIDs = markers.map(\.changeID)
        guard Set(ids).count == ids.count,
              Set(markerIDs).count == markerIDs.count,
              Set(ids) == Set(markerIDs),
              markers.allSatisfy({
                  $0.ownerID == ownerID
                      && $0.payloadFingerprint.count == 64
                      && $0.payloadFingerprint.allSatisfy(\.isHexDigit)
                      && $0.resultingRevision >= 0
                      && $0.resultingRevision <= maximumRevision
              }) else {
            throw MobileChangeImportError.corruptDomainMarkers
        }
        return Dictionary(markers.map { ($0.changeID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func upsert(_ record: NightRecord) throws {
        try Self.validate(record)
        try database.run(
            """
            INSERT INTO nights(id, local_date, time_zone_id)
            VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              local_date = excluded.local_date,
              time_zone_id = excluded.time_zone_id;
            """,
            bind: [
                .text(record.id.databaseText),
                .text(record.localDate),
                .text(record.timeZoneID),
            ]
        )
    }

    private func upsert(_ record: SeriesRecord) throws {
        try Self.validate(record)
        try database.run(
            """
            INSERT INTO series(
              id, project_id, night_id, setup_id, setup_descriptor, sensor_mode,
              passband, exposure_seconds, filter_name, filter_id, gain, offset, binning
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              project_id = excluded.project_id,
              night_id = excluded.night_id,
              setup_id = excluded.setup_id,
              setup_descriptor = excluded.setup_descriptor,
              sensor_mode = excluded.sensor_mode,
              passband = excluded.passband,
              exposure_seconds = excluded.exposure_seconds,
              filter_name = excluded.filter_name,
              filter_id = excluded.filter_id,
              gain = excluded.gain,
              offset = excluded.offset,
              binning = excluded.binning;
            """,
            bind: [
                .text(record.id.databaseText),
                .text(record.projectID.databaseText),
                .text(record.nightID.databaseText),
                record.setupID.map(SQLiteValue.text) ?? .null,
                .text(record.setupDescriptor),
                .text(record.sensorMode.rawValue),
                .text(record.passband.rawValue),
                .real(record.exposureSeconds),
                record.filterName.map(SQLiteValue.text) ?? .null,
                record.filterID.map(SQLiteValue.text) ?? .null,
                record.gain.map(SQLiteValue.real) ?? .null,
                record.offset.map(SQLiteValue.real) ?? .null,
                .text(record.binning),
            ]
        )
    }

    private func upsert(_ record: FrameDecisionRecord) throws {
        try database.run(
            """
            INSERT INTO frame_decisions(id, series_id, relative_path, verdict, logically_excluded)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              series_id = excluded.series_id,
              relative_path = excluded.relative_path,
              verdict = excluded.verdict,
              logically_excluded = excluded.logically_excluded;
            """,
            bind: [
                .text(record.id.databaseText),
                .text(record.seriesID.databaseText),
                .text(record.relativePath),
                .text(record.verdict.rawValue),
                .int(record.logicallyExcluded ? 1 : 0),
            ]
        )
    }

    private func upsert(_ record: ReviewStateRecord) throws {
        try Self.validateFinite(
            record.updatedAt.timeIntervalSince1970,
            record: "review_states",
            field: "updated_at"
        )
        try database.run(
            """
            INSERT INTO review_states(id, series_id, status, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              series_id = excluded.series_id,
              status = excluded.status,
              updated_at = excluded.updated_at;
            """,
            bind: [
                .text(record.id.databaseText),
                .text(record.seriesID.databaseText),
                .text(record.status.rawValue),
                .real(record.updatedAt.timeIntervalSince1970),
            ]
        )
    }

    private func upsert(_ record: MutationJournalRecord) throws {
        try Self.validateFinite(
            record.createdAt.timeIntervalSince1970,
            record: "mutation_journal",
            field: "created_at"
        )
        try database.run(
            """
            INSERT INTO mutation_journal(id, operation_id, status, created_at, payload_json)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              operation_id = excluded.operation_id,
              status = excluded.status,
              created_at = excluded.created_at,
              payload_json = excluded.payload_json;
            """,
            bind: [
                .text(record.id.databaseText),
                .text(record.operationID.databaseText),
                .text(record.status.rawValue),
                .real(record.createdAt.timeIntervalSince1970),
                .text(record.payloadJSON),
            ]
        )
    }

    private static func validate(_ record: NightRecord) throws {
        guard validCivilDate(record.localDate) else {
            throw MetadataStoreError.invalidField(record: "nights", field: "local_date")
        }
        guard TimeZone(identifier: record.timeZoneID) != nil else {
            throw MetadataStoreError.invalidField(record: "nights", field: "time_zone_id")
        }
    }

    private static func validate(_ record: SeriesRecord) throws {
        try validateFinite(
            record.exposureSeconds,
            record: "series",
            field: "exposure_seconds",
            mustBePositive: true
        )
        if let gain = record.gain {
            try validateFinite(gain, record: "series", field: "gain")
        }
        if let offset = record.offset {
            try validateFinite(offset, record: "series", field: "offset")
        }
    }

    private static func validateFinite(
        _ value: Double,
        record: String,
        field: String,
        mustBePositive: Bool = false
    ) throws {
        guard value.isFinite, !mustBePositive || value > 0 else {
            throw MetadataStoreError.invalidField(record: record, field: field)
        }
    }

    private static func validCivilDate(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
    }

    private static func project(from row: SQLiteRow) throws -> ProjectRecord {
        let idText = row.string(0) ?? ""
        guard let id = UUID(uuidString: idText),
              let catalogID = row.string(1),
              let displayName = row.string(2),
              let phaseText = row.string(3),
              let phase = ProjectWorkflowPhase(rawValue: phaseText)
        else { throw MetadataStoreError.invalidRecord(table: "projects", id: idText) }
        return ProjectRecord(id: id, catalogID: catalogID, displayName: displayName, phase: phase)
    }

    private static func night(from row: SQLiteRow) throws -> NightRecord {
        let idText = row.string(0) ?? ""
        guard let id = UUID(uuidString: idText),
              let localDate = row.string(1),
              let timeZoneID = row.string(2)
        else { throw MetadataStoreError.invalidRecord(table: "nights", id: idText) }
        let record = NightRecord(id: id, localDate: localDate, timeZoneID: timeZoneID)
        try validate(record)
        return record
    }

    private static func series(from row: SQLiteRow) throws -> SeriesRecord {
        let idText = row.string(0) ?? ""
        guard let id = UUID(uuidString: idText),
              let projectID = row.string(1).flatMap(UUID.init(uuidString:)),
              let nightID = row.string(2).flatMap(UUID.init(uuidString:)),
              let setupDescriptor = row.string(4),
              let sensorModeText = row.string(5),
              let sensorMode = SeriesSensorMode(rawValue: sensorModeText),
              let passbandText = row.string(6),
              let passband = SeriesPassband(rawValue: passbandText),
              let exposureSeconds = row.double(7),
              let binning = row.string(12)
        else { throw MetadataStoreError.invalidRecord(table: "series", id: idText) }
        let record = SeriesRecord(
            id: id,
            projectID: projectID,
            nightID: nightID,
            setupID: row.string(3),
            setupDescriptor: setupDescriptor,
            sensorMode: sensorMode,
            passband: passband,
            exposureSeconds: exposureSeconds,
            filterName: row.string(8),
            filterID: row.string(9),
            gain: row.double(10),
            offset: row.double(11),
            binning: binning
        )
        try validate(record)
        return record
    }

    private static func frameDecision(from row: SQLiteRow) throws -> FrameDecisionRecord {
        let idText = row.string(0) ?? ""
        guard let id = UUID(uuidString: idText),
              let seriesID = row.string(1).flatMap(UUID.init(uuidString:)),
              let relativePath = row.string(2),
              let verdictText = row.string(3),
              let verdict = FrameVerdict(rawValue: verdictText),
              let logicallyExcluded = row.int64(4)
        else { throw MetadataStoreError.invalidRecord(table: "frame_decisions", id: idText) }
        return FrameDecisionRecord(
            id: id,
            seriesID: seriesID,
            relativePath: relativePath,
            verdict: verdict,
            logicallyExcluded: logicallyExcluded != 0
        )
    }

    private static func reviewState(from row: SQLiteRow) throws -> ReviewStateRecord {
        let idText = row.string(0) ?? ""
        guard let id = UUID(uuidString: idText),
              let seriesID = row.string(1).flatMap(UUID.init(uuidString:)),
              let statusText = row.string(2),
              let status = ReviewStatus(rawValue: statusText),
              let updatedAt = row.double(3)
        else { throw MetadataStoreError.invalidRecord(table: "review_states", id: idText) }
        let record = ReviewStateRecord(
            id: id,
            seriesID: seriesID,
            status: status,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
        try validateFinite(
            record.updatedAt.timeIntervalSince1970,
            record: "review_states",
            field: "updated_at"
        )
        return record
    }

    private static func mutationJournal(from row: SQLiteRow) throws -> MutationJournalRecord {
        let idText = row.string(0) ?? ""
        guard let id = UUID(uuidString: idText),
              let operationID = row.string(1).flatMap(UUID.init(uuidString:)),
              let statusText = row.string(2),
              let status = MutationJournalStatus(rawValue: statusText),
              let createdAt = row.double(3),
              let payloadJSON = row.string(4)
        else { throw MetadataStoreError.invalidRecord(table: "mutation_journal", id: idText) }
        let record = MutationJournalRecord(
            id: id,
            operationID: operationID,
            status: status,
            createdAt: Date(timeIntervalSince1970: createdAt),
            payloadJSON: payloadJSON
        )
        try validateFinite(
            record.createdAt.timeIntervalSince1970,
            record: "mutation_journal",
            field: "created_at"
        )
        return record
    }
}

private extension UUID {
    var databaseText: String { uuidString.lowercased() }
}
