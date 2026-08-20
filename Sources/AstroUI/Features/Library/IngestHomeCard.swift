import AstroApplication
import AstroCore
import SwiftUI

/// V3 pre-stack program, section 5.1 (Ingest-figyelő): registers the Home
/// banner through the Wave 0 `HomeCardProviding` seam (see that protocol's
/// own doc comment, `Sources/AstroUI/Features/Home/HomeCardProviding.swift`)
/// -- this is the ONE file 5.1 ever needs to touch to add its own card,
/// never `HomeView`'s shared body.
///
/// `runScan` mirrors `V2RootView.performRescan` exactly -- the same rescan
/// the existing `.importCapture` route already runs once a copy finishes,
/// so newly-copied frames actually show up in the library index rather than
/// only appearing after the owner happens to trigger some OTHER scan.
@MainActor
public struct IngestHomeCardProvider: HomeCardProviding {
    private let watcher: IngestWatcher
    private let runScan: () -> Void

    public init(watcher: IngestWatcher, runScan: @escaping () -> Void) {
        self.watcher = watcher
        self.runScan = runScan
    }

    /// "Nothing real, nothing shown" -- `nil` whenever the watcher has no
    /// candidate (nothing mounted, mounted-but-not-a-card, or already
    /// dismissed/handled) or the library context it needs to build the
    /// sheet hasn't been configured yet (no library open).
    public func card(store: HomeStore) -> AnyView? {
        guard let candidate = watcher.candidate, watcher.libraryContext != nil else { return nil }
        return AnyView(IngestVolumeCard(watcher: watcher, candidate: candidate, runScan: runScan))
    }
}

/// "Új felvétel-forrás található: `/Volumes/EOS_DIGITAL` — 214 fájl, 3
/// burst" -- the spec's own example copy. "Import…" opens the SAME
/// `CaptureImportView` sheet the manual wizard uses, pre-loaded via its
/// `ingestCandidate:` initializer; "Not now" only ever dismisses THIS
/// candidate (`IngestWatcher.dismissCandidate`'s own doc comment covers why
/// the same still-mounted volume never reappears on its own afterward).
private struct IngestVolumeCard: View {
    @Bindable var watcher: IngestWatcher
    let candidate: IngestWatcher.Candidate
    let runScan: () -> Void
    @State private var isPresentingImport = false

    var body: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("New capture source found").font(.headline)
            // `candidate.volume.name`/counts are real, already-computed
            // facts (`IngestWatcher`'s own scan/group), never re-derived
            // here. The two counts are pre-formatted into ONE `String`
            // before interpolation -- the same "%@, never two raw %lld's in
            // one sentence" rule `HomeView`'s own "Moon interferes tonight"
            // comment documents for a multi-number fragment.
            Text("\(candidate.volume.name) — \(filesAndBurstsSummary)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("v2.home.ingest-banner-detail")
            HStack(spacing: AstroTokens.Spacing.standard) {
                Button("Import…") { isPresentingImport = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("v2.home.ingest-import")
                Button("Not now") { watcher.dismissCandidate() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("v2.home.ingest-dismiss")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
        .accessibilityIdentifier("v2.home.ingest-banner")
        .sheet(isPresented: $isPresentingImport) {
            if let context = watcher.libraryContext {
                CaptureImportView(
                    rootURL: context.rootURL,
                    accessMode: context.accessMode,
                    indexedFolders: context.indexedFolders,
                    existingProjects: context.existingProjects,
                    ingestCandidate: candidate,
                    dismiss: {
                        isPresentingImport = false
                        watcher.markCandidateHandled()
                    },
                    runScan: runScan
                )
            }
        }
    }

    private var filesAndBurstsSummary: String {
        "\(candidate.discovered.count) files, \(candidate.groups.count) bursts"
    }
}
