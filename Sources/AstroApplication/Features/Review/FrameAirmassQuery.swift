import AstroCore
import Foundation

/// One frame's existing quality `score` (`FrameQualityMetrics.score`,
/// `Rater`'s own ranking, higher is better), by `relativePath` -- the only
/// input `FrameAirmassQuery.lowAltitudeQC(frames:)` needs beyond its own
/// `db`/`config`. `score == nil` (never rated yet) is a legitimate value, not
/// an error -- `lowAltitudeQC` drops those frames from its own ranking
/// rather than the caller having to pre-filter.
public struct FrameAirmassScoreInput: Equatable, Sendable {
    public let relativePath: String
    public let score: Double?

    public init(relativePath: String, score: Double?) {
        self.relativePath = relativePath
        self.score = score
    }
}

/// The "leggyengébb kereteid alacsonyan készültek" QC signal (expert
/// ideation #10): this session's worst-scoring frames were shot meaningfully
/// lower in the sky than its best-scoring frames -- worth starting the
/// target later next time, higher above the horizon (thicker air at low
/// altitude both scatters more light into the background and blurs stars
/// through more atmospheric turbulence, so a real altitude/score correlation
/// is a genuine, actionable cause, not a coincidence).
public struct LowAltitudeQC: Equatable, Sendable {
    /// Frame count in each quartile compared (`resolved.count / 4` --
    /// `resolved` is `lowAltitudeQC`'s own scored-AND-altitude-resolved
    /// population, see its doc comment). The digest line's own "your N
    /// weakest frames" count.
    public let worstQuartileFrameCount: Int
    public let worstQuartileMedianAltitudeDeg: Double
    public let bestQuartileMedianAltitudeDeg: Double

    public init(
        worstQuartileFrameCount: Int,
        worstQuartileMedianAltitudeDeg: Double,
        bestQuartileMedianAltitudeDeg: Double
    ) {
        self.worstQuartileFrameCount = worstQuartileFrameCount
        self.worstQuartileMedianAltitudeDeg = worstQuartileMedianAltitudeDeg
        self.bestQuartileMedianAltitudeDeg = bestQuartileMedianAltitudeDeg
    }
}

/// Per-frame altitude at each frame's OWN capture instant, and the
/// low-altitude QC signal derived from it -- pure glue over FOUR engines
/// `AstroCore` already owns (no new astronomy lives here):
/// `SessionTimeline.parseDateObs` for the instant, `TargetCoordinates
/// .coordinates(headerJSON:solvedRA:solvedDec:)` for the frame's RA/Dec,
/// `Planner.resolveSite` for the observing site, and `SiderealTime.lstHours`
/// + `AltAz.position` for the altitude itself -- the exact same four-engine
/// stack `SkyTrack.altitudeTrack` already glues together for the chart's
/// forward-looking "how high WILL this target get tonight" curve. This type
/// is the backward-looking counterpart: "how high WAS each frame actually
/// shot", one measured instant per already-captured frame rather than one
/// sampled instant per five minutes of a future night.
///
/// Read-only, same "engine result passed straight through, never runs a
/// measurement itself" stance `FrameQualityQuery` already documents for
/// itself -- this never writes anything.
public struct FrameAirmassQuery: Sendable {
    private let db: Database
    private let config: AstroConfig

    public init(db: Database, config: AstroConfig) {
        self.db = db
        self.config = config
    }

