import AppKit
import SwiftUI

/// The normal (root reachable, at least one scan done) shell: sidebar +
/// routed detail, replacing the old six-tab `TabView` (R9-T1).
struct MainShellView: View {
    @Environment(AppState.self) private var appState
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView()
        } detail: {
            DetailContainerView()
        }
        // Toggled by "Oldalsáv" (⌃⌘S, `Views/Commands.swift`).
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
        }
    }
}

extension Notification.Name {
    static let toggleSidebar = Notification.Name("AstroTool.toggleSidebar")
}

/// The routed detail pane + its window toolbar (spec A.8/A.9's "Beolvasás",
/// "+", "Műveletek", recent-roots menu, activity clock).
private struct DetailContainerView: View {
    @Environment(AppState.self) private var appState
    @State private var showNewSessionSheet = false
    @State private var showActivityPopover = false
    @State private var bannerDismissed = false
    /// R9-T4: `OverviewView`'s DSS-ingest result alert, relocated here now
    /// that "DSS-döntések importálása" itself moved from that deleted page's
    /// button into this toolbar's "Műveletek" menu.
    @State private var showDSSIngestAlert = false

    var body: some View {
        VStack(spacing: 0) {
            if appState.scanIsStale && !bannerDismissed {
                staleScanBanner
            }
            page(for: appState.currentPage)
        }
        .navigationTitle(title(for: appState.currentPage))
        .toolbar {
            ToolbarItem(placement: .principal) {
                rootMenu
            }
            ToolbarItemGroup(placement: .primaryAction) {
                scanControl
                activityButton
                Menu {
                    Button("Új session…") { showNewSessionSheet = true }
                        .disabled(appState.db == nil)
                } label: {
                    Image(systemName: "plus")
                }
                Menu {
                    // R9-T4: the first WORKING item in this menu -- moved
                    // (and enabled) from `OverviewView`'s "DSS-döntések
                    // importálása" quick button, gated the same way that
                    // button was (`hasDSSFilelists`, true only when the
                    // library actually has DeepSkyStacker byproducts on
                    // record). T6 wires the two placeholders below against
                    // the real batch operations; the one other WORKING
                    // "Műveletek" action (Audit futtatása) lives in the menu
                    // bar's "Műveletek" menu (`Views/Commands.swift`,
                    // ⌘⌥A), not duplicated here.
                    if appState.hasDSSFilelists {
                        Button("DSS-döntések importálása") { appState.runIngestDSS() }
                            .disabled(appState.isBusy || appState.db == nil)
                        Divider()
                    }
                    Button("Minden célpont pontozása…") {}
                        .disabled(true)
                    Button("Minden célpont exportálása…") {}
                        .disabled(true)
                } label: {
                    Label("Műveletek", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showNewSessionSheet) {
            NewSessionSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newSession)) { _ in
            showNewSessionSheet = true
        }
        .onChange(of: appState.dssIngestSummary) { _, newValue in
            showDSSIngestAlert = newValue != nil
        }
        .alert("DSS-adatok beolvasva", isPresented: $showDSSIngestAlert, presenting: appState.dssIngestSummary) { _ in
            Button("OK") {}
        } message: { summary in
            Text(
                "info.txt: \(summary.infoFilesParsed), rating: \(summary.ratingsUpserted), "
                    + ".dssfilelist: \(summary.filelistsParsed), döntés: \(summary.verdictsRecorded), "
                    + "kihagyva: \(summary.skipped)"
            )
        }
    }

    private var staleScanBanner: some View {
        HStack {
            Image(systemName: "info.circle").foregroundStyle(.blue)
            Text("Új fájlok lehetnek.")
            Button("Beolvasás") { appState.runScan() }
                .disabled(appState.isBusy)
            Spacer()
            Button {
                bannerDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.1))
    }

    @ViewBuilder
    private func page(for page: Page) -> some View {
        switch page {
        case .tonight: TonightPage()
        // R9-T4: the standalone `CalendarPage` is gone -- its content is now
        // `TonightPage`'s "Következő 30 éjszaka" segment. The sidebar/⌘2
        // route to `.tonight` with `AppState.tonightSegment = .calendar`
        // preselected instead of ever constructing this case; it's kept
        // (not deleted from `Page`) only so any future direct navigation to
        // `.calendar` still lands somewhere sensible rather than being
        // unrepresentable.
        case .calendar: TonightPage()
        case .allTargets: StatsView()
        // R9-T3: `.id(name)` forces a fresh `TargetDetailPage` instance (and
        // thus a fresh `onAppear`/`@State`) whenever the sidebar switches
        // straight from one target to another -- `MainShellView` would
        // otherwise just hand the SAME view struct a new `target` value in
        // place, which triggers neither `onAppear` nor any `@State` reset.
        case .target(let name): TargetDetailPage(target: name).id(name)
        case .calibration: CalibrationPage()
        case .audit: AuditPage()
        case .sensor: SensorPage()
        case .searchResults: SearchResultsPage()
        }
    }

    private func title(for page: Page) -> String {
        switch page {
        case .tonight: return "Ma este"
        case .calendar: return "Naptár"
        case .allTargets: return "Minden célpont"
        case .target(let name): return appState.stats.first { $0.target == name }?.displayName ?? name
        case .calibration: return "Kalibráció"
        case .audit: return "Audit"
        case .sensor: return "Szenzor-profilok"
        case .searchResults: return "Kereső"
        }
    }

    private var rootMenu: some View {
        let rootURL = URL(fileURLWithPath: appState.config.rootPath, isDirectory: true)
        let label = appState.config.rootPath.isEmpty ? "AstroTool" : rootURL.lastPathComponent

        return Menu {
            Button("Mappa választása…") { appState.chooseRoot() }
            if !appState.recentRoots.isEmpty {
                Menu("Legutóbbi könyvtárak") {
                    ForEach(appState.recentRoots) { recent in
                        Button(URL(fileURLWithPath: recent.path, isDirectory: true).lastPathComponent) {
                            appState.selectRecentRoot(recent)
                        }
                    }
                }
            }
            Divider()
            Button("Megnyitás Finderben") { appState.revealRootInFinder() }
            Button("config.json megjelenítése") { appState.revealConfigInFinder() }
        } label: {
            Text(label)
        }
    }

    @ViewBuilder
    private var scanControl: some View {
        if appState.isBusy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(appState.progressText).foregroundStyle(.secondary)
                Button("Mégse") { appState.cancelCurrentOperation() }
            }
        } else {
            HStack(spacing: 6) {
                Button {
                    appState.runScan()
                } label: {
                    Label("Beolvasás", systemImage: "arrow.clockwise")
                }
                .disabled(appState.db == nil)

                if let lastScanDate = appState.lastScanDate {
                    Text("Utolsó: \(AppState.relativeTimeText(since: lastScanDate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var activityButton: some View {
        Button {
            showActivityPopover = true
        } label: {
            Image(systemName: "clock")
        }
        .popover(isPresented: $showActivityPopover) {
            ActivityLogPopover()
        }
    }
}

/// B15: the toolbar clock icon's popover -- last 50 completed background
/// operations, newest first, relative time + title, errors in red.
private struct ActivityLogPopover: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tevékenység").font(.headline).padding(12)
            Divider()
            if appState.activityLog.isEmpty {
                Text("Még nincs tevékenység.")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.activityLog) { entry in
                            row(entry)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 340)
    }

    private func row(_ entry: AppState.ActivityEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.title)
                Spacer()
                Text(AppState.relativeTimeText(since: entry.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .error(let message) = entry.outcome {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .font(.callout)
    }
}
