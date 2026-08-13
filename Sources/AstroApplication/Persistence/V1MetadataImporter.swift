import AstroCore
import CryptoKit
import Foundation

public struct ImportSummary: Equatable, Sendable {
    public let discovered: Int
    public let inserted: Int
    public let tags: Int
    public let sessionNotes: Int
    public let verdicts: Int
    public let filterProfiles: Int
    public let captureGroups: Int
    public let captureSources: Int
    public let captureAssignments: Int
    public let acknowledgements: Int
    public let userConfigurations: Int
    public let conversionReceipts: Int
    public let quarantineReceipts: Int
    public let sensorMeasurements: Int
}

public enum V1MetadataImporter {
    public static func importReadOnly(
        from snapshot: V1StoreSnapshot,
        into destination: MetadataStore
    ) async throws -> ImportSummary {
        let database = try SQLiteDB(readOnlyPath: snapshot.databaseURL.path)
        var records: [LegacyImportRecord] = []
        var counts: [LegacyImportKind: Int] = [:]

        func append(_ kind: LegacyImportKind, key: String, payload: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard let json = String(data: data, encoding: .utf8) else {
                throw MetadataStoreError.invalidField(record: "legacy_imports", field: "payload_json")
            }
            records.append(LegacyImportRecord(
                id: deterministicID(key),
                sourceKey: key,
                kind: kind,
                payloadJSON: json
            ))
            counts[kind, default: 0] += 1
        }

        if try tableExists("tags", database) {
            try database.query("SELECT target, session_date, tag FROM tags ORDER BY target, session_date, tag;") { row in
                guard let target = row.string(0), let tag = row.string(2) else { return }
                let date = row.string(1)
                try append(.tag, key: "tag|\(target)|\(date ?? "")|\(tag)", payload: [
                    "target": target, "sessionDate": value(date), "tag": tag,
                ])
            }
        }
        if try tableExists("session_notes", database) {
            try database.query("SELECT target, session_date, key, value FROM session_notes ORDER BY target, session_date, key;") { row in
                guard let target = row.string(0), let date = row.string(1),
                      let key = row.string(2), let note = row.string(3) else { return }
                try append(.sessionNote, key: "db-note|\(target)|\(date)|\(key)", payload: [
                    "target": target, "sessionDate": date, "key": key,
                    "value": note, "origin": "database",
                ])
            }
        }
        if try tableExists("user_verdicts", database), try tableExists("files", database) {
            try database.query("""
                SELECT files.path, user_verdicts.accepted, user_verdicts.source,
                       user_verdicts.recorded_at
                FROM user_verdicts JOIN files ON files.id = user_verdicts.file_id
                ORDER BY files.path;
                """) { row in
                guard let path = row.string(0), let accepted = row.int64(1),
                      let source = row.string(2), let recordedAt = row.double(3) else { return }
                try append(.frameVerdict, key: "verdict|\(path)", payload: [
                    "relativePath": path, "accepted": accepted != 0,
                    "source": source, "recordedAt": recordedAt,
                ])
            }
        }
        if try tableExists("filter_profiles", database) {
            try database.query("""
                SELECT manufacturer, model, name, signal_mode, notes, identity_key
                FROM filter_profiles ORDER BY identity_key;
                """) { row in
                guard let signalMode = row.string(3), let identity = row.string(5) else { return }
                try append(.filterProfile, key: "filter|\(identity)", payload: [
                    "manufacturer": value(row.string(0)), "model": value(row.string(1)),
                    "name": value(row.string(2)), "signalMode": signalMode,
                    "notes": value(row.string(4)), "identityKey": identity,
                ])
            }
        }

        var groupKeys: [Int64: String] = [:]
        if try tableExists("capture_groups", database) {
            try database.query("""
                SELECT id, target, session_date, slug, display_name, sensor_mode,
                       signal_mode, filter_manufacturer, filter_model, filter_name, notes
                FROM capture_groups ORDER BY target, session_date, slug;
                """) { row in
                guard let legacyID = row.int64(0), let target = row.string(1),
                      let date = row.string(2), let slug = row.string(3),
                      let displayName = row.string(4), let sensorMode = row.string(5),
                      let signalMode = row.string(6) else { return }
                let groupKey = "\(target)|\(date)|\(slug)"
                groupKeys[legacyID] = groupKey
                try append(.captureGroup, key: "capture-group|\(groupKey)", payload: [
                    "target": target, "sessionDate": date, "slug": slug,
                    "displayName": displayName, "sensorMode": sensorMode,
                    "signalMode": signalMode, "filterManufacturer": value(row.string(7)),
                    "filterModel": value(row.string(8)), "filterName": value(row.string(9)),
                    "notes": value(row.string(10)),
                ])
            }
        }
        if try tableExists("capture_sources", database) {
            try database.query("SELECT capture_group_id, relative_path, role FROM capture_sources ORDER BY relative_path;") { row in
                guard let groupID = row.int64(0), let groupKey = groupKeys[groupID],
                      let path = row.string(1), let role = row.string(2) else { return }
                try append(.captureSource, key: "capture-source|\(groupKey)|\(path)", payload: [
                    "groupKey": groupKey, "relativePath": path, "role": role,
                ])
            }
        }
        if try tableExists("file_capture_assignments", database), try tableExists("files", database) {
            try database.query("""
                SELECT files.path, file_capture_assignments.capture_group_id,
                       sensor_mode_override, signal_mode_override,
                       filter_manufacturer_override, filter_model_override,
                       filter_name_override, assignment_source, assigned_at
                FROM file_capture_assignments
                JOIN files ON files.id = file_capture_assignments.file_id
                ORDER BY files.path;
                """) { row in
                guard let path = row.string(0), let groupID = row.int64(1),
                      let groupKey = groupKeys[groupID], let source = row.string(7),
                      let assignedAt = row.double(8) else { return }
                try append(.captureAssignment, key: "capture-assignment|\(path)", payload: [
                    "relativePath": path, "groupKey": groupKey,
                    "sensorModeOverride": value(row.string(2)),
                    "signalModeOverride": value(row.string(3)),
                    "filterManufacturerOverride": value(row.string(4)),
                    "filterModelOverride": value(row.string(5)),
                    "filterNameOverride": value(row.string(6)),
                    "assignmentSource": source, "assignedAt": assignedAt,
                ])
            }
        }
        var acknowledgements: [(category: String, groupKey: String, ackedAt: Date, note: String?)] = []
        if try tableExists("finding_acks", database) {
            try database.query("SELECT ack_key, category, group_key, acked_at, note FROM finding_acks ORDER BY ack_key;") { row in
                guard let ackKey = row.string(0), let category = row.string(1),
                      let groupKey = row.string(2), let ackedAt = row.double(3) else { return }
                try append(.acknowledgement, key: "ack|\(ackKey)", payload: [
                    "ackKey": ackKey, "category": category, "groupKey": groupKey,
                    "ackedAt": ackedAt, "note": value(row.string(4)),
                ])
                acknowledgements.append((category, groupKey, Date(timeIntervalSince1970: ackedAt), row.string(4)))
            }
        }
        try importSensors(database, table: "sensor_profile", history: false, append: append)
        try importSensors(database, table: "sensor_profile_history", history: true, append: append)
        try importAuxiliary(snapshot.auxiliaryDirectory, append: append)

        records.sort { $0.sourceKey < $1.sourceKey }
        let inserted = try await destination.importLegacyRecords(records)
        // Also lands each legacy ack in the native `audit_acknowledgements`
        // table (schema v5) so V2's Health UI can honor it directly, not
        // just carry it as frozen `legacy_imports` JSON. Upserts on
        // `ack_key`, so a repeated import never duplicates a row.
        for acknowledgement in acknowledgements {
            try await destination.acknowledgeFindingGroup(
                category: acknowledgement.category,
                groupKey: acknowledgement.groupKey,
                note: acknowledgement.note,
                at: acknowledgement.ackedAt
            )
        }
        return ImportSummary(
            discovered: records.count, inserted: inserted,
            tags: counts[.tag, default: 0], sessionNotes: counts[.sessionNote, default: 0],
            verdicts: counts[.frameVerdict, default: 0], filterProfiles: counts[.filterProfile, default: 0],
            captureGroups: counts[.captureGroup, default: 0], captureSources: counts[.captureSource, default: 0],
            captureAssignments: counts[.captureAssignment, default: 0],
            acknowledgements: counts[.acknowledgement, default: 0],
            userConfigurations: counts[.userConfiguration, default: 0],
            conversionReceipts: counts[.conversionReceipt, default: 0],
            quarantineReceipts: counts[.quarantineReceipt, default: 0],
            sensorMeasurements: counts[.legacySensorMeasurement, default: 0]
        )
    }

