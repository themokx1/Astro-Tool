import Foundation

/// A compact per-frame equipment descriptor -- camera + focal length + pixel
/// size + Bayer pattern + guide camera (when present) -- e.g.
/// `"ASI2600MC·302mm·3.76µm·RGGB"`. Two frames sharing every component (and
/// therefore the same `descriptor`) count as "the same setup"; mixing
/// setups within one session/target is what the `mixed-setup-in-session`/
/// `mixed-setup-in-target` audit findings surface. `Hashable` (via the
/// compiler-synthesized conformance over all stored properties, `descriptor`
/// included) so it can key a `[SetupFingerprint: Int]` frame-count dictionary.
public struct SetupFingerprint: Codable, Sendable, Hashable {
    public var camera: String?
    public var focalLengthMM: Double?
    public var pixelSizeUM: Double?
    public var bayerPattern: String?
    public var guideCam: String?
    public var descriptor: String

    public init(
        camera: String? = nil,
        focalLengthMM: Double? = nil,
        pixelSizeUM: Double? = nil,
        bayerPattern: String? = nil,
        guideCam: String? = nil,
        descriptor: String
    ) {
        self.camera = camera
        self.focalLengthMM = focalLengthMM
        self.pixelSizeUM = pixelSizeUM
        self.bayerPattern = bayerPattern
        self.guideCam = guideCam
        self.descriptor = descriptor
    }
}

/// Builds `SetupFingerprint`s from `fits_meta` (+ `header_json` for the two
/// fields with no dedicated column, `BAYERPAT`/`GUIDECAM`) and rolls them up
/// per session. Read-only against `Database`; the audit rules that also need
/// this (`MixedSetupInSessionRule`/`MixedSetupInTargetRule`) call the shared,
/// DB-free `fingerprintCounts` helper directly against `AuditContext`'s own
/// data instead, so the two never disagree about what counts as "the same
/// setup".
public enum EquipmentProfile {
    /// One frame's setup fingerprint. `nil` when the frame carries NONE of
    /// camera/focal length/pixel size -- i.e. there's nothing at all to
    /// build a descriptor from (a completely bare header). Binning
    /// (`XBINNING`/`YBINNING`) is folded into `descriptor` only when present
    /// (e.g. `"2x2"`) -- it has no dedicated field on `SetupFingerprint`,
    /// since `descriptor` (part of the `Hashable` conformance) already
    /// carries any difference it makes.
    ///
    /// `focalLengthBuckets` (W7-C) is the per-camera
    /// `FocalLengthBucketing.clusters(_:)` lookup -- when it has an entry
    /// for this frame's camera, `focalLengthMM` snaps to that cluster's
    /// canonical value instead of a plain per-frame rounding, so ASI-Air
    /// plate-solve jitter (255/256/261/262 mm from one physical rig) always
    /// collapses to the SAME fingerprint. Defaults to `[:]`, which preserves
    /// the original "round to the nearest mm" behavior exactly -- existing
    /// callers that never pass a table see no change at all.
    public static func fingerprint(
        meta: FITSMetaRecord,
        headerJSON: String?,
        focalLengthBuckets: [String: [Double: Double]] = [:]
    ) -> SetupFingerprint? {
        let camera = meta.instrume
        let focalLengthMM: Double? = meta.focallen.map { raw in
            guard let camera, let buckets = focalLengthBuckets[camera] else { return raw.rounded() }
            return FocalLengthBucketing.canonicalize(raw, buckets: buckets)
        }
        let pixelSizeUM = meta.xpixsz.map { ($0 * 100).rounded() / 100 }

        guard camera != nil || focalLengthMM != nil || pixelSizeUM != nil else { return nil }

        var bayerPattern: String?
        var guideCam: String?
        var binningText: String?
        if let headerJSON, let data = headerJSON.data(using: .utf8),
           let cards = try? JSONDecoder().decode([String: String].self, from: data)
        {
            let header = FITSHeader(rawValues: cards)
            bayerPattern = header.string("BAYERPAT")
            guideCam = header.string("GUIDECAM")
            if let xBinning = header.int("XBINNING") {
                let yBinning = header.int("YBINNING") ?? xBinning
                binningText = "\(xBinning)x\(yBinning)"
            }
        }

        var parts: [String] = []
        if let camera { parts.append(camera) }
        // `Int(_:)` truncates -- rounded first since a merged bucket's
        // canonical value can land on a half mm (the median of an
        // even-sized cluster, e.g. 257.5 for the 255/260 mm buckets).
        if let focalLengthMM { parts.append("\(Int(focalLengthMM.rounded()))mm") }
        if let pixelSizeUM { parts.append("\(String(format: "%.2f", pixelSizeUM))µm") }
        if let binningText { parts.append(binningText) }
        if let bayerPattern { parts.append(bayerPattern) }
        if let guideCam { parts.append(guideCam) }

        return SetupFingerprint(
            camera: camera,
            focalLengthMM: focalLengthMM,
            pixelSizeUM: pixelSizeUM,
            bayerPattern: bayerPattern,
            guideCam: guideCam,
            descriptor: parts.joined(separator: "·")
        )
    }

