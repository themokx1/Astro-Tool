import AppKit
import AstroCore
import Foundation
import Observation

/// What we currently know about the configured library root: whether it's
/// reachable, and if not, why -- drives whether the app shows the tab UI or
/// a full-screen guidance view (`AccessDeniedView`).
enum RootStatus: Equatable {
    case ok
    case accessDenied
    case notMounted
    case notScanned
    case noRoot
}

/// The navigation shell's routing target (R9-T1) -- every page reachable
/// from the sidebar, the menu bar, or a "jump to target" action. Detail
/// pages for this task reuse existing view bodies; later R9 tasks replace
/// individual cases' content without touching this enum's shape.
enum Page: Hashable {
    case tonight
    case calendar
    case allTargets
    case target(String)
    case calibration
    case audit
    case sensor
    case searchResults
}

/// The app's single source of truth. Thin by design: every real operation
/// (scan/audit/rate/stats/calib/new-session) is a direct call into AstroCore,
/// run off the main thread; this class only tracks UI-observable state and
/// hops results back to the main actor.
///
/// Marked `@unchecked Sendable` so a reference to this `@MainActor`-isolated
/// instance can be captured by the `@Sendable` background closures below
/// (for progress reporting). This is safe because the type itself is
/// `@MainActor`, so every actual read/write of its stored properties is still
/// forced through the main actor -- the closures only ever mutate it via a
/// nested `Task { @MainActor in ... }` hop.
@MainActor
@Observable
final class AppState: @unchecked Sendable {
    private static let bookmarkKey = "rootBookmark"
    private static let recentRootsKey = "recentRootBookmarks"

    /// App-lifetime singleton reference, set from `init()`. The menu bar
    /// (`Views/Commands.swift`) needs to call into `AppState` from `.commands`
    /// closures, which don't get SwiftUI's `@Environment` injection the way
    /// view bodies do -- a `@FocusedObject` would need every scene's root
    /// view to publish one, which is more machinery than this app (a single
    /// window + a Settings scene) needs. Since there is only ever one
    /// `AppState` for the process's lifetime (the `@State` in
    /// `AstroToolApp`), a plain singleton is a pragmatic, documented
    /// exception to "no globals" here.
    @ObservationIgnored
    static var shared: AppState!

    var config: AstroConfig = AstroConfig()
    var db: Database?
    var rootStatus: RootStatus = .noRoot

    /// The navigation shell's current page (R9-T1) -- drives both the
    /// sidebar's selection highlight and which detail view is shown.
    var currentPage: Page = .tonight

    /// One entry per completed background operation (B15 activity log),
    /// newest first, capped at 50 -- appended from `endOperation` (see its
    /// doc comment for why that's the one hook point instead of editing
    /// every `beginOperation`/`endOperation` call site). Shown from the
    /// toolbar's clock-icon popover.
    struct ActivityEntry: Identifiable {
        enum Outcome: Equatable {
            case ok
            case error(String)
        }
        let id = UUID()
        let date: Date
        let title: String
        let outcome: Outcome
    }
    var activityLog: [ActivityEntry] = []
    /// Titles of not-yet-finished operations, keyed by `beginOperation`'s
    /// UUID -- `endOperation` consumes its entry to build the `ActivityEntry`
    /// it appends. `@ObservationIgnored`: purely an implementation detail of
    /// the begin/end bookkeeping, never read by a view.
    @ObservationIgnored
    private var pendingActivityTitle: [UUID: String] = [:]

    /// One bookmark per recently-opened root (R9-T1 toolbar "Legutóbbi
    /// könyvtárak"), most-recent-first, capped at 5. Persisted as an array of
    /// security-scoped bookmark blobs under `recentRootsKey`; `path` is
    /// re-derived by resolving each bookmark so the menu can show a
    /// human-readable label without re-prompting the user.
    struct RecentRoot: Identifiable {
        let path: String
        let bookmark: Data
        var id: String { path }
    }
    var recentRoots: [RecentRoot] = []

    /// The most recent `runs.kind == "scan"` timestamp for the current root,
    /// `nil` until a scan has ever completed for it (across launches, not
    /// just this session) -- drives the toolbar's "Utolsó: <relatív idő>"
    /// caption AND (together with `didDismissFirstRun`) whether the
    /// first-run `FirstScanView` or the normal shell is shown.
    var lastScanDate: Date?
    /// Set once the user explicitly moves past the first-run flow (either
    /// "Beolvasás indítása" finishes and they hit "Tovább", or they hit
    /// "Kihagyom, később") -- session-only, deliberately not persisted, so a
    /// skipped first scan doesn't silently disable the flow forever if the
    /// user relaunches still not having scanned.
    var didDismissFirstRun: Bool = false

    /// B6: a non-mounted volume that reappears (`NSWorkspace.didMountNotification`)
    /// auto-retries root access; kept so the observer is only ever
    /// registered once per process.
    @ObservationIgnored
    private var mountObserver: NSObjectProtocol?

    var scanSummary: ScanSummary?
    var findings: [Finding] = []
    var lastRunID: Int64?
    var includeSuspiciousInScript: Bool = false

    var cleanupSummary: CleanupSummary?
    /// R9-T2/A.5's "Takarítható" segment `Limit` stepper -- how many paths
    /// each expanded cleanup-category row shows before an "…további N" row,
    /// same idea as the CLI `cleanup --limit` display cap (default 10).
    /// Purely a view-layer display cap: `CleanupReport.build`'s own
    /// `maxPathsPerGroup` (50) already limits what's fetched from the DB at
    /// all; this only limits what's shown from that.
    var cleanupLimit: Int = 10

    /// R9-T2/A.5's three-segment Audit page picker.
    enum AuditSegment: Hashable {
        case errors
        case suspicious
        case cleanable
    }
    /// Which segment `AuditPage` shows -- settable by the sidebar's
    /// "Takarítás" row (which preselects `.cleanable` before navigating to
    /// `.audit`) as well as the page's own segmented picker.
    var auditSegment: AuditSegment = .errors
    /// R9-T2/A.5's toolbar toggle: when `false` (the default), any group
    /// whose ack key is in `ackedKeys` is hidden entirely from the Hibák/
    /// Gyanús list; when `true`, acked groups reappear, dimmed, with their
    /// `⋯` menu offering "Rendben-jelölés visszavonása" instead of "...
    /// megjelölése rendben lévőként".
    var showAckedFindings: Bool = false
    /// B5: every currently-acked `(category, groupKey)` key
    /// (`Database.ackKey`), loaded once when the root opens (`openRoot`) and
    /// kept in sync locally by `ackFindingGroup`/`unackFindingGroup` so a
    /// view never has to re-query the DB just to check one group's state.
    var ackedKeys: Set<String> = []

    /// R9-T4/A.1's segmented picker on `TonightPage` -- settable by the
    /// sidebar's "Naptár" row (which preselects `.calendar` before
    /// navigating to `.tonight`, since the old standalone `Page.calendar`
    /// route is no longer how either the sidebar or the menu bar reach the
    /// calendar content) as well as the page's own segmented picker. Same
    /// "preselect a segment, then navigate" pattern `auditSegment`/
    /// "Takarítás" already established.
    enum TonightSegment: Hashable {
        case tonight
        case calendar
    }
    var tonightSegment: TonightSegment = .tonight

    /// R9-T4/B10's `Settings` scene tab picker -- settable by the "Ma este"
    /// page's "Helyszín" tile (which preselects `.location` before opening
    /// the Settings window) so that click actually lands on the tab it
    /// promises, not just Settings in general.
    enum SettingsTab: Hashable {
        case library
        case location
        case calibration
        case rating
        case libraryRules
    }
    var settingsTab: SettingsTab = .library

    // MARK: - Global search (R9-T6/B3)

    /// The query behind the currently shown `Page.searchResults` -- set by
    /// `runSearch`, read by `SearchResultsPage`'s "N találat erre: ..."
    /// header.
    var searchQuery: String = ""
    /// `nil` before the first search this session; `SearchResults()`
    /// (`.isEmpty == true`) after a search that matched nothing. Both route
    /// `SearchResultsPage` to the same `ContentUnavailableView.search`, so
    /// the distinction only matters to avoid flashing a stale previous
    /// query's results while a new search is still running.
    var searchResults: SearchResults?
    /// A search result's session/note row sets this (alongside
    /// `pendingTargetSegment`) right before navigating to `Page.target` --
    /// `TargetDetailPage`'s `SessionsSegment` consumes it once (selecting
    /// that row and clearing this back to `nil`) as soon as its session
    /// list has loaded.
    var pendingSessionSelection: String?
    /// A search result's session/note row sets this right before
    /// navigating to `Page.target`, so the target page opens straight to
    /// the segment that actually shows the hit (Sessionök for a session
    /// hit, Jegyzetek for a note hit) instead of always defaulting to
    /// Áttekintés. `TargetDetailPage.onAppear` consumes it once.
    var pendingTargetSegment: TargetDetailPage.Segment?

    var stats: [TargetStats] = []
    /// Every target's session detail rows, keyed by target name -- populated
    /// alongside `stats` in `loadStats()` so `StatsView`'s hierarchical
    /// `Table` has every row's children available up front (a `Table` can't
    /// lazily fetch a row's children on first expand).
    var sessionDetailsByTarget: [String: [SessionDetail]] = [:]
    /// Every target's mosaic-panel breakdown (`FieldGeometry.panels`, R6-3),
    /// keyed by target name -- populated alongside `stats`/
    /// `sessionDetailsByTarget` in `loadStats()`. Only targets with `>= 2`
    /// panels (`isMosaic`) show anything in `StatsView`, but every target
    /// gets an entry so a re-render never has to guess "not loaded yet" vs.
    /// "genuinely a single field".
    var panelReportsByTarget: [String: PanelReport] = [:]
    /// Every target's discovered stack files (`StackDiscovery.discover`,
    /// R8-1), keyed by target name -- populated alongside `stats`/
    /// `panelReportsByTarget` in `loadStats()`. A target with no discovered
    /// stacks at all still gets an entry (`stacks == []`), same "never
    /// guess not-loaded-yet vs. genuinely-empty" convention
    /// `panelReportsByTarget` uses.
    var stackReportsByTarget: [String: TargetStacks] = [:]
    /// Every target's discovered stacks, grouped into variant families
    /// (`StackDiscovery.groupedStacks`, R8-3) -- keyed by target name,
    /// populated alongside `stackReportsByTarget` in `loadStats()`. Powers
    /// `StackGroupSheet`'s hierarchical table; a target with no discovered
    /// stacks still gets an entry (`[]`), same convention as
    /// `stackReportsByTarget`.
    var stackGroupsByTarget: [String: [StackGroup]] = [:]
    var calibNeeds: [CalibNeed] = []
    /// `CalibHealth.report`'s result -- flat discipline, bias inventory, dark
    /// master health -- shown below the coverage table on the Kalibráció
    /// fül. `nil` until `loadCalibHealth()` has run at least once this
    /// session.
    var calibHealth: CalibHealthReport?
    /// Measured sensor characterization per `(camera, gain, offset)` combo
    /// (R7-B1 item C) -- read-only "Szenzor-profilok" list on the
    /// Kalibráció fül, `[]` until `loadSensorProfiles()`/
    /// `measureSensorProfiles()` has run at least once this session.
    var sensorProfiles: [SensorProfileRecord] = []
    var frameScores: [FrameScore] = []

