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
        metadata: MetadataStore,
        imagingSetups: [ImagingSetupProfile] = []
    ) async throws -> ScanWorkflowMaterializationSummary {
        let database = try SQLiteDB(readOnlyPath: indexDatabase.standardizedFileURL.path)
        var frames: [ScannedFrame] = []
        // W7-D: capture groups (V1's own equipment/filter metadata table,
        // stored in this exact index database) are the second rung of the
        // passband precedence chain -- a headerless OSC frame sitting under
        // `captures/<slug>/` inherits its group's declared `signal_mode`
        // rather than being guessed as broadband. Keyed like
        // `CaptureResolver.scopeKey` (target/session_date/slug), using the
        // RAW session-date string (not the civil night `SessionDateParser`
        // resolves below) because that raw string is exactly what
        // `capture_groups.session_date` was written with.
        var captureGroupSignalModeByScope: [String: SignalMode] = [:]
        try? database.query(
            "SELECT target, session_date, slug, signal_mode FROM capture_groups;"
        ) { row in
            guard let target = row.string(0), let sessionDate = row.string(1),
                  let slug = row.string(2),
                  let signalMode = row.string(3).flatMap(SignalMode.init(rawValue:)),
                  signalMode != .unknown
            else { return }
            captureGroupSignalModeByScope[captureGroupScopeKey(target: target, sessionDate: sessionDate, slug: slug)] = signalMode
        }
        // The fallback of last resort (precedence level 4): the default
        // imaging setup's declared filter, if the user configured one --
        // see `ImagingSetupProfile.defaultFilterSignalMode`'s own doc
        // comment for why this only ever applies to OSC frames.
        let setupDefaultSignalMode: SignalMode? = {
            guard let mode = ImagingSetupProfile.defaultSetup(in: imagingSetups)?.defaultFilterSignalMode,
                  mode != .unknown
            else { return nil }
            return mode
        }()
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
                  let rawDate = row.string(2),
                  let sessionDate = SessionDateParser.parse(rawDate),
                  let exposure = row.double(4), exposure.isFinite, exposure > 0
            else { return }
            let captureSlug = PathClassifier.classify(relativePath: path).captureSlug
            let captureGroupSignalMode = captureSlug.flatMap {
                captureGroupSignalModeByScope[captureGroupScopeKey(target: target, sessionDate: rawDate, slug: $0)]
            }
            frames.append(ScannedFrame(
                path: path, target: target, date: sessionDate.start,
                fileExtension: row.string(3) ?? "",
                exposure: exposure,
                gain: row.double(5), offset: row.double(6),
                instrument: nonBlank(row.string(7)), focalLength: row.double(8),
                filter: nonBlank(row.string(9)), headerJSON: row.string(10),
                captureSlug: captureSlug,
                captureGroupSignalMode: captureGroupSignalMode,
                setupDefaultSignalMode: setupDefaultSignalMode
            ))
        }

        // W7-C: canonicalize plate-solve FOCALLEN jitter (255/256/261/262 mm
        // from ASI Air, all one physical rig) BEFORE grouping into series --
        // otherwise one rig imaged across several nights fragments into a
        // "series-setup" per jittered value, which is exactly what made a
        // project header read "133mm; 134mm; 135mm" for a single telescope.
        // Built once, over every collected frame, using the same engine
        // `EquipmentProfile.fingerprint` uses for the same purpose.
        var rawFocalLengthsByCamera: [String: [Double]] = [:]
        for frame in frames {
            guard let instrument = frame.instrument, let focalLength = frame.focalLength else { continue }
            rawFocalLengthsByCamera[instrument, default: []].append(focalLength)
        }
        let focalLengthBuckets = rawFocalLengthsByCamera.mapValues { FocalLengthBucketing.clusters($0) }

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
            grouped[
                SeriesKey(projectID: project.id, nightID: night.id, frame: frame, focalLengthBuckets: focalLengthBuckets),
                default: []
            ].append(frame)
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
        // Only reached once every read/write above has succeeded -- this is
        // the actual "V2 looked at the library" moment `ArchiveMapQuery`'s
        // freshness headline needs. A thrown error anywhere above (bad
        // index, a rejected write) skips this line entirely, so a failed or
        // cancelled scan never claims to be fresh (wave 6 Task 15).
        try await metadata.recordScanCompleted()
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
        // Missing/unreadable config.json (no setups ever configured, the
        // common case) falls back to an empty list -- same
        // "best-effort, never throws" convention as
        // `SiteSettingsStore.productionConfigLoader`.
        let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
        let imagingSetups = (try? AstroConfig.load(from: configURL))?.imagingSetups ?? []
        return try await materialize(
            indexDatabase: storage.indexDatabase,
            metadata: MetadataStore(storagePaths: storage),
            imagingSetups: imagingSetups
        )
    }

    /// Same identity `CaptureResolver.scopeKey` uses for the equivalent V1
    /// lookup -- kept file-private here since V2's series builder never
    /// shares a `CaptureResolver` instance (it reads the scan index
    /// directly, read-only, rather than loading a full `Database`).
    private static func captureGroupScopeKey(target: String, sessionDate: String, slug: String) -> String {
        "\(target)\u{1F}\(sessionDate)\u{1F}\(slug)"
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
    /// Slug from `sessions/<target>/<date>/captures/<slug>/...`, or `nil`
    /// for a classic non-capture-aware session path (W7-D precedence
    /// level 3: the folder name itself is evidence when nothing else is).
    let captureSlug: String?
    /// This frame's capture group's own declared `signal_mode`, already
    /// resolved by the caller (W7-D precedence level 2) -- `nil` when the
    /// frame isn't in a captures/ folder, has no matching group row, or
    /// that group never declared one (`.unknown`).
    let captureGroupSignalMode: SignalMode?
    /// The library's default imaging setup's configured fallback filter
    /// (W7-D precedence level 4), resolved once per `materialize` call.
    let setupDefaultSignalMode: SignalMode?

    var sensorMode: SeriesSensorMode {
        if ["cr3", "tif", "tiff"].contains(fileExtension.lowercased()) { return .dslr }
        if headerJSON?.localizedCaseInsensitiveContains("BAYERPAT") == true { return .osc }
        return .mono
    }

    /// W7-D: one derivation for the whole precedence chain -- FITS header
    /// text > capture group's declared signal mode > the capture slug's own
    /// name > the default setup's configured fallback > an unfiltered/
    /// broadband guess. Each level is only ever consulted when every level
    /// above it has nothing to say, so a real FITS `FILTER` value (however
    /// it's spelled) always wins, and the ASI Air "no filter wheel, no
    /// FILTER header" case for an OSC + duoband/narrowband train is the
    /// ONLY case that ever reaches levels 2-4.
    var passband: SeriesPassband {
        if let filter {
            return Self.inferredPassband(fromText: filter) ?? .other
        }
        if let captureGroupSignalMode, let mapped = SeriesPassband(rawValue: captureGroupSignalMode.rawValue) {
            return mapped
        }
        if let captureSlug, let inferred = Self.inferredPassband(fromText: captureSlug) {
            return inferred
        }
        if sensorMode == .osc, let setupDefaultSignalMode,
           let mapped = SeriesPassband(rawValue: setupDefaultSignalMode.rawValue) {
            return mapped
        }
        return sensorMode == .mono ? .unfiltered : .broadband
    }

    /// The same marker vocabulary applied to both a FITS `FILTER` value and
    /// a capture-slug/folder name -- "sv220_dual-band" and a filter literally
    /// named "SV220" mean the same thing to this derivation.
    private static func inferredPassband(fromText rawText: String) -> SeriesPassband? {
        let normalized = rawText.lowercased()
        if normalized.contains("sv220") || normalized.contains("dual") || normalized.contains("duo") { return .dualBand }
        if ["ha", "halpha", "h-alpha", "oiii", "sii"].contains(where: normalized.contains) { return .narrowband }
        if ["l", "r", "g", "b"].contains(normalized) { return .lrgb }
        return nil
    }

    /// `focalLengthBuckets` (W7-C) is the per-camera
    /// `FocalLengthBucketing.clusters(_:)` lookup built once over every
    /// frame this materialize call collected -- see the call site in
    /// `ScanWorkflowMaterializer.materialize` for why grouping needs the
    /// CANONICAL focal length rather than this frame's own raw, possibly
    /// plate-solve-jittered value. The raw value itself is untouched here;
    /// it stays available to callers that read `fits_meta` directly.
    func setupDescriptor(focalLengthBuckets: [String: [Double: Double]]) -> String {
        let canonicalFocalLength: Double? = focalLength.map { raw in
            guard let instrument, let buckets = focalLengthBuckets[instrument] else { return raw }
            return FocalLengthBucketing.canonicalize(raw, buckets: buckets)
        }
        return [instrument ?? "Unknown camera", canonicalFocalLength.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) mm" }]
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

    init(projectID: UUID, nightID: UUID, frame: ScannedFrame, focalLengthBuckets: [String: [Double: Double]]) {
        self.projectID = projectID
        self.nightID = nightID
        self.setupDescriptor = frame.setupDescriptor(focalLengthBuckets: focalLengthBuckets)
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
