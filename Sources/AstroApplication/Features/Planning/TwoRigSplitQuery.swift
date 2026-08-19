import AstroCore
import Foundation

/// One tonight-target input to `TwoRigSplitQuery.assign` -- just the two
/// fields the assignment decision needs. `AstroUI`'s own
/// `HomeTonightRecommendation` already carries both, but this module cannot
/// import `AstroUI` (the dependency runs the other way), so `HomeStore` maps
/// its tonight rows into this small, dependency-free shape before calling
/// `assign`.
public struct TwoRigSplitTarget: Equatable, Sendable {
    /// The raw catalog/session folder name -- feeds
    /// `TargetCatalog.target(matchingFolderName:)` for the size lookup and
    /// keys the caller-supplied `historicalFingerprint` closure. NOT the
    /// human-readable `displayName` below (a folder name resolves through
    /// `TargetNameResolver`; a display string does not reliably).
    public let target: String
    /// Carried through to the result unchanged -- `assign` never needs it
    /// for the decision itself.
    public let displayName: String

    public init(target: String, displayName: String) {
        self.target = target
        self.displayName = displayName
    }
}

/// Why `TwoRigSplitQuery.assign` did (or didn't) pick a rig for one target.
public enum TwoRigSplitReason: Equatable, Sendable {
    /// The target's own catalog angular size framed better in this setup's
    /// field of view than in any other candidate's -- `TargetCatalog`'s
    /// `sizeArcmin` resolved, so this is the primary, most direct signal.
    case fieldOfViewFit
    /// The target has no resolvable catalog size (most LBN/vdB/Sh2 entries,
    /// or anything not in `TargetCatalog` at all), but this library's own
    /// scanned history says exactly one candidate's camera shot it before.
    case historicalFingerprint
    /// Neither a resolvable size nor a resolvable, unambiguous shooting
    /// history exists for this target -- an honest "nem eldönthető", never
    /// a guess between two equally plausible rigs.
    case undecidable
}

/// One target's rig assignment -- `Identifiable` by `target` so
/// `HomeView` can `ForEach` the result directly.
public struct TwoRigSplitAssignment: Equatable, Sendable, Identifiable {
    public var id: String { target }
    public let target: String
    public let displayName: String
    /// `nil` exactly when `reason == .undecidable`.
    public let setupID: String?
    public let setupName: String?
    public let reason: TwoRigSplitReason

    public init(target: String, displayName: String, setupID: String?, setupName: String?, reason: TwoRigSplitReason) {
        self.target = target
        self.displayName = displayName
        self.setupID = setupID
        self.setupName = setupName
        self.reason = reason
    }
}

/// Ideation #5 ("Két géped mára" -- tonight's rig split): with two or more
/// saved `ImagingSetupProfile`s out the same night, which one points at
/// which of tonight's recommended targets. `assign` is pure and DB-free --
/// `HomeStore` resolves tonight's plan (never re-planned here) and this
/// library's own shooting history, then hands both in as plain values.
///
/// The decision, per target, independently of every other target's own
/// assignment (a plain greedy pick, not a global optimization -- two targets
/// competing for the same "best" rig both get it, since a photographer runs
/// each rig on ITS OWN mount, not in the kind of shared-resource contention a
/// scheduler would need to resolve):
///
/// 1. Resolve the target's catalog major-axis size (`TargetCatalog`, via
///    `TargetNameResolver`). When known, score every candidate setup's own
///    `fieldOfView()` by how close the size's short-edge coverage lands to
///    `idealCoverage` -- closest wins. This naturally sends a large target to
///    the widest-FOV rig (a narrow rig's coverage overshoots 1.0, scoring far
///    from ideal) and a small target to the narrowest rig that still frames
///    it well (a wide rig's coverage undershoots, scoring further from ideal
///    than a closer-matched narrow one) -- see this type's own tests.
/// 2. No resolvable size (or no candidate has a valid FOV at all): fall back
///    to `historicalFingerprint(target)` -- this library's own dominant
///    `EquipmentProfile` fingerprint for every past session of this target,
///    across its full history (see `historicalDominantFingerprint` below).
///    When its `camera` string matches exactly one candidate's own
///    `cameraName` (folded, substring match -- a saved setup's freeform name
///    rarely equals a FITS `INSTRUME` string byte-for-byte), that candidate
///    wins.
/// 3. Neither resolves (or the fingerprint's camera matches zero or more
///    than one candidate): `.undecidable`, `setupID`/`setupName` both `nil`
///    -- included in the result, never dropped.
public enum TwoRigSplitQuery {
    /// Below this many saved setups there is nothing to split -- V2 has no
    /// imaging-setup CRUD yet (a known gap), so `assign` hides the whole
    /// feature rather than showing a one-rig "split" that means nothing.
    public static let minimumSetupCount = 2

    /// The short-edge coverage fraction (`target size / frame short edge`)
    /// this scoring treats as "ideally framed" -- the same center
    /// `PlanningQuery`'s own composition scoring aims for (a target that
    /// fills roughly half the short edge, neither lost in empty sky nor
    /// spilling into a mosaic).
    private static let idealCoverage = 0.45

    /// `nil` when fewer than `minimumSetupCount` setups are configured --
    /// `HomeView` hides the whole card in that case. Otherwise returns
    /// exactly one assignment per `targets` row, in the same order, even
    /// when every one of them turns out `.undecidable`.
    public static func assign(
        targets: [TwoRigSplitTarget],
        setups: [ImagingSetupProfile],
        historicalFingerprint: @Sendable (String) -> SetupFingerprint?
    ) -> [TwoRigSplitAssignment]? {
        guard setups.count >= minimumSetupCount else { return nil }
        return targets.map { row in
            assignOne(row: row, setups: setups, historicalFingerprint: historicalFingerprint)
        }
    }

