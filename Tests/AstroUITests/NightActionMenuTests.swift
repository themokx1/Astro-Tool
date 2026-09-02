@testable import AstroUI
import AstroApplication
import Foundation
import Testing

/// Source-string surface checks, the same shape `V2WorkspaceParitySurfaceTests`
/// already uses throughout this suite: `NightActionMenu` is a SwiftUI view
/// with no host-independent way to drive a real context menu headlessly, so
/// this asserts every action is wired to a REAL handler (not a stub) by
/// reading the source directly, and that every row surface (`NightsView`,
/// the night workspace toolbar, the project workspace's Nights tab) actually
/// wires the shared menu in rather than reimplementing its own subset.
@Suite("V2 Night action menu")
struct NightActionMenuTests {
    private func read(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("Every listed action is bound to a real handler, not a disabled stub")
    func everyActionHasARealHandler() throws {
        let menu = try read("Sources/AstroUI/Features/Nights/NightActionMenu.swift")

        #expect(menu.contains("public struct NightActionMenu"))
        #expect(menu.contains("Button(\"Open Night\""))
        #expect(menu.contains("Button(\"Reveal in Finder\", systemImage: \"folder\", action: revealInFinder)"))
        #expect(menu.contains("Button(\"Edit Night Notes…\", systemImage: \"note.text\", action: editNotes)"))
        #expect(menu.contains("Button(\"Open Calibration…\", systemImage: \"camera.filters\", action: openCalibration)"))
        #expect(menu.contains("Button(\"Rate Frames\", systemImage: \"star.leadinghalf.filled\", action: rateFrames)"))
        #expect(menu.contains("Button(\"Open in Insights\""))
        #expect(menu.contains("openInsights(setupDescriptor)"))
        #expect(menu.contains("NSWorkspace.shared.activateFileViewerSelecting"))
        // W5-1: "Night Report…" is gone -- the owner's own words, "tünjenek
        // el az exportálás file-ba gombok". Its content lives natively in
        // `NightWorkspaceView`'s Overview tab now (`NightReportQuery`).
        #expect(!menu.contains("Night Report"))
        #expect(!menu.contains("exportNightReport"))
        #expect(menu.contains("FrameRatingCommand.production(rootURL: rootURL)"))
        #expect(menu.contains("command.run("))
        #expect(menu.contains("v2.nights.action-menu"))

        // No inert stubs anywhere in the menu.
        #expect(!menu.contains(".disabled(true)"))
        #expect(!menu.contains("action: {}"))
        #expect(!menu.contains("action: { }"))
    }

    @Test("Reveal in Finder resolves the night's own on-disk path with containment, never a bare join")
    func revealInFinderIsContainmentChecked() throws {
        let menu = try read("Sources/AstroUI/Features/Nights/NightActionMenu.swift")
        #expect(menu.contains("FrameThumbnailCell.resolvedURL(rootURL: rootURL, relativePath: \"sessions/\\(target)/\\(date)\")"))
    }

    @Test("The Nights table wires the shared action menu into every row's context menu")
    func nightsViewWiresSharedMenu() throws {
        let nights = try read("Sources/AstroUI/Features/Nights/NightsView.swift")
        #expect(nights.contains("NightActionMenu("))
        #expect(nights.contains("contextMenu(forSelectionType: UUID.self"))
        #expect(nights.contains("NightNoteSheet("))
        #expect(nights.contains("openCalibration"))
        #expect(nights.contains("openInsights"))
    }

    @Test("The night workspace toolbar surfaces the shared action menu")
    func nightWorkspaceWiresSharedMenu() throws {
        // Wave 4 (post-20014) fix: `NightWorkspaceView` no longer constructs
        // `NightActionMenu(...)` (or any view at all) for its toolbar action
        // -- it builds a plain `WorkspaceActionNightMenu` DATA payload and
        // hands it to the shared `WorkspaceActionCenter`; the shell's own
        // stable toolbar (`V2RootView`) is what actually calls
        // `NightActionMenu(...)` from that data (see
        // `WorkspaceActionItem`'s own doc comment for why the old
        // `.custom(id:view:)` -- which DID build the view inline here --
        // was the very mechanism that caused the invalidation storm this
        // fixes).
        let workspace = try read("Sources/AstroUI/Features/Nights/NightWorkspaceView.swift")
        #expect(workspace.contains("WorkspaceActionNightMenu("))
        #expect(workspace.contains("v2.night.workspace.actions"))
        #expect(workspace.contains("NightNoteSheet("))

        let root = try read("Sources/AstroUI/App/V2RootView.swift")
        #expect(root.contains("NightActionMenu("))
    }

    @Test("The project workspace's Nights tab wires the shared action menu into every row's context menu")
    func projectWorkspaceNightsTabWiresSharedMenu() throws {
        let project = try read("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        #expect(project.contains("NightActionMenu("))
        #expect(project.contains("contextMenu(forSelectionType: UUID.self"))
        #expect(project.contains("NightNoteSheet("))
    }

    @Test("Open in Insights presets AppRouter's pending setup filter before navigating")
    func openInsightsPresetsSetupFilter() throws {
        let router = try read("Sources/AstroUI/App/AppModel.swift")
        let root = try read("Sources/AstroUI/App/V2RootView.swift")
        #expect(router.contains("pendingInsightsSetupFilter"))
        #expect(router.contains("func navigateToInsights(presetSetupFilter"))
        #expect(root.contains("router.navigateToInsights(presetSetupFilter: setup)"))
        #expect(root.contains("initialSetupFilter: router.pendingInsightsSetupFilter"))
    }
}

/// v5 library-switch fixes (item 3, follow-up): `Self.rateFrames` used to
/// open its own confined `MetadataStore` connection through `metadataFactory`
/// on every call, competing with `ProjectsStore`'s already-open one for the
/// same file. Unlike the rest of this file, `rateFrames` is a plain static
/// function -- no view rendering needed -- so this drives it directly rather
/// than through another source-string check.
@MainActor
@Suite("V2 Night action menu rating")
struct NightActionMenuRatingTests {
    @Test("An already-open metadata store is reused instead of opening a second connection")
    func rateFramesReusesTheSharedMetadataStore() async throws {
        let shared = try MetadataStore.temporary()
        let host = OperationHost(center: OperationCenter())
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())

        NightActionMenu.rateFrames(
            target: "M 31", date: "2026-01-01", nightID: UUID(), rootURL: rootURL,
            // Opening one here would be the bug -- `rateFrames` must go
            // through `sharedMetadata` and never touch this.
            metadataFactory: { _ in throw NightActionMenuTestFailure.shouldNotOpenASecondConnection },
            sharedMetadata: shared,
            operationHost: host
        )

        // `rateFrames` is fire-and-forget (an internal, unstructured `Task`),
        // so this polls for its own "nothing to rate" notification -- the
        // fresh `shared` store has no series recorded for this night -- the
        // same honest early exit `LibraryHealthStoreTests`' own `waitUntil`
        // helper is used for elsewhere in this suite.
        try await waitUntil { host.toasts.contains { $0.level == .info } }

        #expect(host.toasts.contains { $0.level == .info && $0.message.contains("No frames to rate") })
    }

    @Test("A root the shared provider does not own still falls back to this call's own factory")
    func rateFramesFallsBackWhenNoSharedStoreIsGiven() async throws {
        let host = OperationHost(center: OperationCenter())
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())

        NightActionMenu.rateFrames(
            target: "M 31", date: "2026-01-01", nightID: UUID(), rootURL: rootURL,
            metadataFactory: { _ in try MetadataStore.temporary() },
            sharedMetadata: nil,
            operationHost: host
        )

        try await waitUntil { host.toasts.contains { $0.level == .info } }

        #expect(host.toasts.contains { $0.level == .info && $0.message.contains("No frames to rate") })
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("Condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private enum NightActionMenuTestFailure: Error, Equatable {
    case shouldNotOpenASecondConnection
}
