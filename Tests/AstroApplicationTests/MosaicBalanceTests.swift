@testable import AstroApplication
import AstroCore
import Testing

/// W7-F item 2 (2026-08-18 expert audit, workflow #5): pure-logic tests for
/// `MosaicBalance` -- no `Database`/FITS fixture needed at all, since
/// `Panel` is a plain, publicly-constructible value and `MosaicBalance`
/// only ever compares `integrationSeconds` across an already-clustered
/// `[Panel]` (same-engine rule: the CLUSTERING itself is `FieldGeometry
/// .panels`'s own job, covered by `FieldGeometryTests`, not re-tested here).
private func panel(_ label: String, hours: Double) -> Panel {
    Panel(label: label, centerRaDeg: 0, centerDecDeg: 0, frameCount: 1, integrationSeconds: hours * 3600)
}

@Suite("MosaicBalance ledger (W7-F item 2)")
struct MosaicBalanceTests {
    // MARK: - deficits(panels:)

    @Test("A=5h/B=2.9h yields a 2.1h deficit for B and 0 for A -- the audit's own fixture numbers")
    func deficitsMatchAuditFixture() {
        let panels = [panel("A", hours: 5.0), panel("B", hours: 2.9)]
        let deficits = MosaicBalance.deficits(panels: panels)
        let byLabel = Dictionary(uniqueKeysWithValues: deficits.map { ($0.panel.label, $0.deficitSeconds) })
        #expect(byLabel["A"] == 0)
        #expect(abs((byLabel["B"] ?? -1) - 2.1 * 3600) < 0.01)
    }

    @Test("A single-panel report has no 'other panel' to be behind -- empty ledger")
    func singlePanelHasNoDeficits() {
        #expect(MosaicBalance.deficits(panels: [panel("A", hours: 3.0)]).isEmpty)
    }

    @Test("A perfectly balanced mosaic gives every panel a 0 deficit")
    func balancedPanelsHaveZeroDeficit() {
        let panels = [panel("A", hours: 3.0), panel("B", hours: 3.0)]
        let deficits = MosaicBalance.deficits(panels: panels)
        #expect(deficits.allSatisfy { $0.deficitSeconds == 0 })
    }

    @Test("Three panels are each measured against the SAME best panel, not against each other pairwise")
    func threePanelsAllMeasuredAgainstTheBest() {
        let panels = [panel("A", hours: 6.0), panel("B", hours: 4.0), panel("C", hours: 1.0)]
        let deficits = MosaicBalance.deficits(panels: panels)
        let byLabel = Dictionary(uniqueKeysWithValues: deficits.map { ($0.panel.label, $0.deficitSeconds) })
        #expect(byLabel["A"] == 0)
        #expect(abs((byLabel["B"] ?? -1) - 2.0 * 3600) < 0.01)
        #expect(abs((byLabel["C"] ?? -1) - 5.0 * 3600) < 0.01)
    }

    // MARK: - dominantGap(panels:) -- the "worth acting on" gate

    @Test("A=5h/B=2.9h (2.1h / 42% of best) clears the bar -- becomes the dominant gap")
    func auditFixtureClearsTheBar() throws {
        let panels = [panel("A", hours: 5.0), panel("B", hours: 2.9)]
        let gap = try #require(MosaicBalance.dominantGap(panels: panels))
        #expect(gap.panel.label == "B")
        #expect(abs(gap.deficitSeconds - 2.1 * 3600) < 0.01)
    }

    @Test("A balanced mosaic never produces a dominant gap")
    func balancedPanelsProduceNoDominantGap() {
        let panels = [panel("A", hours: 3.0), panel("B", hours: 3.0)]
        #expect(MosaicBalance.dominantGap(panels: panels) == nil)
    }

    @Test("A single-field report never produces a dominant gap")
    func singlePanelProducesNoDominantGap() {
        #expect(MosaicBalance.dominantGap(panels: [panel("A", hours: 3.0)]) == nil)
    }

    @Test("A tiny absolute deficit under a big project's relative bar stays quiet (6min vs. a 30h best panel is <1%, nowhere near 20%)")
    func tinyRelativeDeficitOnALargeProjectStaysQuiet() {
        let panels = [panel("A", hours: 30.0), panel("B", hours: 29.9)]
        #expect(MosaicBalance.dominantGap(panels: panels) == nil)
    }

    @Test("On a large project the relative (20%) bar is the larger, binding one -- a deficit just past it fires")
    func deficitPastTheDominantRelativeBarFires() throws {
        // Best = 10h (36000s). 20% of best = 2h (7200s), which is larger
        // than the flat 30-minute floor, so 7200s is the binding bar here.
        // A 2h05m (7500s) deficit clears it by 5 minutes.
        let panels = [panel("A", hours: 10.0), panel("B", hours: 10.0 - (7500.0 / 3600))]
        let gap = try #require(MosaicBalance.dominantGap(panels: panels))
        #expect(gap.panel.label == "B")
    }

    @Test("A deficit sitting exactly AT the larger bar does not exceed it -- the gate is strictly greater-than, never off-by-one lenient")
    func deficitExactlyAtTheBarDoesNotFire() {
        // Best = 1h (3600s). max(20% * 3600, 1800) = max(720, 1800) = 1800s
        // (the 30-minute absolute floor dominates here). A deficit of
        // EXACTLY 1800s must not fire.
        let panels = [panel("A", hours: 1.0), panel("B", hours: 1.0 - (1800.0 / 3600))]
        #expect(MosaicBalance.dominantGap(panels: panels) == nil)
    }

    @Test("A best panel with zero recorded integration has nothing to be a fraction of -- no dominant gap")
    func zeroIntegrationBestPanelProducesNoDominantGap() {
        let panels = [panel("A", hours: 0), panel("B", hours: 0)]
        #expect(MosaicBalance.dominantGap(panels: panels) == nil)
    }
}
