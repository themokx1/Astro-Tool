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

    var config: AstroConfig = AstroConfig()
    var db: Database?
    var rootStatus: RootStatus = .noRoot

    var scanSummary: ScanSummary?
    var findings: [Finding] = []
    var lastRunID: Int64?
    var includeSuspiciousInScript: Bool = false

    var cleanupSummary: CleanupSummary?

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

    /// Called once from `.onAppear`: resolves a previously-saved
    /// security-scoped bookmark if there is one, otherwise falls back to
    /// `AstroConfig()`'s default root path. Never scans automatically --
    /// a large external volume should only be walked on explicit request.
    func resolveRootOnLaunch() {
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

    /// "Mappa választása…": prompts via `NSOpenPanel`, persists a
    /// security-scoped bookmark for next launch, then opens the chosen root.
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
        persistBookmark(for: url)
        openRoot(at: url)
    }

    private func persistBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        } catch {
            // Non-fatal: the root is still usable for this run, only
            // persistence across launches is lost.
        }
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
                    let scanner = LibraryScanner(config: cfg, db: db)
                    return try scanner.scan(subpath: nil) { count in
                        Task { @MainActor in
                            self?.progressText = "Beolvasva: \(count) fájl…"
                        }
                    }
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.scanSummary = summary
                self.rootStatus = .ok
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
    /// to) -- the audit run itself always evaluates every rule plus
    /// duplicate detection, same as the CLI's default.
    func runAudit(includeSuspicious: Bool) {
        guard let db else { return }
        let cfg = config
        includeSuspiciousInScript = includeSuspicious

        let opID = beginOperation("Audit fut…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (runID, findings) = try await Task.detached(priority: .userInitiated) {
                    let engine = AuditEngine(config: cfg, db: db)
                    return try engine.run(includeDuplicates: true)
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
                if let count = try await self.refreshStatsCore(db: db, cfg: cfg) {
                    self.progressText = "Statisztika kész: \(count) célpont"
                }
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Planner

    /// Loads tonight's plan for every target. Also resolves the effective
    /// observing site (config's explicit `site`, else the median
    /// SITELAT/SITELONG across the library) and caches it back into
    /// `config.site` in memory ONLY -- never written to disk -- so a
    /// second "Frissítés" this session, or any other tab reading
    /// `appState.config`, sees the resolved coordinates without
    /// recomputing them from scratch every time.
    func loadPlan() {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Terv számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let count = try await self.refreshPlanCore(db: db, cfg: cfg) {
                    self.progressText = "Terv kész: \(count) célpont"
                }
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// StatsView's `.onAppear`: loads whichever of `stats`/`plan` is still
    /// missing, as ONE operation. Deliberately not `loadStats()` +
    /// `loadPlan()` called back-to-back from the view -- two synchronous
    /// `beginOperation`-based calls chain-cancel each other (see the
    /// refresh-core comment at the bottom of this file), so on first
    /// appearance only the plan would ever land and the stats table stayed
    /// empty until a second visit.
    func loadStatsTabIfNeeded() {
        guard let db else { return }
        let cfg = config
        let needStats = stats.isEmpty
        let needPlan = plan == nil
        guard needStats || needPlan else { return }

        let opID = beginOperation("Statisztika számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                if needStats, let count = try await self.refreshStatsCore(db: db, cfg: cfg) {
                    self.progressText = "Statisztika kész: \(count) célpont"
                }
                if needPlan, let count = try await self.refreshPlanCore(db: db, cfg: cfg) {
                    self.progressText = "Terv kész: \(count) célpont"
                }
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
                if let count = try await self.refreshCalibCore(db: db, cfg: cfg) {
                    self.progressText = "Kalibráció kész: \(count) kombináció"
                }
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
                if try await self.refreshCalibHealthCore(db: db, cfg: cfg) {
                    self.progressText = "Kalibráció-egészség kész"
                }
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// CalibrationView's `.onAppear`: loads whichever of the Kalibráció
    /// fül's three data sets (`calibNeeds`/`calibHealth`/`sensorProfiles`)
    /// is still missing, as ONE operation. Deliberately not three
    /// conditional `loadX()` calls back-to-back from the view -- those
    /// chain-cancel each other (see the refresh-core comment at the bottom
    /// of this file), so on first appearance only the LAST load in the
    /// chain ever landed and the tab needed several visits to fill in.
    func loadCalibTabIfNeeded() {
        guard let db else { return }
        let cfg = config
        let needCoverage = calibNeeds.isEmpty
        let needHealth = calibHealth == nil
        let needProfiles = sensorProfiles.isEmpty
        guard needCoverage || needHealth || needProfiles else { return }

        let opID = beginOperation("Kalibrációs adatok betöltése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                if needCoverage, let count = try await self.refreshCalibCore(db: db, cfg: cfg) {
                    self.progressText = "Kalibráció kész: \(count) kombináció"
                }
                if needHealth, try await self.refreshCalibHealthCore(db: db, cfg: cfg) {
                    self.progressText = "Kalibráció-egészség kész"
                }
                if needProfiles, let count = try await self.refreshSensorProfilesCore(db: db) {
                    self.progressText = "Szenzor-profilok betöltve: \(count) kombináció"
                }
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
                if let count = try await self.refreshSensorProfilesCore(db: db) {
                    self.progressText = "Szenzor-profilok betöltve: \(count) kombináció"
                }
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
    /// `stats`/`sessionDetailsByTarget` afterward (via `refreshStatsCore`,
    /// inside this same operation) so a newly recorded DSS verdict count
    /// shows up on the Statisztika fül without a separate manual
    /// "Frissítés".
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
                try await self.refreshStatsCore(db: db, cfg: cfg)
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Rate

    /// `force`, when `true`, passes through to `Rater.rate` -- a deliberate
    /// full re-measure of every frame regardless of cache state, driven by
    /// QualityView's "Újrapontozás" checkbox (the manual escape hatch next
    /// to the self-heal `Rater` already does automatically for stale rows).
    ///
    /// On success, also refreshes the Minőség fül's "Session-minőség"
    /// (`qualitySummaries`) and "Expozíció-tanácsadó" (`exposureAdvice`)
    /// panels for the same target -- both key off frame-score/quality data
    /// this very call just changed, and QualityView only otherwise
    /// refreshes them on a target-PICKER change (`.onChange(of:
    /// selectedTarget)`), never on a re-rate of the already-selected
    /// target. Without this, the two panels are left showing whatever
    /// stale ("nincs adat"/"n/a") state they had before rating, even
    /// though the frame table below updates fine from `frameScores`.
    ///
    /// Deliberately done INLINE, inside this same `Task`/`opID` (via
    /// `refreshQualityPanelsCore`), rather than by starting new
    /// `beginOperation`-based loads -- chained public loads cancel each
    /// other's Tasks (see the refresh-core comment at the bottom of this
    /// file for the full race).
    func runRate(target: String, date: String?, force: Bool = false) {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Pontozás indul…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await Task.detached(priority: .userInitiated) { [weak self] in
                    var provider: StarMetricsProvider?
                    if FileManager.default.isExecutableFile(atPath: cfg.rating.sirilPath) {
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

                try await self.refreshQualityPanelsCore(target: target, db: db, cfg: cfg)
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
    /// show the result, and the stats + plan data is refreshed so a newly
    /// solved coordinate immediately shows up in the plan/panel-tracking
    /// data instead of only after the user manually refreshes.
    ///
    /// The refresh happens INLINE, inside this same `Task`/`opID` (via
    /// `refreshStatsCore`/`refreshPlanCore`) -- it used to be
    /// `self.loadStats(); self.loadPlan()`, but two `beginOperation`-based
    /// loads called back-to-back cancel each other's Tasks, so the stats
    /// refresh was silently dropped every time (see the refresh-core
    /// comment at the bottom of this file for the full race).
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
                try await self.refreshStatsCore(db: db, cfg: cfg)
                try await self.refreshPlanCore(db: db, cfg: cfg)
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Session quality (absolute metrics + night timeline)

    /// Loads `qualitySummaries` AND `exposureAdvice` (R7-B3
    /// `ExposureAdvisor`) for `target` as ONE operation -- called whenever
    /// the Minőség fül's target picker changes. Deliberately one combined
    /// method rather than separate summary/advice loads called back-to-back
    /// from the view -- those chain-cancel each other (see the refresh-core
    /// comment at the bottom of this file), which used to silently drop the
    /// summaries on every target change. Clears `sessionTimeline`/
    /// `nightHealth` too, since a previously selected session's rows no
    /// longer apply once the target itself changes. An advisor "no data"
    /// condition is never an app error -- it comes back as
    /// `ExposureAdvice.notAvailableReason`, an ordinary (if unhelpful)
    /// result, not a failure.
    func loadQualityPanels(target: String) {
        guard let db else { return }
        let cfg = config
        sessionTimeline = nil
        nightHealth = nil
        exposureAdvice = nil

        let opID = beginOperation("Minőség-összegzés számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let count = try await self.refreshQualityPanelsCore(target: target, db: db, cfg: cfg) {
                    self.progressText = "Minőség-összegzés kész: \(count) session"
                }
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

    // MARK: - Shared refresh cores

    /// The computation + apply-to-published-state halves of the `loadX()`
    /// operations above, WITHOUT any `beginOperation`/`endOperation`/
    /// `currentTask` bookkeeping of their own -- so an already-running
    /// operation (`runPlateSolve`, `runRate`, `runIngestDSS`, the combined
    /// tab loaders) can await them inside its own `Task`/opID.
    ///
    /// Why they exist: calling two public `loadX(); loadY()` methods
    /// back-to-back synchronously does NOT run both. Each goes through
    /// `beginOperation`, which does `currentTask?.cancel()` -- and with no
    /// `await` between the two calls, the second cancels the FIRST call's
    /// just-created `Task` before its closure even starts. The cancelled
    /// Task still runs its detached computation (a `Task.detached` child is
    /// an independent root task), but its `guard !Task.isCancelled` then
    /// silently discards the result -- so only the LAST load in such a
    /// chain ever lands. This bit `runPlateSolve` (stats refresh dropped
    /// after every solve) and every view that chained loads in `.onAppear`/
    /// `.onChange`.
    ///
    /// Each core checks `Task.isCancelled` after its detached computation
    /// and applies nothing if the SURROUNDING operation was cancelled
    /// meanwhile -- returning `nil` (or `false`) so wrappers know not to
    /// update `progressText` either.

    /// Core of `loadStats()`: recomputes `stats` + every target's session/
    /// panel/stack detail. Returns the target count, or `nil` if cancelled.
    @discardableResult
    private func refreshStatsCore(db: Database, cfg: AstroConfig) async throws -> Int? {
        let (result, sessionsByTarget, panelsByTarget, stacksByTarget) = try await Task.detached(priority: .userInitiated) {
            let stats = try StatsQueries.perTarget(db: db, config: cfg)
            var sessionsByTarget: [String: [SessionDetail]] = [:]
            var panelsByTarget: [String: PanelReport] = [:]
            let discoveredStacks = try StackDiscovery.discover(db: db, config: cfg)
            let stacksByTarget = Dictionary(uniqueKeysWithValues: discoveredStacks.map { ($0.target, $0) })
            for stat in stats {
                sessionsByTarget[stat.target] = try SessionStatsQueries.sessions(
                    target: stat.target, db: db, config: cfg
                )
                panelsByTarget[stat.target] = try FieldGeometry.panels(
                    target: stat.target, db: db, config: cfg
                )
            }
            return (stats, sessionsByTarget, panelsByTarget, stacksByTarget)
        }.value
        guard !Task.isCancelled else { return nil }
        self.stats = result
        self.sessionDetailsByTarget = sessionsByTarget
        self.panelReportsByTarget = panelsByTarget
        self.stackReportsByTarget = stacksByTarget
        return result.count
    }

    /// Core of `loadPlan()`: recomputes `plan` and caches the resolved
    /// observing site back into `config.site` (in memory only). Returns the
    /// planned-target count, or `nil` if cancelled.
    @discardableResult
    private func refreshPlanCore(db: Database, cfg: AstroConfig) async throws -> Int? {
        let (result, resolvedSite) = try await Task.detached(priority: .userInitiated) {
            let plans = try Planner.plan(db: db, config: cfg)
            let site = try Planner.resolveSite(db: db, config: cfg)
            return (plans, site)
        }.value
        guard !Task.isCancelled else { return nil }
        self.plan = result
        self.config.site = resolvedSite
        return result.count
    }

    /// Core of `loadQualityPanels(target:)` and `runRate`'s post-rate
    /// refresh: recomputes `qualitySummaries` + `exposureAdvice` for one
    /// target in a single background hop (both are cheap DB reads over the
    /// same target). Returns the session-summary count, or `nil` if
    /// cancelled.
    @discardableResult
    private func refreshQualityPanelsCore(target: String, db: Database, cfg: AstroConfig) async throws -> Int? {
        let (summaries, advice) = try await Task.detached(priority: .userInitiated) {
            let summaries = try SessionQuality.summaries(target: target, db: db, config: cfg)
            let advice = try ExposureAdvisor.advise(target: target, db: db, config: cfg)
            return (summaries, advice)
        }.value
        guard !Task.isCancelled else { return nil }
        self.qualitySummaries = summaries
        self.exposureAdvice = advice
        return summaries.count
    }

    /// Core of `loadCalib()`: recomputes `calibNeeds`. Returns the
    /// combination count, or `nil` if cancelled.
    @discardableResult
    private func refreshCalibCore(db: Database, cfg: AstroConfig) async throws -> Int? {
        let result = try await Task.detached(priority: .userInitiated) {
            try CalibAnalyzer.coverage(db: db, config: cfg)
        }.value
        guard !Task.isCancelled else { return nil }
        self.calibNeeds = result
        return result.count
    }

    /// Core of `loadCalibHealth()`: recomputes `calibHealth`. Returns
    /// whether the result was applied (`false` if cancelled).
    @discardableResult
    private func refreshCalibHealthCore(db: Database, cfg: AstroConfig) async throws -> Bool {
        let result = try await Task.detached(priority: .userInitiated) {
            try CalibHealth.report(db: db, config: cfg)
        }.value
        guard !Task.isCancelled else { return false }
        self.calibHealth = result
        return true
    }

    /// Core of `loadSensorProfiles()`: reloads the persisted
    /// `sensor_profile` rows. Returns the profile count, or `nil` if
    /// cancelled.
    @discardableResult
    private func refreshSensorProfilesCore(db: Database) async throws -> Int? {
        let result = try await Task.detached(priority: .userInitiated) {
            try db.allSensorProfiles()
        }.value
        guard !Task.isCancelled else { return nil }
        self.sensorProfiles = result
        return result.count
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
        return id
    }

    private func endOperation(_ id: UUID) {
        guard currentOperationID == id else { return }
        isBusy = false
    }
}
