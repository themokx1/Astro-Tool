import AstroApplication
@testable import AstroCore
import Testing

/// Pre-flight Checklist ("Indulás előtti lista", ideation #1, usefulness
/// 5/5): `PreflightChecklist.build` synthesizes four facts `HomeStore`'s own
/// providers already compute -- calibration coverage, tonight's cloud
/// picture, the top tonight recommendation's own Moon verdict, and that same
/// recommendation's own visible-window start time -- into one ✓/✗/n-a ritual.
/// This suite exercises the pure composition directly (the same "extract the
/// pure decision, test it directly" shape `HomeStore.cloudOutlook`/
/// `HomeStore.composeHighlights` already use), with plain fixture values
/// rather than a real `HomeSnapshot` -- `AstroApplication` cannot depend on
/// `AstroUI`, where `HomeSnapshot` itself lives.
@Suite("Pre-flight checklist (ideation #1)")
struct PreflightChecklistTests {
    @Test("Everything current, clear, and moon-free collapses to one all-clear ritual")
    func allGreenIsAllClear() {
        let checklist = PreflightChecklist.build(
            calibrationMissingCount: 0,
            isCloudyTonight: false,
            topRecommendation: .init(
                displayName: "Elefántormány-köd", visibleWindow: "21:48–01:23", verdict: .goodTonight
            )
        )

        #expect(checklist.allClear)
        #expect(checklist.items.count == 4)
        #expect(checklist.items.allSatisfy { $0.status != .attention })
    }

    @Test("Stale calibration coverage is the one red line, and it is not honest to call this all-clear")
    func staleCalibrationIsARedLine() {
        let checklist = PreflightChecklist.build(
            calibrationMissingCount: 2,
            isCloudyTonight: false,
            topRecommendation: .init(
                displayName: "Elefántormány-köd", visibleWindow: "21:48–01:23", verdict: .goodTonight
            )
        )

        #expect(!checklist.allClear)
        let calibItem = checklist.items.first { if case .calibrationCurrent = $0.kind { true } else { false } }
        #expect(calibItem?.status == .attention)
        if case let .calibrationCurrent(missingCount) = calibItem?.kind {
            #expect(missingCount == 2)
        } else {
            Issue.record("Expected a .calibrationCurrent item")
        }
    }

    @Test("A cloudy tonight is a red sky line")
    func cloudyTonightIsARedLine() {
        let checklist = PreflightChecklist.build(
            calibrationMissingCount: 0,
            isCloudyTonight: true,
            topRecommendation: nil
        )

        let skyItem = checklist.items.first { $0.kind == .skyClear }
        #expect(skyItem?.status == .attention)
        #expect(!checklist.allClear)
    }

    @Test("No weather data at all is an honest n/a, never a red ✗")
    func missingWeatherIsNotApplicableNotAttention() {
        let checklist = PreflightChecklist.build(
            calibrationMissingCount: 0,
            isCloudyTonight: nil,
            topRecommendation: nil
        )

        let skyItem = checklist.items.first { $0.kind == .skyClear }
        #expect(skyItem?.status == .notApplicable)
        #expect(skyItem?.status != .attention)
    }

    @Test("A Moon-interferes verdict on tonight's top target is a red Moon line, carrying its own numbers")
    func moonInterferenceIsARedLineWithNumbers() {
        let checklist = PreflightChecklist.build(
            calibrationMissingCount: 0,
            isCloudyTonight: false,
            topRecommendation: .init(
                displayName: "M 42", visibleWindow: "20:00–23:00",
                verdict: .moonInterferes(separationDeg: 34, illuminationPercent: 62)
            )
        )

        let moonItem = checklist.items.first { if case .moonImpact = $0.kind { true } else { false } }
        #expect(moonItem?.status == .attention)
        if case let .moonImpact(separationDeg, illuminationPercent) = moonItem?.kind {
            #expect(separationDeg == 34)
            #expect(illuminationPercent == 62)
        } else {
            Issue.record("Expected a .moonImpact item")
        }
    }

    @Test("No tonight recommendation at all leaves the Moon and altitude lines an honest n/a")
    func noTonightRecommendationLeavesMoonAndAltitudeNotApplicable() {
        let checklist = PreflightChecklist.build(
            calibrationMissingCount: 0,
            isCloudyTonight: false,
            topRecommendation: nil
        )

        let moonItem = checklist.items.first { if case .moonImpact = $0.kind { true } else { false } }
        let altitudeItem = checklist.items.first { if case .altitudeWindow = $0.kind { true } else { false } }
        #expect(moonItem?.status == .notApplicable)
        #expect(altitudeItem?.status == .notApplicable)
        // n/a items never force a red state on their own.
        #expect(checklist.items.allSatisfy { $0.status != .attention })
    }

