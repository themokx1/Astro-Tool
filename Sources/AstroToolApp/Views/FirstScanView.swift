import AstroCore
import SwiftUI

/// First-run screen (R9-T1, spec A.9), shown once a root has been chosen but
/// never successfully scanned (`AppState.lastScanDate == nil`) -- between
/// `WelcomeView` (no root at all) and the normal shell (`lastScanDate != nil`
/// once a scan finishes, tracked by `AppState.currentPage` shells reading
/// the runs table so this survives relaunches, not just this session).
struct FirstScanView: View {
    @Environment(AppState.self) private var appState
    @State private var showStructureHelp = false
    @State private var runAuditAfter = true
    @State private var didStartScan = false
    @State private var scanFinished = false
    /// D27: was a computed property re-running `FileManager.contentsOfDirectory`
    /// (synchronous disk I/O) on every render of `checklist` -- computed once
    /// into this instead, on `.onAppear`. The root doesn't change while this
    /// screen is on screen, so re-reading it per-render bought nothing.
    @State private var topLevelEntries: Set<String> = []

    /// The expected top-level areas (spec: "sessions/calibration_library/
    /// stacks/processed present?") -- a cheap, read-only
    /// `contentsOfDirectory` on the root, never anything recursive.
    private static let expectedDirs = ["sessions", "calibration_library", "stacks", "processed"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if scanFinished, let summary = appState.scanSummary {
                resultCard(summary)
            } else {
                readyHeader
                checklist
                if appState.isBusy {
                    busyRow
                } else {
                    actions
                }
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }

            Spacer(minLength: 0)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showStructureHelp) {
            FolderStructureHelpSheet()
        }
        .onAppear {
            let entries = try? FileManager.default.contentsOfDirectory(atPath: appState.config.rootPath)
            topLevelEntries = Set(entries ?? [])
        }
        .onChange(of: appState.isBusy) { wasBusy, isBusyNow in
            guard didStartScan, wasBusy, !isBusyNow, !scanFinished else { return }
            scanFinished = true
            if runAuditAfter {
                appState.runAudit(includeSuspicious: false)
            }
        }
    }

    private var readyHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Készen áll").font(.largeTitle).bold()
            Text(appState.config.rootPath)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mappaszerkezet").font(.headline)
            ForEach(Self.expectedDirs, id: \.self) { dir in
                checklistRow(dir, present: topLevelEntries.contains(dir))
            }
            if topLevelEntries.contains("tools") {
                HStack(spacing: 8) {
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    Text("tools").font(.system(.body, design: .monospaced))
                    Text("(kizárva a beolvasásból)").foregroundStyle(.secondary)
                }
            }
            Button("Milyen mappastruktúrát vár?") { showStructureHelp = true }
                .buttonStyle(.link)
                .padding(.top, 4)
        }
    }

    private func checklistRow(_ dir: String, present: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: present ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(present ? .green : .secondary)
            Text(dir).font(.system(.body, design: .monospaced))
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Auditot is futtassunk most?", isOn: $runAuditAfter)
                .toggleStyle(.checkbox)
            HStack {
                Button("Beolvasás indítása") {
                    didStartScan = true
                    appState.runScan()
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.db == nil)

                Button("Kihagyom, később") { appState.didDismissFirstRun = true }
            }
        }
        .padding(.top, 8)
    }

    private var busyRow: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text(appState.progressText).foregroundStyle(.secondary)
            Button("Mégse") { appState.cancelCurrentOperation() }
        }
        .padding(.top, 8)
    }

    private func resultCard(_ summary: ScanSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kész!").font(.largeTitle).bold()

            let fileCount = summary.added + summary.updated + summary.unchanged
            let targetCount = appState.stats.count
            let sessionCount = appState.stats.reduce(0) { $0 + $1.sessionDates.count }
            Text("\(fileCount) fájl · \(targetCount) célpont · \(sessionCount) session")
                .font(.title3)

            if appState.isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(appState.progressText).foregroundStyle(.secondary)
                }
            }

            Button("Tovább a Ma este oldalra") {
                appState.currentPage = .tonight
                appState.didDismissFirstRun = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // R11-T12/F12: right after the first successful scan's result --
            // the natural next moment to point a first-time user at "what's
            // left before this app is fully useful" (audit, helyszín, Siril,
            // pontozás, szenzor-profil).
            Divider().padding(.vertical, 4)
            Text("Első lépések").font(.headline)
            FirstStepsChecklistView()
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}
