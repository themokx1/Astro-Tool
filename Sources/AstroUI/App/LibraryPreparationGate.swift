import AstroApplication
import Foundation

/// What `V2RootView.prepareLibrary` should do about the library preparations
/// already in flight -- factored out of the view purely so the decision is
/// unit-testable without a SwiftUI host (`LibraryPreparationTests`).
///
/// v5 library-switch fixes (item 1): `prepareLibrary` used to dedupe against
/// its OWN `OperationKind.loadHome(library:)` key. Preparing library B while
/// A was still preparing -- which is exactly what happens when the
/// `.task(id:)` re-fires on a new library summary -- compared B's key against
/// A's, found no match, and started a SECOND concurrent preparation: two
/// `ScanWorkflowMaterializer` passes, two `projectsStore.open`/
/// `nightsStore.open`/`homeStore.configure` pipelines, and two sets of shell
/// state writes racing each other. Preparation is exclusive per window, so
/// the gate reads `OperationKind.isLoadingLibrary` rather than one key.
enum LibraryPreparationGate {
    enum Decision: Equatable {
        /// No library is being prepared -- go ahead.
        case start
        /// This exact library is ALREADY being prepared. Nothing to do, and
        /// deliberately distinct from `waitFor`: a duplicate request must
        /// not invalidate the preparation that is already running (see
        /// `prepareLibrary`'s own generation handling).
        case skipDuplicate
        /// A DIFFERENT library is still preparing. Wait for that operation
        /// to settle first rather than running two pipelines at once; by
        /// then a newer request may have superseded this one, which is what
        /// the caller's generation check is for.
        case waitFor(UUID)
    }

    static func decision(
        preparing kind: OperationKind,
        activeOperations: [OperationHost.ActiveOperation]
    ) -> Decision {
        guard let running = activeOperations.first(where: { $0.kind.isLoadingLibrary }) else { return .start }
        return running.kind == kind ? .skipDuplicate : .waitFor(running.id)
    }
}