    private static func assignOne(
        row: TwoRigSplitTarget,
        setups: [ImagingSetupProfile],
        historicalFingerprint: (String) -> SetupFingerprint?
    ) -> TwoRigSplitAssignment {
        if let sizeArcmin = TargetCatalog.target(matchingFolderName: row.target)?.sizeArcmin,
           sizeArcmin.isFinite, sizeArcmin > 0,
           let best = bestFieldOfViewFit(sizeArcmin: sizeArcmin, setups: setups)
        {
            return TwoRigSplitAssignment(
                target: row.target, displayName: row.displayName,
                setupID: best.id, setupName: best.name, reason: .fieldOfViewFit
            )
        }

        if let fingerprint = historicalFingerprint(row.target), let camera = fingerprint.camera {
            let matches = setups.filter { normalizedCameraMatch(setupCamera: $0.cameraName, fingerprintCamera: camera) }
            if matches.count == 1, let match = matches.first {
                return TwoRigSplitAssignment(
                    target: row.target, displayName: row.displayName,
                    setupID: match.id, setupName: match.name, reason: .historicalFingerprint
                )
            }
        }

        return TwoRigSplitAssignment(
            target: row.target, displayName: row.displayName,
            setupID: nil, setupName: nil, reason: .undecidable
        )
    }

    /// The candidate whose own `fieldOfView()` frames `sizeArcmin` closest to
    /// `idealCoverage`, among only those setups with a resolvable FOV at all
    /// (a hand-edited profile's `fieldOfView()` can return `nil` -- see that
    /// method's own doc). `nil` when no candidate has one, letting the
    /// caller fall through to the historical-fingerprint branch. Ties break
    /// on the ascending `id` -- an arbitrary but STABLE choice, so calling
    /// `assign` twice on the same input (the "assignment stability"
    /// contract) never depends on `setups`' own array order or on any
    /// floating-point tie landing differently across calls.
    private static func bestFieldOfViewFit(
        sizeArcmin: Double, setups: [ImagingSetupProfile]
    ) -> ImagingSetupProfile? {
        var best: (setup: ImagingSetupProfile, score: Double)?
        for setup in setups {
            guard let fov = setup.fieldOfView() else { continue }
            let shortEdgeArcmin = min(fov.widthDeg, fov.heightDeg) * 60
            guard shortEdgeArcmin.isFinite, shortEdgeArcmin > 0 else { continue }
            let coverage = sizeArcmin / shortEdgeArcmin
            let score = 1 - abs(coverage - idealCoverage)
            if let current = best {
                if score > current.score || (score == current.score && setup.id < current.setup.id) {
                    best = (setup, score)
                }
            } else {
                best = (setup, score)
            }
        }
        return best?.setup
    }

    /// Case/diacritic-insensitive, whitespace-stripped containment match --
    /// a saved setup's freeform `cameraName` ("ASI2600MC") rarely matches a
    /// FITS `INSTRUME` string byte-for-byte ("ZWO ASI2600MC Pro"), so this
    /// asks only whether one normalized form contains the other, the same
    /// fold `HomeStore.normalized`/`TargetCatalog`'s own search
    /// normalization already use elsewhere in this app for exactly this
    /// "loose, offline text match" purpose.
    static func normalizedCameraMatch(setupCamera: String, fingerprintCamera: String) -> Bool {
        let a = normalizedCameraText(setupCamera)
        let b = normalizedCameraText(fingerprintCamera)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.contains(b) || b.contains(a)
    }

    private static func normalizedCameraText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains)
            .map(String.init).joined().lowercased()
    }

    // MARK: - Database-backed resolution (production only)

    /// This library's own dominant `EquipmentProfile` fingerprint for
    /// `target`, across EVERY session on record -- unlike
    /// `EquipmentProfile.sessionFingerprints` (scoped to one target+date),
    /// this pools every usable light the target has ever had, the same
    /// "whole target, not one session" scope `FieldGeometry.panels` uses for
    /// its own mosaic clustering. `nil` when the target has no usable light
    /// with a derivable fingerprint at all (never scanned, or every frame's
    /// header is too bare) -- `assign`'s fallback branch then falls straight
    /// through to `.undecidable`.
    ///
    /// `EquipmentProfile.fingerprintCounts(usableLights:meta:)`/`.dominant(_:)`
    /// are now `public` in `AstroCore` for exactly this call -- the
    /// frame-counting/majority-vote (and its tie-break) live in ONE place,
    /// never a second, divergent notion of "the dominant setup".
    public static func historicalDominantFingerprint(
        target: String, db: Database, config: AstroConfig
    ) throws -> SetupFingerprint? {
        let files = try db.allFiles(includeMissing: false)
        let lights = files.filter { $0.target == target && $0.area == .sessions && $0.role == .light }
        guard !lights.isEmpty else { return nil }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in lights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }

        let buckets = FrameSet.lightBuckets(files: lights, meta: metaByFileID, config: config)
        guard !buckets.usable.isEmpty else { return nil }

        let counts = EquipmentProfile.fingerprintCounts(usableLights: buckets.usable, meta: metaByFileID)
        return EquipmentProfile.dominant(counts)
    }
}
