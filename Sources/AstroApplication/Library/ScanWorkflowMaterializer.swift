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
        // V3 5.4 (metadata fixer): V2 used to run its own ad hoc "W7-D"
        // precedence chain here (FITS filter text > raw-SQL capture_groups.
        // signal_mode > slug text > setup default), which never consulted
        // `file_capture_assignments` at all -- a manual override made in V1
        // was completely invisible to every V2 session grouping and filter
        // breakdown. `CaptureResolver` is V1's own mature, override-aware
        // engine for exactly this resolution (manual override > capture
        // group > FITS header, with `conflicts` when two sources disagree);
        // this materializer now builds one from the same index database and
        // asks it, rather than re-deriving a second, override-blind copy of
        // the same precedence. See `ScannedFrame.passband`/`filterName`/
        // `sensorMode` below for exactly which V2-only fallback levels still
        // apply when the resolver has nothing to say (no override, no
        // group, no FITS header), and
        // `ScanWorkflowMaterializerCaptureResolverParityTests` for the
        // documented, intentional behavior differences from the old chain.
        let resolver = CaptureResolver(
            groups: loadCaptureGroups(from: database),
            sources: loadCaptureSources(from: database),
            assignments: loadFileCaptureAssignments(from: database)
        )
        // The fallback of last resort (used only when the resolver's own
        // three levels all come back empty): the default imaging setup's
        // declared filter, if the user configured one -- see
        // `ImagingSetupProfile.defaultFilterSignalMode`'s own doc comment
        // for why this only ever applies to OSC frames.
        let setupDefaultSignalMode: SignalMode? = {
            guard let mode = ImagingSetupProfile.defaultSetup(in: imagingSetups)?.defaultFilterSignalMode,
                  mode != .unknown
            else { return nil }
            return mode
        }()
        try database.query(
            """
            SELECT files.id, files.path, files.target, files.session_date, files.ext,
                   fits_meta.filter, fits_meta.header_json,
                   fits_meta.exptime, fits_meta.gain, fits_meta."offset",
                   fits_meta.instrume, fits_meta.focallen
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
            guard let fileID = row.int64(0), let path = row.string(1), let target = row.string(2),
                  let rawDate = row.string(3),
                  let sessionDate = SessionDateParser.parse(rawDate),
                  let exposure = row.double(7), exposure.isFinite, exposure > 0
            else { return }
            let captureSlug = PathClassifier.classify(relativePath: path).captureSlug
            let fileRecord = FileRecord(
                id: fileID, path: path, size: 0, mtime: 0, ext: row.string(4) ?? "",
                kind: "fits", area: .sessions, target: target, sessionDate: rawDate,
                role: .light, scannedAt: 0
            )
            let fitsMeta = FITSMetaRecord(fileID: fileID, filter: row.string(5), headerJSON: row.string(6))
            frames.append(ScannedFrame(
                path: path, target: target, date: sessionDate.start,
                fileExtension: row.string(4) ?? "",
                exposure: exposure,
                gain: row.double(8), offset: row.double(9),
                instrument: nonBlank(row.string(10)), focalLength: row.double(11),
                headerJSON: row.string(6),
                rawFITSFilter: nonBlank(row.string(5)),
                captureSlug: captureSlug,
                setupDefaultSignalMode: setupDefaultSignalMode,
                resolved: resolver.resolve(file: fileRecord, meta: fitsMeta)
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
        // W7-G: the prior universe of series/decisions/review-states, read
        // ONCE up front -- a rescan whose derivation (W7-C focal bucketing,
        // W7-D filter inheritance, or any future change to `SeriesKey.
        // identity`) now resolves differently for the same physical frames
        // mints a NEW stable series id for them, orphaning whatever used to
        // be keyed to the OLD id. `existingDecisionByPath` is keyed by
        // `relativePath` rather than series id on purpose: `relativePath` is
        // the one thing that stays stable across a descriptor change, and
        // `frame_decisions.relative_path` is globally `UNIQUE` in the schema
        // anyway, so this dictionary can never drop a row to a key collision.
        let priorSeriesIDs = Set(try await metadata.allSeries().map(\.id))
        let existingDecisionByPath = Dictionary(
            uniqueKeysWithValues: try await metadata.allFrameDecisions().map { ($0.relativePath, $0) }
        )
        let existingReviewStates = try await metadata.allReviewStates()
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
        // W7-G: which series id THIS run's fresh grouping actually assigns
        // to each scanned path -- the relink pass below needs this both to
        // decide whether an existing decision must move, and (after the
        // loop) to work out which prior series ids no longer have ANY frame
        // landing in them at all.
        var newSeriesIDByPath: [String: UUID] = [:]
        for key in grouped.keys.sorted(by: SeriesKey.sort) {
            guard let members = grouped[key] else { continue }
            let seriesID = stableID("series|\(key.identity)")
            let series = key.record(id: seriesID)
            seriesRecords.append(series)
            for frame in members {
                newSeriesIDByPath[frame.path] = seriesID
                if let existing = existingDecisionByPath[frame.path] {
                    // Already correctly linked (the common case on a
                    // no-op rescan) -- leave the row untouched so a human
                    // verdict is never rewritten. Otherwise the SAME row
                    // (same id, same verdict) just moves its `seriesID`
                    // FK onto the series this run actually produced for
                    // its path: this IS the relink, folded into the exact
                    // spot the pre-W7-G code created a brand-new
                    // `.undecided` placeholder and crashed on `relative_
                    // path`'s UNIQUE constraint instead.
                    if existing.seriesID != seriesID {
                        decisionRecords.append(FrameDecisionRecord(
                            id: existing.id,
                            seriesID: seriesID,
                            relativePath: existing.relativePath,
                            verdict: existing.verdict,
                            logicallyExcluded: existing.logicallyExcluded
                        ))
                    }
                } else {
                    decisionRecords.append(FrameDecisionRecord(
                        id: stableID("frame|\(seriesID.uuidString)|\(frame.path)"),
                        seriesID: seriesID,
                        relativePath: frame.path,
                        verdict: .undecided,
                        logicallyExcluded: false
                    ))
                }
            }
        }

        // W7-G continued: relink `review_states` the same way -- but only
        // when an orphaned series' membership maps onto exactly ONE
        // successor series this run (an unambiguous "this whole series
        // became that series"). A split (its frames now land in more than
        // one new series) has no single rightful successor for a
        // series-level status, so it's deliberately left attached to the
        // old, now-orphaned id -- which in turn keeps that orphan
        // ineligible for deletion below, the conservative "don't guess"
        // choice over silently picking a winner.
        let currentSeriesIDs = Set(seriesRecords.map(\.id))
        var decisionsByPriorSeriesID: [UUID: [FrameDecisionRecord]] = [:]
        for decision in existingDecisionByPath.values {
            decisionsByPriorSeriesID[decision.seriesID, default: []].append(decision)
        }
        var reviewStateRecords: [ReviewStateRecord] = []
        var relinkedReviewStateSeriesIDs: Set<UUID> = []
        for reviewState in existingReviewStates where !currentSeriesIDs.contains(reviewState.seriesID) {
            let successors = Set(
                (decisionsByPriorSeriesID[reviewState.seriesID] ?? [])
                    .compactMap { newSeriesIDByPath[$0.relativePath] }
            )
            guard let successor = successors.first, successors.count == 1 else { continue }
            reviewStateRecords.append(ReviewStateRecord(
                id: reviewState.id, seriesID: successor,
                status: reviewState.status, updatedAt: reviewState.updatedAt
            ))
            relinkedReviewStateSeriesIDs.insert(reviewState.seriesID)
        }

        // W7-G continued: an orphan (a prior series id this run's grouping
        // no longer produces) is only safe to delete once EVERY decision
        // and review state that used to point at it has actually moved
        // elsewhere above -- i.e. none of its paths were simply absent from
        // this scan (a temporarily missing/moved file keeps its old series
        // alive on purpose, since that decision has nowhere else to go yet).
        let orphanIDs = priorSeriesIDs.subtracting(currentSeriesIDs)
        let deletedSeriesIDs = orphanIDs.filter { orphanID in
            let remainingDecisions = decisionsByPriorSeriesID[orphanID]?.contains {
                newSeriesIDByPath[$0.relativePath] == nil
            } ?? false
            let remainingReviewState = existingReviewStates.contains {
                $0.seriesID == orphanID && !relinkedReviewStateSeriesIDs.contains(orphanID)
            }
            return !remainingDecisions && !remainingReviewState
        }

        try await metadata.save(MetadataWriteBatch(
            projects: projects,
            nights: nights,
            series: seriesRecords,
            frameDecisions: decisionRecords,
            reviewStates: reviewStateRecords,
            deletedSeriesIDs: Array(deletedSeriesIDs)
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

    /// Reads every `capture_groups` row from the (read-only) scan index --
    /// same column set and ordering `Database.allCaptureGroups()` uses, kept
    /// as a private raw-SQL mirror here rather than opening a second,
    /// read-write `Database` connection onto a file this materializer only
    /// ever reads. A missing/pre-v11 index (no such table) yields an empty
    /// list rather than throwing, matching this file's existing
    /// "best-effort against an old index" convention.
    private static func loadCaptureGroups(from database: SQLiteDB) -> [CaptureGroupRecord] {
        var result: [CaptureGroupRecord] = []
        try? database.query(
            """
            SELECT id, target, session_date, slug, display_name, sensor_mode, signal_mode,
                   filter_manufacturer, filter_model, filter_name, notes, created_at, updated_at
            FROM capture_groups;
            """
        ) { row in
            result.append(CaptureGroupRecord(
                id: row.int64(0),
                target: row.string(1) ?? "",
                sessionDate: row.string(2) ?? "",
                slug: row.string(3) ?? "",
                displayName: row.string(4) ?? "",
                sensorMode: row.string(5).flatMap(SensorMode.init(rawValue:)) ?? .unknown,
                signalMode: row.string(6).flatMap(SignalMode.init(rawValue:)) ?? .unknown,
                filterManufacturer: row.string(7),
                filterModel: row.string(8),
                filterName: row.string(9),
                notes: row.string(10),
                createdAt: row.double(11) ?? 0,
                updatedAt: row.double(12) ?? 0
            ))
        }
        return result
    }

    /// Same convention as `loadCaptureGroups` for `capture_sources`.
    private static func loadCaptureSources(from database: SQLiteDB) -> [CaptureSourceRecord] {
        var result: [CaptureSourceRecord] = []
        try? database.query(
            "SELECT id, capture_group_id, relative_path, role FROM capture_sources;"
        ) { row in
            result.append(CaptureSourceRecord(
                id: row.int64(0),
                captureGroupID: row.int64(1) ?? 0,
                relativePath: row.string(2) ?? "",
                role: row.string(3).flatMap(FrameRole.init(rawValue:)) ?? .other
            ))
        }
        return result
    }

    /// Same convention as `loadCaptureGroups` for `file_capture_assignments`
    /// -- this is the table a V1 manual override lives in, and the whole
    /// reason this materializer now builds a `CaptureResolver` instead of
    /// re-deriving its own precedence: without reading this table, no V2
    /// surface could ever see an override a user already made in V1.
    private static func loadFileCaptureAssignments(from database: SQLiteDB) -> [Int64: FileCaptureAssignmentRecord] {
        var result: [Int64: FileCaptureAssignmentRecord] = [:]
        try? database.query(
            """
            SELECT file_id, capture_group_id, sensor_mode_override, signal_mode_override,
                   filter_manufacturer_override, filter_model_override, filter_name_override,
                   assignment_source, assigned_at
            FROM file_capture_assignments;
            """
        ) { row in
            let record = FileCaptureAssignmentRecord(
                fileID: row.int64(0) ?? 0,
                captureGroupID: row.int64(1) ?? 0,
                sensorModeOverride: row.string(2).flatMap(SensorMode.init(rawValue:)),
                signalModeOverride: row.string(3).flatMap(SignalMode.init(rawValue:)),
                filterManufacturerOverride: row.string(4),
                filterModelOverride: row.string(5),
                filterNameOverride: row.string(6),
                assignmentSource: row.string(7) ?? "",
                assignedAt: row.double(8) ?? 0
            )
            result[record.fileID] = record
        }
        return result
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
    let headerJSON: String?
    /// The raw, un-normalized `fits_meta.filter` text, kept ALONGSIDE
    /// `resolved` purely for the V2-only fallback tail in `passband` below.
    /// `CaptureResolver.signalMode(fromFilter:)` uses a deliberately
    /// conservative marker vocabulary (e.g. it recognizes "h-alpha"/"halpha"/
    /// "ha "/"ha-" but not a bare "Ha", to avoid false-positive substring
    /// matches on unrelated filter names) -- when that marker set doesn't
    /// match a real, present filter string, this file's own historically
    /// looser inline classifier (`inferredPassband(fromText:)`) still gets a
    /// chance, exactly as it did before this refactor. This is NOT a copy of
    /// `CaptureResolver`'s predicate; it only ever runs when `CaptureResolver`
    /// found nothing at all (`resolved.signalOrigin == .unknown`).
    let rawFITSFilter: String?
    /// Slug from `sessions/<target>/<date>/captures/<slug>/...`, or `nil`
    /// for a classic non-capture-aware session path. Still consulted as a
    /// V2-only fallback (see `passband` below) when `resolved` itself has
    /// nothing to say -- `CaptureResolver` has no notion of "infer a
    /// passband from the folder's own name text", only from a real
    /// `capture_groups` row or FITS header.
    let captureSlug: String?
    /// The library's default imaging setup's configured fallback filter
    /// (the last-resort V2-only fallback level), resolved once per
    /// `materialize` call.
    let setupDefaultSignalMode: SignalMode?
    /// V1's own `CaptureResolver.resolve(file:meta:)` verdict for this exact
    /// frame -- manual override (`file_capture_assignments`) > declared
    /// capture group > FITS header, in that authoritative order, with
    /// `conflicts` populated whenever two sources disagree. This REPLACES
    /// the old ad hoc "W7-D" raw-SQL precedence this type used to run
    /// entirely for `filterName`, and supplies the first three (of up to
    /// six) precedence levels for `passband`/`sensorMode` below.
    let resolved: ResolvedCaptureMetadata

    /// `resolved.sensorOrigin == .manualOverride` is the only case this
    /// overrides the classic extension/header-based guess -- `CaptureResolver
    /// .SensorMode` has no `.dslr` case (CR3 files carry no `fits_meta` row
    /// for it to read BAYERPAT from at all), so a CR3 frame with no explicit
    /// override still falls through to the extension check below exactly as
    /// before.
    var sensorMode: SeriesSensorMode {
        if resolved.sensorOrigin == .manualOverride,
           let mapped = SeriesSensorMode(rawValue: resolved.sensorMode.rawValue)
        {
            return mapped
        }
        if ["cr3", "tif", "tiff"].contains(fileExtension.lowercased()) { return .dslr }
        if headerJSON?.localizedCaseInsensitiveContains("BAYERPAT") == true { return .osc }
        return .mono
    }

    /// `resolved.filterLabel` (manufacturer + model/name, formatted by
    /// `CaptureFilterLabel`) is a strict superset of what the old raw FITS
    /// `filter` text column gave `SeriesKey.filter`: `resolved.filterOrigin`
    /// only stays `.unknown` when there is neither an override nor a group
    /// filter NOR a FITS filter -- exactly the cases where the old raw
    /// column was `nil` too.
    var filterName: String? { resolved.filterLabel }

    /// V1-authoritative precedence (via `resolved`) first, falling through
    /// to the two V2-only levels `CaptureResolver` doesn't know about
    /// (capture-slug folder-name text, then the default imaging setup's
    /// configured fallback) only when the resolver found nothing at all --
    /// no override, no group signal mode, no FITS filter text. Documented,
    /// intentional difference from the pre-refactor chain: a capture
    /// group's declared signal mode now OUTRANKS a raw FITS `FILTER` header
    /// value instead of losing to it (matches `CaptureResolver`'s own
    /// precedence, the same one V1 has used since capture groups shipped) --
    /// see `ScanWorkflowMaterializerCaptureResolverParityTests`.
    var passband: SeriesPassband {
        if resolved.signalOrigin != .unknown, let mapped = SeriesPassband(rawValue: resolved.signalMode.rawValue) {
            return mapped
        }
        // CaptureResolver had nothing at all to say -- no override, no
        // group, and (if a FITS filter string exists) no match in its own
        // marker vocabulary either. Preserve the pre-refactor chain's
        // remaining levels exactly: the raw filter text under the older,
        // looser inline vocabulary (matching a bare "Ha", for instance),
        // then the capture-slug folder name, then the default setup, then
        // an absolute sensor-based guess.
        if let rawFITSFilter {
            return Self.inferredPassband(fromText: rawFITSFilter) ?? .other
        }
        if let captureSlug, let inferred = Self.inferredPassband(fromText: captureSlug) {
            return inferred
        }
        if sensorMode == .osc, let setupDefaultSignalMode,
           let mapped = SeriesPassband(rawValue: setupDefaultSignalMode.rawValue)
        {
            return mapped
        }
        return sensorMode == .mono ? .unfiltered : .broadband
    }

    /// The same marker vocabulary applied to a capture-slug/folder name --
    /// "sv220_dual-band" means dual-band whether it's a FITS `FILTER` value
    /// (now `CaptureResolver`'s job) or a folder name (still this type's
    /// job, since the resolver has no folder-name inference at all).
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
        self.filter = frame.filterName
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
