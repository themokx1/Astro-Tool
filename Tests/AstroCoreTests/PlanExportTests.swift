import Foundation
import Testing
@testable import AstroCore

/// `PlanExport` is pure (no `Database`/filesystem access) -- these tests
/// build `TargetPlan`s by hand via its public memberwise `init`, no fixture
/// library/scan needed.

private func makePlan(
    target: String = "M42_Orion",
    displayName: String? = nil,
    raDeg: Double? = 83.822,
    decDeg: Double? = -5.391,
    usableIntegrationSeconds: Double = 3600,
    visibleWindowLocal: String? = "20:15–01:40",
    maxAltitudeDeg: Double? = 62.4,
    moonIlluminationPercent: Double? = 34.0,
    verdict: String = "ma jó",
    filterGoals: [FilterIntegration] = [],
    filterAdvice: FilterAdvisor.Advice? = nil
) -> TargetPlan {
    TargetPlan(
        target: target,
        displayName: displayName,
        raDeg: raDeg,
        decDeg: decDeg,
        usableIntegrationSeconds: usableIntegrationSeconds,
        maxAltitudeDeg: maxAltitudeDeg,
        visibleWindowLocal: visibleWindowLocal,
        moonIlluminationPercent: moonIlluminationPercent,
        verdict: verdict,
        score: 1,
        filterGoals: filterGoals,
        filterAdvice: filterAdvice
    )
}

// MARK: - renderCSV

@Test func renderCSVStartsWithTheSpecColumnHeader() throws {
    let csv = PlanExport.renderCSV([])
    #expect(csv.hasPrefix("target,ra_deg,dec_deg,window_start,window_end,max_alt_deg,moon_illum,verdict,filter_suggestion\n"))
}

@Test func renderCSVUsesTheRawTargetNameNotDisplayName() throws {
    let plan = makePlan(target: "M42_Orion", displayName: "M 42 · Orion-köd")
    let csv = PlanExport.renderCSV([plan])
    let lines = csv.components(separatedBy: "\n")
    #expect(lines[1].hasPrefix("M42_Orion,"))
}

@Test func renderCSVSplitsTheVisibleWindowIntoStartAndEndColumns() throws {
    let plan = makePlan(visibleWindowLocal: "20:15–01:40")
    let csv = PlanExport.renderCSV([plan])
    let fields = csv.components(separatedBy: "\n")[1].components(separatedBy: ",")
    // target, ra_deg, dec_deg, window_start, window_end, ...
    #expect(fields[3] == "20:15")
    #expect(fields[4] == "01:40")
}

@Test func renderCSVLeavesWindowColumnsEmptyWhenTargetIsNeverVisible() throws {
    let plan = makePlan(visibleWindowLocal: nil)
    let csv = PlanExport.renderCSV([plan])
    let fields = csv.components(separatedBy: "\n")[1].components(separatedBy: ",")
    #expect(fields[3] == "")
    #expect(fields[4] == "")
}

@Test func renderCSVCarriesTheFilterSuggestionWhenTheTargetHasFilterGoals() throws {
    let goals = [
        FilterIntegration(filter: "Ha", usableFrameCount: 10, integrationSeconds: 8 * 3600, goalSeconds: 12 * 3600, missingSeconds: 4 * 3600),
    ]
    let advice = FilterAdvisor.advice(
        moonIlluminationPercent: 82, moonSeparationDeg: 90, filterGoals: goals, narrowbandFilters: AstroConfig().plan.narrowbandFilters
    )
    let plan = makePlan(filterGoals: goals, filterAdvice: advice)
    let csv = PlanExport.renderCSV([plan])
    #expect(csv.contains("Ha (-4,0h)"))
}

@Test func renderCSVLeavesFilterSuggestionEmptyWithoutFilterGoals() throws {
    let plan = makePlan()
    let csv = PlanExport.renderCSV([plan])
    let fields = csv.components(separatedBy: "\n")[1].components(separatedBy: ",")
    #expect(fields.last == "")
}

@Test func renderCSVProducesOneRowPerPlanInOrder() throws {
    let plans = [makePlan(target: "A"), makePlan(target: "B"), makePlan(target: "C")]
    let csv = PlanExport.renderCSV(plans)
    let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }
    #expect(lines.count == 4) // header + 3 rows
    #expect(lines[1].hasPrefix("A,"))
    #expect(lines[2].hasPrefix("B,"))
    #expect(lines[3].hasPrefix("C,"))
}

// MARK: - renderClipboardText

@Test func renderClipboardTextUsesDisplayNameAndHMSDMSCoordinates() throws {
    // dec=-5.391 -> "-05°..."; RA in degrees=83.822 -> ~05h35m
    let plan = makePlan(target: "M42_Orion", displayName: "M 42 · Orion-köd", raDeg: 83.822, decDeg: -5.391)
    let text = PlanExport.renderClipboardText([plan])
    #expect(text.contains("M 42 · Orion-köd"))
    #expect(text.contains("05h"))
    #expect(text.contains("-05°"))
}

@Test func renderClipboardTextUsesDashForMissingCoordinatesAndWindow() throws {
    let plan = makePlan(raDeg: nil, decDeg: nil, visibleWindowLocal: nil)
    let text = PlanExport.renderClipboardText([plan])
    let dataLine = text.components(separatedBy: "\n")[1]
    let fields = dataLine.components(separatedBy: "\t")
    #expect(fields[1] == "-")
    #expect(fields[2] == "-")
    #expect(fields[3] == "-")
    #expect(fields[4] == "-")
}

@Test func renderClipboardTextStartsWithAHungarianHeaderRow() throws {
    let text = PlanExport.renderClipboardText([])
    #expect(text == "Célpont\tRA\tDec\tLáthatósági ablak\tJavasolt szűrő")
}
