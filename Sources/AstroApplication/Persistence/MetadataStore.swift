import AstroCore
import Darwin
import Foundation

public struct MetadataWriteBatch: Sendable {
    public var projects: [ProjectRecord]
    public var nights: [NightRecord]
    public var series: [SeriesRecord]
    public var frameDecisions: [FrameDecisionRecord]
    public var results: [ResultRecord]
    public var lineageEdges: [LineageEdgeRecord]
    public var reviewStates: [ReviewStateRecord]
    public var mutationJournal: [MutationJournalRecord]

    public init(
        projects: [ProjectRecord] = [],
        nights: [NightRecord] = [],
        series: [SeriesRecord] = [],
        frameDecisions: [FrameDecisionRecord] = [],
        results: [ResultRecord] = [],
        lineageEdges: [LineageEdgeRecord] = [],
        reviewStates: [ReviewStateRecord] = [],
        mutationJournal: [MutationJournalRecord] = []
    ) {
        self.projects = projects
        self.nights = nights
        self.series = series
        self.frameDecisions = frameDecisions
        self.results = results
        self.lineageEdges = lineageEdges
        self.reviewStates = reviewStates
        self.mutationJournal = mutationJournal
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

    public func save(_ annotation: ProjectAnnotationRecord) throws {
        try transaction { try upsert(annotation) }
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

    public func save(_ result: ResultRecord) throws {
        try transaction { try upsert(result) }
    }

    public func save(_ lineageEdge: LineageEdgeRecord) throws {
        try transaction { try upsert(lineageEdge) }
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
            for record in batch.results { try upsert(record) }
            for record in batch.lineageEdges { try upsert(record) }
            for record in batch.reviewStates { try upsert(record) }
            for record in batch.mutationJournal { try upsert(record) }
        }
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
            "SELECT project_id, integration_goal_hours, notes, updated_at FROM project_annotations WHERE project_id = ?;",
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
                updatedAt: Date(timeIntervalSince1970: updatedAt)
            )
        }
        return record
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

    public func result(id: UUID) throws -> ResultRecord? {
        var record: ResultRecord?
        try database.query(
            """
            SELECT id, project_id, parent_result_id, kind, role, relative_path,
                   created_at, software_name, software_version
            FROM results WHERE id = ?;
            """,
            bind: [.text(id.databaseText)]
        ) { row in record = try Self.result(from: row) }
        return record
    }

    public func results(projectID: UUID) throws -> [ResultRecord] {
        var records: [ResultRecord] = []
        try database.query(
            """
            SELECT id, project_id, parent_result_id, kind, role, relative_path,
                   created_at, software_name, software_version
            FROM results WHERE project_id = ? ORDER BY created_at, id;
            """,
            bind: [.text(projectID.databaseText)]
        ) { row in records.append(try Self.result(from: row)) }
        return records
    }

    public func lineageEdges(resultID: UUID) throws -> [LineageEdgeRecord] {
        var records: [LineageEdgeRecord] = []
        try database.query(
            """
            SELECT id, result_id, source_kind,
                   COALESCE(source_series_id, source_frame_id, source_result_id)
            FROM lineage_edges WHERE result_id = ? ORDER BY source_kind, id;
            """,
            bind: [.text(resultID.databaseText)]
        ) { row in records.append(try Self.lineageEdge(from: row)) }
        return records
    }

