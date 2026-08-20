import Foundation
import Testing
@testable import AstroCore

// MARK: - Fixtures

private func input(
    id: String,
    target: String,
    date: String,
    fwhm: Double? = nil,
    efficiency: Double? = nil,
    background: Double? = nil
) -> NightLeaderboard.Input {
    NightLeaderboard.Input(
        id: id, target: target, date: date,
        medianFWHMArcsec: fwhm, efficiencyPercent: efficiency, backgroundEPerSecPerArcsec2: background
    )
}

// MARK: - Composite ordering

@Test func compositeRanksBestCaptureFirstWhenAllThreeMetricsAgree() throws {
    // All three metrics move together (C1 best on every axis, C5 worst on
    // every axis) -- the simplest case a composite has to get right.
    let inputs = [
        input(id: "c1", target: "T1", date: "2026-01-01", fwhm: 1.0, efficiency: 90, background: 0.001),
        input(id: "c2", target: "T2", date: "2026-01-02", fwhm: 2.0, efficiency: 80, background: 0.002),
        input(id: "c3", target: "T3", date: "2026-01-03", fwhm: 3.0, efficiency: 70, background: 0.003),
        input(id: "c4", target: "T4", date: "2026-01-04", fwhm: 4.0, efficiency: 60, background: 0.004),
        input(id: "c5", target: "T5", date: "2026-01-05", fwhm: 5.0, efficiency: 50, background: 0.005)
    ]
    let result = NightLeaderboard.rank(inputs)

    #expect(result.best.map(\.id) == ["c1", "c2", "c3", "c4", "c5"])
    #expect(result.worst.map(\.id) == ["c5", "c4", "c3", "c2", "c1"])
    // Best gets the minimum composite score (0 -- winner on every axis);
    // worst gets the maximum (1 -- loser on every axis).
    #expect(result.best.first?.compositeScore == 0)
    #expect(result.worst.first?.compositeScore == 1)
}

@Test func compositeOrderingCapsAtDisplayCountAmongMoreEligibleCaptures() throws {
    // 8 distinct, cleanly-ordered captures -- best/worst must each cap at 5
    // (`NightLeaderboard.displayCount`), not return every eligible capture.
    let inputs = (1...8).map { i in
        input(
            id: "c\(i)", target: "T\(i)", date: "2026-01-\(String(format: "%02d", i))",
            fwhm: Double(i), efficiency: 100 - Double(i) * 5, background: Double(i) * 0.001
        )
    }
    let result = NightLeaderboard.rank(inputs)

    #expect(result.best.count == NightLeaderboard.displayCount)
    #expect(result.worst.count == NightLeaderboard.displayCount)
    #expect(result.best.first?.id == "c1")
    #expect(result.worst.first?.id == "c8")
    #expect(result.measuredCount == 8)
}

// MARK: - Missing-field handling

@Test func aCaptureMissingOneMetricIsRankedOnlyOnThePresentOnes() throws {
    // "c3" carries no FWHM at all but has the best efficiency AND the best
    // background of the set. If the missing FWHM were wrongly imputed as a
    // value (worst-case 1.0, or even a neutral 0.5), c3's composite would
    // be pulled away from 0 -- excluding it correctly is the only way its
    // composite lands exactly on 0, the global best.
    let inputs = [
        input(id: "c1", target: "T1", date: "2026-01-01", fwhm: 1.0, efficiency: 50, background: 0.005),
        input(id: "c2", target: "T2", date: "2026-01-02", fwhm: 2.0, efficiency: 60, background: 0.004),
        input(id: "c3", target: "T3", date: "2026-01-03", fwhm: nil, efficiency: 90, background: 0.001),
        input(id: "c4", target: "T4", date: "2026-01-04", fwhm: 4.0, efficiency: 70, background: 0.003),
        input(id: "c5", target: "T5", date: "2026-01-05", fwhm: 5.0, efficiency: 80, background: 0.002)
    ]
    let result = NightLeaderboard.rank(inputs)

    let c3 = try #require(result.best.first { $0.id == "c3" })
    #expect(c3.compositeScore == 0)
    #expect(c3.medianFWHMArcsec == nil)
    // c3 is unambiguously the best of the five given only its present axes.
    #expect(result.best.first?.id == "c3")
}

@Test func aCaptureWithNoMeasuredMetricAtAllIsExcludedFromMeasuredCountAndRanking() throws {
    let inputs = [
        input(id: "c1", target: "T1", date: "2026-01-01", fwhm: 1.0, efficiency: 90, background: 0.001),
        input(id: "c2", target: "T2", date: "2026-01-02", fwhm: 2.0, efficiency: 80, background: 0.002),
        input(id: "c3", target: "T3", date: "2026-01-03", fwhm: 3.0, efficiency: 70, background: 0.003),
        input(id: "c4", target: "T4", date: "2026-01-04", fwhm: 4.0, efficiency: 60, background: 0.004),
        input(id: "c5", target: "T5", date: "2026-01-05", fwhm: 5.0, efficiency: 50, background: 0.005),
        // No metric on record at all -- e.g. only calibration frames ever
        // landed in this capture group.
        input(id: "c6", target: "T6", date: "2026-01-06")
    ]
    let result = NightLeaderboard.rank(inputs)

    #expect(result.measuredCount == 5)
    #expect(!result.best.contains { $0.id == "c6" })
    #expect(!result.worst.contains { $0.id == "c6" })
}