    private static func importSensors(
        _ database: SQLiteDB,
        table: String,
        history: Bool,
        append: (LegacyImportKind, String, [String: Any]) throws -> Void
    ) throws {
        guard try tableExists(table, database) else { return }
        try database.query("""
            SELECT camera, gain, offset, bias_level_adu, read_noise_e,
                   dark_rate_e_per_s, dark_temp_c, egain, measured_at,
                   estimator_version FROM \(table)
            ORDER BY camera, gain, offset, measured_at;
            """) { row in
            guard let camera = row.string(0), let measuredAt = row.double(8) else { return }
            let origin = history ? "history" : "current"
            let key = "sensor|\(origin)|\(camera)|\(row.double(1) ?? -1)|\(row.double(2) ?? -1)|\(measuredAt)"
            try append(.legacySensorMeasurement, key, [
                "origin": origin, "camera": camera, "gain": value(row.double(1)),
                "offset": value(row.double(2)), "biasLevelADU": value(row.double(3)),
                "readNoiseE": value(row.double(4)), "darkRateEPerSecond": value(row.double(5)),
                "darkTemperatureC": value(row.double(6)), "eGain": value(row.double(7)),
                "measuredAt": measuredAt, "estimatorVersion": value(row.int64(9)),
            ])
        }
    }

