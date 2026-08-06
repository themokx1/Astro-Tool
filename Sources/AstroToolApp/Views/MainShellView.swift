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
    /// R9-T6/B14: the menu bar's "Műveletek" (`Views/Commands.swift`) posts
    /// these -- it has no local view state of its own to hold a confirm
    /// sheet, so it hands off to whichever view actually owns one.
    static let runRateAllRequested = Notification.Name("AstroTool.runRateAllRequested")
    static let adviseAllRequested = Notification.Name("AstroTool.adviseAllRequested")
    static let plateSolveAllRequested = Notification.Name("AstroTool.plateSolveAllRequested")
    static let measureSensorRequested = Notification.Name("AstroTool.measureSensorRequested")
}

/// The routed detail pane + its window toolbar (spec A.8/A.9's "Beolvasás",
/// "+", "Műveletek", recent-roots menu, activity clock).
private struct DetailContainerView: View {
    @Environment(AppState.self) private var appState
    @State private var showNewSessionSheet = false
    @State private var showActivityPopover = false
    @State private var bannerDismissed = false
    /// R9-T6/B14 batch action sheets -- the toolbar's "Műveletek" menu AND
    /// the menu bar's own copy (`Views/Commands.swift`, which has no local
    /// view state of its own) both trigger these via the notifications
    /// below.
    @State private var showRateAllConfirm = false
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
                    // R9-T6/B14: the batch operations menu -- same set as
                    // the menu bar's own "Műveletek" (`Views/Commands.swift`,
                    // A.8), duplicated here for toolbar-only convenience.
                    Button("Minden célpont pontozása…") { showRateAllConfirm = true }
                        .disabled(appState.stats.isEmpty || appState.db == nil)
                    Button("Plate-solve minden koordináta nélküli célpontra…") { appState.runPlateSolveAll() }
                        .disabled(appState.isBusy || appState.db == nil)
                    Button("Expozíció-tanácsadó minden célpontra…") { appState.adviseAll() }
                        .disabled(appState.isBusy || appState.db == nil)
                    Button("Szenzor mérése…") {
                        appState.currentPage = .sensor
                        NotificationCenter.default.post(name: .measureSensorRequested, object: nil)
                    }
                    .disabled(appState.db == nil)
                } label: {
                    Label("Műveletek", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showNewSessionSheet) {
            NewSessionSheet()
        }
        .sheet(isPresented: $showRateAllConfirm) {
            RateAllConfirmSheet()
        }
        .sheet(isPresented: exposureAdviceAllSheetBinding) {
            ExposureAdviceAllSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newSession)) { _ in
            showNewSessionSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .runRateAllRequested)) { _ in
            showRateAllConfirm = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .adviseAllRequested)) { _ in
            appState.adviseAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .plateSolveAllRequested)) { _ in
            appState.runPlateSolveAll()
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

    /// Gates `ExposureAdviceAllSheet`'s presentation on
    /// `AppState.exposureAdviceAll` being non-`nil` (set by `adviseAll()`)
    /// -- dismissing the sheet clears it back to `nil` so a stale previous
    /// run's rows never flash before the next `adviseAll()` call replaces
    /// them.
    private var exposureAdviceAllSheetBinding: Binding<Bool> {
        Binding(
            get: { appState.exposureAdviceAll != nil },
            set: { isPresented in if !isPresented { appState.exposureAdviceAll = nil } }
        )
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
        // D25: `.calendar` is its own `Page` case now (so the sidebar's
        // "Naptár" row / ⌘2 highlight correctly, distinct from "Ma este"),
        // but there's still no standalone calendar view -- it renders the
        // exact same `TonightPage`, just forcing its "Következő 30 éjszaka"
        // segment via `.onAppear` before the page's own segmented picker
        // gets a chance to show whatever it last had selected.
        case .calendar:
            TonightPage()
                .onAppear { appState.tonightSegment = .calendar }
        case .allTargets: AllTargetsPage()
        // R9-T3: `.id(name)` forces a fresh `TargetDetailPage` instance (and
        // thus a fresh `onAppear`/`@State`) whenever the sidebar switches
        // straight from one target to another -- `MainShellView` would
        // otherwise just hand the SAME view struct a new `target` value in
        // place, which triggers neither `onAppear` nor any `@State` reset.
        case .target(let name): TargetDetailPage(target: name).id(name)
        case .calibration: CalibrationPage()
        case .audit: AuditPage()
        // D25: same "own `Page` case, same underlying view, segment forced
        // on appear" shape as `.calendar` above -- the sidebar's "Takarítás"
        // row / ⌘6.
        case .cleanup:
            AuditPage()
                .onAppear { appState.auditSegment = .cleanable }
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
        case .cleanup: return "Takarítás"
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
