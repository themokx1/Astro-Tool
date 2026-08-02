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

    var stats: [TargetStats] = []
    var calibNeeds: [CalibNeed] = []
    var frameScores: [FrameScore] = []

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
            db = try Database(path: dbURL.path)
            rootStatus = .notScanned
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

    // MARK: - Stats

    func loadStats() {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Statisztika számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try StatsQueries.perTarget(db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.stats = result
                self.progressText = "Statisztika kész: \(result.count) célpont"
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

    // MARK: - Rate

    func runRate(target: String, date: String?) {
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
                    return try rater.rate(target: target, date: date) { done, total in
                        Task { @MainActor in
                            self?.progressText = "Pontozás: \(done)/\(total)"
                        }
                    }
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.frameScores = results
                self.progressText = "Pontozás kész: \(results.count) frame"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - New session

    private nonisolated static let sessionReadmeTemplate = """
    Camera:
    Sensor temp:
    Gain/Offset:
    Exposure (lights):
    Filter:
    Optics:
    Mount:
    Guiding:
    Total integration:
    Location/Bortle:
    Notes/issues:
    """

    /// Creates `sessions/<sanitize(catalog)_sanitize(name)>/<date>/...`.
    /// `date` must already be a canonical `YYYY-MM-DD` string -- callers
    /// (`NewSessionSheet`) are expected to validate via `SessionDateParser`
    /// before enabling the "Létrehozás" button, but this re-validates so the
    /// guard holds even if called from elsewhere.
    func createSession(catalog: String, name: String, date: String) {
        guard let parsedDate = SessionDateParser.parse(date), parsedDate.isCanonical else {
            lastError = "Érvénytelen dátum: \(date) (YYYY-MM-DD formátum szükséges)"
            return
        }
        guard rootStatus == .ok || rootStatus == .notScanned else {
            lastError = "A gyökér nem elérhető."
            return
        }

        let cfg = config
        let target = Sanitizer.makeTarget(catalog: catalog, name: name)
        let writeGuard = WriteGuard(root: URL(fileURLWithPath: cfg.rootPath, isDirectory: true))

        let opID = beginOperation("Session létrehozása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let created = try await Task.detached(priority: .userInitiated) {
                    try writeGuard.createSessionTree(target: target, dateDir: date, readme: Self.sessionReadmeTemplate)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.progressText = "Session létrehozva: \(target)/\(date)"
                if let dirURL = created.first?.deletingLastPathComponent() {
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
        return id
    }

    private func endOperation(_ id: UUID) {
        guard currentOperationID == id else { return }
        isBusy = false
    }
}
