import AstroCore
import Foundation

/// W7-B item 1: the app's own measured sky background, standing in for the
/// SQM (Sky Quality Meter) reading `IntegrationTimeModel.hours`'s
/// `skySurfaceBrightness` input has silently defaulted to μ=21 for on every
/// call site (`PlanningQuery.integrationEstimate`) -- an honest planning tool
/// should prefer what this library's own measured sessions already say about
/// the sky it was shot under over a hardcoded broadband assumption.
public struct MeasuredSkySurfaceBrightness: Equatable, Sendable {
    /// Derived mag/arcsec2 -- see `MeasuredSkyQuery.magnitudePerArcsec2
    /// (fromEPerSecPerArcsec2:)` for the documented zero-point assumption
    /// this conversion rests on.
    public let magnitudePerArcsec2: Double
    /// How many measured (bias-corrected) sessions contributed to the
    /// median -- surfaced so a caller can show its own confidence ("from N
    /// of your own sessions") rather than a bare number with no provenance.
    public let sessionCount: Int

    public init(magnitudePerArcsec2: Double, sessionCount: Int) {
        self.magnitudePerArcsec2 = magnitudePerArcsec2
        self.sessionCount = sessionCount
    }
}

/// Reads `SessionQuality`'s already bias-corrected
/// `backgroundEPerSecPerArcsec2` across this library's own sessions and folds
/// it into one median sky-brightness figure `PlanningQuery.integrationEstimate`
/// can feed `IntegrationTimeModel` instead of its μ=21 fallback.
///
/// Grouping honesty: the audit asks for "the CURRENT site+setup class".
/// Neither is actually recoverable at the `SessionQualitySummary` level
/// today -- a session row carries no resolved site of its own (site
/// resolution is per-LIBRARY, `Planner.resolveSite`, not per-session), and
/// `SessionQualitySummary` does not preserve the FITS `instrume` camera
/// identity that fed it (only `CaptureQualitySummary`'s per-capture-group
/// background, further down, does -- and only when the library actually
/// tags capture groups). Rather than build a false-precision grouping key
/// out of data that is not really there, this query is honest about its
/// actual scope: every measured session in the OPEN library, which in
/// practice already means "this owner's current site+setup" for the
/// overwhelmingly common case of one active rig per library. A future pass
/// can tighten this once capture-group camera identity is threaded through
/// `SessionQualitySummary` itself.
public enum MeasuredSkyQuery {
    /// Below this many matching measured sessions, a median is not a stable
    /// enough estimate to override the honest μ=21 fallback -- one or two
    /// nights could be an outlier (haze, a nearby streetlight, or a session
    /// that predates this app's own Moon-aware fixes). Three is
    /// conservative without demanding a large library.
    public static let minimumSessionCount = 3

    /// The zero point this app assumes when converting `SessionQuality`'s
    /// measured e-/s/arcsec2 background into a mag/arcsec2 number
    /// `IntegrationTimeModel` can compare against its own μ=21/μ=22
    /// constants. There is no calibration source in this app (no
    /// photometric standard star, no independent SQM cross-check) to derive
    /// a rigorous zero point from, so this is a DOCUMENTED ASSUMPTION, not a
    /// measured constant -- the standard flux-magnitude (Pogson) relation is
    /// `μ = ZP - 2.5*log10(F)`, and this file supplies `ZP` by anchoring it
    /// to a real number already on record elsewhere in this codebase:
    /// `SessionQuality.swift`'s own doc comment cites 0.0023 e-/s/arcsec2 as
    /// the bias-corrected ground truth for a real (Rosette) session; solving
    /// `ZP` so that figure reads back as approximately μ 20.4 -- itself the
    /// W7-B audit's own illustrative "saját mérésekből: μ≈20.4" label --
    /// gives `ZP ≈ 13.8`. This ties the assumption to a concrete, already-
    /// cited real measurement rather than an arbitrary invented constant,
    /// but it remains a planning heuristic, not a photometric calibration:
    /// it does not attempt to back out the observing setup's own aperture/
    /// throughput to recover an instrument-independent "true" sky
    /// brightness (the same simplification `IntegrationTimeModel.hours`
    /// already accepts for its own μ=21 reference -- see that type's "not a
    /// promise of final-image SNR" doc comment).
    static let assumedZeroPointMag = 13.8

    /// `nil` for a non-finite or non-positive flux (bad or missing data) --
    /// `log10` of a zero/negative background is undefined, and this must
    /// never manufacture a number from garbage input.
    public static func magnitudePerArcsec2(fromEPerSecPerArcsec2 flux: Double) -> Double? {
        guard flux.isFinite, flux > 0 else { return nil }
        return assumedZeroPointMag - 2.5 * log10(flux)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 { return (sorted[mid - 1] + sorted[mid]) / 2 }
        return sorted[mid]
    }

    /// One read of every measured session background this library has on
    /// record, reduced to a single median mag/arcsec2 figure -- `nil` when
    /// fewer than `minimumSessionCount` sessions have a measured
    /// (bias-corrected) background at all, the honest "not enough data" case
    /// `PlanningQuery.integrationEstimate` falls back to μ=21 for.
    public static func snapshot(db: Database, config: AstroConfig) throws -> MeasuredSkySurfaceBrightness? {
        let targets = Set(
            try db.allFiles(includeMissing: false)
                .filter { $0.area == .sessions && $0.target != nil }
                .compactMap(\.target)
        )
        var fluxes: [Double] = []
        for target in targets {
            let summaries = try SessionQuality.summaries(target: target, db: db, config: config)
            fluxes.append(contentsOf: summaries.compactMap(\.backgroundEPerSecPerArcsec2))
        }
        guard fluxes.count >= minimumSessionCount, let medianFlux = median(fluxes),
              let mag = magnitudePerArcsec2(fromEPerSecPerArcsec2: medianFlux)
        else { return nil }
        return MeasuredSkySurfaceBrightness(magnitudePerArcsec2: mag, sessionCount: fluxes.count)
    }

    /// `nil` whenever no library is open, matching every other Planning
    /// production provider's "no root, no answer" contract
    /// (`PlanningStore.productionSkyContext`).
    public static func production(rootURL: URL) throws -> MeasuredSkySurfaceBrightness? {
        let root = rootURL.standardizedFileURL
        let identity = LibraryIdentity(rootURL: root)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: root)
        let database = try Database(path: storage.indexDatabase.path)
        let configURL = root.appendingPathComponent(".astro_tool/config.json")
        var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
        config.rootPath = root.path
        return try snapshot(db: database, config: config)
    }
}