    private static func importAuxiliary(
        _ root: URL,
        append: (LegacyImportKind, String, [String: Any]) throws -> Void
    ) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            guard url.standardizedFileURL.path.hasPrefix(prefix) else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            let data = try Data(contentsOf: url)
            if relative == "config.json" {
                _ = try JSONSerialization.jsonObject(with: data)
                try append(.userConfiguration, "config|config.json", [
                    "relativePath": relative, "json": String(decoding: data, as: UTF8.self),
                ])
            } else if relative.hasPrefix("notes/") {
                let stem = url.deletingPathExtension().lastPathComponent
                guard stem.count > 11 else { continue }
                let dateStart = stem.index(stem.endIndex, offsetBy: -10)
                let date = String(stem[dateStart...])
                let targetEnd = stem.index(before: dateStart)
                let target = String(stem[..<targetEnd])
                for (key, note) in parseNotes(data).sorted(by: { $0.key < $1.key }) {
                    try append(.sessionNote, "file-note|\(relative)|\(key)", [
                        "target": target, "sessionDate": date, "key": key,
                        "value": note, "origin": "note_store", "relativePath": relative,
                    ])
                }
            } else if relative.hasPrefix("conversions/") && relative.hasSuffix(".json") {
                _ = try JSONSerialization.jsonObject(with: data)
                try append(.conversionReceipt, "conversion|\(relative)", [
                    "relativePath": relative, "json": String(decoding: data, as: UTF8.self),
                ])
            } else if relative.hasPrefix("cleanup_quarantine/") && relative.hasSuffix(".json") {
                _ = try JSONSerialization.jsonObject(with: data)
                try append(.quarantineReceipt, "quarantine|\(relative)", [
                    "relativePath": relative, "json": String(decoding: data, as: UTF8.self),
                ])
            }
        }
    }

    private static func tableExists(_ name: String, _ database: SQLiteDB) throws -> Bool {
        var exists = false
        try database.query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
            bind: [.text(name)]
        ) { _ in exists = true }
        return exists
    }

    private static func parseNotes(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var notes: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let valueStart = line.index(after: separator)
            let value = line[valueStart...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty { notes[key] = value }
        }
        return notes
    }

    private static func deterministicID(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func value(_ value: String?) -> Any { value ?? NSNull() }
    private static func value(_ value: Double?) -> Any { value ?? NSNull() }
    private static func value(_ value: Int64?) -> Any { value ?? NSNull() }
}