// MARK: - Below the minimum

@Test func fewerThanMinimumMeasuredCapturesYieldsEmptyLeaderboardButReportsTheRealCount() throws {
    let inputs = (1...4).map { i in
        input(id: "c\(i)", target: "T\(i)", date: "2026-01-0\(i)", fwhm: Double(i))
    }
    let result = NightLeaderboard.rank(inputs)

    #expect(result.best.isEmpty)
    #expect(result.worst.isEmpty)
    #expect(result.measuredCount == 4)
}

@Test func exactlyTheMinimumMeasuredCapturesProducesANonEmptyLeaderboard() throws {
    let inputs = (1...NightLeaderboard.minimumMeasuredCount).map { i in
        input(id: "c\(i)", target: "T\(i)", date: "2026-01-0\(i)", fwhm: Double(i))
    }
    let result = NightLeaderboard.rank(inputs)

    #expect(result.measuredCount == NightLeaderboard.minimumMeasuredCount)
    #expect(!result.best.isEmpty)
    #expect(!result.worst.isEmpty)
}

@Test func emptyInputYieldsAnEmptyLeaderboard() throws {
    let result = NightLeaderboard.rank([])
    #expect(result.best.isEmpty)
    #expect(result.worst.isEmpty)
    #expect(result.measuredCount == 0)
}

// MARK: - Tie determinism

@Test func tiedCompositeScoresBreakDeterministicallyByTargetThenDateThenID() throws {
    // "tie-a" and "tie-z" carry IDENTICAL raw metrics on every axis, so
    // their composite scores are exactly equal -- only the target-name
    // tiebreak ("Alpha" < "Zulu") can decide their relative order, and it
    // must decide it the same way regardless of which order the inputs were
    // handed in.
    let tieA = input(id: "tie-a", target: "Alpha", date: "2026-01-01", fwhm: 2.0, efficiency: 70, background: 0.002)
    let tieZ = input(id: "tie-z", target: "Zulu", date: "2026-01-01", fwhm: 2.0, efficiency: 70, background: 0.002)
    let filler = [
        input(id: "f1", target: "F1", date: "2026-01-02", fwhm: 1.0, efficiency: 90, background: 0.001),
        input(id: "f2", target: "F2", date: "2026-01-03", fwhm: 3.0, efficiency: 50, background: 0.004),
        input(id: "f3", target: "F3", date: "2026-01-04", fwhm: 4.0, efficiency: 40, background: 0.005)
    ]

    let forward = NightLeaderboard.rank([tieA, tieZ] + filler)
    let reversed = NightLeaderboard.rank(filler.reversed() + [tieZ, tieA])

    #expect(forward.best.first { $0.id == "tie-a" }?.compositeScore == forward.best.first { $0.id == "tie-z" }?.compositeScore)

    func tieOrder(_ result: NightLeaderboard.Result) -> [String] {
        result.best.map(\.id).filter { $0 == "tie-a" || $0 == "tie-z" }
    }
    #expect(tieOrder(forward) == ["tie-a", "tie-z"])
    #expect(tieOrder(forward) == tieOrder(reversed))

    // The worst list orders the same tied pair the same deterministic way
    // too (tiebreak fields don't flip direction just because the score
    // comparison itself did).
    func worstTieOrder(_ result: NightLeaderboard.Result) -> [String] {
        result.worst.map(\.id).filter { $0 == "tie-a" || $0 == "tie-z" }
    }
    #expect(worstTieOrder(forward) == ["tie-a", "tie-z"])
    #expect(worstTieOrder(forward) == worstTieOrder(reversed))
}

// MARK: - Overlap on a thin library

@Test func bestAndWorstOverlapWhenExactlyTheMinimumIsEligible() throws {
    // With exactly 5 eligible captures, both lists necessarily show the
    // same 5 -- an honest reflection of a thin library, not a bug.
    let inputs = [
        input(id: "c1", target: "T1", date: "2026-01-01", fwhm: 1.0, efficiency: 90, background: 0.001),
        input(id: "c2", target: "T2", date: "2026-01-02", fwhm: 2.0, efficiency: 80, background: 0.002),
        input(id: "c3", target: "T3", date: "2026-01-03", fwhm: 3.0, efficiency: 70, background: 0.003),
        input(id: "c4", target: "T4", date: "2026-01-04", fwhm: 4.0, efficiency: 60, background: 0.004),
        input(id: "c5", target: "T5", date: "2026-01-05", fwhm: 5.0, efficiency: 50, background: 0.005)
    ]
    let result = NightLeaderboard.rank(inputs)
    #expect(Set(result.best.map(\.id)) == Set(result.worst.map(\.id)))
    #expect(result.best.map(\.id) == Array(result.worst.map(\.id).reversed()))
}
