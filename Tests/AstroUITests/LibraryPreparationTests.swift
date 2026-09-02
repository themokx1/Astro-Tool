@testable import AstroUI
import AstroApplication
import Foundation
import Testing

/// v5 library-switch fixes, item 1: `V2RootView.prepareLibrary` deduped on
/// `OperationKind.loadHome(library:)` -- its OWN library's key. Preparing
/// library B while A was still preparing (the `.task(id:)` re-fires the
/// moment a new summary lands) therefore passed that guard and started a
/// SECOND concurrent preparation: two `ScanWorkflowMaterializer` passes,
/// two `projectsStore.open`/`nightsStore.open`/`homeStore.configure`
/// pipelines, and two sets of shell-state writes racing each other.
///
/// The decision itself is factored into `LibraryPreparationGate` so it is
/// testable without a SwiftUI host; the wiring half is pinned by
/// `LibrarySwitchRobustnessSurfaceTests`.
@MainActor
@Suite("Library preparation gate")
struct LibraryPreparationTests {
    private func operation(kind: OperationKind, id: UUID = UUID()) -> OperationHost.ActiveOperation {
        OperationHost.ActiveOperation(
            id: id, kind: kind, title: "Preparing", cancellationPolicy: .unavailable,
            phase: .running, completed: 0, total: nil
        )
    }

    @Test("With nothing in flight the preparation just starts")
    func nothingInFlightStarts() {
        let decision = LibraryPreparationGate.decision(
            preparing: .loadHome(library: "Astro"), activeOperations: []
        )
        #expect(decision == .start)
    }

    @Test("Unrelated operations do not hold a preparation back")
    func unrelatedOperationsDoNotBlock() {
        let decision = LibraryPreparationGate.decision(
            preparing: .loadHome(library: "Astro"),
            activeOperations: [
                operation(kind: .scan(library: "Astro")),
                operation(kind: .audit(library: "Astro")),
                operation(kind: .rate(series: "all-projects-Astro")),
            ]
        )
        #expect(decision == .start)
    }

    @Test("A second request for the library already being prepared is refused")
    func duplicateRequestForTheSameLibraryIsRefused() {
        let decision = LibraryPreparationGate.decision(
            preparing: .loadHome(library: "Astro"),
            activeOperations: [operation(kind: .loadHome(library: "Astro"))]
        )
        #expect(decision == .skipDuplicate)
    }

    @Test("Another library's preparation is waited out instead of run alongside")
    func anotherLibrarysPreparationIsWaitedOut() {
        let inFlight = UUID()
        let decision = LibraryPreparationGate.decision(
            preparing: .loadHome(library: "Backup"),
            activeOperations: [operation(kind: .loadHome(library: "Astro"), id: inFlight)]
        )
        // The exact bug: this used to be `.start`, because the dedupe guard
        // compared against `loadHome(library: "Backup")` only.
        #expect(decision == .waitFor(inFlight))
    }

    @Test("isLoadingLibrary answers for every loadHome key and nothing else")
    func isLoadingLibraryCoversOnlyLoadHome() {
        #expect(OperationKind.loadHome(library: "Astro").isLoadingLibrary)
        #expect(OperationKind.loadHome(library: "Backup").isLoadingLibrary)
        #expect(!OperationKind.scan(library: "Astro").isLoadingLibrary)
        #expect(!OperationKind.audit(library: "Astro").isLoadingLibrary)
        #expect(!OperationKind.catalogFetch.isLoadingLibrary)
    }

    @Test("The gate waits for the FIRST library preparation it finds, so a chain of waiters resolves in one order")
    func waitTargetsTheOperationThatIsActuallyRunning() async {
        let host = OperationHost(center: OperationCenter())
        let id = await host.run(
            kind: .loadHome(library: "Astro"), title: "Preparing Astro", cancellation: .unavailable
        ) {}
        await host.settle()

        // Once it has settled it is gone from `activeOperations`, so a
        // later preparation is not held back by a finished one.
        #expect(!host.activeOperations.contains { $0.id == id })
        #expect(
            LibraryPreparationGate.decision(
                preparing: .loadHome(library: "Backup"), activeOperations: host.activeOperations
            ) == .start
        )
    }
}
