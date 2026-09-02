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

    // MARK: - v5 flow review, I2: the A -> B -> A selection sequence.

    /// The decisions the three requests get, in order, with A's own run
    /// still in flight for the third one. The third is `.skipDuplicate` --
    /// which is correct, and exactly why that branch may not simply return:
    /// A's own runner has been made stale by B's generation bump, so this
    /// duplicate is the only request left that can publish A's outcome.
    @Test("Selecting A, then B, then A again while A still runs makes the third request the only one that can publish")
    func theThirdRequestIsTheDuplicateThatMustAdopt() {
        let aRun = UUID()
        let aKind = OperationKind.loadHome(library: "Astro")
        let bKind = OperationKind.loadHome(library: "Backup")

        // 1. Nothing in flight: A starts.
        #expect(LibraryPreparationGate.decision(preparing: aKind, activeOperations: []) == .start)

        let aInFlight = [operation(kind: aKind, id: aRun)]
        // 2. B waits A out rather than running alongside it.
        #expect(LibraryPreparationGate.decision(preparing: bKind, activeOperations: aInFlight) == .waitFor(aRun))
        // 3. A again, with A's run still going: a duplicate, and the run it
        //    must adopt is findable by kind alone.
        #expect(LibraryPreparationGate.decision(preparing: aKind, activeOperations: aInFlight) == .skipDuplicate)
        #expect(aInFlight.first(where: { $0.kind == aKind })?.id == aRun)
    }

    /// The seam `adoptRunningPreparation` stands on: a second, later caller
    /// awaiting the SAME operation must get its real settled phase, both
    /// while it is still running and after it has already settled.
    @Test("A second awaiter of the same operation gets the same settled outcome")
    func outcomeCanBeAdoptedByASecondAwaiter() async {
        let host = OperationHost(center: OperationCenter())
        let id = await host.run(
            kind: .loadHome(library: "Astro"), title: "Preparing Astro", cancellation: .unavailable
        ) {}

        async let first = host.outcome(of: id)
        async let second = host.outcome(of: id)
        let (firstPhase, secondPhase) = await (first, second)
        #expect(firstPhase == .succeeded)
        #expect(secondPhase == .succeeded)

        // Adopting after the fact works too -- the duplicate request may
        // only reach its await once the run has already finished.
        #expect(await host.outcome(of: id) == .succeeded)
    }

    @Test("An adopted failure is reported as a failure, not silently swallowed")
    func adoptedFailureKeepsItsPhaseAndMessage() async {
        struct PreparationFailure: Error, LocalizedError {
            var errorDescription: String? { "Projects could not be built." }
        }
        let host = OperationHost(center: OperationCenter())
        let id = await host.run(
            kind: .loadHome(library: "Astro"), title: "Preparing Astro", cancellation: .unavailable
        ) {
            throw PreparationFailure()
        }

        #expect(await host.outcome(of: id) == .failed)
        #expect(await host.errorMessage(for: id) == "Projects could not be built.")
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
