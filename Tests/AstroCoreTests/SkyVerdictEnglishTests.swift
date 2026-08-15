import Foundation
import Testing
@testable import AstroCore

/// V2 UI/UX audit (2026-08-15) section 4: `SkyVerdict`'s own vocabulary is
/// Hungarian (`Planner.plan`/`DiscoveryPlanner.discover` both still need it
/// exactly as-is -- V1 and the `astrotool` CLI read it today), but the V2
/// Planning/Home screens render it directly on an otherwise-English UI.
/// `SkyVerdict.english` is the single translation choke point both V2 call
/// sites (`PlanningQuery.recommendations()`, `HomeView`) use instead of
/// showing the raw Hungarian string -- these tests pin its whole closed
/// vocabulary, including the two parameterized cases, so a future wording
/// change to `SkyVerdict` itself cannot silently desync the translation.
@Suite("SkyVerdict.english")
struct SkyVerdictEnglishTests {
    @Test func translatesNoCoordinate() {
        #expect(SkyVerdict.english(SkyVerdict.noCoordinate) == "no coordinates")
    }

    @Test func translatesNotVisibleTonight() {
        #expect(SkyVerdict.english(SkyVerdict.notVisibleTonight) == "not visible tonight")
    }

    @Test func translatesGood() {
        #expect(SkyVerdict.english(SkyVerdict.good) == "good tonight")
    }

    @Test func translatesCometStaleCoordinate() {
        let english = SkyVerdict.english(SkyVerdict.cometStaleCoordinate)
        #expect(english == "comet -- stored coordinate is from capture time, not valid for tonight")
    }

    @Test func translatesTooLowPreservingTheAltitude() {
        #expect(SkyVerdict.english(SkyVerdict.tooLow(7)) == "low (max 7°)")
        #expect(SkyVerdict.english(SkyVerdict.tooLow(88.4)) == "low (max 88°)")
    }

    @Test func translatesMoonInterferesPreservingBothNumbers() {
        let hu = SkyVerdict.moonInterferes(separationDeg: 30, illuminationPercent: 88)
        #expect(SkyVerdict.english(hu) == "Moon interferes (30°, 88%)")
    }

    @Test func unrecognizedInputPassesThroughRatherThanHidingInformation() {
        #expect(SkyVerdict.english("already in English") == "already in English")
    }

    // MARK: - Structured parsing (localization pass's own seam)

    @Test func parsesEveryCaseIntoItsStructuredKind() {
        #expect(SkyVerdict.parse(SkyVerdict.noCoordinate) == .noCoordinates)
        #expect(SkyVerdict.parse(SkyVerdict.notVisibleTonight) == .notVisibleTonight)
        #expect(SkyVerdict.parse(SkyVerdict.good) == .goodTonight)
        #expect(SkyVerdict.parse(SkyVerdict.cometStaleCoordinate) == .cometStaleCoordinate)
        #expect(SkyVerdict.parse(SkyVerdict.tooLow(7)) == .lowAltitude(maxDeg: 7))
        #expect(
            SkyVerdict.parse(SkyVerdict.moonInterferes(separationDeg: 30, illuminationPercent: 88))
                == .moonInterferes(separationDeg: 30, illuminationPercent: 88)
        )
        #expect(SkyVerdict.parse("something else") == .unrecognized("something else"))
    }

    @Test func structuredKindsRenderTheSameEnglishAsTheStringConvenience() {
        #expect(SkyVerdictKind.lowAltitude(maxDeg: 7).english == "low (max 7°)")
        #expect(
            SkyVerdictKind.moonInterferes(separationDeg: 30, illuminationPercent: 88).english
                == "Moon interferes (30°, 88%)"
        )
        #expect(SkyVerdictKind.goodTonight.english == "good tonight")
    }
}
