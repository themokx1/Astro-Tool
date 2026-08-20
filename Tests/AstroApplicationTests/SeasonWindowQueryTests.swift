@testable import AstroApplication
import AstroCore
import Foundation
import Testing

private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    var comps = DateComponents()
    comps.year = year; comps.month = month; comps.day = day
    comps.hour = hour; comps.minute = minute
    return calendar.date(from: comps)!
}

/// Same 46N-ish latitude the feature's own design doc names as its worked
/// example ("an autumn-peaking target at 46N"); longitude is otherwise
/// irrelevant to season shape (it only shifts local clock time, not which
/// nights are dark).
private let site46N = SiteRule(latitudeDeg: 46, longitudeDeg: 19)
private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

struct SeasonWindowQueryTests {
    @Test("An unresolved site returns no season window rather than an invented one")
    func unresolvedSiteReturnsNil() throws {
        let target = try #require(TargetCatalog.all.first { $0.designation == "M 31" })
        let noSite = SiteRule(latitudeDeg: nil, longitudeDeg: nil)
        #expect(SeasonWindowQuery.evaluate(target: target, site: noSite, referenceDate: utc(2026, 1, 1)) == nil)
    }

    @Test("M31 at 46N has a real autumn/winter season, an October night falls inside it, and a June night doesn't")
    func m31HasAKnownAutumnWinterSeasonAt46N() throws {
        let target = try #require(TargetCatalog.all.first { $0.designation == "M 31" })
        let result = try #require(SeasonWindowQuery.evaluate(target: target, site: site46N, referenceDate: utc(2026, 1, 1)))

        #expect(result.isCircumpolarYearRound == false)
        #expect(result.hasNoUsableSeason == false)
        #expect(!result.ranges.isEmpty)

        // Ground truth from the exact same engine (DiscoveryPlanner.discover)
        // this query itself sweeps -- never a second, independently-derived
        // expectation.
        let octoberHours = groundTruthVisibleHours(target: target, date: utc(2026, 10, 15))
        #expect(octoberHours >= SeasonWindowQuery.defaultMinVisibleHours, "fixture assumption: October must be a genuinely usable night")
        #expect(result.ranges.contains { $0.contains(utc(2026, 10, 15), calendar: utcCalendar) })

        let juneHours = groundTruthVisibleHours(target: target, date: utc(2026, 6, 15))
        #expect(juneHours < SeasonWindowQuery.defaultMinVisibleHours, "fixture assumption: June must be a genuinely unusable night")
        #expect(!result.ranges.contains { $0.contains(utc(2026, 6, 15), calendar: utcCalendar) })

        // The peak can only be at least as good as a night already inside
        // the season.
        let peakHours = try #require(result.peakVisibleHours)
        #expect(peakHours >= octoberHours)
        #expect(result.peakDate != nil)

        #expect(result.monthlySamples.count == 12)
    }

    @Test("A high-declination target never leaves its usable window from 46N -- circumpolar, not a bounded season")
    func circumpolarTargetIsYearRound() throws {
        let target = CatalogTarget(
            designation: "TEST-CIRCUMPOLAR", commonNameHU: nil,
            raDeg: 120, decDeg: 80, kind: .other, sizeArcmin: nil, magnitude: nil
        )
        let result = try #require(SeasonWindowQuery.evaluate(target: target, site: site46N, referenceDate: utc(2026, 1, 1)))

        #expect(result.isCircumpolarYearRound == true)
        #expect(result.hasNoUsableSeason == false)
        #expect(result.ranges.isEmpty)
        #expect(result.peakDate != nil)
        #expect(result.peakVisibleHours != nil)
        #expect(result.monthlySamples.count == 12)
    }

    @Test("A steeply southern target never rises usefully from 46N -- no usable season at all, honestly reported")
    func farSouthernTargetHasNoUsableSeason() throws {
        let target = CatalogTarget(
            designation: "TEST-FAR-SOUTH", commonNameHU: nil,
            raDeg: 120, decDeg: -70, kind: .other, sizeArcmin: nil, magnitude: nil
        )
        let result = try #require(SeasonWindowQuery.evaluate(target: target, site: site46N, referenceDate: utc(2026, 1, 1)))

        #expect(result.hasNoUsableSeason == true)
        #expect(result.isCircumpolarYearRound == false)
        #expect(result.ranges.isEmpty)
        #expect(result.peakDate == nil)
        #expect(result.peakVisibleHours == nil)
        #expect(result.monthlySamples.count == 12)
    }

    @Test("The usable-hours threshold is a real boundary: raising it past the target's own peak erases the season, lowering it below the trough makes it circumpolar")
    func thresholdIsARealBoundary() throws {
        let target = try #require(TargetCatalog.all.first { $0.designation == "M 31" })

        let impossible = try #require(
            SeasonWindowQuery.evaluate(target: target, site: site46N, minVisibleHours: 20, referenceDate: utc(2026, 1, 1))
        )
        #expect(impossible.hasNoUsableSeason == true)
        #expect(impossible.ranges.isEmpty)

        let trivial = try #require(
            SeasonWindowQuery.evaluate(target: target, site: site46N, minVisibleHours: 0.01, referenceDate: utc(2026, 1, 1))
        )
        #expect(trivial.hasNoUsableSeason == false)
    }

    @Test("A single evaluate() call is fast enough for on-demand, per-selection use -- never a whole-catalog sweep")
    func evaluateIsFastEnoughForOnSelectionUse() throws {
        let target = try #require(TargetCatalog.all.first { $0.designation == "M 31" })
        let start = Date()
        _ = SeasonWindowQuery.evaluate(target: target, site: site46N, referenceDate: utc(2026, 1, 1))
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 3.0, "evaluate() took \(elapsed)s -- too slow for on-selection use")
    }

    private func groundTruthVisibleHours(target: CatalogTarget, date: Date) -> Double {
        DiscoveryPlanner.discover(date: date, site: site46N, targets: [target]).first?.visibleHours ?? 0
    }
}

struct SeasonWindowRangeTests {
    @Test("A non-wrapping range contains dates only inside its start...end span")
    func nonWrappingRangeContainment() {
        let range = SeasonWindowRange(startDate: utc(2026, 3, 1), endDate: utc(2026, 6, 1))
        #expect(range.contains(utc(2026, 4, 15), calendar: utcCalendar))
        #expect(!range.contains(utc(2026, 8, 1), calendar: utcCalendar))
        #expect(!range.contains(utc(2026, 1, 1), calendar: utcCalendar))
    }

    @Test("A year-wrapping range (start later in the year than end) contains dates on either side of New Year's")
    func wrappingRangeContainment() {
        // "Opens" in September (day-of-year ~254), "closes" the following
        // February (day-of-year ~51) -- startDate's absolute instant sits
        // LATER than endDate's, which is the documented wraparound shape.
        let range = SeasonWindowRange(startDate: utc(2026, 9, 10), endDate: utc(2027, 2, 20))
        #expect(range.contains(utc(2026, 11, 28), calendar: utcCalendar))
        #expect(range.contains(utc(2027, 1, 15), calendar: utcCalendar))
        #expect(!range.contains(utc(2026, 6, 1), calendar: utcCalendar))
    }
}