    /// Frame counts per distinct fingerprint among `usableLights` -- pure
    /// and DB-free so both `sessionFingerprints` (below) and the mixed-setup
    /// audit rules (which only ever see an `AuditContext`) can share it.
    /// Frames with no derivable fingerprint (see `fingerprint`'s doc) are
    /// silently skipped -- they neither create a new bucket nor count
    /// against an existing one. `focalLengthBuckets` defaults to `[:]`
    /// (no jitter canonicalization, matching every caller that predates
    /// W7-C); pass `EquipmentProfile.focalLengthBuckets(_:)`'s result to
    /// fold ASI-Air plate-solve jitter into one setup per physical rig.
    ///
    /// `public` (rather than `internal`, its original scope) so
    /// `TwoRigSplitQuery.historicalDominantFingerprint` in `AstroApplication`
    /// can call this SAME counting logic instead of hand-rolling its own --
    /// see that function's own doc comment.
    public static func fingerprintCounts(
        usableLights: [FileRecord],
        meta: [Int64: FITSMetaRecord],
        focalLengthBuckets: [String: [Double: Double]] = [:]
    ) -> [SetupFingerprint: Int] {
        var counts: [SetupFingerprint: Int] = [:]
        for file in usableLights {
            guard let id = file.id, let record = meta[id],
                  let fp = fingerprint(meta: record, headerJSON: record.headerJSON, focalLengthBuckets: focalLengthBuckets)
            else { continue }
            counts[fp, default: 0] += 1
        }
        return counts
    }

    /// Builds the per-camera `FocalLengthBucketing.clusters(_:)` lookup from
    /// every `(camera, focalLength)` pair in `metas` -- one pass over
    /// whatever frame population a caller already has in hand (a session's
    /// lights, a target's lights, ...). Pass the result to `fingerprint`/
    /// `fingerprintCounts` so two frames of the same physical rig collapse
    /// to one setup even when their raw `FOCALLEN` differs by the few
    /// percent ASI-Air's plate-solve refinement jitters it by (W7-C). Frames
    /// missing a camera or a focal length are skipped, same convention as
    /// `fingerprint` itself.
    public static func focalLengthBuckets(_ metas: some Sequence<FITSMetaRecord>) -> [String: [Double: Double]] {
        var rawByCamera: [String: [Double]] = [:]
        for meta in metas {
            guard let camera = meta.instrume, let focalLength = meta.focallen else { continue }
            rawByCamera[camera, default: []].append(focalLength)
        }
        return rawByCamera.mapValues { FocalLengthBucketing.clusters($0) }
    }

    /// The most common fingerprint in `counts` -- "this session's setup" for
    /// the mixed-setup-in-target comparison and `SessionDetail.setupDescriptor`.
    /// Ties break on the descriptor text (ascending) purely for
    /// deterministic output; `nil` for an empty `counts`.
    ///
    /// `public` for the same reason as `fingerprintCounts` above --
    /// `TwoRigSplitQuery.historicalDominantFingerprint` shares this exact
    /// majority-vote/tie-break instead of reproducing it.
    public static func dominant(_ counts: [SetupFingerprint: Int]) -> SetupFingerprint? {
        counts.max { a, b in
            a.value != b.value ? a.value < b.value : a.key.descriptor > b.key.descriptor
        }?.key
    }

    /// Fingerprint counts across one target/date session's usable lights
    /// (deduped via `FrameSet.lightBuckets`, same convention as
    /// `SessionStatsQueries`). `[:]` when the session has no light-role
    /// files on record at all.
    public static func sessionFingerprints(target: String, date: String, db: Database, config: AstroConfig) throws -> [SetupFingerprint: Int] {
        let files = try db.allFiles(includeMissing: false)
        let lights = files.filter { $0.target == target && $0.area == .sessions && $0.sessionDate == date && $0.role == .light }
        guard !lights.isEmpty else { return [:] }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in lights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }

        let buckets = FrameSet.lightBuckets(files: lights, meta: metaByFileID, config: config)
        return fingerprintCounts(usableLights: buckets.usable, meta: metaByFileID)
    }
}
