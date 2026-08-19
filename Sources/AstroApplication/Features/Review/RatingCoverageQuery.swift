import AstroCore
import Foundation

/// One read of how much of the indexed light-frame history still has no
/// `Rater` measurement on record -- W7-E (2026-08-18 owner audit, "rating is
/// the gate on half the app, and nothing drives you through it"). Home's
/// "N nights still have unrated frames" callout, and Insights' matching
/// empty-trend hint, both need to know this without counting frames in a
/// view body; read-only, mirrors `FrameQualityQuery`'s own "engine result
/// passed straight through" stance -- this never runs `Rater` itself, only
/// reads back what it has (or hasn't) already written to the `ratings`
/// table.
///
/// A `(target, sessionDate)` pair is the unit counted here because it's
/// `FrameRatingCommand`'s own session anchor (`firstKnownFrame`) -- the exact
/// scope one `FrameRatingCommand.run`/`ProjectRatingRunner` pass rates in one
/// call. Mirrors `Rater.rate`'s own frame filter exactly (`area == .sessions
/// && role == .light`, no `FrameDecisionRecord` involved) so this count never
/// promises to close a gap `FrameRatingCommand` wouldn't actually touch --
/// `Rater.rate` rates every scanned light frame regardless of accept/reject
/// decision, not just "usable" ones.
public struct RatingCoverageSnapshot: Equatable, Sendable {
    public let unratedNightCount: Int
    public let unratedFrameCount: Int
    /// OWNER BUG (2026-08-19 real-library audit): scanned, targeted light
    /// frames whose extension `Rater.processFrame` can never turn into a
    /// `ratings` row at all -- today, exactly the non-`LibraryScanner.fitsExtensions`
    /// ones (Canon CR3 today; `NativeStats.compute` only understands FITS
    /// bytes, so it throws on a CR3 read and `processFrame` silently `return
    /// nil`s, skipping the frame forever). These are EXCLUDED from
    /// `unratedNightCount`/`unratedFrameCount` above -- counting them there
    /// promises "rate them from Home" will eventually zero the gate out,
    /// which is false: no number of `ProjectRatingRunner` reruns can ever
    /// produce a score for a frame `NativeStats` cannot read. Counted here
    /// instead so a caller can say so honestly (e.g. "N CR3 frame nem
    /// mérhető").
    public let unmeasurableFrameCount: Int

    public init(unratedNightCount: Int, unratedFrameCount: Int, unmeasurableFrameCount: Int = 0) {
        self.unratedNightCount = unratedNightCount
        self.unratedFrameCount = unratedFrameCount
        self.unmeasurableFrameCount = unmeasurableFrameCount
    }
}

public struct RatingCoverageQuery: Sendable {
    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    public static func production(rootURL: URL) throws -> Self {
        let root = rootURL.standardizedFileURL
        let identity = LibraryIdentity(rootURL: root)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: root)
        let database = try Database(path: storage.indexDatabase.path)
        return Self(db: database)
    }

    /// A `(target, sessionDate)` session counts as unrated the moment at
    /// least one of its scanned, present light frames has no `ratings.score`
    /// on record. A frame with no `target`/`sessionDate` at all is excluded
    /// -- `FrameRatingCommand.firstKnownFrame` could never resolve a session
    /// for it either, so no button this gate offers could ever rate it.
    public func snapshot() throws -> RatingCoverageSnapshot {
        struct SessionKey: Hashable { let target: String; let sessionDate: String }

        let lights = try db.allFiles(includeMissing: false).filter {
            $0.area == .sessions && $0.role == .light && $0.target != nil && $0.sessionDate != nil
        }
        let fileIDs = lights.compactMap(\.id)
        let ratings = try db.ratingsBatch(fileIDs: fileIDs)

        var unratedNights = Set<SessionKey>()
        var unratedFrameCount = 0
        var unmeasurableFrameCount = 0
        for file in lights {
            guard let fileID = file.id, let target = file.target, let sessionDate = file.sessionDate else { continue }
            guard ratings[fileID]?.score == nil else { continue }
            // `LibraryScanner.fitsExtensions` ("fit"/"fits"/"fz") is the exact set
            // `NativeStats.compute` can actually read -- anything else (CR3
            // today) makes `Rater.processFrame` skip the frame silently and
            // forever, so it must never be counted as something "Rate
            // Everything" could still close out. See `RatingCoverageSnapshot.
            // unmeasurableFrameCount`'s own doc comment.
            guard LibraryScanner.fitsExtensions.contains(file.ext.lowercased()) else {
                unmeasurableFrameCount += 1
                continue
            }
            unratedFrameCount += 1
            unratedNights.insert(SessionKey(target: target, sessionDate: sessionDate))
        }
        return RatingCoverageSnapshot(
            unratedNightCount: unratedNights.count,
            unratedFrameCount: unratedFrameCount,
            unmeasurableFrameCount: unmeasurableFrameCount
        )
    }
}