    /// Whether any `.dssfilelist` is currently tracked -- gates the
    /// Áttekintés "DSS-adatok beolvasása" quick button (R7-B2), so it's
    /// never shown for a library with no DeepSkyStacker byproducts at all.
    /// Refreshed after `openRoot`/`runScan` via the cheap, targeted
    /// `Database.hasTrackedFileWithSuffix` query -- never a full `allFiles`
    /// scan just to answer this one yes/no question.
    var hasDSSFilelists: Bool = false
    /// The result of the last `runIngestDSS()` run, shown as the Áttekintés
    /// result alert. `nil` before the button has ever been used this
    /// session.
    var dssIngestSummary: DSSIngestSummary?

    /// R7-1: the plate-solve backfill result shown in `PlateSolveSheet`
    /// while it's open -- `nil` before the sheet's operation has finished
    /// (it shows a spinner until this is set), cleared when the sheet
    /// closes so a stale previous target's result never flashes before the
    /// next open's finishes.
    var plateSolveSummary: SolveSummary?

    /// Tonight's observation plan (`Planner.plan`), shown in the
    /// "Ma este" box on the Áttekintés tab. `nil` until `loadPlan()` has
    /// run at least once this session.
    var plan: [TargetPlan]?

    /// R9-T4/B10's fix: `Planner.resolveSite`'s result, cached here (in
    /// memory only, never persisted) so `TonightPage`'s "Helyszín" tile can
    /// show the RESOLVED coordinate even in Automatikus mode, where
    /// `config.site` itself stays `nil`. Previously `loadPlan()`/
    /// `loadTargetDetail()` mutated `config.site` directly with this same
    /// value -- which meant a plain Settings "Mentés" (in Automatikus mode,
    /// touching none of the Helyszín fields at all) silently persisted
    /// whatever had been derived from FITS headers as if the user had typed
    /// it in manually. `config.site` now only ever holds what a user
    /// actually saved from the Helyszín tab (or `SiteRule()`, i.e. "derive
    /// it"); this property holds today's actually-in-effect coordinate.
    var resolvedSite: SiteRule = SiteRule()

    /// Tonight's (or `planDate`'s) dark-time/Moon summary
    /// (`Planner.nightInfo`), backing `TonightPage`'s "Sötét idő"/"Hold"
    /// tiles. `nil` until `loadPlan()` has run at least once this session,
    /// refreshed alongside `plan`/`resolvedSite`.
    var nightInfo: NightInfo?

    /// The date `plan`/`resolvedSite`/`nightInfo` were last computed for --
    /// `nil` means "tonight" (today, at whatever instant `loadPlan()` ran).
    /// Set by `loadPlan(date:)`; drives `TonightPage`'s "<dátum> éjszakájára"
    /// caption + "Vissza a mai estéhez" button once a calendar row's "Terv
    /// erre az éjszakára" context menu recomputes the plan for a different
    /// night.
    var planDate: Date?

    /// The month-at-a-glance planning calendar (`Planner.month`, R7-B5),
    /// shown in the "Hónap" sheet off the Áttekintés tab. `nil` until
    /// `loadMonthPlan()` has run at least once this session -- never loaded
    /// automatically (same "time-of-day-sensitive, don't auto-refresh"
    /// stance as `plan`).
    var monthPlan: [NightSummary]?

    /// Every target's pipeline status (`ProjectStatusQueries.projects`),
    /// shown in the "Projektek" box on the Áttekintés tab. `[]` until
    /// `loadProjects()` has run at least once this session (also refreshed
    /// automatically after a scan, unlike `plan`).
    var projectStates: [ProjectState] = []

    /// The currently selected target's per-session absolute quality summaries
    /// (`SessionQuality.summaries`) -- shown above the frame table in the
    /// Minőség fül. Cleared whenever a different target is selected so a
    /// stale previous target's rows never flash before the new ones load.
    var qualitySummaries: [SessionQualitySummary] = []
    /// The currently selected target's sub-exposure/relative-SNR advice
    /// (R7-B3 `ExposureAdvisor`) -- shown just above `qualitySummaries` in
    /// the Minőség fül. `nil` until `loadExposureAdvice(target:)` has run
    /// for the current target (cleared on target change, same as
    /// `qualitySummaries`).
    var exposureAdvice: ExposureAdvice?
    /// R9-T6/B14 batch action result: every target's `ExposureAdvisor.advise`
    /// output from "Expozíció-tanácsadó minden célpontra…" -- `nil` before
    /// `adviseAll()` has run this session; non-`nil` is what
    /// `ExposureAdviceAllSheet` gates its presentation on.
    var exposureAdviceAll: [ExposureAdvice]?
    /// The night-timeline for whichever session row is currently selected in
    /// the quality summary section, `nil` until one is selected/loaded.
    var sessionTimeline: SessionTimeline?
    /// The per-night hardware-health report (cooler stability + focus
    /// drift, R6-2) for whichever session row is currently selected --
    /// loaded alongside `sessionTimeline` by `loadSessionTimeline`, `nil`
    /// under the same conditions.
    var nightHealth: NightHealthReport?

    /// The plan currently shown in `CalibLinkSheet`, `nil` while it's still
    /// loading (or the sheet isn't open). Cleared whenever the sheet closes
    /// so a stale plan from a previous session never flashes on next open.
    var calibLinkPlan: CalibLinkPlan?
    /// Set once `applyCalibLinkPlan()` finishes -- the sheet switches from
    /// showing the plan to showing this result.
    var calibLinkResult: LinkResult?

    /// R9-T5/A.4: the session `CalibLinkSheet` is currently open for from
    /// `CalibrationPage`'s Lefedettség action cards / row context menu.
    /// `CalibNeed` only records which TARGETS need a combo, not which
    /// session -- `openCalibLinkSheet(forNeed:)` resolves this pragmatically
    /// (first target, most recent session date) and sets this, which drives
    /// `CalibrationPage`'s `.sheet(item:)`. Separate from `StatsView`'s/
    /// `TargetDetailPage`'s own `linkingSession` `@State` so the three call
    /// sites never fight over one shared trigger.
    var calibNeedLinkSession: LinkingSession?

    /// The best-frame selection currently shown in `StackListSheet` (R7-B4),
    /// `nil` while it's still (re)computing -- recomputed every time the
    /// sheet's keep-fraction slider settles on a new value, since `select`
    /// is a cheap, read-only query. Cleared whenever the sheet closes so a
    /// stale previous session's selection never flashes on next open.
    var stackListSelection: StackSelection?
    /// Set once `exportStackList()` finishes -- the sheet's "Exportálás"
    /// button switches to a "kész" state and shows this path.
    var stackListExportDir: URL?

    var isBusy: Bool = false
    var progressText: String = ""
    var lastError: String?

    /// Set on a successful `createSession(...)` so `NewSessionSheet` can
    /// observe it and dismiss itself.
    var lastCreatedSessionDir: URL?

    /// The in-flight background operation, if any. "Mégse" cancels it, but
    /// since the AstroCore calls underneath (scan/audit/rate) are plain
    /// synchronous functions with no cancellation checks of their own, this
    /// only ever prevents the FOLLOW-UP step (applying the result to
    /// published state) from running -- it can never abort mid-operation.
    @ObservationIgnored
    private var currentTask: Task<Void, Never>?

    // MARK: - Root selection

    init() {
        loadRecentRoots()
        AppState.shared = self
    }

