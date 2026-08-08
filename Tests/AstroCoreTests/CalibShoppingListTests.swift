import Foundation
import Testing
@testable import AstroCore

/// `CalibShoppingList` is pure (no `Database` access) -- these tests build
/// `CalibNeed`/`TargetPlan` by hand, no fixture library/scan needed.

private func makeNeed(
    exposureSeconds: Double = 300,
    tempC: Double? = -10,
    targets: [String] = ["M31"],
    matchedMasterPath: String? = nil,
    isStale: Bool = false,
    todo: String? = "készíts 300 s / -10 °C darkot (5 light frame-hez)"
) -> CalibNeed {
    CalibNeed(
        kind: .dark,
        exposureSeconds: exposureSeconds,
        tempC: tempC,
        lightCount: 5,
        targets: targets,
        matchedMasterPath: matchedMasterPath,
        masterAgeDays: matchedMasterPath == nil ? nil : 45,
        isStale: isStale,
        todo: todo
    )
}

private func makePlan(target: String, verdict: String) -> TargetPlan {
    TargetPlan(target: target, usableIntegrationSeconds: 0, verdict: verdict, score: 0)
}

// MARK: - isObservableTonight

@Test func isObservableTonightAcceptsAPlainGoodVerdict() throws {
    #expect(CalibShoppingList.isObservableTonight(makePlan(target: "M31", verdict: "ma jó")))
}

@Test func isObservableTonightAcceptsAnNBAugmentedGoodVerdict() throws {
    #expect(CalibShoppingList.isObservableTonight(makePlan(target: "M31", verdict: "ma jó — Ha-ra")))
}

@Test func isObservableTonightAcceptsAMoonInterferenceVerdict() throws {
    #expect(CalibShoppingList.isObservableTonight(makePlan(target: "M31", verdict: "Hold zavar (12°, 82%)")))
}

@Test func isObservableTonightRejectsEveryOtherVerdict() throws {
    #expect(!CalibShoppingList.isObservableTonight(makePlan(target: "M31", verdict: "nincs koordináta")))
    #expect(!CalibShoppingList.isObservableTonight(makePlan(target: "M31", verdict: "alacsony (max 12°)")))
    #expect(!CalibShoppingList.isObservableTonight(makePlan(target: "M31", verdict: "nem látszik ma éjjel")))
}

// MARK: - build

@Test func buildIncludesAMissingComboUsedByATonightObservableTarget() throws {
    let need = makeNeed(targets: ["M31"], matchedMasterPath: nil)
    let plans = [makePlan(target: "M31", verdict: "ma jó")]
    let items = CalibShoppingList.build(coverage: [need], plans: plans)
    #expect(items.count == 1)
    #expect(items[0].targets == ["M31"])
    #expect(items[0].isStale == false)
}

@Test func buildIncludesAStaleComboUsedByATonightObservableTarget() throws {
    let need = makeNeed(targets: ["M31"], matchedMasterPath: "calibration_library/darks/300sec_-10deg", isStale: true, todo: "a(z) 300sec_-10deg dark 45 napos — készíts frisset")
    let plans = [makePlan(target: "M31", verdict: "ma jó")]
    let items = CalibShoppingList.build(coverage: [need], plans: plans)
    #expect(items.count == 1)
    #expect(items[0].isStale == true)
}

@Test func buildExcludesAFreshMatchedCombo() throws {
    let need = makeNeed(targets: ["M31"], matchedMasterPath: "calibration_library/darks/300sec_-10deg", isStale: false)
    let plans = [makePlan(target: "M31", verdict: "ma jó")]
    #expect(CalibShoppingList.build(coverage: [need], plans: plans).isEmpty)
}

@Test func buildExcludesATargetThatIsNotObservableTonight() throws {
    let need = makeNeed(targets: ["M31"], matchedMasterPath: nil)
    let plans = [makePlan(target: "M31", verdict: "nincs koordináta")]
    #expect(CalibShoppingList.build(coverage: [need], plans: plans).isEmpty)
}

@Test func buildKeepsOnlyTheTonightObservableSubsetOfACombosTargets() throws {
    let need = makeNeed(targets: ["M31", "M42", "M45"], matchedMasterPath: nil)
    let plans = [
        makePlan(target: "M31", verdict: "ma jó"),
        makePlan(target: "M42", verdict: "nincs koordináta"),
        makePlan(target: "M45", verdict: "Hold zavar (10°, 90%)"),
    ]
    let items = CalibShoppingList.build(coverage: [need], plans: plans)
    #expect(items.count == 1)
    #expect(items[0].targets == ["M31", "M45"])
}

@Test func buildReturnsEmptyWhenNoTargetIsObservableTonightAtAll() throws {
    let need = makeNeed(targets: ["M31"], matchedMasterPath: nil)
    let plans = [makePlan(target: "M31", verdict: "nincs koordináta")]
    #expect(CalibShoppingList.build(coverage: [need], plans: plans).isEmpty)
}

@Test func buildSortsMissingCombosBeforeStaleOnesThenByExposureDescending() throws {
    let stale = makeNeed(exposureSeconds: 600, targets: ["M31"], matchedMasterPath: "x", isStale: true, todo: "stale todo")
    let missingShort = makeNeed(exposureSeconds: 60, targets: ["M31"], matchedMasterPath: nil, todo: "missing short")
    let missingLong = makeNeed(exposureSeconds: 300, targets: ["M31"], matchedMasterPath: nil, todo: "missing long")
    let plans = [makePlan(target: "M31", verdict: "ma jó")]

    let items = CalibShoppingList.build(coverage: [stale, missingShort, missingLong], plans: plans)
    #expect(items.map(\.exposureSeconds) == [300, 60, 600])
}

// MARK: - Item.summary / markdown

@Test func itemSummaryAppendsTheAffectedTonightTargets() throws {
    let need = makeNeed(targets: ["M31", "M42"], matchedMasterPath: nil, todo: "készíts 300 s / -10 °C darkot (5 light frame-hez)")
    let plans = [makePlan(target: "M31", verdict: "ma jó"), makePlan(target: "M42", verdict: "ma jó")]
    let items = CalibShoppingList.build(coverage: [need], plans: plans)
    #expect(items[0].summary == "készíts 300 s / -10 °C darkot (5 light frame-hez) — M31, M42 használná")
}

@Test func markdownRendersOneCheckboxBulletPerItem() throws {
    let need1 = makeNeed(exposureSeconds: 300, targets: ["M31"], matchedMasterPath: nil, todo: "todo A")
    let need2 = makeNeed(exposureSeconds: 60, targets: ["M31"], matchedMasterPath: nil, todo: "todo B")
    let plans = [makePlan(target: "M31", verdict: "ma jó")]
    let items = CalibShoppingList.build(coverage: [need1, need2], plans: plans)
    let markdown = CalibShoppingList.markdown(items)
    #expect(markdown == "- [ ] todo A — M31 használná\n- [ ] todo B — M31 használná")
}

@Test func markdownIsEmptyForAnEmptyList() throws {
    #expect(CalibShoppingList.markdown([]).isEmpty)
}