    public func lineageEdge(id: UUID) throws -> LineageEdgeRecord? {
        var record: LineageEdgeRecord?
        try database.query(
            """
            SELECT id, result_id, source_kind,
                   COALESCE(source_series_id, source_frame_id, source_result_id)
            FROM lineage_edges WHERE id = ?;
            """,
            bind: [.text(id.databaseText)]
        ) { row in record = try Self.lineageEdge(from: row) }
        return record
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
            INSERT INTO project_annotations(project_id, integration_goal_hours, notes, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(project_id) DO UPDATE SET
              integration_goal_hours = excluded.integration_goal_hours,
              notes = excluded.notes,
              updated_at = excluded.updated_at;
            """,
            bind: [
                .text(record.projectID.databaseText),
                record.integrationGoalHours.map(SQLiteValue.real) ?? .null,
                .text(record.notes),
                .real(record.updatedAt.timeIntervalSince1970),
            ]
        )
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

    private func upsert(_ record: ResultRecord) throws {
        try Self.validate(record)
        try validateDependency(resultID: record.id, dependsOn: record.parentResultID)
        try database.run(
            """
            INSERT INTO results(
              id, project_id, parent_result_id, kind, role, relative_path,
              created_at, software_name, software_version
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              project_id = excluded.project_id,
              parent_result_id = excluded.parent_result_id,
              kind = excluded.kind,
              role = excluded.role,
              relative_path = excluded.relative_path,
              created_at = excluded.created_at,
              software_name = excluded.software_name,
              software_version = excluded.software_version;
            """,
            bind: [
                .text(record.id.databaseText),
                .text(record.projectID.databaseText),
                record.parentResultID.map { .text($0.databaseText) } ?? .null,
                .text(record.kind.rawValue),
                .text(record.role.rawValue),
                record.relativePath.map(SQLiteValue.text) ?? .null,
                .real(record.createdAt.timeIntervalSince1970),
                record.softwareName.map(SQLiteValue.text) ?? .null,
                record.softwareVersion.map(SQLiteValue.text) ?? .null,
            ]
        )
    }

    private func upsert(_ record: LineageEdgeRecord) throws {
        if record.sourceKind == .result {
            try validateDependency(
                resultID: record.resultID,
                dependsOn: record.sourceID,
                excludingLineageEdgeID: record.id
            )
        }
        let sources: (series: SQLiteValue, frame: SQLiteValue, result: SQLiteValue)
        switch record.sourceKind {
        case .series:
            sources = (.text(record.sourceID.databaseText), .null, .null)
        case .frame:
            sources = (.null, .text(record.sourceID.databaseText), .null)
        case .result:
            sources = (.null, .null, .text(record.sourceID.databaseText))
        }
        try database.run(
            """
            INSERT INTO lineage_edges(
              id, result_id, source_kind, source_series_id, source_frame_id, source_result_id
            )
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              result_id = excluded.result_id,
              source_kind = excluded.source_kind,
              source_series_id = excluded.source_series_id,
              source_frame_id = excluded.source_frame_id,
              source_result_id = excluded.source_result_id;
            """,
            bind: [
                .text(record.id.databaseText),
                .text(record.resultID.databaseText),
                .text(record.sourceKind.rawValue),
                sources.series,
                sources.frame,
                sources.result,
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

    private func validateDependency(
        resultID: UUID,
        dependsOn dependencyID: UUID?,
        excludingLineageEdgeID: UUID? = nil
    ) throws {
        guard let dependencyID else { return }
        guard dependencyID != resultID else {
            throw MetadataStoreError.resultDependencyCycle
        }

        var reachesResult = false
        try database.query(
            """
            WITH RECURSIVE dependencies(id) AS (
              SELECT ?
              UNION
              SELECT results.parent_result_id
              FROM results JOIN dependencies ON results.id = dependencies.id
              WHERE results.parent_result_id IS NOT NULL
              UNION
              SELECT lineage_edges.source_result_id
              FROM lineage_edges JOIN dependencies ON lineage_edges.result_id = dependencies.id
              WHERE lineage_edges.source_kind = 'result'
                AND lineage_edges.source_result_id IS NOT NULL
                AND lineage_edges.id <> ?
            )
            SELECT 1 FROM dependencies WHERE id = ? LIMIT 1;
            """,
            bind: [
                .text(dependencyID.databaseText),
                .text(excludingLineageEdgeID?.databaseText ?? ""),
                .text(resultID.databaseText),
            ]
        ) { _ in reachesResult = true }
        guard !reachesResult else {
            throw MetadataStoreError.resultDependencyCycle
        }
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

    private static func validate(_ record: ResultRecord) throws {
        try validateFinite(
            record.createdAt.timeIntervalSince1970,
            record: "results",
            field: "created_at"
        )
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

    private static func result(from row: SQLiteRow) throws -> ResultRecord {
        let idText = row.string(0) ?? ""
        let parentText = row.string(2)
        guard let id = UUID(uuidString: idText),
              let projectID = row.string(1).flatMap(UUID.init(uuidString:)),
              parentText == nil || UUID(uuidString: parentText!) != nil,
              let kindText = row.string(3),
              let kind = ResultKind(rawValue: kindText),
              let roleText = row.string(4),
              let role = ResultRole(rawValue: roleText),
              let createdAt = row.double(6)
        else { throw MetadataStoreError.invalidRecord(table: "results", id: idText) }
        let record = ResultRecord(
            id: id,
            projectID: projectID,
            parentResultID: parentText.flatMap(UUID.init(uuidString:)),
            kind: kind,
            role: role,
            relativePath: row.string(5),
            createdAt: Date(timeIntervalSince1970: createdAt),
            softwareName: row.string(7),
            softwareVersion: row.string(8)
        )
        try validate(record)
        return record
    }

    private static func lineageEdge(from row: SQLiteRow) throws -> LineageEdgeRecord {
        let idText = row.string(0) ?? ""
        guard let id = UUID(uuidString: idText),
              let resultID = row.string(1).flatMap(UUID.init(uuidString:)),
              let kindText = row.string(2),
              let sourceKind = LineageSourceKind(rawValue: kindText),
              let sourceID = row.string(3).flatMap(UUID.init(uuidString:))
        else { throw MetadataStoreError.invalidRecord(table: "lineage_edges", id: idText) }
        return LineageEdgeRecord(
            id: id,
            resultID: resultID,
            sourceKind: sourceKind,
            sourceID: sourceID
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
