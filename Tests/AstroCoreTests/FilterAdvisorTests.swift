import Foundation
import Testing
@testable import AstroCore

/// `FilterAdvisor` is pure (no `Database` access) -- these tests build
/// `[FilterIntegration]` by hand, no fixture library/scan needed.

private let defaultNarrowbandFilters = AstroConfig().plan.narrowbandFilters

// MARK: - advice: sky-state threshold rule

@Test func adviceMarksNarrowbandNightWhenMoonIsBrightRegardlessOfSeparation() throws {
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 82, moonSeparationDeg: 90, filterGoals: [], narrowbandFilters: defaultNarrowbandFilters
    )
    #expect(advice.skyState == .narrowband)
    #expect(advice.label == "keskenysáv-éjszaka")
}

@Test func adviceMarksNarrowbandNightWhenSeparationIsCloseRegardlessOfIllumination() throws {
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 10, moonSeparationDeg: 41, filterGoals: [], narrowbandFilters: defaultNarrowbandFilters
    )
    #expect(advice.skyState == .narrowband)
}

@Test func adviceMarksDarkNightWhenIlluminationLowAndSeparationFar() throws {
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 10, moonSeparationDeg: 90, filterGoals: [], narrowbandFilters: defaultNarrowbandFilters
    )
    #expect(advice.skyState == .dark)
    #expect(advice.label == "sötét ég")
}

@Test func adviceReasonNamesIlluminationAndSeparation() throws {
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 82, moonSeparationDeg: 41, filterGoals: [], narrowbandFilters: defaultNarrowbandFilters
    )
    #expect(advice.reason.contains("82"))
    #expect(advice.reason.contains("41"))
}

// MARK: - advice: recommended filter by category

@Test func adviceRecommendsBiggestNBDeficitOnNarrowbandNight() throws {
    let goals = [
        FilterIntegration(filter: "Ha", usableFrameCount: 10, integrationSeconds: 8 * 3600, goalSeconds: 12 * 3600, missingSeconds: 4 * 3600),
        FilterIntegration(filter: "L", usableFrameCount: 5, integrationSeconds: 2 * 3600, goalSeconds: 12 * 3600, missingSeconds: 10 * 3600),
    ]
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 82, moonSeparationDeg: 90, filterGoals: goals, narrowbandFilters: defaultNarrowbandFilters
    )
    // Narrowband night: even though "L" has the bigger absolute deficit, it's
    // a broadband filter -- the NB category's own biggest deficit (Ha) wins.
    #expect(advice.recommendedFilter?.filter == "Ha")
}

@Test func adviceRecommendsBiggestBBDeficitOnDarkNight() throws {
    let goals = [
        FilterIntegration(filter: "Ha", usableFrameCount: 10, integrationSeconds: 8 * 3600, goalSeconds: 12 * 3600, missingSeconds: 4 * 3600),
        FilterIntegration(filter: "L", usableFrameCount: 5, integrationSeconds: 2 * 3600, goalSeconds: 12 * 3600, missingSeconds: 10 * 3600),
    ]
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 10, moonSeparationDeg: 90, filterGoals: goals, narrowbandFilters: defaultNarrowbandFilters
    )
    #expect(advice.recommendedFilter?.filter == "L")
}

@Test func adviceReturnsNilRecommendedFilterWhenThereAreNoFilterGoalsAtAll() throws {
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 82, moonSeparationDeg: 90, filterGoals: [], narrowbandFilters: defaultNarrowbandFilters
    )
    #expect(advice.recommendedFilter == nil)
}

@Test func adviceReturnsNilRecommendedFilterWhenTheCategoryHasNoOutstandingDeficit() throws {
    // Only an already-met NB goal exists -- narrowband night still has
    // nothing left to recommend.
    let goals = [
        FilterIntegration(filter: "Ha", usableFrameCount: 20, integrationSeconds: 12 * 3600, goalSeconds: 12 * 3600, missingSeconds: 0),
    ]
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 82, moonSeparationDeg: 90, filterGoals: goals, narrowbandFilters: defaultNarrowbandFilters
    )
    #expect(advice.recommendedFilter == nil)
}

@Test func adviceHonorsACustomNarrowbandFiltersList() throws {
    // With "L" reclassified as narrowband via config, a narrowband night
    // must recommend it instead of "Ha".
    let goals = [
        FilterIntegration(filter: "Ha", usableFrameCount: 10, integrationSeconds: 8 * 3600, goalSeconds: 12 * 3600, missingSeconds: 4 * 3600),
        FilterIntegration(filter: "L", usableFrameCount: 5, integrationSeconds: 2 * 3600, goalSeconds: 12 * 3600, missingSeconds: 10 * 3600),
    ]
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 82, moonSeparationDeg: 90, filterGoals: goals, narrowbandFilters: ["L"]
    )
    #expect(advice.recommendedFilter?.filter == "L")
}

// MARK: - isNarrowbandByIlluminationAlone