    @Test("The altitude line reads the exact start time already rendered in the top target's own visible window")
    func altitudeLineReadsTheVisibleWindowStart() {
        let checklist = PreflightChecklist.build(
            calibrationMissingCount: 0,
            isCloudyTonight: false,
            topRecommendation: .init(
                displayName: "IC 1396", visibleWindow: "21:48–01:23", verdict: .goodTonight
            )
        )

        let altitudeItem = checklist.items.first { if case .altitudeWindow = $0.kind { true } else { false } }
        #expect(altitudeItem?.status == .ready)
        if case let .altitudeWindow(targetDisplayName, clearsAtLocal) = altitudeItem?.kind {
            #expect(targetDisplayName == "IC 1396")
            #expect(clearsAtLocal == "21:48")
        } else {
            Issue.record("Expected a .altitudeWindow item")
        }
    }

    @Test("A top target with no visible window at all (never swept) leaves the altitude line an honest n/a")
    func topRecommendationWithNoVisibleWindowIsNotApplicable() {
        let checklist = PreflightChecklist.build(
            calibrationMissingCount: 0,
            isCloudyTonight: false,
            topRecommendation: .init(displayName: "IC 1396", visibleWindow: nil, verdict: .goodTonight)
        )

        let altitudeItem = checklist.items.first { if case .altitudeWindow = $0.kind { true } else { false } }
        #expect(altitudeItem?.status == .notApplicable)
    }

    @Test("displayOrder surfaces the failing lines first, keeping each group's own relative order")
    func displayOrderPutsFailingLinesFirst() {
        let checklist = PreflightChecklist.build(
            calibrationMissingCount: 3,
            isCloudyTonight: nil,
            topRecommendation: .init(
                displayName: "M 42", visibleWindow: "20:00–23:00",
                verdict: .moonInterferes(separationDeg: 34, illuminationPercent: 62)
            )
        )

        let order = checklist.displayOrder
        #expect(order.count == 4)
        // Calibration and Moon are the two failing lines here (sky is
        // n/a, altitude is ready) -- both must sort ahead of the rest,
        // in their own original relative order.
        #expect(order[0].kind == .calibrationCurrent(missingCount: 3))
        if case .moonImpact = order[1].kind {} else { Issue.record("Expected .moonImpact second") }
        // Every attention item precedes every non-attention item.
        let statuses = order.map(\.status)
        let firstNonAttention = statuses.firstIndex { $0 != .attention } ?? statuses.count
        #expect(statuses.prefix(firstNonAttention).allSatisfy { $0 == .attention })
    }

    // MARK: - Section 5.2 (Kalibrációs automata): `.flatNeeded` wired to real data

    @Test("The .flatNeeded item has a stable id")
    func flatNeededItemHasStableID() {
        let item = PreflightChecklist.Item(kind: .flatNeeded(missingCount: 3), status: .attention)
        #expect(item.id == "flatNeeded")
        if case let .flatNeeded(missingCount) = item.kind {
            #expect(missingCount == 3)
        } else {
            Issue.record("Expected a .flatNeeded item")
        }
    }

    @Test("Omitting flatMissingCount (every pre-5.2 call site) never produces a .flatNeeded item -- an honest 'nothing to say yet', not a silent .ready")
    func omittedFlatMissingCountNeverProducesFlatNeededItem() {
        let checklist = PreflightChecklist.build(
            calibrationMissingCount: 5,
            isCloudyTonight: true,
            topRecommendation: .init(
                displayName: "M 42", visibleWindow: "20:00–23:00",
                verdict: .moonInterferes(separationDeg: 10, illuminationPercent: 20)
            )
        )
        #expect(!checklist.items.contains { if case .flatNeeded = $0.kind { true } else { false } })
        #expect(checklist.items.count == 4)
    }

    @Test("A positive flatMissingCount adds a red .flatNeeded line")
    func positiveFlatMissingCountIsARedLine() {
        let checklist = PreflightChecklist.build(
            calibrationMissingCount: 0,
            isCloudyTonight: false,
            topRecommendation: .init(
                displayName: "Elefántormány-köd", visibleWindow: "21:48–01:23", verdict: .goodTonight
            ),
            flatMissingCount: 2
        )

        #expect(!checklist.allClear)
        #expect(checklist.items.count == 5)
        let flatItem = checklist.items.first { if case .flatNeeded = $0.kind { true } else { false } }
        #expect(flatItem?.status == .attention)
        if case let .flatNeeded(missingCount) = flatItem?.kind {
            #expect(missingCount == 2)
        } else {
            Issue.record("Expected a .flatNeeded item")
        }
    }

    @Test("A zero flatMissingCount adds a ready .flatNeeded line, not an attention one")
    func zeroFlatMissingCountIsReady() {
        let checklist = PreflightChecklist.build(
            calibrationMissingCount: 0,
            isCloudyTonight: false,
            topRecommendation: .init(
                displayName: "Elefántormány-köd", visibleWindow: "21:48–01:23", verdict: .goodTonight
            ),
            flatMissingCount: 0
        )

        #expect(checklist.allClear)
        let flatItem = checklist.items.first { if case .flatNeeded = $0.kind { true } else { false } }
        #expect(flatItem?.status == .ready)
    }
}
