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

    public init(unratedNightCount: Int, unratedFrameCount: Int) {
        self.unratedNightCount = unratedNightCount
        self.unratedFrameCount = unratedFrameCount
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
        for file in lights {
            guard let fileID = file.id, let target = file.target, let sessionDate = file.sessionDate else { continue }
            guard ratings[fileID]?.score == nil else { continue }
            unratedFrameCount += 1
            unratedNights.insert(SessionKey(target: target, sessionDate: sessionDate))
        }
        return RatingCoverageSnapshot(unratedNightCount: unratedNights.count, unratedFrameCount: unratedFrameCount)
    }
}
