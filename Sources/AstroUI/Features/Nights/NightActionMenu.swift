import AppKit
import AstroApplication
import SwiftUI
import UniformTypeIdentifiers

/// Shared context-menu content for one night/session row -- the V2
/// equivalent of V1's `SessionActionMenu`
/// (`Sources/AstroToolApp/Views/SharedComponents.swift:205-292`), reused
/// identically by the Nights table (`NightsView`), the night workspace
/// toolbar (`NightWorkspaceView`), and the project workspace's Nights tab
/// (`ProjectWorkspaceView`'s `ProjectNightsSummary`) rather than each
/// re-declaring its own subset of actions.
///
/// Every action here is fully self-contained (resolves its own path,
/// renders its own export, runs its own operation) except the three that
/// need routing state this menu doesn't own: `openNight`/`openCalibration`
/// (both navigate `AppRouter`) and `editNotes` (presents `NightNoteSheet`,
/// which needs `@State` that outlives this menu's own ephemeral view
/// lifetime -- SwiftUI tears down a context-menu's content view as soon as
/// the menu closes, so a sheet's `isPresented` state must live on the
/// row/workspace that hosts this menu, not in here). Those three are
/// plain callbacks the caller wires to its own router/state, the same
/// shape `openNight`/`openCalibration` already take in `HealthView`.
public struct NightActionMenu: View {
    let target: String
    let date: String
    let setupDescriptor: String?
    let nightID: UUID
    let rootURL: URL?
    let openNight: (() -> Void)?
    let editNotes: () -> Void
    let openCalibration: () -> Void
    let openInsights: (String?) -> Void
    let metadataFactory: NightsStore.MetadataFactory

    @Environment(OperationHost.self) private var operationHost

    /// - Parameter openNight: `nil` when this menu is already hosted BY the
    ///   night workspace itself (opening the night you're already viewing
    ///   would be a no-op menu item) -- omit it there; every other call site
    ///   supplies it.
    public init(
        target: String,
        date: String,
        setupDescriptor: String?,
        nightID: UUID,
        rootURL: URL?,
        openNight: (() -> Void)? = nil,
        editNotes: @escaping () -> Void,
        openCalibration: @escaping () -> Void,
        openInsights: @escaping (String?) -> Void,
        metadataFactory: @escaping NightsStore.MetadataFactory = ProjectsStore.productionMetadata
    ) {
        self.target = target
        self.date = date
        self.setupDescriptor = setupDescriptor
        self.nightID = nightID
        self.rootURL = rootURL
        self.openNight = openNight
        self.editNotes = editNotes
        self.openCalibration = openCalibration
        self.openInsights = openInsights
        self.metadataFactory = metadataFactory
    }

    public var body: some View {
        Group {
            if let openNight {
                Button("Open Night", systemImage: "moon.stars.fill", action: openNight)
            }
            Button("Reveal in Finder", systemImage: "folder", action: revealInFinder)
                .disabled(nightDirectoryURL == nil)
            Divider()
            Button("Night Report…", systemImage: "doc.richtext", action: exportNightReport)
                .disabled(rootURL == nil)
            Button("Edit Night Notes…", systemImage: "note.text", action: editNotes)
                .disabled(rootURL == nil)
            Divider()
            Button("Open Calibration…", systemImage: "camera.filters", action: openCalibration)
            Button("Rate Frames", systemImage: "star.leadinghalf.filled", action: rateFrames)
                .disabled(rootURL == nil)
            Button("Open in Insights", systemImage: "chart.xyaxis.line") { openInsights(setupDescriptor) }
        }
        .accessibilityIdentifier("v2.nights.action-menu.\(nightID.uuidString)")
    }

    /// `sessions/<target>/<date>` -- the fixed on-disk layout every session
    /// lives under (`SessionCreator.targetFolder` resolves new sessions
    /// against this same `sessions/` root), resolved with the identical
    /// containment + existence check `FrameThumbnailCell.resolvedURL`/
    /// `ResultsView.resultURL` already apply to every other library-relative
    /// path this app resolves.
    private var nightDirectoryURL: URL? {
        guard let rootURL else { return nil }
        return FrameThumbnailCell.resolvedURL(rootURL: rootURL, relativePath: "sessions/\(target)/\(date)")
    }

