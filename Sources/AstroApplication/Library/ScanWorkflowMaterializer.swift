import AstroCore
import CryptoKit
import Foundation

public struct ScanWorkflowMaterializationSummary: Equatable, Sendable {
    public let projects: Int
    public let nights: Int
    public let series: Int
    public let frames: Int
}

/// Converts the disposable read-only scan index into stable workflow identities.
/// It reads only the external index and writes only AstroTool's external metadata DB.
public enum ScanWorkflowMaterializer {
    public static func materialize(
        indexDatabase: URL,
        metadata: MetadataStore
    ) async throws -> ScanWorkflowMaterializationSummary {
        let database = try SQLiteDB(readOnlyPath: indexDatabase.standardizedFileURL.path)
        var frames: [ScannedFrame] = []
        try database.query(
            """
            SELECT files.path, files.target, files.session_date, files.ext,
                   fits_meta.exptime, fits_meta.gain, fits_meta."offset",
                   fits_meta.instrume, fits_meta.focallen, fits_meta.filter,
                   fits_meta.header_json
            FROM files
            LEFT JOIN fits_meta ON fits_meta.file_id = files.id
            WHERE files.missing = 0
              AND files.area = 'sessions'
              AND files.role = 'light'
              AND files.target IS NOT NULL AND files.target <> ''
              AND files.session_date IS NOT NULL AND files.session_date <> ''
            ORDER BY files.target, files.session_date, files.path;
            """
        ) { row in
            guard let path = row.string(0), let target = row.string(1),
                  let date = row.string(2) else { return }
            frames.append(ScannedFrame(
                path: path, target: target, date: date,
                fileExtension: row.string(3) ?? "",
                exposure: row.double(4) ?? 0,
                gain: row.double(5), offset: row.double(6),
                instrument: nonBlank(row.string(7)), focalLength: row.double(8),
                filter: nonBlank(row.string(9)), headerJSON: row.string(10)
            ))
        }

        let existingProjects = try await metadata.projects()
        var projectByCatalog = Dictionary(uniqueKeysWithValues: existingProjects.map { ($0.catalogID, $0) })
        let existingNights = try await metadata.nights()
        var nightByDate = Dictionary(uniqueKeysWithValues: existingNights.map { ($0.localDate, $0) })
        var projects: [ProjectRecord] = []
        var nights: [NightRecord] = []
        var grouped: [SeriesKey: [ScannedFrame]] = [:]

        for frame in frames {
            let catalog = catalogIdentity(for: frame.target)
            let project = projectByCatalog[catalog.catalogID] ?? ProjectRecord(
                id: stableID("project|\(catalog.catalogID)"),
                catalogID: catalog.catalogID,
                displayName: catalog.displayName,
                phase: .collecting
            )
            if projectByCatalog[catalog.catalogID] == nil {
                projectByCatalog[catalog.catalogID] = project
                projects.append(project)
            }
            let night = nightByDate[frame.date] ?? NightRecord(
                id: stableID("night|\(frame.date)"),
                localDate: frame.date,
                timeZoneID: TimeZone.current.identifier
            )
            if nightByDate[frame.date] == nil {
                nightByDate[frame.date] = night
                nights.append(night)
            }
            grouped[SeriesKey(projectID: project.id, nightID: night.id, frame: frame), default: []].append(frame)
        }

        var seriesRecords: [SeriesRecord] = []
        var decisionRecords: [FrameDecisionRecord] = []
        for key in grouped.keys.sorted(by: SeriesKey.sort) {
            guard let members = grouped[key] else { continue }
            let seriesID = stableID("series|\(key.identity)")
            let series = key.record(id: seriesID)
            seriesRecords.append(series)
            let existing = Dictionary(
                uniqueKeysWithValues: try await metadata.frameDecisions(seriesID: seriesID)
                    .map { ($0.relativePath, $0) }
            )
            for frame in members where existing[frame.path] == nil {
                decisionRecords.append(FrameDecisionRecord(
                    id: stableID("frame|\(seriesID.uuidString)|\(frame.path)"),
                    seriesID: seriesID,
                    relativePath: frame.path,
                    verdict: .undecided,
                    logicallyExcluded: false
                ))
            }
        }
        try await metadata.save(MetadataWriteBatch(
            projects: projects,
            nights: nights,
            series: seriesRecords,
            frameDecisions: decisionRecords
        ))
        return ScanWorkflowMaterializationSummary(
            projects: Set(grouped.keys.map(\.projectID)).count,
            nights: Set(grouped.keys.map(\.nightID)).count,
            series: seriesRecords.count,
            frames: frames.count
        )
    }

