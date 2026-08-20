import Foundation
import Testing

/// OWNER BUG (2026-08-19 real-library audit): the owner's own words on the
/// Insights screen, "1 mért capture — a trendhez több mérés kell, erre kell
/// valami gomb, akár ide a felületre" ("more measurements are needed for a
/// trend, there needs to be some button, maybe right here"). This is a
/// source-string surface check, the same shape `NightActionMenuTests`
/// already uses for `FrameRatingCommand` wiring: `InsightsView` is a
/// SwiftUI view with no host-independent way to drive it headlessly, so
/// this asserts the "Start Measuring" action is wired to a REAL
/// `ProjectRatingRunner.run(..., mode: .fullReMeasure, ...)` call (never an
/// inert stub), and that it reuses `OperationHost`/`ProjectRatingRunner.
/// kind(for:)` the exact same way `HomeView`'s "Rate Everything" gate card
/// already does, rather than inventing a second rating path.
@Suite("Insights Start Measuring button")
struct InsightsStartMeasuringSurfaceTests {
    private func read(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("Start Measuring is bound to a real .fullReMeasure ProjectRatingRunner call, not a disabled stub")
    func startMeasuringIsWiredToFullReMeasure() throws {
        let view = try read("Sources/AstroUI/Features/Insights/InsightsView.swift")

        #expect(view.contains("Button(\"Start Measuring\", action: startMeasuring)"))
        #expect(view.contains("private func startMeasuring()"))
        #expect(view.contains("await ProjectRatingRunner.run("))
        #expect(view.contains("mode: .fullReMeasure"))
        #expect(view.contains("metadataFactory: ProjectsStore.productionMetadata"))
        #expect(view.contains("v2.insights.start-measuring"))

        // No inert stub -- same guard `NightActionMenuTests` applies.
        #expect(!view.contains(".disabled(true)"))
    }

    @Test("The FWHM and Background trend blockers are distinguished, never one conflated hint")
    func fwhmAndBackgroundHintsAreDistinct() throws {
        let view = try read("Sources/AstroUI/Features/Insights/InsightsView.swift")

        #expect(view.contains("private func fwhmMeasurementHint"))
        #expect(view.contains("v2.insights.fwhm-measurement-hint"))
        #expect(view.contains("v2.insights.sensor-profile-hint"))
        #expect(view.contains("store.sensorProfileMeasured"))
        // The FWHM hint fires on point-count sparsity alone, independent of
        // `unratedNightCount` -- the owner's own "1 mért capture" case had
        // `captureTrendPoints.isEmpty == false`, so gating only on emptiness
        // (the pre-fix condition) would have stayed silent for him.
        #expect(view.contains("if fwhmPoints.count < 2 {"))
    }

    @Test("Progress from an in-flight measuring run reuses OperationHost, keyed the same way Home's own card is")
    func measuringProgressReusesOperationHostKind() throws {
        let view = try read("Sources/AstroUI/Features/Insights/InsightsView.swift")

        #expect(view.contains("private var measuringOperation: OperationHost.ActiveOperation?"))
        #expect(view.contains("ProjectRatingRunner.kind(for: .allProjects(libraryName: rootURL.lastPathComponent))"))
        #expect(view.contains("v2.insights.measure-progress"))
        // Reloads the snapshot once the run this screen started finishes, so
        // the just-filled trends actually appear without navigating away.
        #expect(view.contains(".onChange(of: operationHost.activeOperations)"))
    }
}