    private func revealInFinder() {
        guard let url = nightDirectoryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// This night's report -- the same engine call `NightsView`/
    /// `NightWorkspaceView`'s own `ExportMenu` items already make
    /// (`ExportService.nightReport`), inlined here so every night row gets
    /// it from ONE place rather than each view re-deriving the panel/toast
    /// dance.
    private func exportNightReport() {
        guard let rootURL else { return }
        do {
            let export = try ExportService.production(rootURL: rootURL).nightReport(target: target, date: date)
            let panel = NSSavePanel()
            panel.title = "Night Report…"
            panel.nameFieldStringValue = export.suggestedFilename
            panel.allowedContentTypes = [.html]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try ExportFileWriter.write(content: export.content, to: url)
            operationHost.notify(.success, message: "\(OperationHost.localized("Exported")) \(url.lastPathComponent)")
        } catch {
            operationHost.notify(.failure, message: "\(OperationHost.localized("Night Report failed:")) \(error.localizedDescription)")
        }
    }

    /// Rates every frame across every series of THIS night -- a thin wrapper
    /// over `Self.rateFrames(target:date:nightID:rootURL:metadataFactory:
    /// operationHost:)` below, which does the actual work. Kept as an
    /// instance method (rather than inlining the static call at the button's
    /// own `action:` site) so `Button("Rate Frames", ..., action: rateFrames)`
    /// -- the exact call shape `NightActionMenuTests` pins down -- keeps
    /// working unchanged.
    private func rateFrames() {
        Self.rateFrames(
            target: target, date: date, nightID: nightID, rootURL: rootURL,
            metadataFactory: metadataFactory, operationHost: operationHost
        )
    }

    /// Rates every frame across every series of THIS night through
    /// `FrameRatingCommand` -- the "night scope" `FrameRatingCommand`
    /// itself doesn't offer directly (it anchors off a hand-picked
    /// `relativePaths` subset, the shape `ReviewStore.rateSelectedSeries`
    /// needs for a single already-selected series), so this gathers every
    /// series' own frame paths for the night first via `MetadataStore`
    /// (the same store `NightsQuery`/`ProjectsQuery` already read), then
    /// hands the FULL set to the command in one call -- its own anchor
    /// resolution rates whichever target that set belongs to, which for a
    /// (by far most common) single-project night rates everything; a
    /// night spanning more than one project rates the first project's
    /// session only, a known, narrow limitation of reusing the
    /// single-session command for a multi-project night rather than
    /// re-deriving `Rater`'s own scope logic here.
    ///
    /// Task 4 (2026-08-17 owner-feedback wave 3) extracted this out of the
    /// instance method above so `NightsView`'s own row-level "Rate Frames"
    /// icon button can trigger the exact same behavior without needing a
    /// live `NightActionMenu` view (and its `@Environment(OperationHost.self)`)
    /// around it -- the owner asked for the Nights page to carry both a row
    /// button AND the ability to rate a night directly, not only through this
    /// menu's own context-menu presentation.
    static func rateFrames(
        target: String,
        date: String,
        nightID: UUID,
        rootURL: URL?,
        metadataFactory: @escaping NightsStore.MetadataFactory,
        operationHost: OperationHost
    ) {
        guard let rootURL else { return }
        let kind = OperationKind.rate(series: "night-\(nightID.uuidString)")
        guard !operationHost.activeOperations.contains(where: { $0.kind == kind }) else {
            operationHost.notify(.info, message: OperationHost.localized("Frame rating is already running for this night."))
            return
        }
        Task {
            do {
                let metadata = try metadataFactory(rootURL)
                let seriesList = try await metadata.series(nightID: nightID)
                var gatheredPaths: [String] = []
                for series in seriesList {
                    let decisions = try await metadata.frameDecisions(seriesID: series.id)
                    gatheredPaths.append(contentsOf: decisions.map(\.relativePath))
                }
                let relativePaths = gatheredPaths
                guard !relativePaths.isEmpty else {
                    operationHost.notify(.info, message: OperationHost.localized("No frames to rate for this night."))
                    return
                }
                let command = try FrameRatingCommand.production(rootURL: rootURL)
                _ = await operationHost.run(
                    kind: kind, title: "\(OperationHost.localized("Rating Frames")) — \(target) · \(date)", cancellation: .cooperative
                ) {
                    try Task.checkCancellation()
                    _ = try command.run(
                        relativePaths: relativePaths, mode: .nativeOnly, isCancelled: { Task.isCancelled }
                    )
                }
            } catch {
                operationHost.notify(.failure, message: "\(OperationHost.localized("Frame rating failed:")) \(error.localizedDescription)")
            }
        }
    }
}