    public static func materializeProductionLibrary(rootURL: URL) async throws -> ScanWorkflowMaterializationSummary {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        return try await materialize(
            indexDatabase: storage.indexDatabase,
            metadata: MetadataStore(storagePaths: storage)
        )
    }

    private static func catalogIdentity(for rawTarget: String) -> (catalogID: String, displayName: String) {
        let readable = rawTarget.replacingOccurrences(of: "_", with: " ")
        let tokens = readable.split(separator: " ").map(String.init)
        let terms = [readable, tokens.prefix(2).joined(separator: " "), tokens.first ?? ""]
        for term in terms where !term.isEmpty {
            if let match = ProjectsQuery.searchCatalog(term, limit: 8).first(where: {
                readable.localizedCaseInsensitiveContains($0.catalogID)
            }) {
                return (match.catalogID, match.displayName)
            }
        }
        return (readable, readable)
    }

    private static func stableID(_ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

private struct ScannedFrame {
    let path: String
    let target: String
    let date: String
    let fileExtension: String
    let exposure: Double
    let gain: Double?
    let offset: Double?
    let instrument: String?
    let focalLength: Double?
    let filter: String?
    let headerJSON: String?

    var sensorMode: SeriesSensorMode {
        if ["cr3", "tif", "tiff"].contains(fileExtension.lowercased()) { return .dslr }
        if headerJSON?.localizedCaseInsensitiveContains("BAYERPAT") == true { return .osc }
        return .mono
    }

    var passband: SeriesPassband {
        guard let filter else { return sensorMode == .mono ? .unfiltered : .broadband }
        let normalized = filter.lowercased()
        if normalized.contains("sv220") || normalized.contains("dual") || normalized.contains("duo") { return .dualBand }
        if ["ha", "halpha", "h-alpha", "oiii", "sii"].contains(where: normalized.contains) { return .narrowband }
        if ["l", "r", "g", "b"].contains(normalized) { return .lrgb }
        return .other
    }

    var setupDescriptor: String {
        [instrument ?? "Unknown camera", focalLength.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) mm" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var binning: String {
        guard let headerJSON, let data = headerJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "1x1" }
        let x = (json["XBINNING"] as? NSNumber)?.intValue ?? 1
        let y = (json["YBINNING"] as? NSNumber)?.intValue ?? x
        return "\(x)x\(y)"
    }
}

private struct SeriesKey: Hashable {
    let projectID: UUID
    let nightID: UUID
    let setupDescriptor: String
    let sensorMode: SeriesSensorMode
    let passband: SeriesPassband
    let exposure: Double
    let filter: String?
    let gain: Double?
    let offset: Double?
    let binning: String

    init(projectID: UUID, nightID: UUID, frame: ScannedFrame) {
        self.projectID = projectID
        self.nightID = nightID
        self.setupDescriptor = frame.setupDescriptor
        self.sensorMode = frame.sensorMode
        self.passband = frame.passband
        self.exposure = frame.exposure
        self.filter = frame.filter
        self.gain = frame.gain
        self.offset = frame.offset
        self.binning = frame.binning
    }

    var identity: String {
        let gainValue = gain.map { String($0) } ?? ""
        let offsetValue = offset.map { String($0) } ?? ""
        return [projectID.uuidString, nightID.uuidString, setupDescriptor, sensorMode.rawValue,
         passband.rawValue, String(exposure), filter ?? "", gainValue,
         offsetValue, binning].joined(separator: "|")
    }

    func record(id: UUID) -> SeriesRecord {
        SeriesRecord(
            id: id, projectID: projectID, nightID: nightID, setupID: nil,
            setupDescriptor: setupDescriptor, sensorMode: sensorMode, passband: passband,
            exposureSeconds: exposure, filterName: filter, filterID: nil,
            gain: gain, offset: offset, binning: binning
        )
    }

    static func sort(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.projectID != rhs.projectID { return lhs.projectID.uuidString < rhs.projectID.uuidString }
        if lhs.nightID != rhs.nightID { return lhs.nightID.uuidString < rhs.nightID.uuidString }
        if lhs.exposure != rhs.exposure { return lhs.exposure < rhs.exposure }
        return lhs.identity < rhs.identity
    }
}