    /// Called once from `.onAppear`: resolves a previously-saved
    /// security-scoped bookmark if there is one, otherwise falls back to
    /// `AstroConfig()`'s default root path. Never scans automatically --
    /// a large external volume should only be walked on explicit request.
    ///
    /// `-ResetOnboarding` (acceptance ⓑ): a debug-only launch argument that
    /// clears the saved bookmark before resolving, so the first-run flow
    /// (`WelcomeView`/`FirstScanView`) can be exercised on a machine that
    /// already has a real library configured, without touching that
    /// configuration on disk.
    func resolveRootOnLaunch() {
        startVolumeMountObserverIfNeeded()
        if ProcessInfo.processInfo.arguments.contains("-ResetOnboarding") {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        }
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey),
           let url = Self.resolveBookmark(data)
        {
            _ = url.startAccessingSecurityScopedResource()
            openRoot(at: url)
            return
        }
        openRoot(at: URL(fileURLWithPath: AstroConfig().rootPath, isDirectory: true))
    }

    /// "Újrapróbálás" on the access-denied/not-mounted screens: re-checks the
    /// currently configured root without prompting for a new one.
    func retryRootAccess() {
        openRoot(at: URL(fileURLWithPath: config.rootPath, isDirectory: true))
    }

    /// "Mappa választása…": prompts via `NSOpenPanel`, then hands the chosen
    /// URL to `selectRoot(at:)`.
    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Kiválasztás"
        panel.message = "Válaszd ki a képkönyvtár gyökerét"
        if !config.rootPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectRoot(at: url)
    }

    /// The one place that actually switches roots from a freshly-chosen
    /// `URL` (folder picker, `WelcomeView`'s drop target, or the toolbar's
    /// "Legutóbbi könyvtárak" list resolving its bookmark first): persists a
    /// security-scoped bookmark as BOTH the "current root" bookmark and a
    /// "Legutóbbi könyvtárak" entry, then opens it.
    func selectRoot(at url: URL) {
        if let bookmark = makeBookmark(for: url) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            rememberRecentRoot(url: url, bookmark: bookmark)
        }
        openRoot(at: url)
    }

    /// "Legutóbbi könyvtárak ▸" menu selection: resolves the stored bookmark
    /// back into an accessible `URL` first (it's a different security scope
    /// than whatever's currently active), then switches to it same as any
    /// other `selectRoot(at:)` call.
    func selectRecentRoot(_ recent: RecentRoot) {
        guard let url = Self.resolveBookmark(recent.bookmark) else { return }
        _ = url.startAccessingSecurityScopedResource()
        selectRoot(at: url)
    }

    private func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func loadRecentRoots() {
        guard let datas = UserDefaults.standard.array(forKey: Self.recentRootsKey) as? [Data] else { return }
        recentRoots = datas.compactMap { data in
            Self.resolveBookmark(data).map { RecentRoot(path: $0.path, bookmark: data) }
        }
    }

    private func rememberRecentRoot(url: URL, bookmark: Data) {
        recentRoots.removeAll { $0.path == url.path }
        recentRoots.insert(RecentRoot(path: url.path, bookmark: bookmark), at: 0)
        if recentRoots.count > 5 {
            recentRoots.removeLast(recentRoots.count - 5)
        }
        UserDefaults.standard.set(recentRoots.map(\.bookmark), forKey: Self.recentRootsKey)
    }

    private static func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// B6: a volume that was missing at launch (`.notMounted`) but then gets
    /// mounted should retry access on its own, not only when the user
    /// happens to press "Újrapróbálás" -- registered once per process.
    private func startVolumeMountObserverIfNeeded() {
        guard mountObserver == nil else { return }
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.rootStatus == .notMounted else { return }
                self.retryRootAccess()
            }
        }
    }

    /// Loads `<url>/.astro_tool/config.json` if present (else defaults),
    /// forces `rootPath` to the chosen URL, then opens (creating if needed)
    /// the database at `<url>/.astro_tool/astrotool.sqlite` -- or sets
    /// `rootStatus` to explain why it couldn't.
    private func openRoot(at url: URL) {
        let path = url.path
        let configURL = url
            .appendingPathComponent(".astro_tool", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)

        var loadedConfig = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
        loadedConfig.rootPath = path
        config = loadedConfig
        db = nil
        lastError = nil
        lastScanDate = nil
        didDismissFirstRun = false

        guard FileManager.default.fileExists(atPath: path) else {
            rootStatus = Self.classifyMissingRoot(path: path)
            return
        }

        do {
            let toolDir = url.appendingPathComponent(".astro_tool", isDirectory: true)
            try FileManager.default.createDirectory(at: toolDir, withIntermediateDirectories: true)
            let dbURL = toolDir.appendingPathComponent("astrotool.sqlite", isDirectory: false)
            let opened = try Database(path: dbURL.path)
            db = opened
            rootStatus = .notScanned
            hasDSSFilelists = (try? opened.hasTrackedFileWithSuffix(".dssfilelist")) ?? false
            lastScanDate = try? opened.lastRunDate(kind: "scan")
            // B5: acked groups must be known before the sidebar's badge or
            // the Audit page can honor them, and neither is guaranteed to
            // call into an explicit "load" method first.
            ackedKeys = (try? opened.ackedKeys()) ?? []
        } catch let error as AstroError {
            handle(error)
        } catch {
            // Directory creation / DB open failing for a reason other than
            // an AstroError case is, in practice, almost always a TCC
            // permission problem -- present the same guidance screen.
            rootStatus = .accessDenied
            lastError = "\(error)"
        }
    }

    private static func classifyMissingRoot(path: String) -> RootStatus {
        if path.hasPrefix("/Volumes/") {
            let comps = path.split(separator: "/", omittingEmptySubsequences: true)
            if comps.count >= 2 {
                let volume = "/" + comps[0] + "/" + comps[1]
                if !FileManager.default.fileExists(atPath: volume) {
                    return .notMounted
                }
            }
        }
        return .noRoot
    }

    // MARK: - Error handling

    private func handle(_ error: Error) {
        if let astroError = error as? AstroError {
            switch astroError {
            case .accessDenied:
                rootStatus = .accessDenied
            case .volumeNotMounted:
                rootStatus = .notMounted
            default:
                lastError = Self.describe(astroError)
            }
        } else {
            lastError = "\(error)"
        }
    }

    private static func describe(_ error: AstroError) -> String {
        switch error {
        case .accessDenied(let path):
            return "Hozzáférés megtagadva: \(path)"
        case .volumeNotMounted(let path):
            return "A kötet nincs csatlakoztatva: \(path)"
        case .pathNotFound(let path):
            return "Az útvonal nem található: \(path)"
        case .corruptFITS(let path, let reason):
            return "Sérült FITS fájl (\(path)): \(reason)"
        case .databaseError(let message):
            return "Adatbázis hiba: \(message)"
        case .writeForbidden(let path):
            return "Írás nem engedélyezett: \(path)"
        case .sirilNotFound(let path):
            return "Siril nem található itt: \(path)"
        case .invalidInput(let reason):
            return "Érvénytelen bemenet: \(reason)"
        }
    }

    // MARK: - Cancellation

    /// "Mégse": see `currentTask`'s doc comment for exactly what this can
    /// and can't stop.
    func cancelCurrentOperation() {
        currentTask?.cancel()
    }

    // MARK: - Scan

    func runScan() {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Könyvtár beolvasása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await Task.detached(priority: .userInitiated) { [weak self] in
                    // Recorded in `runs` (kind "scan") so `lastRunDate(kind:)`
                    // can answer "has this root ever been scanned" and drive
                    // the toolbar's "Utolsó: <relatív idő>" caption across
                    // launches -- best-effort (`try?`), a bookkeeping failure
                    // here shouldn't block the scan itself.
                    let runID = try? db.beginRun(kind: "scan", root: cfg.rootPath, configJSON: nil)
                    let scanner = LibraryScanner(config: cfg, db: db)
                    let result = try scanner.scan(subpath: nil) { count in
                        Task { @MainActor in
                            self?.progressText = "Beolvasva: \(count) fájl…"
                        }
                    }
                    if let runID { try? db.finishRun(id: runID) }
                    return result
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.scanSummary = summary
                self.rootStatus = .ok
                self.lastScanDate = Date()
                self.progressText =
                    "Kész — új: \(summary.added), frissült: \(summary.updated), " +
                    "változatlan: \(summary.unchanged), hiányzó: \(summary.missing)"

                // Refresh Stats/Calib so those tabs never show stale
                // pre-scan data. Best-effort: a failure here shouldn't turn
                // an otherwise-successful scan into a reported error.
                let statsTask = Task.detached(priority: .userInitiated) {
                    try StatsQueries.perTarget(db: db, config: cfg)
                }
                if let statsResult = try? await statsTask.value {
                    self.stats = statsResult
                }
                let calibTask = Task.detached(priority: .userInitiated) {
                    try CalibAnalyzer.coverage(db: db, config: cfg)
                }
                if let calibResult = try? await calibTask.value {
                    self.calibNeeds = calibResult
                }
                let calibHealthTask = Task.detached(priority: .userInitiated) {
                    try CalibHealth.report(db: db, config: cfg)
                }
                if let calibHealthResult = try? await calibHealthTask.value {
                    self.calibHealth = calibHealthResult
                }
                let projectsTask = Task.detached(priority: .userInitiated) {
                    try ProjectStatusQueries.projects(db: db, config: cfg)
                }
                if let projectsResult = try? await projectsTask.value {
                    self.projectStates = projectsResult
                }
                let dssCheckTask = Task.detached(priority: .userInitiated) {
                    try db.hasTrackedFileWithSuffix(".dssfilelist")
                }
                if let dssCheckResult = try? await dssCheckTask.value {
                    self.hasDSSFilelists = dssCheckResult
                }
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Audit

    /// `includeSuspicious` is stashed for later use by `generateSuggestions()`
    /// (and mirrors whatever the "Gyanúsak is a scriptbe" toggle is bound
    /// to). `includeDuplicates` (R9-T2/A.5's "Duplikátum-keresés nélkül
    /// (gyors)" menu item) skips `DuplicateFinder`'s content hashing -- the
    /// slow part of a full audit on a large library -- while every
    /// protocol-based rule still runs; defaults to `true` so every existing
    /// call site (and the CLI's own default) is unaffected.
    func runAudit(includeSuspicious: Bool, includeDuplicates: Bool = true) {
        guard let db else { return }
        let cfg = config
        includeSuspiciousInScript = includeSuspicious

        let opID = beginOperation("Audit fut…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (runID, findings) = try await Task.detached(priority: .userInitiated) {
                    let engine = AuditEngine(config: cfg, db: db)
                    return try engine.run(includeDuplicates: includeDuplicates)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.lastRunID = runID
                self.findings = findings
                self.progressText = "Audit kész: \(findings.count) találat"

                // Best-effort refresh of the cleanup report, same as Stats/
                // Calib get refreshed after a scan -- a failure here
                // shouldn't turn an otherwise-successful audit into a
                // reported error.
                if let cleanupResult = try? await Task.detached(priority: .userInitiated, operation: {
                    try CleanupReport.build(db: db, config: cfg)
                }).value {
                    self.cleanupSummary = cleanupResult
                }
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Finding acks (B5)

    /// The sidebar's Audit badge (spec A.5/T2's "sidebar Audit badge counts
    /// sureError groups EXCLUDING acked ones") -- grouped via the same
    /// `FindingGrouper` the page itself uses, so a single recurring root
    /// cause (e.g. one nested-session-tree finding) counts once, and any
    /// group the user has already acked away is excluded so the badge stops
    /// nagging about something already reviewed.
    var auditErrorBadgeCount: Int {
        let sureErrors = findings.filter { $0.severity == .sureError }
        let groups = FindingGrouper.group(sureErrors, config: config)
        return groups.filter { !ackedKeys.contains(Database.ackKey(category: $0.key.category, groupKey: $0.key.groupKey)) }.count
    }

    /// Marks one `FindingGrouper` group as acknowledged so it stays hidden
    /// (unless `showAckedFindings` is on) across re-audits -- keyed on
    /// `(category, groupKey)`, not any individual finding's id, which is why
    /// this survives `runAudit` inserting a fresh set of `findings` rows.
    func ackFindingGroup(category: String, groupKey: String, note: String? = nil) {
        guard let db else { return }
        do {
            try db.ackFindingGroup(category: category, groupKey: groupKey, note: note)
            ackedKeys.insert(Database.ackKey(category: category, groupKey: groupKey))
        } catch {
            handle(error)
        }
    }

    /// Reverses `ackFindingGroup` -- the group reappears (undimmed) the next
    /// time findings are shown.
    func unackFindingGroup(category: String, groupKey: String) {
        guard let db else { return }
        do {
            try db.unackFindingGroup(category: category, groupKey: groupKey)
            ackedKeys.remove(Database.ackKey(category: category, groupKey: groupKey))
        } catch {
            handle(error)
        }
    }

    /// Writes a suggestion script from the last audit's findings and reveals
    /// it in Finder. A no-op if there's nothing actionable to write.
    func generateSuggestions() {
        guard !findings.isEmpty else { return }
        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        let writeGuard = WriteGuard(root: root)
        let findingsCopy = findings
        let includeSuspicious = includeSuspiciousInScript

        let opID = beginOperation("Javaslat-script írása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try SuggestionScript.write(
                        findings: findingsCopy,
                        root: root,
                        includeSuspicious: includeSuspicious,
                        timestamp: Date(),
                        using: writeGuard
                    )
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                if let url {
                    self.progressText = "Script elmentve: \(url.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    self.progressText = "Nincs javasolható tétel."
                }
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Renders and writes one target's acquisition export (`astrobin`/`csv`/
    /// `md`) under `.astro_tool/exports/` and reveals it in Finder -- the
    /// Statisztika tab's per-target "Exportálás…" menu.
    func exportAcquisition(target: String, format: ExportFormat) {
        guard let db else { return }
        let cfg = config
        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        let writeGuard = WriteGuard(root: root)

        let opID = beginOperation("Exportálás…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try AcquisitionExport.write(
                        target: target, format: format, timestamp: Date(), db: db, config: cfg, using: writeGuard
                    )
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.progressText = "Exportálva: \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Cleanup

    /// Loads the size-ordered cleanup report (residue + duplicate-content
    /// groups) for "Áttekintés"'s takarítás box. Safe to call any time the
    /// DB has data -- unlike `runAudit`, this never runs duplicate-content
    /// hashing itself, it only reads whatever's already cached.
    func loadCleanup() {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Takarítási riport számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try CleanupReport.build(db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.cleanupSummary = result
                self.progressText = "Takarítási riport kész: \(result.groups.count) csoport"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Writes the quarantine-based cleanup suggestion script from the last
    /// loaded `cleanupSummary` and reveals it in Finder. A no-op if there's
    /// nothing to clean up.
    func generateCleanupScript() {
        guard let summary = cleanupSummary, !summary.groups.isEmpty else { return }
        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        let writeGuard = WriteGuard(root: root)
        let timestamp = Date()
        let findings = CleanupReport.quarantineFindings(for: summary, timestamp: timestamp)

        let opID = beginOperation("Takarítási script írása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try SuggestionScript.write(
                        findings: findings,
                        root: root,
                        includeSuspicious: true,
                        timestamp: timestamp,
                        using: writeGuard,
                        commentSuspicious: false
                    )
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                if let url {
                    self.progressText = "Takarítási script elmentve: \(url.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    self.progressText = "Nincs takarítható tétel."
                }
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Stats

    /// Loads `stats` plus every target's session detail rows in one go (one
    /// `SessionStatsQueries.sessions` call per target, on the same
    /// background operation) -- with the library's target count this is
    /// cheap, and it's what lets `StatsView`'s hierarchical `Table` show
    /// session sub-rows without a separate lazy-load-on-expand step.
    func loadStats() {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Statisztika számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (result, sessionsByTarget, panelsByTarget, stacksByTarget, stackGroupsByTarget) = try await Task.detached(priority: .userInitiated) {
                    let stats = try StatsQueries.perTarget(db: db, config: cfg)
                    var sessionsByTarget: [String: [SessionDetail]] = [:]
                    var panelsByTarget: [String: PanelReport] = [:]
                    var stackGroupsByTarget: [String: [StackGroup]] = [:]
                    let discoveredStacks = try StackDiscovery.discover(db: db, config: cfg)
                    let stacksByTarget = Dictionary(uniqueKeysWithValues: discoveredStacks.map { ($0.target, $0) })
                    for stat in stats {
                        sessionsByTarget[stat.target] = try SessionStatsQueries.sessions(
                            target: stat.target, db: db, config: cfg
                        )
                        panelsByTarget[stat.target] = try FieldGeometry.panels(
                            target: stat.target, db: db, config: cfg
                        )
                        // R8-3: only worth grouping targets that actually have
                        // discovered stacks -- same "don't do useless work"
                        // stance as skipping an empty `stacksByTarget` entry.
                        if let report = stacksByTarget[stat.target], !report.stacks.isEmpty {
                            stackGroupsByTarget[stat.target] = try StackDiscovery.groupedStacks(
                                target: stat.target, db: db, config: cfg
                            )
                        }
                    }
                    return (stats, sessionsByTarget, panelsByTarget, stacksByTarget, stackGroupsByTarget)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.stats = result
                self.sessionDetailsByTarget = sessionsByTarget
                self.panelReportsByTarget = panelsByTarget
                self.stackReportsByTarget = stacksByTarget
                self.stackGroupsByTarget = stackGroupsByTarget
                self.progressText = "Statisztika kész: \(result.count) célpont"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Planner

    /// Loads the plan for `date` (`nil` means tonight) for every target.
    /// Also resolves the effective observing site (config's explicit
    /// `site`, else the median SITELAT/SITELONG across the library) and
    /// tonight's dark-time/Moon summary -- cached into `resolvedSite`/
    /// `nightInfo`, in memory ONLY, never written to `config.site` on disk
    /// (see `resolvedSite`'s own doc for why that used to be a bug).
    /// `date` is remembered as `planDate` so `TonightPage` can show which
    /// night is currently on screen (R9-T4/A.1's "Terv erre az éjszakára").
    func loadPlan(date: Date? = nil) {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Terv számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (result, resolvedSite, night) = try await Task.detached(priority: .userInitiated) {
                    let plans = try Planner.plan(date: date, db: db, config: cfg)
                    let site = try Planner.resolveSite(db: db, config: cfg)
                    let night = Planner.nightInfo(date: date, site: site)
                    return (plans, site, night)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.plan = result
                self.resolvedSite = resolvedSite
                self.nightInfo = night
                self.planDate = date
                self.progressText = "Terv kész: \(result.count) célpont"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Loads the month-at-a-glance planning calendar (`Planner.month`,
    /// R7-B5) for the "Hónap" sheet. Never triggered automatically, same
    /// "time-of-day-sensitive" reasoning as `loadPlan()`.
    func loadMonthPlan() {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Havi terv számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Planner.month(db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.monthPlan = result
                self.progressText = "Havi terv kész: \(result.count) éjszaka"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Project pipeline status

    /// Loads every target's pipeline status for the "Projektek" box. Safe to
    /// call any time the DB has data -- read-only, same shape as
    /// `loadCalib()`.
    func loadProjects() {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Projekt-állapot számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ProjectStatusQueries.projects(db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.projectStates = result
                self.progressText = "Projekt-állapot kész: \(result.count) célpont"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Tags

    /// Adds a free-form tag to a target (`date == nil`) or one of its
    /// sessions (`date` given, one of that target's `sessionDates`).
    /// Idempotent at the DB layer -- adding the same tag twice is a no-op.
    /// Refreshes `stats` (always) and `sessionDetails` (if this target is
    /// currently selected) so the chip UI reflects the change immediately.
    func addTag(target: String, date: String?, tag: String) {
        guard let db else { return }
        let cfg = config
        let record = TagRecord(kind: date == nil ? "target" : "session", target: target, sessionDate: date, tag: tag)

        let opID = beginOperation("Címke hozzáadása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try db.addTag(record)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                await self.reloadStatsAfterTagChange(db: db, config: cfg, target: target)
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Removes a previously added tag; a no-op if it wasn't present.
    func removeTag(target: String, date: String?, tag: String) {
        guard let db else { return }
        let cfg = config
        let record = TagRecord(kind: date == nil ? "target" : "session", target: target, sessionDate: date, tag: tag)

        let opID = beginOperation("Címke törlése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try db.removeTag(record)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                await self.reloadStatsAfterTagChange(db: db, config: cfg, target: target)
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Best-effort refresh of `stats` (always) and `target`'s entry in
    /// `sessionDetailsByTarget` after a tag mutation -- mirrors the post-scan
    /// refresh in `runScan()`. Best-effort: a failure here shouldn't turn an
    /// otherwise-successful tag edit into a reported error.
    private func reloadStatsAfterTagChange(db: Database, config: AstroConfig, target: String) async {
        if let statsResult = try? await Task.detached(priority: .userInitiated, operation: {
            try StatsQueries.perTarget(db: db, config: config)
        }).value {
            self.stats = statsResult
        }
        if let sessionsResult = try? await Task.detached(priority: .userInitiated, operation: {
            try SessionStatsQueries.sessions(target: target, db: db, config: config)
        }).value {
            self.sessionDetailsByTarget[target] = sessionsResult
        }
    }

    // MARK: - Goal (B11)

    /// Writes/replaces a target's `goal:Xh` tag (R9-T3/B11's inline
    /// hour-stepper popover): removes every existing `goal:*` tag first
    /// (there should only ever be at most one, but this is defensive against
    /// a manually-edited DB with more), then adds the new one -- unless
    /// `hours` is `nil`/`0`, which just clears the goal entirely ("Nincs
    /// cél"). Refreshes `stats` (+ this target's `sessionDetailsByTarget`
    /// entry, via the same helper a plain tag edit uses), `projectStates`
    /// (so `missingSeconds`/phase reflect the new goal), and `plan` (if
    /// already loaded -- so "Ma este"'s Cél/Hiányzik columns don't need a
    /// separate manual refresh) -- the three places acceptance ⓓ checks.
    func setGoal(target: String, hours: Double?) {
        guard let db else { return }
        let cfg = config
        let existingGoalTags = (stats.first { $0.target == target }?.tags ?? []).filter {
            $0.lowercased().hasPrefix("goal:")
        }

        let opID = beginOperation("Cél mentése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    for tag in existingGoalTags {
                        try db.removeTag(TagRecord(kind: "target", target: target, sessionDate: nil, tag: tag))
                    }
                    if let hours, hours > 0 {
                        let tag = Self.formatGoalTag(hours: hours)
                        try db.addTag(TagRecord(kind: "target", target: target, sessionDate: nil, tag: tag))
                    }
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                await self.reloadStatsAfterTagChange(db: db, config: cfg, target: target)
                if let projectsResult = try? await Task.detached(priority: .userInitiated, operation: {
                    try ProjectStatusQueries.projects(db: db, config: cfg)
                }).value {
                    self.projectStates = projectsResult
                }
                // `self.planDate` (not always `nil`): if the currently
                // shown plan is date-scoped (a calendar row's "Terv erre az
                // éjszakára"), a goal edit must refresh THAT night's plan,
                // not silently snap the view back to tonight's.
                let planDate = self.planDate
                if self.plan != nil, let planResult = try? await Task.detached(priority: .userInitiated, operation: {
                    try Planner.plan(date: planDate, db: db, config: cfg)
                }).value {
                    self.plan = planResult
                }
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Same integral-hours-print-without-decimal convention
    /// `ProjectStatusQueries.formatGoalHours` uses for the todo sentence, so
    /// a `6`-hour goal round-trips as `"goal:6h"`, not `"goal:6.0h"`.
    private static nonisolated func formatGoalTag(hours: Double) -> String {
        if hours.rounded() == hours { return "goal:\(Int(hours))h" }
        return "goal:\(String(format: "%.1f", hours))h"
    }

    // MARK: - Target detail overview extras (R9-T3/A.3)

    /// The Célpont-részletek "Áttekintés" segment's coordinate box: the
    /// median resolved (RA, Dec) across the target's usable session lights,
    /// plus which source actually contributed it. Deliberately only three
    /// labels (unlike `TargetReport`'s more granular four) -- the spec's own
    /// wording ("WCS fejléc"/"plate-solve"/"nincs").
    struct TargetCoordinateInfo: Equatable {
        var raDeg: Double
        var decDeg: Double
        var sourceLabel: String
    }

    /// `nil` until `loadTargetDetail(target:)` has run for the current
    /// target; ALSO `nil` (rather than some default) when the target
    /// genuinely has no resolvable coordinate at all -- the Overview segment
    /// treats that the same as `sourceLabel == "nincs"` (shows the
    /// "Plate-solve…" button either way).
    var targetCoordinateInfo: TargetCoordinateInfo?
    /// One entry per distinct `SessionDetail.setupDescriptor` among the
    /// target's sessions (camera/gyújtótáv/gain/szűrő fingerprint, R6-3) --
    /// the Overview segment pairs each with its session count.
    var targetSetupDescriptors: [String] = []
    /// The target's calibration status, one `SessionMatcher.match` per
    /// session -- the Overview segment's "calibration status filtered to
    /// this target" line.
    var targetSessionCalibrations: [SessionCalibration] = []
    /// One `NightHealth.report` per session date, keyed by `dateRaw` -- the
    /// Sessionök table's "Hűtés"/"Fókusz" columns need every row's verdict
    /// up front (unlike the inline detail band below the table, which only
    /// ever needs the SELECTED row's, via the existing `nightHealth`/
    /// `loadSessionTimeline`).
    var targetNightHealthByDate: [String: NightHealthReport] = [:]

    /// Bundles every query `TargetDetailPage.onAppear` needs so they can all
    /// load inside ONE `Task`/`beginOperation` -- see the doc on `runRate`'s
    /// inline summaries+advice reload for why: `beginOperation` cancels
    /// whatever `currentTask` is currently running, so firing several public
    /// `loadXxx()` methods back-to-back with no `await` between them (as a
    /// naive `onAppear` calling `loadStats()`, `loadPlan()`,
    /// `loadCalibHealth()`, ... one after another would) lets each new call
    /// cancel the previous one's outer `Task` before its own `guard
    /// !Task.isCancelled` line ever runs -- so only the LAST call's result
    /// would actually land. Bundling avoids that race entirely for the one
    /// page that needs this many queries at once.
    private struct TargetDetailBundle {
        var stats: [TargetStats]
        var sessions: [SessionDetail]
        var panels: PanelReport
        var stacksByTarget: [String: TargetStacks]
        var stackGroups: [StackGroup]
        var projects: [ProjectState]
        var plan: [TargetPlan]
        var site: SiteRule
        var calibHealth: CalibHealthReport
        var coordInfo: TargetCoordinateInfo?
        var setupDescriptors: [String]
        var calibs: [SessionCalibration]
        var nightHealthByDate: [String: NightHealthReport]
        var qualitySummaries: [SessionQualitySummary]
        var advice: ExposureAdvice
    }

    /// Loads everything the Célpont-részletek page's header + Áttekintés/
    /// Minőség segments need for `target`, in one background hop -- called
    /// from `TargetDetailPage.onAppear` (and again whenever the page is
    /// re-created for a different target, via its `.id(target)`). Refreshes
    /// the SAME published properties `loadStats()`/`loadPlan()`/
    /// `loadCalibHealth()`/`loadQualitySummaries()`/`loadExposureAdvice()`
    /// each own, so a target opened straight from the sidebar (never having
    /// visited "Minden célpont"/"Ma este") still gets a fully populated page,
    /// AND the effect is the same "refresh everything" a manual reload on
    /// any of those other pages would give.
    func loadTargetDetail(target: String) {
        guard let db else { return }
        let cfg = config
        targetCoordinateInfo = nil
        targetSetupDescriptors = []
        targetSessionCalibrations = []
        targetNightHealthByDate = [:]
        qualitySummaries = []
        exposureAdvice = nil
        sessionTimeline = nil
        nightHealth = nil

        let opID = beginOperation("Célpont-részletek betöltése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let bundle = try await Task.detached(priority: .userInitiated) {
                    let stats = try StatsQueries.perTarget(db: db, config: cfg)
                    let sessions = try SessionStatsQueries.sessions(target: target, db: db, config: cfg)
                    let panels = try FieldGeometry.panels(target: target, db: db, config: cfg)
                    let discovered = try StackDiscovery.discover(db: db, config: cfg)
                    let stacksByTarget = Dictionary(uniqueKeysWithValues: discovered.map { ($0.target, $0) })
                    let stackGroups: [StackGroup]
                    if let report = stacksByTarget[target], !report.stacks.isEmpty {
                        stackGroups = try StackDiscovery.groupedStacks(target: target, db: db, config: cfg)
                    } else {
                        stackGroups = []
                    }
                    let projects = try ProjectStatusQueries.projects(db: db, config: cfg)
                    let plan = try Planner.plan(db: db, config: cfg)
                    let site = try Planner.resolveSite(db: db, config: cfg)
                    let calibHealth = try CalibHealth.report(db: db, config: cfg)
                    let coordInfo = try Self.resolveCoordinateInfo(target: target, db: db)
                    let setupDescriptors = Array(Set(sessions.compactMap(\.setupDescriptor))).sorted()
                    var calibs: [SessionCalibration] = []
                    var nightHealthByDate: [String: NightHealthReport] = [:]
                    for session in sessions {
                        calibs.append(try SessionMatcher.match(target: target, date: session.dateRaw, db: db, config: cfg))
                        nightHealthByDate[session.dateRaw] = try NightHealth.report(target: target, date: session.dateRaw, db: db, config: cfg)
                    }
                    let qualitySummaries = try SessionQuality.summaries(target: target, db: db, config: cfg)
                    let advice = try ExposureAdvisor.advise(target: target, db: db, config: cfg)
                    return TargetDetailBundle(
                        stats: stats, sessions: sessions, panels: panels, stacksByTarget: stacksByTarget,
                        stackGroups: stackGroups, projects: projects, plan: plan, site: site,
                        calibHealth: calibHealth, coordInfo: coordInfo, setupDescriptors: setupDescriptors,
                        calibs: calibs, nightHealthByDate: nightHealthByDate,
                        qualitySummaries: qualitySummaries, advice: advice
                    )
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.stats = bundle.stats
                self.sessionDetailsByTarget[target] = bundle.sessions
                self.panelReportsByTarget[target] = bundle.panels
                self.stackReportsByTarget = bundle.stacksByTarget
                self.stackGroupsByTarget[target] = bundle.stackGroups
                self.projectStates = bundle.projects
                self.plan = bundle.plan
                // `bundle.plan` is always TODAY's plan (`Planner.plan` with
                // no `date:`) -- reset `planDate` too, so a previously
                // date-scoped "Ma este" view (via a calendar row's "Terv
                // erre az éjszakára") doesn't keep showing a stale caption
                // for a night this reload didn't actually recompute.
                self.planDate = nil
                self.resolvedSite = bundle.site
                self.calibHealth = bundle.calibHealth
                self.targetCoordinateInfo = bundle.coordInfo
                self.targetSetupDescriptors = bundle.setupDescriptors
                self.targetSessionCalibrations = bundle.calibs
                self.targetNightHealthByDate = bundle.nightHealthByDate
                self.qualitySummaries = bundle.qualitySummaries
                self.exposureAdvice = bundle.advice
                self.progressText = "Célpont-részletek kész: \(target)"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// App-layer copy of `TargetReport.resolveCoordinateInfo`'s query (that
    /// one is `private` inside `AstroCore/Export/TargetReport.swift`, and
    /// deriving a *label* rather than a full `CoordinateInfo` isn't worth a
    /// new AstroCore API for one call site) -- same `TargetCoordinates.
    /// medianCoordinates` query, collapsed to the spec's three labels.
    private static nonisolated func resolveCoordinateInfo(target: String, db: Database) throws -> TargetCoordinateInfo? {
        let allFiles = try db.allFiles(includeMissing: false)
        let targetLights = allFiles.filter { $0.target == target && $0.area == .sessions && $0.role == .light }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in targetLights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }

        guard let coord = TargetCoordinates.medianCoordinates(files: targetLights, meta: metaByFileID) else {
            return nil
        }

        var hasWCS = false
        var hasOther = false
        for file in targetLights {
            guard let id = file.id, let meta = metaByFileID[id] else { continue }
            if let headerJSON = meta.headerJSON,
               let data = headerJSON.data(using: .utf8),
               let cards = try? JSONDecoder().decode([String: String].self, from: data)
            {
                if Double(cards["CRVAL1"] ?? "") != nil, Double(cards["CRVAL2"] ?? "") != nil {
                    hasWCS = true
                } else if cards["RA"] != nil {
                    hasOther = true
                }
            }
            if meta.solvedRA != nil, meta.solvedDec != nil { hasOther = true }
        }

        let sourceLabel: String
        if hasWCS {
            sourceLabel = "WCS fejléc"
        } else if hasOther {
            sourceLabel = "plate-solve"
        } else {
            sourceLabel = "nincs"
        }
        return TargetCoordinateInfo(raDeg: coord.raDeg, decDeg: coord.decDeg, sourceLabel: sourceLabel)
    }

    // MARK: - Report files (R9-T3/A.3 "Riportok")

    /// Every generated report HTML for `target` under `.astro_tool/reports/`
    /// -- the whole-target report (`target-<sanitized>.html`,
    /// `TargetReport`) plus any per-night reports
    /// (`<sanitized>-<date>.html`, `NightReport`). Read-only `FileManager`
    /// listing, safe to call from a view's computed property (no DB, no
    /// background hop needed -- the Vasszabály only restricts WRITES to the
    /// library, and this doesn't even touch the library, only this tool's
    /// own `.astro_tool/reports/`).
    func reportFiles(for target: String) -> [URL] {
        guard !config.rootPath.isEmpty else { return [] }
        let reportsDir = URL(fileURLWithPath: config.rootPath, isDirectory: true)
            .appendingPathComponent(".astro_tool", isDirectory: true)
            .appendingPathComponent("reports", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: reportsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        let sanitized = Sanitizer.sanitize(target)
        return entries.filter { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(".html") else { return false }
            return name == "target-\(sanitized).html" || name.hasPrefix("\(sanitized)-")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// "Újragenerálás" on one Riportok row: re-derives whether `url` is the
    /// whole-target report or one night's report from its filename
    /// convention, and re-runs the matching export.
    func regenerateReport(_ url: URL, target: String) {
        let sanitized = Sanitizer.sanitize(target)
        let stem = url.deletingPathExtension().lastPathComponent
        if stem == "target-\(sanitized)" {
            exportTargetReport(target: target)
        } else if stem.hasPrefix("\(sanitized)-") {
            let date = String(stem.dropFirst(sanitized.count + 1))
            exportNightReport(target: target, date: date)
        }
    }

    // MARK: - Calibration hard-linking

    /// Computes the `CalibLinkPlan` for one session -- read-only, safe to
    /// call every time `CalibLinkSheet` appears. `calibLinkResult` is reset
    /// too, so reopening the sheet for a different session never shows a
    /// stale previous result before the new plan arrives.
    func loadCalibLinkPlan(target: String, date: String) {
        guard let db else { return }
        let cfg = config
        calibLinkPlan = nil
        calibLinkResult = nil

        let opID = beginOperation("Kalibráció-terv számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await Task.detached(priority: .userInitiated) {
                    try CalibLinker.plan(target: target, date: date, db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.calibLinkPlan = plan
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Applies `calibLinkPlan` through `CalibLinker.apply` (WriteGuard-gated
    /// hard-linking) -- the one place this button/flow actually writes
    /// anything. On success, `calibLinkResult` is set (so the sheet can show
    /// linked/skipped counts) and `plan.target`'s entry in
    /// `sessionDetailsByTarget` is refreshed, same as a tag edit does, so the
    /// session row's own dark/bias counts reflect the newly-linked files
    /// without requiring a manual "Frissítés".
    func applyCalibLinkPlan() {
        guard let plan = calibLinkPlan else { return }
        let cfg = config
        let root = URL(fileURLWithPath: cfg.rootPath, isDirectory: true)
        let writeGuard = WriteGuard(root: root)
        let target = plan.target

        let opID = beginOperation("Kalibráció linkelése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try CalibLinker.apply(plan, root: root, using: writeGuard)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.calibLinkResult = result
                self.progressText = "Linkelve: \(result.linked.count), kihagyva: \(result.skipped.count)"
                if let db = self.db {
                    if let refreshed = try? await Task.detached(priority: .userInitiated, operation: {
                        try SessionStatsQueries.sessions(target: target, db: db, config: cfg)
                    }).value {
                        self.sessionDetailsByTarget[target] = refreshed
                    }
                }
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Called when `CalibLinkSheet` closes, so its state never leaks into
    /// the next time it's opened (for this session or another one).
    func clearCalibLinkPlan() {
        calibLinkPlan = nil
        calibLinkResult = nil
    }

    /// R9-T5/A.4: resolves a `CalibNeed` (from the Lefedettség coverage
    /// table/action cards) to a concrete `(target, date)` pair and opens
    /// `CalibLinkSheet` for it -- pragmatic per spec ("map CalibNeed.targets
    /// to a session picker or link the first"): the need's first target, at
    /// its most recent session date. Uses `sessionDetailsByTarget` if
    /// already cached (from `loadStats()`), otherwise fetches it via
    /// `SessionStatsQueries.sessions` on demand -- the Kalibráció page never
    /// requires visiting "Minden célpont" first just to make "Linkelés…"
    /// work.
    func openCalibLinkSheet(forNeed need: CalibNeed) {
        guard let target = need.targets.first else { return }
        if let date = sessionDetailsByTarget[target]?.map(\.dateRaw).max() {
            calibNeedLinkSession = LinkingSession(target: target, date: date)
            return
        }
        guard let db else { return }
        let cfg = config
        Task { [weak self] in
            guard let self else { return }
            let sessions: [SessionDetail]
            do {
                sessions = try await Task.detached(priority: .userInitiated) {
                    try SessionStatsQueries.sessions(target: target, db: db, config: cfg)
                }.value
            } catch {
                return
            }
            self.sessionDetailsByTarget[target] = sessions
            if let date = sessions.map(\.dateRaw).max() {
                self.calibNeedLinkSession = LinkingSession(target: target, date: date)
            }
        }
    }

    // MARK: - Stack-list export (R7-B4)

    /// Computes `StackList.select` for one session at the given keep
    /// fraction -- read-only, safe to call every time `StackListSheet`
    /// appears AND every time its keep-slider settles on a new value.
    /// `stackListExportDir` is reset too, so adjusting the slider after a
    /// successful export goes back to showing the (now stale) selection
    /// preview rather than the old export result.
    func loadStackListSelection(target: String, date: String, keepFraction: Double) {
        guard let db else { return }
        let cfg = config
        stackListSelection = nil
        stackListExportDir = nil

        let opID = beginOperation("Stack-lista számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let selection = try await Task.detached(priority: .userInitiated) {
                    try StackList.select(target: target, date: date, keepFraction: keepFraction, db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.stackListSelection = selection
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Exports `stackListSelection` through `StackList.export`
    /// (WriteGuard-gated hardlinking + `.dssfilelist`/`.ssf` writing) and
    /// reveals the resulting stacklist directory in Finder. On success,
    /// `stackListExportDir` is set so the sheet can switch to a "kész" state.
    func exportStackList() {
        guard let selection = stackListSelection else { return }
        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        let writeGuard = WriteGuard(root: root)

        let opID = beginOperation("Stack-lista exportálása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let dir = try await Task.detached(priority: .userInitiated) {
                    try StackList.export(selection, root: root, using: writeGuard)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.stackListExportDir = dir
                self.progressText = "Exportálva: \(dir.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Called when `StackListSheet` closes, so its state never leaks into
    /// the next time it's opened (for this session or another one).
    func clearStackListSelection() {
        stackListSelection = nil
        stackListExportDir = nil
    }

    // MARK: - Night report (R7-B5)

    /// Renders and writes one session's HTML night-report card
    /// (`NightReport.write`) under `.astro_tool/reports/`, then opens it in
    /// the user's default browser -- the Statisztika tab's per-session
    /// "Éjszaka-riport…" button.
    func exportNightReport(target: String, date: String) {
        guard let db else { return }
        let cfg = config
        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        let writeGuard = WriteGuard(root: root)

        let opID = beginOperation("Éjszaka-riport készítése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try NightReport.write(target: target, date: date, timestamp: Date(), db: db, config: cfg, using: writeGuard)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.progressText = "Riport kész: \(url.lastPathComponent)"
                NSWorkspace.shared.open(url)
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Target report (R8-2)

    /// Renders and writes the full "everything about one target" HTML
    /// report (`TargetReport.write`) under `.astro_tool/reports/`, then
    /// opens it in the user's default browser -- the Statisztika tab's
    /// per-target "Célpont-riport" menu item, same open-in-browser
    /// convention as `exportNightReport`.
    func exportTargetReport(target: String) {
        guard let db else { return }
        let cfg = config
        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        let writeGuard = WriteGuard(root: root)

        let opID = beginOperation("Célpont-riport készítése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try TargetReport.write(target: target, db: db, config: cfg, using: writeGuard)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.progressText = "Riport kész: \(url.lastPathComponent)"
                NSWorkspace.shared.open(url)
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Calibration coverage

    func loadCalib() {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Kalibrációs lefedettség számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try CalibAnalyzer.coverage(db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.calibNeeds = result
                self.progressText = "Kalibráció kész: \(result.count) kombináció"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Loads the calibration-HEALTH report (flat discipline, bias inventory,
    /// dark master health) -- shown below the coverage table on the
    /// Kalibráció fül.
    func loadCalibHealth() {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Kalibráció-egészség számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try CalibHealth.report(db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.calibHealth = result
                self.progressText = "Kalibráció-egészség kész"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Sensor profiles (R7-B1 item C)

    /// Loads whatever's already persisted in `sensor_profile` -- read-only,
    /// never runs a measurement itself. Shown as the "Szenzor-profilok" list
    /// on the Kalibráció fül.
    func loadSensorProfiles() {
        guard let db else { return }

        let opID = beginOperation("Szenzor-profilok betöltése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try db.allSensorProfiles()
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.sensorProfiles = result
                self.progressText = "Szenzor-profilok betöltve: \(result.count) kombináció"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Runs `SensorProfiler.measure` in the background (the "Mérés" button):
    /// re-derives every `(camera, gain, offset)` combo's bias level/read
    /// noise/dark rate/EGAIN from tracked BIAS/DARK frames, persisting as it
    /// goes, then refreshes `sensorProfiles` with the fresh set.
    func measureSensorProfiles() {
        guard let db else { return }
        let cfg = config
        let root = URL(fileURLWithPath: cfg.rootPath, isDirectory: true)

        let opID = beginOperation("Szenzor-mérés indul…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    try SensorProfiler.measure(db: db, config: cfg, root: root) { message in
                        Task { @MainActor in
                            self?.progressText = message
                        }
                    }
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.sensorProfiles = result
                self.progressText = "Szenzor-mérés kész: \(result.count) kombináció"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - DSS ingest (R7-B2)

    /// Runs `DSSIngest.ingest` in the background (Áttekintés
    /// "DSS-adatok beolvasása" quick button): harvests every tracked
    /// `<frame>.info.txt`'s star metrics and every tracked `.dssfilelist`'s
    /// accept/reject decisions already sitting in the library. Refreshes
    /// `stats`/`sessionDetailsByTarget` afterward (via `loadStats()`) so a
    /// newly recorded DSS verdict count shows up on the Statisztika fül
    /// without a separate manual "Frissítés".
    func runIngestDSS() {
        guard let db else { return }
        let cfg = config
        let root = URL(fileURLWithPath: cfg.rootPath, isDirectory: true)
        dssIngestSummary = nil

        let opID = beginOperation("DSS-adatok beolvasása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    try DSSIngest.ingest(db: db, config: cfg, root: root) { message in
                        Task { @MainActor in
                            self?.progressText = message
                        }
                    }
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.dssIngestSummary = result
                self.progressText =
                    "DSS beolvasás kész: \(result.ratingsUpserted) rating, \(result.verdictsRecorded) döntés, " +
                    "\(result.skipped) kihagyva"
                self.loadStats()
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Rate

    /// `force`, when `true`, passes through to `Rater.rate` -- a deliberate
    /// full re-measure of every frame regardless of cache state, driven by
    /// `QualitySegment`'s "Újra minden keret mérése (lassú)" menu item (the
    /// manual escape hatch next to the self-heal `Rater` already does
    /// automatically for stale rows).
    ///
    /// On success, also refreshes the Minőség segment's "Session-minőség"
    /// (`qualitySummaries`) and Áttekintés segment's "Expozíció-tanácsadó"
    /// (`exposureAdvice`) panels for the same target -- both key off
    /// frame-score/quality data this very call just changed, and neither
    /// segment otherwise reloads them on a re-rate of the already-open
    /// target (only `TargetDetailPage.onAppear`'s `loadTargetDetail` does).
    /// Without this, the two panels are left showing whatever stale ("nincs
    /// adat"/"n/a") state they had before rating, even though the frame
    /// table below updates fine from `frameScores`.
    ///
    /// Deliberately done INLINE, inside this same `Task`/`opID`, rather
    /// than by calling the public `loadQualitySummaries(target:)`/
    /// `loadExposureAdvice(target:)` -- each of those calls its OWN
    /// `beginOperation`, which does `currentTask?.cancel()` on whatever
    /// `currentTask` currently is. Called back-to-back synchronously (no
    /// `await` between them), the second call would cancel the FIRST
    /// call's still-pending `Task` before its detached work even finishes,
    /// and that Task's own `guard !Task.isCancelled` would then silently
    /// discard its result once it resumes -- so only the last chained load
    /// would ever actually land. (The same latent race already exists in
    /// `runPlateSolve`'s `loadStats(); loadPlan()` chain; left alone here
    /// since it's a separate, pre-existing issue outside this fix's scope.)
    /// `noSiril` (R9-T3/A.3's "Siril nélkül (csak natív)" menu item): forces
    /// `provider` to `nil` regardless of whether a working Siril install is
    /// configured, so `Rater.rate` falls back to native-only metrics (star
    /// count/FWHM/roundness columns come back `nil`, background/exptime
    /// still compute) -- the GUI's first way to reach what the CLI's
    /// `--no-siril` flag already offered.
    func runRate(target: String, date: String?, force: Bool = false, noSiril: Bool = false) {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Pontozás indul…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await Task.detached(priority: .userInitiated) { [weak self] in
                    var provider: StarMetricsProvider?
                    if !noSiril, FileManager.default.isExecutableFile(atPath: cfg.rating.sirilPath) {
                        provider = try? SirilCLI(path: cfg.rating.sirilPath)
                    }
                    let rater = Rater(db: db, config: cfg, provider: provider)
                    return try rater.rate(target: target, date: date, force: force) { done, total in
                        Task { @MainActor in
                            self?.progressText = "Pontozás: \(done)/\(total)"
                        }
                    }
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.frameScores = results
                self.progressText = "Pontozás kész: \(results.count) frame"

                let (summaries, advice) = try await Task.detached(priority: .userInitiated) {
                    let summaries = try SessionQuality.summaries(target: target, db: db, config: cfg)
                    let advice = try ExposureAdvisor.advise(target: target, db: db, config: cfg)
                    return (summaries, advice)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.qualitySummaries = summaries
                self.exposureAdvice = advice
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Plate-solve backfill (R7-1)

    /// Runs `PlateSolver.solveTarget` for `target` in the background,
    /// showing per-frame progress via `progressText`. On completion (success
    /// OR a caught `PlateSolver.init` failure -- missing Siril -- handled by
    /// `handle(_:)`), `plateSolveSummary` is set so `PlateSolveSheet` can
    /// show the result, and `loadStats()`/`loadPlan()` are re-run so a newly
    /// solved coordinate immediately shows up in the plan/panel-tracking
    /// data instead of only after the user manually refreshes.
    func runPlateSolve(target: String) {
        guard let db else { return }
        let cfg = config
        plateSolveSummary = nil

        let opID = beginOperation("Plate-solve indul…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let solver = try PlateSolver(sirilPath: cfg.rating.sirilPath)
                    return try solver.solveTarget(target, db: db, config: cfg) { done, total in
                        Task { @MainActor in
                            self?.progressText = "Plate-solve: \(done)/\(total)"
                        }
                    }
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.plateSolveSummary = summary
                self.progressText = "Plate-solve kész: \(summary.solved)/\(summary.attempted) megoldva"
                self.loadStats()
                self.loadPlan()
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// R9-T4/A.1's "0 koordináta" empty state's "Plate-solve mindenre…"
    /// action -- solves every target that has at least one session light on
    /// record but no resolvable coordinate at all yet, one after another
    /// (same target selection `astrotool solve --all` uses), then refreshes
    /// `stats`/`plan` once every target's been attempted. Unlike
    /// `runPlateSolve`, there's no per-target sheet to show progress in --
    /// `progressText` carries the running "target N/M" caption instead.
    func runPlateSolveAll() {
        guard let db else { return }
        let cfg = config
        plateSolveSummary = nil

        let opID = beginOperation("Plate-solve (minden célpont) indul…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (summaries, targets) = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let allFiles = try db.allFiles(includeMissing: false)
                    let lights = allFiles.filter { $0.area == .sessions && $0.role == .light }
                    var metaByFileID: [Int64: FITSMetaRecord] = [:]
                    for file in lights {
                        guard let id = file.id else { continue }
                        if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
                    }
                    let targetsWithFrames = Set(lights.compactMap(\.target)).sorted()
                    let targets = targetsWithFrames.filter { t in
                        let targetLights = lights.filter { $0.target == t }
                        return TargetCoordinates.medianCoordinates(files: targetLights, meta: metaByFileID) == nil
                    }
                    guard !targets.isEmpty else { return ([String: SolveSummary](), [String]()) }

                    let solver = try PlateSolver(sirilPath: cfg.rating.sirilPath)
                    var summaries: [String: SolveSummary] = [:]
                    for t in targets {
                        summaries[t] = try solver.solveTarget(t, db: db, config: cfg) { done, total in
                            Task { @MainActor in
                                self?.progressText = "Plate-solve: \(t) (\(done)/\(total))"
                            }
                        }
                    }
                    return (summaries, targets)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                if targets.isEmpty {
                    self.progressText = "Nincs koordináta nélküli célpont."
                } else {
                    let solved = summaries.values.reduce(0) { $0 + $1.solved }
                    let attempted = summaries.values.reduce(0) { $0 + $1.attempted }
                    self.progressText = "Plate-solve kész: \(solved)/\(attempted) megoldva (\(targets.count) célpont)"
                }
                self.loadStats()
                self.loadPlan()
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Session quality (absolute metrics + night timeline)

    /// Loads `qualitySummaries` for `target` -- called whenever the Minőség
    /// fül's target picker changes. Clears `sessionTimeline` too, since a
    /// previously selected session's timeline no longer applies once the
    /// target itself changes.
    func loadQualitySummaries(target: String) {
        guard let db else { return }
        let cfg = config
        sessionTimeline = nil
        nightHealth = nil

        let opID = beginOperation("Minőség-összegzés számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try SessionQuality.summaries(target: target, db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.qualitySummaries = result
                self.progressText = "Minőség-összegzés kész: \(result.count) session"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Loads `exposureAdvice` for `target` (R7-B3 `ExposureAdvisor`) --
    /// called alongside `loadQualitySummaries` whenever the Minőség fül's
    /// target picker changes. Never surfaces a "no data" condition as an
    /// app error -- that comes back as `ExposureAdvice.notAvailableReason`,
    /// an ordinary (if unhelpful) result, not a failure.
    func loadExposureAdvice(target: String) {
        guard let db else { return }
        let cfg = config
        exposureAdvice = nil

        let opID = beginOperation("Expozíció-tanácsadó számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ExposureAdvisor.advise(target: target, db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.exposureAdvice = result
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Loads the night timeline AND the per-night hardware-health report
    /// (cooler stability + focus drift, R6-2) for one session -- called
    /// when a row in the quality summary section is selected. Both reads
    /// are cheap DB-only queries over the same session, so they share one
    /// background hop rather than two separate operations/progress texts.
    func loadSessionTimeline(target: String, date: String) {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Idővonal számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let timeline = try SessionTimeline.timeline(target: target, date: date, db: db, config: cfg)
                    let health = try NightHealth.report(target: target, date: date, db: db, config: cfg)
                    return (timeline, health)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.sessionTimeline = result.0
                self.nightHealth = result.1
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Global search (R9-T6/B3)

    /// Runs the sidebar's ⌘F/Enter global search and navigates to
    /// `Page.searchResults`. `Database.searchAll`'s notes section only ever
    /// sees README-sourced notes; this unions in whatever the T6 note
    /// editor additionally holds (`SessionNoteStore`, `.astro_tool/notes/`)
    /// the same way the CLI's `search` command does, with the README
    /// winning any `(target, date, key)` collision.
    func runSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery = trimmed
        currentPage = .searchResults
        guard let db, !trimmed.isEmpty else {
            searchResults = trimmed.isEmpty ? nil : SearchResults()
            return
        }
        let cfg = config

        let opID = beginOperation("Keresés…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    var results = try db.searchAll(query: trimmed)
                    let sessionCandidates = try db.allSessionPairs()
                    let storeHits = SessionNoteStore.search(
                        query: trimmed, root: URL(fileURLWithPath: cfg.rootPath, isDirectory: true),
                        sessions: sessionCandidates
                    )
                    results.notes = Self.mergeNoteHits(readme: results.notes, store: storeHits)
                    return results
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.searchResults = result
                self.progressText =
                    "Keresés kész: \(result.targets.count + result.sessions.count + result.files.count + result.notes.count) találat"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// De-dupes by `(target, date, key)`, README-sourced rows winning a
    /// collision -- the exact precedence `SessionStatsQueries` applies when
    /// building `SessionDetail.notes`, and the CLI's `search` command
    /// applies the same way (its own private copy, since the CLI and app
    /// targets don't share a module).
    private nonisolated static func mergeNoteHits(
        readme: [(target: String, date: String, key: String, value: String)],
        store: [(target: String, date: String, key: String, value: String)]
    ) -> [(target: String, date: String, key: String, value: String)] {
        struct Key: Hashable { let target: String; let date: String; let key: String }
        var seen = Set<Key>()
        var result = readme
        for row in readme { seen.insert(Key(target: row.target, date: row.date, key: row.key)) }
        for row in store where !seen.contains(Key(target: row.target, date: row.date, key: row.key)) {
            result.append(row)
        }
        return result.sorted { ($0.target, $0.date, $0.key) < ($1.target, $1.date, $1.key) }
    }

    // MARK: - Session notes (R9-T6/B4)

    /// This session's README-parsed notes ONLY (not merged with the note
    /// editor's own store) -- backs `SessionNoteSheet`'s read-only,
    /// lock-icon rows, which must show exactly what the README says.
    /// Read-only, synchronous: a single keyed `session_notes` lookup, cheap
    /// enough to call straight from a view (same stance `reportFiles(for:)`
    /// takes on synchronous reads).
    func readmeNotes(target: String, date: String) -> [String: String] {
        guard let db else { return [:] }
        return (try? db.sessionNotes(target: target, date: date)) ?? [:]
    }

    /// This session's note-editor-only notes (`SessionNoteStore`, under
    /// `.astro_tool/notes/`) -- backs `SessionNoteSheet`'s editable rows'
    /// initial values. Read-only, synchronous, safe to call speculatively
    /// for a session that was never edited (returns `[:]`).
    func storeNotes(target: String, date: String) -> [String: String] {
        guard !config.rootPath.isEmpty else { return [:] }
        return SessionNoteStore.load(target: target, date: date, root: URL(fileURLWithPath: config.rootPath, isDirectory: true))
    }

    /// Saves `SessionNoteSheet`'s editable rows for one session (B4) --
    /// writes via `SessionNoteStore.save` under `.astro_tool/notes/`, NEVER
    /// touching that session's `README.txt` (the iron rule). Refreshes
    /// `sessionDetailsByTarget[target]` afterwards so every reader of
    /// `SessionDetail.notes` already on screen (the Jegyzetek segment, the
    /// Sessionök table's README tooltip) reflects the save immediately,
    /// with no rescan needed.
    func saveSessionNotes(target: String, date: String, notes: [(String, String)]) {
        guard !config.rootPath.isEmpty else { return }
        guard let db else { return }
        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        let writeGuard = WriteGuard(root: root)
        let cfg = config

        let opID = beginOperation("Jegyzet mentése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let refreshed = try await Task.detached(priority: .userInitiated) {
                    try SessionNoteStore.save(target: target, date: date, notes: notes, using: writeGuard)
                    return try SessionStatsQueries.sessions(target: target, db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.sessionDetailsByTarget[target] = refreshed
                self.progressText = "Jegyzet elmentve."
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Batch actions (R9-T6/B14)

    /// "Minden célpont pontozása…" -- serially rates every target on
    /// record (the same `Rater.rate` call `runRate` makes for one target,
    /// looped, one `Rater`/Siril-provider instance reused across all of
    /// them), aggregating progress as "target i/N — done/total frame". The
    /// caller (the Műveletek menu) shows a confirm sheet with the target
    /// count/estimate BEFORE calling this -- this method itself never asks.
    func runRateAll() {
        guard let db else { return }
        let cfg = config
        let targets = stats.map(\.target)
        guard !targets.isEmpty else { return }

        let opID = beginOperation("Minden célpont pontozása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) { [weak self] in
                    var provider: StarMetricsProvider?
                    if FileManager.default.isExecutableFile(atPath: cfg.rating.sirilPath) {
                        provider = try? SirilCLI(path: cfg.rating.sirilPath)
                    }
                    let rater = Rater(db: db, config: cfg, provider: provider)
                    for (index, target) in targets.enumerated() {
                        _ = try rater.rate(target: target, date: nil, force: false) { done, total in
                            Task { @MainActor in
                                self?.progressText = "Pontozás: \(target) (\(index + 1)/\(targets.count)) — \(done)/\(total)"
                            }
                        }
                    }
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.progressText = "Pontozás kész: \(targets.count) célpont"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// "Expozíció-tanácsadó minden célpontra…" -- populates
    /// `exposureAdviceAll`, which `ExposureAdviceAllSheet`'s presentation is
    /// gated on (non-`nil` -> shown).
    func adviseAll() {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Expozíció-tanácsadó (minden célpont)…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ExposureAdvisor.adviseAll(db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.exposureAdviceAll = result
                self.progressText = "Expozíció-tanácsadó kész: \(result.count) célpont"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - New session

    /// Creates `sessions/<sanitize(catalog)_sanitize(name)>/<date>/...` (plus
    /// the matching `stacks`/`processed`/`calibration_library` entries) via
    /// `SessionCreator`. `date` must already be a canonical `YYYY-MM-DD`
    /// string -- callers (`NewSessionSheet`) are expected to validate via
    /// `SessionDateParser` before enabling the "Létrehozás" button, but this
    /// re-validates so the guard holds even if called from elsewhere.
    func createSession(catalog: String, name: String, date: String) {
        guard let parsedDate = SessionDateParser.parse(date), parsedDate.isCanonical else {
            lastError = "Érvénytelen dátum: \(date) (YYYY-MM-DD formátum szükséges)"
            return
        }
        guard rootStatus == .ok || rootStatus == .notScanned else {
            lastError = "A gyökér nem elérhető."
            return
        }

        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)

        let opID = beginOperation("Session létrehozása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try SessionCreator.create(root: root, catalogRaw: catalog, nameRaw: name, date: date)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.progressText = "Session létrehozva: \(result.targetFolder)/\(date)"
                if let lightsDir = result.createdURLs.first(where: { $0.lastPathComponent == "lights" }) {
                    let dirURL = lightsDir.deletingLastPathComponent()
                    self.lastCreatedSessionDir = dirURL
                    NSWorkspace.shared.activateFileViewerSelecting([dirURL])
                }
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Busy bookkeeping

    /// Identifies the in-flight operation so a stale completion (one whose
    /// `Task` was superseded by a newer `beginOperation` call before it
    /// finished -- e.g. the user cancels and immediately starts a different
    /// operation) can't clobber `isBusy`/`progressText` out from under the
    /// operation that's actually current.
    @ObservationIgnored
    private var currentOperationID: UUID?

    private func beginOperation(_ text: String) -> UUID {
        currentTask?.cancel()
        lastError = nil
        isBusy = true
        progressText = text
        let id = UUID()
        currentOperationID = id
        pendingActivityTitle[id] = text
        return id
    }

    /// B15: every operation started via `beginOperation` gets exactly one
    /// `ActivityEntry` here, regardless of which of the ~20 call sites
    /// started it -- outcome is read off `lastError`, which `beginOperation`
    /// always resets to `nil` at the start and `handle(_:)` always sets
    /// before the matching `catch { self.handle(error) }` calls this, so by
    /// the time this runs it faithfully reflects "did THIS operation fail".
    private func endOperation(_ id: UUID) {
        let title = pendingActivityTitle.removeValue(forKey: id)
        guard currentOperationID == id else { return }
        isBusy = false
        if let title {
            let outcome: ActivityEntry.Outcome = lastError.map { .error($0) } ?? .ok
            activityLog.insert(ActivityEntry(date: Date(), title: title, outcome: outcome), at: 0)
            if activityLog.count > 50 {
                activityLog.removeLast(activityLog.count - 50)
            }
        }
    }

    // MARK: - Finder helpers (R9-T1 toolbar menu)

    func revealRootInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: config.rootPath, isDirectory: true)])
    }

    func revealConfigInFinder() {
        let configURL = URL(fileURLWithPath: config.rootPath, isDirectory: true)
            .appendingPathComponent(".astro_tool", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    /// Reveals one root-relative path in Finder -- the Audit page's group
    /// `⋯` menu's "Első fájl megnyitása Finderben" (R9-T2/A.5).
    func revealPathInFinder(_ relativePath: String) {
        let url = URL(fileURLWithPath: config.rootPath, isDirectory: true).appendingPathComponent(relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Copies every given root-relative path, one per line, to the general
    /// pasteboard -- the Audit page's group `⋯` menu's "Összes útvonal
    /// másolása" (R9-T2/A.5).
    func copyPathsToPasteboard(_ paths: [String]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    // MARK: - First-run / staleness

    /// `true` once more than 24h have passed since `lastScanDate` -- drives
    /// the shell's dismissible "Új fájlok lehetnek. [Beolvasás]" banner
    /// (B6). `false` (no banner) before any scan has ever completed for
    /// this root, same "don't guess" stance used elsewhere in this file.
    var scanIsStale: Bool {
        guard let lastScanDate else { return false }
        return Date().timeIntervalSince(lastScanDate) > 24 * 3600
    }

    /// "5 perce" / "3 órája" / "2 napja" -- deliberately hand-rolled rather
    /// than `RelativeDateTimeFormatter` so the wording stays the same
    /// hand-picked Hungarian style as the rest of this hand-translated UI
    /// regardless of the user's system locale.
    static func relativeTimeText(since date: Date) -> String {
        let seconds = max(0, Int(-date.timeIntervalSinceNow))
        if seconds < 60 { return "most" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) perce" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) órája" }
        let days = hours / 24
        return "\(days) napja"
    }
}
