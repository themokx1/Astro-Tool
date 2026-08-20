import Foundation
import Testing
@testable import AstroCore

/// W5-4 item 1: `Planner.overlapSeconds` (a private, hand-rolled night-bounded
/// altitude-sweep loop used only by `Planner.month`) duplicates
/// `NightSweep.sweep`'s own predicate for "is this target above
/// `minAltitudeDeg` at this instant" -- two copies of the same "how long is
/// this target up during darkness" answer is exactly the two-screens-
/// disagree failure mode this codebase has been bitten by before.
///
/// This file proves the two are equivalent BEFORE `Planner.month` is
/// converted to call `NightSweep.sweep` directly (and `overlapSeconds` is
/// deleted): `oldOverlapSeconds` below is a verbatim reimplementation of
/// `Planner.overlapSeconds`'s own loop (copied here because the real one is
/// `private` to `Planner.swift` and therefore unreachable even via
/// `@testable import`), compared sample-for-sample against
/// `NightSweep.sweep(...).visibleSeconds` at the SAME `stepMinutes: 10`
/// `Planner.month` already uses for this scan, across several site/date/
/// target combinations: always-up, always-down, and a target that rises and
/// sets mid-night.
@Suite("Planner.overlapSeconds vs NightSweep.sweep equivalence")
struct PlannerOverlapSecondsEquivalenceTests {
    /// Verbatim copy of `Planner.overlapSeconds`'s own loop (see that
    /// function's doc comment in `Sources/AstroCore/Sky/Planner.swift`) --
    /// intentionally duplicated ONE more time, here, so this test can compare
    /// it against `NightSweep.sweep` without reaching into `Planner`'s
    /// private implementation. Deleted from this file once `Planner.month`
    /// itself is converted and this equivalence has been demonstrated to
    /// hold.
    private func oldOverlapSeconds(
        raDeg: Double, decDeg: Double, latDeg: Double, lonDeg: Double,
        duskUTC: Date, dawnUTC: Date, minAltitudeDeg: Double, stepMinutes: Double = 10
    ) -> Double {
        var visibleSampleCount = 0
        let stepSeconds = stepMinutes * 60
        var t = duskUTC
        while t <= dawnUTC {
            let jd = JulianDate.julianDay(t)
            let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: lonDeg)
            let position = AltAz.position(raDeg: raDeg, decDeg: decDeg, lstHours: lst, latDeg: latDeg)
            if position.altitudeDeg >= minAltitudeDeg {
                visibleSampleCount += 1
            }
            t = t.addingTimeInterval(stepSeconds)
        }
        return Double(visibleSampleCount) * stepSeconds
    }

    private func newOverlapSeconds(
        raDeg: Double, decDeg: Double, latDeg: Double, lonDeg: Double,
        duskUTC: Date, dawnUTC: Date, minAltitudeDeg: Double
    ) -> Double {
        NightSweep.sweep(
            raDeg: raDeg, decDeg: decDeg, latDeg: latDeg, lonDeg: lonDeg,
            duskUTC: duskUTC, dawnUTC: dawnUTC, minAltitudeDeg: minAltitudeDeg, stepMinutes: 10
        ).visibleSeconds
    }

    private func utc(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day; comps.hour = 12
        return calendar.date(from: comps)!
    }

    private struct Combo {
        let label: String
        let latDeg: Double
        let lonDeg: Double
        let raDeg: Double
        let decDeg: Double
        let date: (Int, Int, Int)
        let minAltitudeDeg: Double
    }

    @Test("Old and new night-window overlap agree across always-up, always-down, and rise/set targets")
    func overlapSecondsAgreesWithNightSweep() throws {
        let combos: [Combo] = [
            // Always above the 30 deg gate for the whole night at lat 47.5
            // (lower culmination alt == dec + lat - 90 == 80 + 47.5 - 90 ==
            // 37.5 deg, same fixture reasoning `PlannerMonthTests` already
            // relies on).
            Combo(label: "always-up", latDeg: 47.5, lonDeg: 19.0, raDeg: 10.0, decDeg: 80.0, date: (2026, 8, 27), minAltitudeDeg: 30),
            // Deep southern declination, never clears the horizon at all from
            // a mid-northern site.
            Combo(label: "always-down", latDeg: 47.5, lonDeg: 19.0, raDeg: 10.0, decDeg: -70.0, date: (2026, 8, 27), minAltitudeDeg: 30),
            // Equatorial declination -- rises and sets within the night,
            // giving a genuine partial-overlap window to compare.
            Combo(label: "rise-and-set", latDeg: 47.5, lonDeg: 19.0, raDeg: 90.0, decDeg: 10.0, date: (2026, 8, 27), minAltitudeDeg: 30),
            // A different site/date/target entirely, and a lower altitude
            // gate, so the equivalence isn't an artifact of one particular
            // latitude or threshold.
            Combo(label: "different-site-and-threshold", latDeg: 35.0, lonDeg: -110.0, raDeg: 200.0, decDeg: 40.0, date: (2026, 12, 15), minAltitudeDeg: 20),
        ]

        for combo in combos {
            let referenceDate = utc(combo.date.0, combo.date.1, combo.date.2)
            let night = SunMoon.astronomicalTwilight(
                nightOf: referenceDate, latDeg: combo.latDeg, lonDeg: combo.lonDeg, timeZone: TimeZone(identifier: "UTC")!
            )
            let dusk = try #require(night.duskUTC, "no dusk resolved for combo \(combo.label)")
            let dawn = try #require(night.dawnUTC, "no dawn resolved for combo \(combo.label)")

            let old = oldOverlapSeconds(
                raDeg: combo.raDeg, decDeg: combo.decDeg, latDeg: combo.latDeg, lonDeg: combo.lonDeg,
                duskUTC: dusk, dawnUTC: dawn, minAltitudeDeg: combo.minAltitudeDeg
            )
            let new = newOverlapSeconds(
                raDeg: combo.raDeg, decDeg: combo.decDeg, latDeg: combo.latDeg, lonDeg: combo.lonDeg,
                duskUTC: dusk, dawnUTC: dawn, minAltitudeDeg: combo.minAltitudeDeg
            )

            #expect(old == new, "combo \(combo.label): old=\(old) new=\(new)")
        }
    }
}
