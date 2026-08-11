import AstroCore
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
        try self.init(databaseURL: storagePaths.metadataDatabase)
    }

    init(databaseURL: URL) throws {
        let standardizedURL = databaseURL.standardizedFileURL
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

    public func project(id: UUID) throws -> ProjectRecord? {
        var record: ProjectRecord?
        try database.query(
            "SELECT id, catalog_id, display_name, phase FROM projects WHERE id = ?;",
            bind: [.text(id.databaseText)]
        ) { row in record = try Self.project(from: row) }
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

    public func frameDecision(id: UUID) throws -> FrameDecisionRecord? {
        var record: FrameDecisionRecord?
        try database.query(
            "SELECT id, series_id, relative_path, verdict, logically_excluded FROM frame_decisions WHERE id = ?;",
            bind: [.text(id.databaseText)]
        ) { row in record = try Self.frameDecision(from: row) }
        return record
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

    private func upsert(_ record: NightRecord) throws {
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
        return NightRecord(id: id, localDate: localDate, timeZoneID: timeZoneID)
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
        return SeriesRecord(
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
        return ResultRecord(
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
        return ReviewStateRecord(
            id: id,
            seriesID: seriesID,
            status: status,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
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
        return MutationJournalRecord(
            id: id,
            operationID: operationID,
            status: status,
            createdAt: Date(timeIntervalSince1970: createdAt),
            payloadJSON: payloadJSON
        )
    }
}

private extension UUID {
    var databaseText: String { uuidString.lowercased() }
}