    public static func production(rootURL: URL) throws -> Self {
        let root = rootURL.standardizedFileURL
        let identity = LibraryIdentity(rootURL: root)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: root)
        let database = try Database(path: storage.indexDatabase.path)
        let configURL = root.appendingPathComponent(".astro_tool/config.json")
        var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
        config.rootPath = root.path
        return Self(db: database, config: config)
    }

    /// One altitude (degrees) per `relativePaths` entry that resolves ALL of:
    /// a scanned `files` row, that file's `FITSMetaRecord`, a parseable
    /// `DATE-OBS` (`SessionTimeline.parseDateObs`), and a resolvable RA/Dec
    /// (`TargetCoordinates.coordinates(headerJSON:solvedRA:solvedDec:)` --
    /// header WCS/RA-DEC first, falling back to `PlateSolver`'s persisted
    /// `solved_ra`/`solved_dec` for a plate-solved wide-field frame with no
    /// header WCS of its own). A path simply absent from the result means
    /// one of those didn't resolve for THAT frame specifically (most
    /// commonly: an unsolved DSLR wide-field frame with neither a header
    /// RA/Dec nor a plate solve on record) -- never a crash, never a `0`
    /// standing in for "unknown". `[:]` outright when the library has no
    /// resolvable observing site at all (`Planner.resolveSite`'s own
    /// `latitudeDeg`/`longitudeDeg` both need to be non-`nil`) -- altitude is
    /// meaningless without a site, regardless of what any individual frame's
    /// header carries.
    public func altitudeDeg(relativePaths: [String]) throws -> [String: Double] {
        guard !relativePaths.isEmpty else { return [:] }
        let site = try Planner.resolveSite(db: db, config: config)
        guard let latDeg = site.latitudeDeg, let lonDeg = site.longitudeDeg else { return [:] }

        var result: [String: Double] = [:]
        result.reserveCapacity(relativePaths.count)
        for path in relativePaths {
            guard let file = try db.file(path: path), let fileID = file.id,
                  let meta = try db.fitsMeta(fileID: fileID),
                  let rawDateObs = meta.dateObs,
                  let instant = SessionTimeline.parseDateObs(rawDateObs),
                  let coord = TargetCoordinates.coordinates(
                      headerJSON: meta.headerJSON, solvedRA: meta.solvedRA, solvedDec: meta.solvedDec
                  )
            else { continue }

            let jd = JulianDate.julianDay(instant)
            let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: lonDeg)
            let position = AltAz.position(raDeg: coord.raDeg, decDeg: coord.decDeg, lstHours: lst, latDeg: latDeg)
            result[path] = position.altitudeDeg
        }
        return result
    }

    /// Fires when this session's worst-scoring quarter of frames sat
    /// MEANINGFULLY lower in the sky than its best-scoring quarter, by a
    /// two-part rule chosen so the line is always honest advice, never a
    /// coincidence report:
    /// 1. The worst quartile's median altitude is AT LEAST 10 deg below the
    ///    best quartile's median altitude -- a real gap, not sampling noise.
    /// 2. The worst quartile's OWN median altitude is under 35 deg -- so the
    ///    line never fires on a session that was already comfortably high
    ///    (e.g. 55 deg vs 65 deg is a real 10 deg gap, but 55 deg is nowhere
    ///    near the "shoot it later" territory this line exists to flag).
    ///
    /// Both frame populations are the STRICT top/bottom quarter (`resolved
    /// .count / 4`, rounded down) of every frame that resolves BOTH a score
    /// (`frames`, this session's existing `FrameQualityMetrics.score` --
    /// never re-derived here) AND an altitude (`altitudeDeg(relativePaths:)`
    /// above) -- ranked by score, ascending.
    ///
    /// `nil` (never a misleading zero-frame line) when: no frame in `frames`
    /// has a score yet (nothing rated), fewer than 4 frames resolve BOTH a
    /// score and an altitude (too few to form a real quartile split on
    /// either end), the library has no resolvable observing site at all, or
    /// the rule itself simply doesn't fire (the two conditions above). The
    /// rating-gate work already explains "no measurements yet" on its own
    /// terms -- this type never re-states that, it just has nothing to add
    /// until scores exist.
    public func lowAltitudeQC(frames: [FrameAirmassScoreInput]) throws -> LowAltitudeQC? {
        let scored = frames.compactMap { frame -> (relativePath: String, score: Double)? in
            guard let score = frame.score else { return nil }
            return (frame.relativePath, score)
        }
        guard !scored.isEmpty else { return nil }

        let altitudes = try altitudeDeg(relativePaths: scored.map(\.relativePath))
        guard !altitudes.isEmpty else { return nil }

        let resolved = scored.compactMap { frame -> (score: Double, altitude: Double)? in
            guard let altitude = altitudes[frame.relativePath] else { return nil }
            return (frame.score, altitude)
        }
        let quartileSize = resolved.count / 4
        guard quartileSize >= 1 else { return nil }

        let sortedByScore = resolved.sorted { $0.score < $1.score }
        let worstQuartile = sortedByScore.prefix(quartileSize)
        let bestQuartile = sortedByScore.suffix(quartileSize)
        let worstMedian = Self.median(worstQuartile.map(\.altitude))
        let bestMedian = Self.median(bestQuartile.map(\.altitude))

        guard bestMedian - worstMedian >= 10, worstMedian < 35 else { return nil }

        return LowAltitudeQC(
            worstQuartileFrameCount: quartileSize,
            worstQuartileMedianAltitudeDeg: worstMedian,
            bestQuartileMedianAltitudeDeg: bestMedian
        )
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
