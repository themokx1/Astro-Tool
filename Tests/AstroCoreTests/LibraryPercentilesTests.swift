import Foundation
import Testing
@testable import AstroCore

// MARK: - LibraryPercentiles.evaluate

@Test func evaluateReturnsNilBelowMinimumSampleSize() throws {
    let values: [Double] = [1, 2, 3, 4, 5]
    #expect(LibraryPercentiles.evaluate(value: 1, allValues: values, higherIsBetter: false) == nil)
}

@Test func evaluateAtMinimumSampleSizeComputesABand() throws {
    let values: [Double] = [1, 2, 3, 4, 5, 6]
    #expect(LibraryPercentiles.evaluate(value: 1, allValues: values, higherIsBetter: false) != nil)
}

@Test func evaluateFWHMLowerIsBetterBandsIntoThirds() throws {
    // FWHM: smaller is sharper -- `higherIsBetter: false`. Six values split
    // evenly into thirds of two: {1,2} best, {3,4} middle, {5,6} worst.
    let values: [Double] = [1, 2, 3, 4, 5, 6]

    #expect(LibraryPercentiles.evaluate(value: 1, allValues: values, higherIsBetter: false)?.band == .best)
    #expect(LibraryPercentiles.evaluate(value: 2, allValues: values, higherIsBetter: false)?.band == .best)
    #expect(LibraryPercentiles.evaluate(value: 3, allValues: values, higherIsBetter: false)?.band == .middle)
    #expect(LibraryPercentiles.evaluate(value: 4, allValues: values, higherIsBetter: false)?.band == .middle)
    #expect(LibraryPercentiles.evaluate(value: 5, allValues: values, higherIsBetter: false)?.band == .worst)
    #expect(LibraryPercentiles.evaluate(value: 6, allValues: values, higherIsBetter: false)?.band == .worst)
}

@Test func evaluateDutyCycleHigherIsBetterFlipsTheBandDirection() throws {
    // Hatékonyság: bigger percentage is better -- `higherIsBetter: true`.
    // Same six values, opposite ranking from the FWHM case above.
    let values: [Double] = [10, 20, 30, 40, 50, 60]

    #expect(LibraryPercentiles.evaluate(value: 60, allValues: values, higherIsBetter: true)?.band == .best)
    #expect(LibraryPercentiles.evaluate(value: 50, allValues: values, higherIsBetter: true)?.band == .best)
    #expect(LibraryPercentiles.evaluate(value: 30, allValues: values, higherIsBetter: true)?.band == .middle)
    #expect(LibraryPercentiles.evaluate(value: 10, allValues: values, higherIsBetter: true)?.band == .worst)
}

@Test func evaluateReportsTheDistributionsOwnMedian() throws {
    let values: [Double] = [1, 2, 3, 4, 5, 6]
    let result = try #require(LibraryPercentiles.evaluate(value: 1, allValues: values, higherIsBetter: false))
    #expect(result.medianValue == 3.5)
}

@Test func evaluateBetterThanFractionCountsStrictlyBetterValuesOnly() throws {
    // Ties: a value equal to itself elsewhere in the distribution never
    // counts as "worse than" -- so a repeated WORST value (tied with
    // another 5, nothing bigger in the array) beats nobody.
    let values: [Double] = [1, 2, 3, 4, 5, 5]
    let result = try #require(LibraryPercentiles.evaluate(value: 5, allValues: values, higherIsBetter: false))
    #expect(result.betterThanFraction == 0)
}

@Test func evaluateBestPossibleValueBeatsEveryoneElse() throws {
    let values: [Double] = [1, 2, 3, 4, 5, 6]
    let result = try #require(LibraryPercentiles.evaluate(value: 1, allValues: values, higherIsBetter: false))
    #expect(result.betterThanFraction == 5.0 / 6.0)
}

// MARK: - LibraryPercentiles.libraryFWHMArcsecValues (R11-T17)

/// `LibraryPercentiles.libraryFWHMArcsecValues` reads only `Database` rows --
/// same fixture spirit as `SessionQualityTests`, which it delegates to
/// per-target.
private func makeMemoryDB() throws -> Database {
    try Database(path: ":memory:")
}

@discardableResult
private func insertRatedLight(
    db: Database, target: String, date: String, name: String,
    xpixsz: Double?, focallen: Double?, fwhm: Double?
) throws -> Int64 {
    let path = "sessions/\(target)/\(date)/lights/\(name).fit"
    let fileID = try db.upsertFile(
        FileRecord(
            path: path, size: 1024, mtime: 1_700_000_000, ext: "fit", kind: "fits",
            area: .sessions, target: target, sessionDate: date, role: .light,
            scannedAt: 1_700_000_100
        )
    )
    try db.backfillInode(id: fileID, inode: fileID, nlink: 1)
    try db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, focallen: focallen, xpixsz: xpixsz))
    try db.upsertRating(RatingRecord(fileID: fileID, fwhm: fwhm, ratedAt: 1_700_000_200, inputSig: "sig-\(name)"))
    return fileID
}

@Test func libraryFWHMArcsecValuesCollectsMedianFWHMAcrossEveryTargetNotJustOne() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    // Two different targets, each with its own session -- the function must
    // walk EVERY target on record, not just the first one it finds.
    try insertRatedLight(db: db, target: "M42", date: "2026-01-01", name: "a", xpixsz: 3.76, focallen: 302, fwhm: 3.0)
    try insertRatedLight(db: db, target: "M31", date: "2026-01-02", name: "b", xpixsz: 3.76, focallen: 302, fwhm: 2.0)

    let values = try LibraryPercentiles.libraryFWHMArcsecValues(db: db, config: config)

    let expectedScale = 206.265 * 3.76 / 302.0
    let expected = Set([3.0 * expectedScale, 2.0 * expectedScale].map { ($0 * 10000).rounded() / 10000 })
    let actual = Set(values.map { ($0 * 10000).rounded() / 10000 })
    #expect(actual == expected)
}

@Test func libraryFWHMArcsecValuesSkipsSessionsWithNoDerivableArcsecValue() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    // No xpixsz/focallen at all -- `medianFWHMArcsec` stays `nil`, so this
    // session contributes NOTHING to the library-wide array (never a 0 or a
    // pixel fallback -- this feeds a percentile comparison, which must never
    // mix units).
    try insertRatedLight(db: db, target: "M42", date: "2026-01-01", name: "a", xpixsz: nil, focallen: nil, fwhm: 3.0)

    let values = try LibraryPercentiles.libraryFWHMArcsecValues(db: db, config: config)
    #expect(values.isEmpty)
}

@Test func libraryFWHMArcsecValuesReturnsEmptyArrayForAnEmptyLibrary() throws {
    let db = try makeMemoryDB()
    let values = try LibraryPercentiles.libraryFWHMArcsecValues(db: db, config: AstroConfig())
    #expect(values.isEmpty)
}
