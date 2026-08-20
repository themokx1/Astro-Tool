import AstroCore
import Foundation

/// One usable light's score/capture-time inputs to
/// `RepresentativeFrameQuery.pick(_:)` -- `Sendable`/`Equatable` so the
/// selection rule itself can be tested against synthetic fixtures without
/// touching `Database`.
public struct RepresentativeFrameCandidate: Equatable, Sendable {
    public let relativePath: String
    public let score: Double?
    public let captureTime: Date?

    public init(relativePath: String, score: Double?, captureTime: Date?) {
        self.relativePath = relativePath
        self.score = score
        self.captureTime = captureTime
    }
}

/// Picks one representative frame for a session's shareable "session card"
/// (expert ideation spec #4 follow-up): `SessionCardContent.
/// thumbnailRelativePath` was wired but always `nil` (see that field's own
/// doc comment as it stood before this query existed) because nothing the
/// Night workspace already loads names an actual frame file --
/// `CaptureGroupSummary`/`CaptureQualitySummary` (`NightReportQuery.Result.
/// captureGroups`) are both aggregate-only; no per-frame `relativePath`
/// survives past `SessionQuality.computeSummary`'s own median math. This is
/// a small, focused sibling of `NightReportQuery` rather than a change to
/// that query's `Result` (nothing else needs a frame list there) -- the same
/// "one small query per distinct need, opening its own `Database` handle"
/// convention `FrameQualityQuery`/`CalibrationQuery` already follow
/// alongside `NightReportQuery` itself in this same directory.
///
/// Selection rule:
/// 1. The highest-`score` usable light, if any usable light has been rated
///    at all (`Rater`'s convention: higher is better).
/// 2. Else the "middle" usable light by capture time (`DATE-OBS`) -- a
///    cheap proxy for "roughly mid-session, not the very first or last frame
///    a clouds/dew/meridian-flip event might have marred" -- among whichever
///    usable lights have a resolvable capture time.
/// 3. Else `nil`: no usable light at all, or every usable light lacks both a
///    score and a resolvable capture time (nothing principled to rank by).
public struct RepresentativeFrameQuery: Sendable {
    private let db: Database
    private let config: AstroConfig

    public init(db: Database, config: AstroConfig) {
        self.db = db
        self.config = config
    }

    /// Opens the production index DB/config for `rootURL` -- same
    /// `.production(rootURL:)` shape `NightReportQuery`/`CalibrationQuery`/
    /// `FrameQualityQuery` already follow.
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

    /// Reads only `Database` rows (`files`/`fits_meta`/`ratings`) -- the
    /// exact same three tables `SessionQuality.computeSummary` reads for
    /// this same session, run through the exact same `FrameSet.
    /// lightBuckets` dedup/reject split -- no new scanning, no filesystem
    /// access beyond the already-open index.
    public func representativeFrame(target: String, date: String) throws -> String? {
        let files = try db.allFiles(includeMissing: false)
        let dayLights = files.filter { $0.target == target && $0.sessionDate == date && $0.role == .light }
        guard !dayLights.isEmpty else { return nil }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in dayLights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }

        let buckets = FrameSet.lightBuckets(files: dayLights, meta: metaByFileID, config: config)

        var candidates: [RepresentativeFrameCandidate] = []
        candidates.reserveCapacity(buckets.usable.count)
        for file in buckets.usable {
            let score = try file.id.flatMap { try db.rating(fileID: $0)?.score }
            let captureTime = file.id
                .flatMap { metaByFileID[$0]?.dateObs }
                .flatMap(SessionTimeline.parseDateObs)
            candidates.append(RepresentativeFrameCandidate(relativePath: file.path, score: score, captureTime: captureTime))
        }
        return Self.pick(candidates)
    }

    /// Pure selection logic -- see this type's own doc comment for the
    /// three-tier rule. `internal`, tested directly against synthetic
    /// candidates (`@testable import`) rather than only through a
    /// `Database` fixture.
    static func pick(_ candidates: [RepresentativeFrameCandidate]) -> String? {
        guard !candidates.isEmpty else { return nil }

        let scored = candidates.filter { $0.score != nil }
        if let best = scored.max(by: { $0.score! < $1.score! }) {
            return best.relativePath
        }

        let byTime = candidates.filter { $0.captureTime != nil }.sorted { $0.captureTime! < $1.captureTime! }
        guard !byTime.isEmpty else { return nil }
        return byTime[byTime.count / 2].relativePath
    }
}