@Test func isNarrowbandByIlluminationAloneMatchesTheAdviceThreshold() throws {
    #expect(FilterAdvisor.isNarrowbandByIlluminationAlone(moonIlluminationPercent: 41) == true)
    #expect(FilterAdvisor.isNarrowbandByIlluminationAlone(moonIlluminationPercent: 40) == false)
    #expect(FilterAdvisor.isNarrowbandByIlluminationAlone(moonIlluminationPercent: 5) == false)
}

// MARK: - chipText

@Test func chipTextReturnsNilWhenTargetHasNoFilterGoalsAtAll() throws {
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 82, moonSeparationDeg: 90, filterGoals: [], narrowbandFilters: defaultNarrowbandFilters
    )
    #expect(FilterAdvisor.chipText(advice: advice, filterGoals: []) == nil)
}

@Test func chipTextShowsTheRecommendedFilterWithItsDeficitInHours() throws {
    let goals = [
        FilterIntegration(filter: "Ha", usableFrameCount: 10, integrationSeconds: 8 * 3600, goalSeconds: 12 * 3600, missingSeconds: 4 * 3600),
    ]
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 82, moonSeparationDeg: 90, filterGoals: goals, narrowbandFilters: defaultNarrowbandFilters
    )
    #expect(FilterAdvisor.chipText(advice: advice, filterGoals: goals) == "Ha (-4,0h)")
}

@Test func chipTextJoinsFilterNamesWhenTheCategoryHasNoOutstandingDeficit() throws {
    let goals = [
        FilterIntegration(filter: "Ha", usableFrameCount: 20, integrationSeconds: 12 * 3600, goalSeconds: 12 * 3600, missingSeconds: 0),
        FilterIntegration(filter: "SII", usableFrameCount: 20, integrationSeconds: 12 * 3600, goalSeconds: 12 * 3600, missingSeconds: 0),
    ]
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 82, moonSeparationDeg: 90, filterGoals: goals, narrowbandFilters: defaultNarrowbandFilters
    )
    #expect(FilterAdvisor.chipText(advice: advice, filterGoals: goals) == "Ha/SII")
}

// MARK: - augmentedVerdict

@Test func augmentedVerdictAppendsTheRecommendedFilterOnAGoodNarrowbandNight() throws {
    let goals = [
        FilterIntegration(filter: "Ha", usableFrameCount: 10, integrationSeconds: 8 * 3600, goalSeconds: 12 * 3600, missingSeconds: 4 * 3600),
    ]
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 82, moonSeparationDeg: 90, filterGoals: goals, narrowbandFilters: defaultNarrowbandFilters
    )
    #expect(FilterAdvisor.augmentedVerdict(baseVerdict: "ma jó", advice: advice) == "ma jó — Ha-ra")
}

/// `OIII`'s last vowel is a front `i` -- must get the "-re" suffix, not
/// "-ra".
@Test func augmentedVerdictUsesFrontVowelSuffixForOIII() throws {
    let goals = [
        FilterIntegration(filter: "OIII", usableFrameCount: 10, integrationSeconds: 8 * 3600, goalSeconds: 12 * 3600, missingSeconds: 4 * 3600),
    ]
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 82, moonSeparationDeg: 90, filterGoals: goals, narrowbandFilters: defaultNarrowbandFilters
    )
    #expect(FilterAdvisor.augmentedVerdict(baseVerdict: "ma jó", advice: advice) == "ma jó — OIII-re")
}

@Test func augmentedVerdictLeavesNonGoodVerdictsUntouched() throws {
    let goals = [
        FilterIntegration(filter: "Ha", usableFrameCount: 10, integrationSeconds: 8 * 3600, goalSeconds: 12 * 3600, missingSeconds: 4 * 3600),
    ]
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 82, moonSeparationDeg: 90, filterGoals: goals, narrowbandFilters: defaultNarrowbandFilters
    )
    let verdict = "Hold zavar (12°, 82%)"
    #expect(FilterAdvisor.augmentedVerdict(baseVerdict: verdict, advice: advice) == verdict)
}

@Test func augmentedVerdictLeavesGoodVerdictUntouchedOnADarkNight() throws {
    let goals = [
        FilterIntegration(filter: "Ha", usableFrameCount: 10, integrationSeconds: 8 * 3600, goalSeconds: 12 * 3600, missingSeconds: 4 * 3600),
    ]
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 10, moonSeparationDeg: 90, filterGoals: goals, narrowbandFilters: defaultNarrowbandFilters
    )
    #expect(FilterAdvisor.augmentedVerdict(baseVerdict: "ma jó", advice: advice) == "ma jó")
}

@Test func augmentedVerdictLeavesGoodVerdictUntouchedWithoutAnyFilterGoals() throws {
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 82, moonSeparationDeg: 90, filterGoals: [], narrowbandFilters: defaultNarrowbandFilters
    )
    #expect(FilterAdvisor.augmentedVerdict(baseVerdict: "ma jó", advice: advice) == "ma jó")
}
