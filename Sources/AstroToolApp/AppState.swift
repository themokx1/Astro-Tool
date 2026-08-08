import AppKit
import AstroCore
import Foundation
import Observation
import UniformTypeIdentifiers

/// What we currently know about the configured library root: whether it's
/// reachable, and if not, why -- drives whether the app shows the normal
/// sidebar shell (`MainShellView`) or a full-screen guidance view
/// (`AccessDeniedView`).
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
///
/// `.calendar` and `.cleanup` (D25/R9 round 2) don't get their own view --
/// `MainShellView.page(for:)` renders `TonightPage()`/`AuditPage()` for them
/// respectively. They exist as their OWN `Page` cases (rather than routing
/// straight to `.tonight`/`.audit` with a segment set as a side effect of
/// the tap, as the sidebar's "Naptár"/"Takarítás" rows used to) purely so
/// `List(selection:)`'s tag-matching highlights the right sidebar row:
/// `.tonight`/`.audit`'s own rows must NOT light up while the "calendar
/// segment of tonight" or "cleanable segment of audit" is what's actually on
/// screen. R11-T13/F13: `AppState.tonightSegment`/`auditSegment` are now
/// DERIVED from this same `currentPage` (see their own doc comments) rather
/// than separately preselected on appear, so the segment shown and the
/// sidebar row highlighted can never drift apart regardless of how
/// `currentPage` got here (sidebar tap, ⌘-shortcut, menu bar, or the page's
/// own segmented picker).
enum Page: Hashable {
    case tonight
    case calendar
    /// R10-B4: "Felfedezés" -- the embedded-catalog discovery sweep
    /// (`DiscoveryPlanner.discover`) suggesting well-placed NON-library
    /// targets for tonight. Sits in the same unnamed top section as
    /// "Ma este"/"Naptár" (a night-planning tool, not a library-browsing
    /// one) -- deliberately NOT next to "Éjszakák" under KÖNYVTÁR, which
    /// only ever shows targets/sessions the user already has.
    case discover
    /// R11-T9/F5: the "Előző éjszaka" morning-triage page -- session cards
    /// for every `(target, date)` the last scan reported a new/updated
    /// LIGHT frame for (`AppState.freshSessionKeys`). Sits in the same
    /// unnamed top section as `.tonight`/`.calendar`/`.discover` (see the UI
    /// plan's sidebar order: Ma este → Naptár → Felfedezés → [feltételes]
    /// Előző éjszaka → [feltételes] Keresés) -- `SidebarView` only shows its
    /// row when `freshSessionKeys` is non-empty, but the `Page` case itself
    /// always exists so a page already open when the last fresh session gets
    /// acted on doesn't vanish out from under the user; it falls back to
    /// `PreviousNightPage`'s own empty state instead (F5 item 6).
    case previousNight
    case allTargets
    /// R10-B3: the "Éjszakák" cross-target session browser -- every session
    /// across every target in one sortable table (`NightsPage`), the flat
    /// counterpart to `AllTargetsPage`'s per-target session sub-rows.
    case nights
    case target(String)
    case calibration
    case audit
    case cleanup
    /// R11-T10/F7: the "Trendek" page -- long-term session-level time series
    /// (median FWHM″, background e⁻/s/″², hatékonyság%) across every target.
    /// Sits in the ÁLLAPOT section after Audit/Takarítás (see the UI plan's
    /// sidebar order), deliberately with NO `⌘`-shortcut of its own -- the
    /// existing ⌘1-9 assignment doesn't move for it, same stance
    /// `Page.previousNight` already takes.
    case trends
    case sensor
    case searchResults
}

/// `FieldGeometry.dominantFOV`'s bare tuple result, wrapped for
/// `@Observable`/SwiftUI `Equatable` diffing -- a plain
/// `(widthDeg: Double, heightDeg: Double)` tuple can't itself be compared
/// with `==` (`@Observable`'s change tracking, and any `.onChange(of:)`
/// watching this property, need a concrete `Equatable` type). See
/// `AppState.discoveryFOV`'s own doc for how it's used.
struct DiscoveryFOV: Equatable {
    var widthDeg: Double
    var heightDeg: Double
}

/// R11-T9/F5: one "Előző éjszaka" triage card -- a `NightRow` (already
/// carries the display name, usable-frame count, integration,
/// `FilterBreakdown`, and median FWHM `SessionsSegment`/`NightsPage` show)
/// plus the two pieces of per-session state that live only on the DETAIL
/// page today (`NightHealth`'s cooler/focus verdicts, `Rater`'s outlier
/// flag) -- built by `AppState.buildPreviousNightCards`, never by a core
/// query of its own (there's no new core API for this beyond `ScanSummary
/// .changedSessions`; every field below is a straight read of an existing
/// one).
struct PreviousNightCard: Identifiable, Equatable {
    var target: String
    var displayName: String
    var date: String
    var usableLightCount: Int
    var integrationSeconds: Double
    var filterBreakdown: [FilterIntegration]
    var medianFWHMArcsec: Double?
    var medianFWHMPixels: Double?
    var coolerVerdict: String
    var focusVerdict: String
    /// Count of frames `Rater.cachedScores` found for this session -- `0`
    /// means "still nincs pontozva" (never rated at all), distinct from a
    /// rated session that just happens to have zero outliers.
    var ratedFrameCount: Int
    /// Fraction (0...1) of `ratedFrameCount` flagged `FrameScore.isOutlier`;
    /// `nil` exactly when `ratedFrameCount == 0` -- the card shows "még
    /// nincs pontozva" in that case rather than a fake "0%".
    var outlierRatio: Double?

    var id: String { "\(target)|\(date)" }
}

/// R11-T12/F12: one "Első lépések" checklist row -- title, a one-sentence
/// "miért" (why this matters), whether it's already done, and the one
/// action (start an operation or navigate/open a settings tab) that moves
/// it forward. Built by `AppState.firstSteps` from data every one of these
/// six checks already has cheaply on hand (no new query beyond
/// `Database.hasAnyRating`, F12's own one small addition).
struct FirstStepItem: Identifiable {
    enum ActionKind {
        case runScan
        case runAudit
        case openLocationSettings
        case openSirilSettings
        case rateAll
        case measureSensor
    }

    let id: String
    let title: String
    let reason: String
    let isDone: Bool
    let actionTitle: String
    let actionKind: ActionKind
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
    /// R11-T9/F5: `autoScanOnMount`'s `UserDefaults` key.
    private static let autoScanOnMountKey = "autoScanOnMount"
    /// R11-T12/F12: `firstStepsCardDismissed`'s `UserDefaults` key.
    private static let firstStepsCardDismissedKey = "firstStepsCardDismissed"
    /// R11-T15/F16: `selectedSiteName`'s `UserDefaults` key.
    private static let selectedSiteNameKey = "selectedSiteName"

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
    /// Distinct filter names currently used by the library but missing from
    /// the saved AstroBin mapping. Settings renders these as add suggestions.
    var usedUnmappedAstroBinFilters: [String] = []

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
            /// R11-T1: `advice` is the "Mit tehetsz: …" follow-up
            /// (`errorAdvice(for:)`), shown ONLY here in the popover --
            /// `message` alone (no advice) is still what the matching toast
            /// gets, see `endOperation`.
            case error(String, advice: String?)
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

    // MARK: - Toasts (R10-A5)

    /// One transient bubble on the global toast layer (`ToastOverlay`,
    /// rendered from `MainShellView` above every page, regardless of which
    /// one is on screen) -- the fix for `lastError` only ever rendering
    /// inline on 8 view surfaces (every other page silently swallowed an
    /// error) AND for success feedback ("Exportálva: …", "Jegyzet
    /// elmentve.") being nothing more than a `progressText` toolbar caption
    /// that vanishes the moment the next operation starts. Pushed from
    /// `endOperation` (see its doc comment); `ToastOverlay` renders them,
    /// newest at the bottom of the stack.
    struct Toast: Identifiable {
        let id: UUID
        let kind: Kind
        let message: String
        enum Kind {
            case success
            case error
            case info
        }
    }
    /// Currently visible toasts, oldest first -- capped at 3 by `pushToast`
    /// so a burst of near-simultaneous background completions can't paper
    /// over the whole screen.
    var toasts: [Toast] = []

    /// Appends a toast, dropping the oldest once more than 3 are visible,
    /// then schedules its own removal -- ~4.5s, ~8s for errors (they matter
    /// more, and deserve more time to actually be read). Removal is
    /// main-actor (this whole class already is) and keyed on the fresh
    /// `UUID` minted right here, so if the same MESSAGE gets pushed again
    /// before the first one's timer fires, the two toasts are tracked
    /// entirely independently -- neither's timer can kill the other's early.
    func pushToast(_ kind: Toast.Kind, _ message: String) {
        let toast = Toast(id: UUID(), kind: kind, message: message)
        toasts.append(toast)
        if toasts.count > 3 {
            toasts.removeFirst(toasts.count - 3)
        }
        let seconds: Double
        switch kind {
        case .error: seconds = 8.0
        case .success, .info: seconds = 4.5
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.dismissToast(id: toast.id)
        }
    }

    /// Removes one toast by id -- used by `pushToast`'s own auto-dismiss
    /// timer above, AND by `ToastOverlay`'s "click to dismiss".
    func dismissToast(id: UUID) {
        toasts.removeAll { $0.id == id }
    }

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

    /// R11-T12/F12: "Ma este"'s dismissible "Első lépések" card -- persisted
    /// (unlike `cloudBannerDismissed`) since the spec wants this to stay
    /// dismissed across relaunches once the user has waved it off, same
    /// `UserDefaults` persistence `autoScanOnMount` already establishes.
    /// The card's own VISIBILITY also requires `firstSteps` to have fewer
    /// than 4 done steps (`MainShellView`/`TonightPage` check both), so
    /// dismissing it here doesn't mean "never compute `firstSteps` again" --
    /// just "don't show the unsolicited nudge".
    ///
    /// R12-U1 item 4: a plain STORED property with a `didSet` mirror to
    /// `UserDefaults` -- was a computed property whose getter/setter read/
    /// wrote `UserDefaults` directly with no backing storage of its own.
    /// `@Observable`'s change tracking only instruments a type's STORED
    /// properties (each one's synthesized accessor calls `access(keyPath:)`/
    /// `withMutation(keyPath:)`); a computed property that reaches straight
    /// into `UserDefaults` participates in none of that, so setting it
    /// never marked any view that had READ it as needing to redraw -- the
    /// dismiss button's own toggle only visually updated when some
    /// UNRELATED tracked property happened to change right after. `init()`
    /// reads the persisted starting value once (a stored property's own
    /// declared default can't reach `UserDefaults` itself).
    var firstStepsCardDismissed: Bool = false {
        didSet { UserDefaults.standard.set(firstStepsCardDismissed, forKey: Self.firstStepsCardDismissedKey) }
    }

    /// R11-T12/F12: the "Első lépések" checklist -- 6 fixed steps, each
    /// derived from data this class already tracks (or, for "Volt már
    /// pontozás?", one cheap `Database.hasAnyRating()` existence probe).
    /// Recomputed on every access (no caching): every input is either
    /// already an in-memory `@Observable` property or a `FileManager`
    /// existence check, so there's nothing expensive to memoize.
    var firstSteps: [FirstStepItem] {
        let sirilAvailable = FileManager.default.isExecutableFile(atPath: config.rating.sirilPath)
        let everRated = (try? db?.hasAnyRating()) ?? false

        return [
            FirstStepItem(
                id: "scan",
                title: "Beolvasás",
                reason: "A beolvasás tölti fel a könyvtárad session-jeit és célpontjait -- minden más lépés erre épül.",
                isDone: lastScanDate != nil,
                actionTitle: "Beolvasás indítása",
                actionKind: .runScan
            ),
            FirstStepItem(
                id: "audit",
                title: "Audit",
                reason: "Az audit megkeresi a hiányzó kalibrációt, a duplikátumokat és az egyéb könyvtár-problémákat.",
                isDone: lastRunID != nil,
                actionTitle: "Audit futtatása",
                actionKind: .runAudit
            ),
            FirstStepItem(
                id: "site",
                title: "Megfigyelési helyszín",
                reason: "Helyszín nélkül a magasság/kulmináció/láthatóság csak a FITS-fejlécekből becsült, nem pontos.",
                isDone: resolvedSite.latitudeDeg != nil && resolvedSite.longitudeDeg != nil,
                actionTitle: "Helyszín beállítása…",
                actionKind: .openLocationSettings
            ),
            FirstStepItem(
                id: "siril",
                title: "Siril",
                reason: "Siril nélkül a FWHM/kerekség/csillagszám metrikák és a plate-solve nem érhetők el -- a natív pontozás enélkül is működik.",
                isDone: sirilAvailable,
                actionTitle: "Siril beállítása…",
                actionKind: .openSirilSettings
            ),
            FirstStepItem(
                id: "rating",
                title: "Keretek pontozása",
                reason: "Pontozás nélkül nincs minőségi sorrend, kiugró-jelzés vagy stacklista-ajánlás.",
                isDone: everRated,
                actionTitle: "Pontozás indítása…",
                actionKind: .rateAll
            ),
            FirstStepItem(
                id: "sensor",
                title: "Szenzor-profil",
                reason: "Mért szenzor-profil nélkül a háttér csak nyers ADU-ban látszik, és az Expozíció-tanácsadó sem tud tanácsot adni.",
                isDone: !sensorProfiles.isEmpty,
                actionTitle: "Szenzor mérése…",
                actionKind: .measureSensor
            ),
        ]
    }

    /// B6: a non-mounted volume that reappears (`NSWorkspace.didMountNotification`)
    /// auto-retries root access; kept so the observer is only ever
    /// registered once per process.
    @ObservationIgnored
    private var mountObserver: NSObjectProtocol?
    /// D31: the stale-scan banner's `scanIsStale` used to only ever
    /// re-evaluate when `lastScanDate` itself changed -- fine right after a
    /// scan, but the 24h threshold can also become true purely because time
    /// passed while the app sat open (or backgrounded) with no scan at all,
    /// and nothing was mutating any tracked property to tell `@Observable`
    /// a dependent view needed to redraw. Registered once per process,
    /// alongside `mountObserver`.
    @ObservationIgnored
    private var activationObserver: NSObjectProtocol?

    var scanSummary: ScanSummary?
    /// R11-T9/F5: every `(target, date)` the MOST RECENT `runScan()` this
    /// process ran reported a new/updated light frame for
    /// (`ScanSummary.changedSessions`) -- the "Előző éjszaka" sidebar row's
    /// badge count and the gate on whether it shows at all. Deliberately
    /// REPLACED (not accumulated) on every scan, and deliberately
    /// session-only (never persisted, unlike `lastScanDate`): the spec is
    /// "what changed since the last scan", not "everything ever flagged
    /// fresh this app run" -- an app relaunch (or a rescan that changes
    /// nothing) naturally empties this back out, same as `scanSummary`
    /// itself resets to whatever the most recent scan reported.
    var freshSessionKeys: [ScanSummary.SessionKey] = []
    /// R11-T9/F5: one triage card per `freshSessionKeys` entry, built by
    /// `loadPreviousNight()`/`runRateFreshSessions()`/
    /// `runRateFreshSession(target:date:)` -- `[]` before the page has ever
    /// loaded this session (or whenever `freshSessionKeys` is empty).
    var previousNightCards: [PreviousNightCard] = []
    /// R11-T9/F5: `PreviousNightReviewSheet`'s own "Átnézés…" load target --
    /// kept separate from the target-detail page's `frameScores` (which
    /// belongs to whichever target's Minőség segment is open) so opening
    /// this sheet from the triage page never clobbers that unrelated
    /// state. `nil` while the sheet's load is in flight (or before it's
    /// been opened at all this session); `PreviousNightReviewSheet`'s own
    /// `onDisappear` clears it back to `nil`, same "operation-scoped
    /// result, cleared on close" convention `PlateSolveSheet`'s
    /// `plateSolveSummary` already established.
    var reviewFrameScores: [FrameScore]?
    /// R12-U1 item 3: `reviewFrameScores`'s own manual-verdict counterpart --
    /// kept SEPARATE from the shared `frameVerdicts` (populated by
    /// `loadFrameScores`/`runRate`/`runRateAll` for the target-detail
    /// Minőség segment) so loading ONE triage session's review frames here
    /// can never silently wipe out verdicts `QualitySegment` already has
    /// cached for some OTHER target/session. Before this, `loadReviewFrames`
    /// fully REPLACED (not merged into) the shared `frameVerdicts` with
    /// whatever this one small session resolved, discarding every other
    /// target's entry in the process. `FrameReviewSheet` reads/writes
    /// whichever of the two dictionaries matches the frame set it was
    /// handed (see its own `isReviewScoped` doc comment). Cleared the same
    /// way `reviewFrameScores` is -- `PreviousNightReviewSheet`'s
    /// `onDisappear`.
    var reviewFrameVerdicts: [String: Bool] = [:]
    /// R12-U1 item 3: the `(target, date)` `loadReviewFrames` was most
    /// recently asked to load -- set right before its background `Task`
    /// starts, re-checked after each `await` inside it before writing
    /// `reviewFrameScores`/`reviewFrameVerdicts`. `Task.isCancelled` alone
    /// doesn't close the race this guards against: `PreviousNightReviewSheet`
    /// is a `.sheet(item:)` (one session at a time), and the freshly
    /// swapped-in sheet's own `.onAppear` (which is what actually calls
    /// `loadReviewFrames` again, cancelling the previous load's
    /// `currentTask`) can lag slightly behind the moment the OLD sheet's
    /// `onDisappear` fires -- if the old session's background query
    /// finishes inside that window, its own `Task.isCancelled` check still
    /// reads `false` (nothing has cancelled it YET), so it would otherwise
    /// apply the WRONG session's frames/verdicts under the sheet that's
    /// actually on screen now. This key is the real ground truth of "what
    /// does the CURRENTLY shown sheet want" -- `nil` whenever no review load
    /// is in flight.
    @ObservationIgnored
    private var reviewFramesRequest: ScanSummary.SessionKey?
    /// R11-T9/F5: "Automatikus beolvasás kötet csatlakozásakor" (Settings ▸
    /// Könyvtár) -- default OFF. This is app-BEHAVIOR config (whether a
    /// filesystem event alone should ever trigger a scan), not
    /// library-shape config, so it deliberately lives in `UserDefaults`
    /// rather than `AstroConfig`/`config.json` -- same reasoning
    /// `bookmarkKey`/`recentRootsKey` above already follow (this app's own
    /// prefs, not something that should round-trip through the library's
    /// checked-in-adjacent config file, and not something the CLI has any
    /// use for). Not `@AppStorage`: `AppState` is a plain `@Observable`
    /// class, not a `View`, so `@AppStorage`'s `DynamicProperty` machinery
    /// wouldn't integrate with `@Observable`'s own change tracking anyway.
    ///
    /// R12-U1 item 4: a plain STORED property with a `didSet` mirror to
    /// `UserDefaults` -- was a computed property whose getter/setter read/
    /// wrote `UserDefaults` directly with no backing storage of its own,
    /// which meant `@Observable` never tracked it at all (its change
    /// tracking only instruments STORED properties -- see
    /// `firstStepsCardDismissed`'s own doc comment for the full
    /// explanation): the Settings toggle bound to this via `$appState
    /// .autoScanOnMount` still worked (a `Binding`'s get/set calls the
    /// accessors directly, tracking or not), but nothing else that merely
    /// READ this property ever got invalidated the instant it changed.
    /// `init()` reads the persisted starting value once.
    var autoScanOnMount: Bool = false {
        didSet { UserDefaults.standard.set(autoScanOnMount, forKey: Self.autoScanOnMountKey) }
    }
    var findings: [Finding] = []
    /// Audit and verify evidence are persisted independently, then composed
    /// into `findings` for the shared Audit UI.
    private var auditFindings: [Finding] = []
    var verifyFindings: [Finding] = []
    var lastRunID: Int64?
    /// R11-T14/F9: set by `runVerify` once a fixity/bitrot check has
    /// completed -- alongside `lastRunID`, the AuditPage's "has
    /// SOMETHING run yet" gate (`hasAnyAuditRun`), so a user who runs ONLY
    /// "Integritás-ellenőrzés…" without ever running a full "Audit
    /// futtatása" still sees its findings instead of the page's "run an
    /// audit first" empty state. Deliberately independent of `lastRunID`
    /// (a `"verify"`-kind run, not `"audit"`) and restored by `openRoot`.
    var lastVerifyRunID: Int64?
    var lastVerifyDate: Date?
    var lastVerifySummary: FixityVerifier.Summary?
    var verifyCoverage: FixityVerifier.Coverage?
    var verifyBaselineErrors: [FixityVerifier.BaselineResult] = []
    /// R11-T8/F6: this run's findings compared against the run immediately
    /// before it (`Database.previousRunID(before:kind:)`), or `nil` when
    /// there is no previous audit run to compare against (the very first
    /// audit ever, or before any audit has run this launch). Set alongside
    /// `lastRunID`/`findings` in both places that populate them --
    /// `runAudit` (a fresh run) and `openRoot` (restoring the last completed
    /// run across launches) -- so the Audit page's diff summary row/"ÚJ"
    /// badges/"Csak az újak" toggle work identically whether the audit just
    /// ran or was restored from disk.
    var auditDiff: AuditDiff.Result?
    var includeSuspiciousInScript: Bool = false

    var cleanupSummary: CleanupSummary?
    var quarantineState: QuarantineState?
    var quarantineInspectionError: String?
    /// R11-T8/F19: per-target on-disk size map for the Audit page's
    /// Takarítható segment "Tárhely" block. Loaded alongside
    /// `cleanupSummary` everywhere that populates it (`loadCleanup`,
    /// `loadDashboardData`) since both are pure `files`-table reads shown on
    /// the same segment -- never tied to whether an audit has ever run.
    var storageSummary: StorageSummary?
    /// R9-T2/A.5's "Takarítható" segment `Limit` stepper -- how many paths
    /// each expanded cleanup-category row shows before an "…további N" row,
    /// same idea as the CLI `cleanup --limit` display cap (default 10).
    /// Purely a view-layer display cap: `CleanupReport.build`'s own
    /// `maxPathsPerGroup` (50) already limits what's fetched from the DB at
    /// all; this only limits what's shown from that.
    var cleanupLimit: Int = 10

    /// R9-T2/A.5's Audit page picker segments. `intentional` (R10-A5) was
    /// added later -- the header tile already counted
    /// `probablyIntentional` findings, but there was no segment to actually
    /// view them, a dead-end number.
    enum AuditSegment: Hashable {
        case errors
        case suspicious
        case cleanable
        case intentional
    }
    /// Which of the three non-cleanup segments (`.errors`/`.suspicious`/
    /// `.intentional`) to show whenever `currentPage` is `.audit` --
    /// `auditSegment`'s own backing memory for everything BUT `.cleanable`
    /// (see that computed property's doc comment for why `.cleanable`
    /// itself is never stored here).
    private var lastNonCleanableAuditSegment: AuditSegment = .errors
    /// Which segment `AuditPage` shows -- R11-T13/F13: DERIVED from
    /// `currentPage` rather than kept as fully independent state, so the
    /// sidebar's "Takarítás" row/⌘8 highlighting and this segment can never
    /// drift apart (the bug this fixes: navigating straight to `.audit` from
    /// `.cleanup` used to leave the picker stuck on "Takarítható" even
    /// though the sidebar/title correctly said "Audit"). `Page` only
    /// distinguishes `.cleanup` from `.audit` though -- not WHICH of the
    /// other three segments -- so unlike `tonightSegment` below this isn't a
    /// clean 1:1 mapping and still needs `lastNonCleanableAuditSegment` to
    /// remember which of those three to come back to. The setter writes
    /// `currentPage` right back (to `.cleanup` for `.cleanable`, to `.audit`
    /// for anything else, but only when it was `.cleanup` before -- leaving
    /// any OTHER current page alone), so `AuditPage`'s segmented `Picker` can
    /// still bind straight to this like any other piece of state.
    var auditSegment: AuditSegment {
        get { currentPage == .cleanup ? .cleanable : lastNonCleanableAuditSegment }
        set {
            if newValue == .cleanable {
                currentPage = .cleanup
            } else {
                lastNonCleanableAuditSegment = newValue
                if currentPage == .cleanup { currentPage = .audit }
            }
        }
    }
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

    /// R9-T4/A.1's segmented picker on `TonightPage`. R11-T13/F13: DERIVED
    /// from `currentPage` rather than kept as independent state -- `.tonight`/
    /// `.calendar` map onto this segment 1:1, so this is a plain computed
    /// property with no backing storage of its own (unlike `auditSegment`
    /// above, which needs one extra bit of memory since `Page` can't
    /// distinguish between three of ITS four segments). Before this, the
    /// segment was a fully independent stored property that only ever got
    /// written FROM `currentPage` (via `MainShellView.page(for:)`'s
    /// `.onAppear`) on the way IN to `.calendar` -- navigating back to
    /// `.tonight` some other way (the sidebar's "Ma este" row, ⌘1, …) left
    /// it stuck on `.calendar`, so the page kept showing the calendar
    /// segment even though the sidebar/title both correctly said "Ma este".
    /// The setter writes `currentPage` right back, so `TonightPage`'s
    /// segmented `Picker` can still bind straight to this like any other
    /// piece of state.
    enum TonightSegment: Hashable {
        case tonight
        case calendar
    }
    var tonightSegment: TonightSegment {
        get { currentPage == .calendar ? .calendar : .tonight }
        set { currentPage = newValue == .calendar ? .calendar : .tonight }
    }
    /// R11-T2: `TonightPage`'s cloud-context banner ("Ma este ~N% felhő
    /// várható…"), dismissed for the rest of THIS app run once the user
    /// closes it -- kept here (not a plain `@State` on `TonightPage` itself)
    /// since that page's view identity doesn't survive navigating away and
    /// back (`MainShellView`'s page switch recreates it), and a plain
    /// `@State` would silently re-show the banner on every visit. Not
    /// `@AppStorage`: the spec explicitly wants this to reset on the next
    /// launch, not stay dismissed forever.
    var cloudBannerDismissed: Bool = false

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
    /// Áttekintés. `TargetDetailPage.onAppear` consumes it once. Also reused
    /// by `AllTargetsPage`'s target row context menu (R9-D8/e: "Kész
    /// stackek…" preselects `.stacks` before navigating) -- the mechanism is
    /// generic ("preselect a segment, then navigate"), not search-specific.
    var pendingTargetSegment: TargetDetailPage.Segment?
    /// `AllTargetsPage`'s session row context menu's "Keretek pontozása"
    /// (R9-D8/f) sets this (alongside `pendingTargetSegment = .quality`)
    /// right before navigating to `Page.target` -- that page has no frame
    /// table of its own to show a rating run in, so this only preselects
    /// the date filter on `QualitySegment`, which consumes it once (same
    /// "set, navigate, consume on appear" pattern as `pendingSessionSelection`).
    var pendingQualityDate: String?
    /// R12-U1 item 5: a session row's "Megnyitás a Trendeken" action
    /// (`SessionActionMenu`, shared by `AllTargetsPage`/`NightsPage`/
    /// `SessionsSegment`) sets this to that session's own dominant setup
    /// descriptor (`SessionDetail.setupDescriptor` -- built from the exact
    /// same `EquipmentProfile.dominant(...)?.descriptor` calculation
    /// `TrendPoint.setupDescriptor` is, so the two always compare equal)
    /// right before navigating to `Page.trends`. `TrendsPage.onAppear`
    /// consumes it once (preselecting its own `selectedSetup` `@State`),
    /// same "set, navigate, consume on appear" pattern as
    /// `pendingTargetSegment` above. `nil` is itself a perfectly valid value
    /// to hand over -- a session with no derivable dominant setup just means
    /// "show unfiltered", exactly `TrendsPage`'s own default, so there's no
    /// need to distinguish "no pending request" from "pending request for no
    /// filter" here.
    var pendingTrendsSetupFilter: String?

    var stats: [TargetStats] = []
    /// Every target's session detail rows, keyed by target name -- populated
    /// alongside `stats` in `loadStats()` so `AllTargetsPage`'s hierarchical
    /// `Table` has every row's children available up front (a `Table` can't
    /// lazily fetch a row's children on first expand).
    var sessionDetailsByTarget: [String: [SessionDetail]] = [:]
    /// Every target's mosaic-panel breakdown (`FieldGeometry.panels`, R6-3),
    /// keyed by target name -- populated alongside `stats`/
    /// `sessionDetailsByTarget` in `loadStats()`. Only targets with `>= 2`
    /// panels (`isMosaic`) show anything in `AllTargetsPage`, but every target
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
    /// `StacksSegment`'s hierarchical table (R9-T3: the old `StackGroupSheet`
    /// this replaced is gone); a target with no discovered stacks still gets
    /// an entry (`[]`), same convention as `stackReportsByTarget`.
    var stackGroupsByTarget: [String: [StackGroup]] = [:]
    var calibNeeds: [CalibNeed] = []
    /// `CalibHealth.report`'s result -- flat discipline, bias inventory, dark
    /// master health -- shown below the coverage table on the Kalibráció
    /// oldal (`CalibrationPage`). `nil` until `loadCalibHealth()` has run at
    /// least once this session.
    var calibHealth: CalibHealthReport?
    /// Measured sensor characterization per `(camera, gain, offset)` combo
    /// (R7-B1 item C) -- read-only "Szenzor-profilok" list on its own
    /// Szenzor-profilok oldal (`SensorPage`, `Page.sensor` -- a dedicated
    /// page since R9-T5, not part of `CalibrationPage`), `[]` until
    /// `loadSensorProfiles()`/`measureSensorProfiles()` has run at least once
    /// this session.
    var sensorProfiles: [SensorProfileRecord] = []
    /// Every `sensor_profile_history` entry for each of `sensorProfiles`'
    /// combos, keyed by `SensorProfileRecord.comboKey` (R11-T10/F8) --
    /// backs `SensorPage`'s per-profile expandable history list + sparkline.
    /// Loaded alongside `sensorProfiles` (`loadSensorProfiles()`/
    /// `measureSensorProfiles()`), never separately -- a combo missing from
    /// this dictionary simply has no history rows on record yet.
    var sensorProfileHistoryByCombo: [String: [SensorProfileHistoryRecord]] = [:]
    var frameScores: [FrameScore] = []
    /// The user's own manual accept/reject verdict for each frame currently
    /// in `frameScores`, keyed by `FrameScore.path` (R10-B1) -- `FrameScore`
    /// itself carries no file id, only a path, so this is path-keyed rather
    /// than the `user_verdicts` table's own `Int64` file id. Populated
    /// alongside `frameScores` by `loadFrameScores`/`runRate`/`runRateAll`
    /// (see `loadVerdicts(forScores:db:)`), patched directly by
    /// `setFrameVerdict` without a full reload. A path absent from this
    /// dictionary means "no verdict recorded", same as `Database
    /// .userVerdict(fileID:)` returning `nil`. A full REPLACE here (not a
    /// merge) is correct and intended whenever it happens alongside a fresh
    /// `frameScores` load, same contract that array itself follows -- this
    /// is "verdicts for whatever `frameScores` currently holds", not a
    /// cross-target running cache. See `reviewFrameVerdicts` for the
    /// SEPARATE dictionary the "Előző éjszaka" review sheet uses instead
    /// (R12-U1 item 3), precisely because ITS load doesn't get to replace
    /// this one.
    var frameVerdicts: [String: Bool] = [:]

    /// Whether any `.dssfilelist` is currently tracked -- gates the
    /// toolbar's "Műveletek" menu's "DSS-döntések importálása" item (R7-B2;
    /// R9-T4 moved it there from the old `OverviewView`'s quick button), so
    /// it's never shown for a library with no DeepSkyStacker byproducts at
    /// all. Refreshed after `openRoot`/`runScan` via the cheap, targeted
    /// `Database.hasTrackedFileWithSuffix` query -- never a full `allFiles`
    /// scan just to answer this one yes/no question.
    var hasDSSFilelists: Bool = false
    /// The result of the last `runIngestDSS()` run, shown as
    /// `MainShellView`'s "DSS-adatok beolvasva" alert. `nil` before the menu
    /// item has ever been used this session.
    var dssIngestSummary: DSSIngestSummary?

    /// R7-1: the plate-solve backfill result shown in `PlateSolveSheet`
    /// while it's open -- `nil` before the sheet's operation has finished
    /// (it shows a spinner until this is set), cleared when the sheet
    /// closes so a stale previous target's result never flashes before the
    /// next open's finishes.
    var plateSolveSummary: SolveSummary?

    /// Tonight's observation plan (`Planner.plan`), backing `TonightPage`'s
    /// plan table (`Page.tonight`, the "Ma este" segment). `nil` until
    /// `loadPlan()` has run at least once this session.
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
    /// R11-T15/F16: `TonightPage`'s site-Picker persisted choice (shown only
    /// once `config.sites.count > 1`) -- `nil` means "use the configured
    /// default site" (`SiteProfile.defaultSite(in:)`). Persisted, same
    /// "app-behavior preference, not library-shape config" reasoning
    /// `autoScanOnMount` documents -- this is a per-machine UI choice, not
    /// something that belongs in `config.json`/the CLI's own `--site` flag
    /// (which always defaults to the configured default site, with no
    /// memory of any previous choice).
    ///
    /// R12-U1 item 4: a plain STORED property with a `didSet` mirror to
    /// `UserDefaults` -- was a computed property whose getter/setter read/
    /// wrote `UserDefaults` directly with no backing storage of its own, the
    /// same untracked-by-`@Observable` shape `firstStepsCardDismissed`'s own
    /// doc comment explains in full. `init()` reads the persisted starting
    /// value once.
    var selectedSiteName: String? = nil {
        didSet {
            if let selectedSiteName {
                UserDefaults.standard.set(selectedSiteName, forKey: Self.selectedSiteNameKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedSiteNameKey)
            }
        }
    }

    /// `selectedSiteName`, but `nil` unless it actually names one of
    /// `config.sites` right now -- what every planning loader below
    /// actually passes as `Planner.resolveSite`/`plan`/`month`'s own
    /// `siteName` argument. Validated here (rather than trusting
    /// `selectedSiteName` directly) so a site deleted from Settings
    /// mid-session, or a persisted choice left over from a config that no
    /// longer defines it, never throws `AstroError.invalidInput` out of a
    /// background load -- it just silently falls back to the configured
    /// default site instead, the same forgiving stance the CLI's own
    /// `--site` flag deliberately does NOT take (there, an unknown name is a
    /// typo worth a hard error).
    ///
    /// R12-U1 item 6: matches site names CASE-INSENSITIVELY, same as
    /// `Planner`'s own `resolveConfiguredSite(config:siteName:)` already
    /// does when it looks up an explicit `siteName` argument -- this used
    /// to be a strict `==`, stricter than what the core itself accepts, so
    /// a `selectedSiteName` whose casing drifted from `config.sites`' own
    /// entry (e.g. a site renamed with different capitalization in
    /// Settings) silently read back as "no selection" here even though
    /// `Planner.resolveSite(siteName:)` would have matched it just fine --
    /// the persisted choice looked "lost" for no reason a user could see.
    var effectiveSiteName: String? {
        guard let name = selectedSiteName,
              config.sites.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        return name
    }

    /// `effectiveSiteName`, falling back to the configured default site's
    /// own name -- what a discreet "Helyszín: <név>" chip (Felfedezés/Naptár
    /// segment headers, R12-U1 item 6) shows, and the same fallback
    /// `TonightPage`'s site-Picker `Binding` getter already computes for
    /// its own selection. `"-"` only in the pathological case `config.sites`
    /// is non-empty but somehow has no entry flagged `isDefault` at all
    /// (shouldn't happen -- `LocationSettingsView.save()` always normalizes
    /// to exactly one -- but this is a display string, never worth a crash).
    var effectiveSiteDisplayName: String {
        effectiveSiteName ?? SiteProfile.defaultSite(in: config.sites)?.name ?? "-"
    }

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
    /// shown in `TonightPage`'s "Következő 30 éjszaka" segment (R9-T4: the
    /// old standalone `CalendarPage`/"Hónap" sheet is gone, this is now
    /// `AppState.TonightSegment.calendar`). `nil` until `loadMonthPlan()` has
    /// run at least once this session -- never loaded automatically (same
    /// "time-of-day-sensitive, don't auto-refresh" stance as `plan`).
    var monthPlan: [NightSummary]?

    /// Every session across every target (`NightsQueries.allNights`, R10-A3),
    /// backing the "Éjszakák" page (`NightsPage`, R10-B3) -- loaded
    /// UNFILTERED (`loadNights()` never passes `year`/`month`), since that
    /// page derives its year/month Picker options and applies the filter
    /// client-side, the same "load once, filter locally" split
    /// `AllTargetsPage`'s search field already uses over `stats`. `nil`
    /// until `loadNights()` has run at least once this session -- never
    /// loaded automatically, same "lazily loaded on the page's own
    /// `onAppear`" stance `monthPlan` takes.
    var nights: [NightRow]?

    /// R11-T17: cheap FWHM-only stand-in for `nights` -- feeds
    /// `SessionsSegment`'s FWHM″ percentile dot the FIRST time a user opens a
    /// target's page in a session, before `nights` itself has ever been
    /// populated (that only happens once "Éjszakák" has actually been
    /// visited -- see `nights`' own doc comment above). `loadTargetDetail`
    /// kicks off `loadLibraryFWHMArcsecBaselineIfNeeded()` in the background
    /// whenever `nights == nil`, entirely OUTSIDE the `beginOperation`/
    /// `currentTask` machinery (never flips `isBusy`, never cancels or is
    /// cancelled by any other operation -- see that function's own doc
    /// comment). `nil` until that fetch completes at least once; `[]` is a
    /// real, valid result (library has no comparable FWHM data yet at all),
    /// so this stays Optional rather than defaulting to `[]`. `SessionsSegment
    /// .libraryFWHMArcsecValues` prefers `nights` itself once THAT'S been
    /// loaded (the superset, authoritative source) and only falls back to
    /// this baseline otherwise.
    var libraryFWHMArcsecBaseline: [Double]?

    /// Every session's trend-relevant metrics across every target
    /// (`TrendQueries.points`, R11-T10/F7), backing the "Trendek" page
    /// (`TrendsPage`) -- loaded UNFILTERED (`loadTrends()` never passes
    /// `setupFingerprint`/`from`/`to`) for the exact same "load once, filter
    /// client-side" reason `nights`/`loadNights()` documents above:
    /// `TrendsPage`'s time-range/setup/target-type controls all narrow this
    /// same in-memory array rather than re-querying per Picker change. `nil`
    /// until `loadTrends()` has run at least once this session.
    var trendPoints: [TrendPoint]?

    /// The catalog "what should I shoot tonight that I don't already have"
    /// sweep (`DiscoveryPlanner.discover`, R10-A4), backing the
    /// "Felfedezés" page (`DiscoveryPage`, R10-B4). `nil` until
    /// `loadDiscovery()` has run at least once this session -- never
    /// loaded automatically, same "lazily loaded on the page's own
    /// `onAppear`" stance `nights`/`monthPlan` already take.
    var discovery: [DiscoveryRow]?
    /// The library's dominant equipment setup's median field of view
    /// (`FieldGeometry.dominantFOV`, R10-B4), computed alongside
    /// `discovery` by the SAME `loadDiscovery()` call and handed to
    /// `DiscoveryPlanner.discover` as its `setupFOVDeg` -- kept as its own
    /// property (not folded into a per-row field) since every row's FOV-fit
    /// column judges against this ONE shared value, not something
    /// per-target. `nil` exactly when `FieldGeometry.dominantFOV` itself
    /// returns `nil` (no usable, WCS-resolved light in the whole library
    /// shares the dominant setup's fingerprint) -- `DiscoveryPage` shows
    /// "n/a" for the FOV tile/column in that case, never a guess.
    var discoveryFOV: DiscoveryFOV?

    // MARK: - Weather (R10-B6)

    /// Opt-in Open-Meteo cloud-cover forecast for `resolvedSite`'s
    /// coordinate -- `nil` until `loadWeather()` has ever fetched
    /// successfully (or forever, when the feature is off or no site is
    /// resolved). The fetch itself lives entirely in `WeatherService` (app
    /// layer only, see its doc comment) -- AstroCore never makes a network
    /// call.
    var nightForecast: NightForecast?
    /// `nightForecast`'s hours bucketed into one min/max/mean summary per
    /// local night, keyed by "yyyy-MM-dd" -- backs the calendar segment's
    /// "Felhő" column. Empty under the same conditions as `nightForecast`
    /// being `nil` (a date simply missing from this dictionary means "no
    /// forecast for that night", which the calendar renders as "—").
    var weatherDailySummaries: [String: DailyCloudSummary] = [:]
    /// Set when `loadWeather()`'s fetch fails AND there was no cached
    /// forecast to fall back on (the only case `WeatherService.fetch`
    /// actually throws) -- the "Felhőzet" tile shows this as its own
    /// caption instead of the generic `lastError` banner, since an optional,
    /// opt-in side feature failing shouldn't compete for the same inline
    /// error real estate the planner itself uses. Cleared on the next
    /// successful fetch.
    var weatherError: String?

    /// Every target's pipeline status (`ProjectStatusQueries.projects`) --
    /// backs the sidebar's phase dots, `AllTargetsPage`'s "Fázis" column and
    /// "Kész / folyamatban" tile, and `TonightPage`'s plan table "Állapot"
    /// column. `[]` until `loadDashboardData()` has run at least once this
    /// session (also refreshed automatically after a scan, unlike `plan`).
    var projectStates: [ProjectState] = []

    /// The currently selected target's per-session absolute quality summaries
    /// (`SessionQuality.summaries`) -- shown above the frame table in the
    /// Célpont-részletek page's Minőség segment (`QualitySegment`). Cleared
    /// whenever a different target is selected so a stale previous target's
    /// rows never flash before the new ones load.
    var qualitySummaries: [SessionQualitySummary] = []
    /// The currently selected target's sub-exposure/relative-SNR advice
    /// (R7-B3 `ExposureAdvisor`) -- shown just above `qualitySummaries` in
    /// the Minőség segment. `nil` until `loadExposureAdvice(target:)` has run
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
    /// `CalibrationPage`'s `.sheet(item:)`. Separate from `AllTargetsPage`'s/
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
    /// R12-U2 (point 2): how many stale hardlinks the same `exportStackList()`
    /// run's own re-export sync removed from `lights/` -- `0` for a fresh
    /// export or one whose tree already matched the current selection.
    /// `StackListSheet`'s "kész" state shows this alongside the export path
    /// whenever it's non-zero.
    var stackListRemovedStaleCount: Int = 0

    var isBusy: Bool = false
    var progressText: String = ""
    var lastError: String?
    /// R11-T1: the `AstroError` case behind `lastError`'s CURRENT message,
    /// when there is one -- `handle(_:)` sets it alongside `lastError`,
    /// `beginOperation` resets it same as `lastError`. Purely
    /// `endOperation`'s own lookup key for `errorAdvice(for:)`; no view
    /// reads this directly. `@ObservationIgnored`: never rendered.
    @ObservationIgnored
    private var lastAstroError: AstroError?

    /// Set on a successful `createSession(...)` so `NewSessionSheet` can
    /// observe it and dismiss itself.
    var lastCreatedSessionDir: URL?

    /// The in-flight background operation, if any. "Mégse" cancels it, but
    /// since the AstroCore calls underneath (scan/audit/rate) are plain
    /// synchronous functions with no cancellation checks of their own, this
    /// only ever prevents the FOLLOW-UP step (applying the result to
    /// published state) from running -- it can never abort mid-operation.
    /// Every loader/mutation in this file shares this ONE slot except
    /// `runScan` (see `scanTask`'s own doc comment) -- `beginOperation`
    /// cancelling whatever's already here is deliberate "latest wins"
    /// behavior for this whole class of quick, idempotent re-fetches.
    @ObservationIgnored
    private var currentTask: Task<Void, Never>?

    /// R12-U1 item 2: `runScan`'s OWN task slot, deliberately independent of
    /// `currentTask`. Before this, `runScan` shared `currentTask` like every
    /// other loader -- harmless for a quick re-fetch (the whole point of
    /// `currentTask`'s "latest wins" cancellation), but a scan is slow,
    /// rare, and its result (`scanSummary`/`lastScanDate`/`freshSessionKeys`
    /// + the post-scan stats/calib/projects refresh) is exactly what the
    /// user is waiting for -- losing it to an unrelated read-only loader
    /// starting in the meantime (e.g. switching pages, which fires
    /// `loadDashboardData`/`loadPlan`/…) is a real bug, not a harmless race.
    /// `Task.detached` (what the scan itself actually runs on) was already
    /// immune to this -- it's deliberately unlinked from the outer `Task`'s
    /// cancellation/priority, so the SCAN never stopped mid-flight either
    /// way -- the bug was purely that `runScan`'s own `guard
    /// !Task.isCancelled` (checking the OUTER wrapper `Task` stored in
    /// whichever slot it's in) would trip and silently discard the
    /// already-finished result once some UNRELATED `beginOperation` call
    /// had cancelled that same shared `currentTask` out from under it.
    /// Giving `runScan` its own slot means only ANOTHER `runScan` call (or
    /// an explicit "Mégse", see `cancelCurrentOperation`) can ever cancel
    /// it -- the `beginOperation`/`isBusy`/`progressText`/activity-log/toast
    /// machinery is untouched, so the progress UI and "Mégse" both keep
    /// working exactly as before. Trade-off, deliberately accepted: if some
    /// OTHER operation starts and finishes WHILE a scan is still running,
    /// `endOperation`'s own `currentOperationID` guard (unchanged) means the
    /// scan's activity-log entry/success toast can end up silently
    /// superseded once the scan itself finishes -- the DATA still lands
    /// (the actual fix this exists for), only the notification of it might
    /// not. Considered the smaller risk of the two options this ticket
    /// weighed (the other being "never gate `runScan`'s own writes on
    /// `Task.isCancelled` at all", which risks an OLDER scan overwriting a
    /// NEWER one's result if two scans ever really do overlap).
    @ObservationIgnored
    private var scanTask: Task<Void, Never>?

    // MARK: - Root selection

    init() {
        // R12-U1 item 4: `firstStepsCardDismissed`/`autoScanOnMount`/
        // `selectedSiteName` are now plain STORED properties (see each
        // one's own doc comment for why) -- the one-time read of whatever
        // was already persisted has to happen explicitly here, since a
        // stored property's own declared default (`false`/`nil`) is all
        // `@Observable` initializes it to otherwise.
        firstStepsCardDismissed = UserDefaults.standard.bool(forKey: Self.firstStepsCardDismissedKey)
        autoScanOnMount = UserDefaults.standard.bool(forKey: Self.autoScanOnMountKey)
        selectedSiteName = UserDefaults.standard.string(forKey: Self.selectedSiteNameKey)
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
        startActivationObserverIfNeeded()
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
                guard let self else { return }
                self.staleCheckTick += 1
                guard self.rootStatus == .notMounted else { return }
                self.retryRootAccess()
                // R11-T9/F5: opt-in auto-scan -- ONLY when the user has
                // explicitly turned on "Automatikus beolvasás kötet
                // csatlakozásakor" (Settings ▸ Könyvtár, default OFF), the
                // root just became reachable (`retryRootAccess()` above
                // moved `rootStatus` off `.notMounted` to something other
                // than another error), and nothing else is already running
                // (`runScan`'s own `beginOperation` would otherwise cancel
                // whatever `openRoot`'s dashboard-data reload just started --
                // harmless on its own, same "latest wins" race every other
                // back-to-back `beginOperation` call in this file already
                // accepts, but pointless to trigger on top of some OTHER
                // operation the user is actively waiting on).
                guard self.autoScanOnMount, !self.isBusy,
                      self.rootStatus == .ok || self.rootStatus == .notScanned
                else { return }
                self.runScan()
            }
        }
    }

    /// D31: the other half of the stale-scan-banner fix -- bringing the app
    /// to the foreground (after sitting backgrounded, possibly well past
    /// the 24h threshold) is exactly the moment a stale-scan warning is
    /// most useful, and exactly the moment nothing else would have
    /// otherwise told `scanIsStale`'s observers to re-evaluate it.
    private func startActivationObserverIfNeeded() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.staleCheckTick += 1
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
        findings = []
        auditFindings = []
        verifyFindings = []
        lastRunID = nil
        lastVerifyRunID = nil
        lastVerifyDate = nil
        lastVerifySummary = nil
        verifyCoverage = nil
        verifyBaselineErrors = []
        quarantineState = nil
        quarantineInspectionError = nil
        // N5 (R9 round 3): switching roots without this left the PREVIOUS
        // root's per-target coordinate memo in place -- a target name that
        // happens to recur across two different libraries would silently
        // reuse the old root's (wrong) cached coordinate/`nil` instead of
        // ever resolving it for the newly opened one.
        coordinateInfoCache = [:]
        // R11-T9/F5: same reasoning -- the PREVIOUS root's "fresh sessions"
        // (and any triage cards built from them) must not leak into the
        // newly opened one, which hasn't been scanned yet at all here.
        freshSessionKeys = []
        previousNightCards = []

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
            // R9-D1: restore the last completed audit's findings from disk
            // so a fresh launch shows them (and the sidebar's error badge,
            // via `auditErrorBadgeCount`) WITHOUT re-running the audit --
            // previously `findings`/`lastRunID` only ever got set by
            // `runAudit()` itself, so both silently reset to empty/`nil` on
            // every relaunch even though the last run's rows were still
            // sitting in the `runs`/`findings` tables.
            lastRunID = try? opened.lastCompletedRunID(kind: "audit")
            auditFindings = lastRunID.flatMap { try? opened.findings(runID: $0) } ?? []
            lastVerifyRunID = try? opened.lastCompletedRunID(kind: "verify")
            verifyFindings = lastVerifyRunID.flatMap { try? opened.findings(runID: $0) } ?? []
            if let verifyRunID = lastVerifyRunID,
               let verifyRun = try? opened.runSummary(id: verifyRunID)
            {
                lastVerifyDate = verifyRun.startedAt
                lastVerifySummary = (try? FixityVerifier.decodeRunMetadata(verifyRun.configJSON))?.summary
            }
            verifyCoverage = try? FixityVerifier.coverage(db: opened)
            findings = Self.composeAuditFindings(audit: auditFindings, verify: verifyFindings)
            // R11-T8/F6: restore the diff-vs-previous-run alongside
            // `findings`/`lastRunID` -- see `auditDiff`'s own doc comment for
            // why this needs to happen in both places that set those two.
            auditDiff = Self.loadAuditDiff(
                currentRunID: lastRunID,
                currentFindings: auditFindings,
                db: opened,
                config: config
            )
            // R9-D2/D3: same idea for the dashboard data (stats/plan/
            // projects/cleanup) every sidebar badge, phase dot, and the "Ma
            // este" Állapot/Hiányzik column depend on -- see
            // `loadDashboardData`'s doc comment.
            loadDashboardData()
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
                // R11-T1: kept alongside `lastError` so `endOperation` can
                // look up this operation's "Mit tehetsz: …" advice for the
                // activity-log popover -- `lastError` itself stays the short
                // message every OTHER display already reads (toasts, this
                // app's ~8 inline `lastError` texts), see `errorAdvice(for:)`.
                lastAstroError = astroError
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
    /// and can't stop. Cancels BOTH task slots (R12-U1 item 2: `runScan` now
    /// runs in its own `scanTask`, not `currentTask`) -- only one of the two
    /// is ever actually running in practice (whichever operation's
    /// `progressText`/"Mégse" button the user is currently looking at), so
    /// cancelling the other is always a harmless no-op against an already-
    /// finished (or `nil`) `Task`.
    func cancelCurrentOperation() {
        currentTask?.cancel()
        scanTask?.cancel()
    }

    // MARK: - Scan

    /// `subpath`, when given, scopes the scan to that root-relative subtree
    /// (D23: `AllTargetsPage`'s folder-drop scoped rescan) -- otherwise the
    /// same full-root scan every other caller (toolbar "Beolvasás", ⌘R,
    /// first-run) has always run.
    ///
    /// R12-U1 item 2: runs in its OWN `scanTask` slot (see that property's
    /// own doc comment) rather than the shared `currentTask` -- an unrelated
    /// read-only loader starting while a scan is still running must never
    /// make this method's own result silently vanish. `scanTask?.cancel()`
    /// right below keeps the one case that SHOULD still cancel a
    /// still-running scan (a second `runScan` call) working exactly like
    /// `beginOperation`'s own `currentTask?.cancel()` already does for every
    /// other loader in this file.
    func runScan(subpath: String? = nil) {
        guard let db else { return }
        let cfg = config

        // R10 review: the subpath (D23 "almappa"-scoped) variant now uses a
        // static, listable title -- was interpolated with the subpath
        // itself, which can never match a `successToastTitles` literal (a
        // `Set<String>` of exact strings), so its "Kész — új: …" summary
        // never toasted even though a full scan's did.
        let opID = beginOperation(subpath == nil ? "Könyvtár beolvasása…" : "Almappa beolvasása…")
        scanTask?.cancel()
        scanTask = Task { [weak self] in
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
                    let result = try scanner.scan(subpath: subpath) { count in
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
                // R11-T9/F5: REPLACES (not merges into) whatever the
                // previous scan this run reported -- "fresh" means "since
                // the last scan", so a rescan that touched nothing empties
                // this back out, same as `scanSummary` itself always
                // reflects only the MOST RECENT scan. Any stale triage
                // cards from a prior fresh set are dropped here too --
                // `PreviousNightPage`'s own `onAppear`/`onChange` reload
                // `previousNightCards` from the new `freshSessionKeys`
                // whenever it's actually visible.
                self.freshSessionKeys = summary.changedSessions
                if summary.changedSessions.isEmpty {
                    self.previousNightCards = []
                }
                // D12: any target's frames may have changed (new files,
                // moved files, re-solved headers) -- drop the whole
                // per-target coordinate-info memo rather than try to guess
                // which targets are still valid.
                self.coordinateInfoCache = [:]
                self.progressText =
                    "Kész — új: \(summary.added), frissült: \(summary.updated), " +
                    "változatlan: \(summary.unchanged), hiányzó: \(summary.missing)"
                // R12-U1 item 5: a rescan may have changed session-level
                // metrics (FWHM/background/duty-cycle, a re-solved setup
                // fingerprint) `trendPoints` was computed from -- `nil`s it
                // back out so `TrendsPage` recomputes on its next visit
                // instead of silently showing pre-scan numbers next to
                // fresh ones. Cheap either way: a scan is rare enough that
                // forcing one extra `TrendQueries.points` re-run next time
                // "Trendek" is opened costs nothing worth guarding against.
                self.trendPoints = nil

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
                    // R11-T16/F17: darks + flats, same merge `loadCalibBundle` uses.
                    try CalibAnalyzer.coverage(db: db, config: cfg) + CalibAnalyzer.flatCoverage(db: db, config: cfg)
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
                let (runID, findings, diff) = try await Task.detached(priority: .userInitiated) {
                    let engine = AuditEngine(config: cfg, db: db)
                    let (runID, findings) = try engine.run(includeDuplicates: includeDuplicates)
                    // R11-T8/F6: diff against the run immediately before
                    // this one -- see `AppState.loadAuditDiff`'s doc comment.
                    let diff = Self.loadAuditDiff(currentRunID: runID, currentFindings: findings, db: db, config: cfg)
                    return (runID, findings, diff)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.lastRunID = runID
                self.auditFindings = findings
                self.findings = Self.composeAuditFindings(
                    audit: self.auditFindings, verify: self.verifyFindings
                )
                self.auditDiff = diff
                self.progressText = "Audit kész: \(findings.count) találat"

                // Best-effort refresh of the cleanup/storage reports, same
                // as Stats/Calib get refreshed after a scan -- a failure
                // here shouldn't turn an otherwise-successful audit into a
                // reported error.
                if let refreshed = try? await Task.detached(priority: .userInitiated, operation: {
                    (
                        try CleanupReport.build(db: db, config: cfg),
                        try StorageQueries.perTarget(db: db, config: cfg),
                        Self.inspectQuarantine(config: cfg)
                    )
                }).value {
                    self.cleanupSummary = refreshed.0
                    self.storageSummary = refreshed.1
                    self.quarantineState = refreshed.2.state
                    self.quarantineInspectionError = refreshed.2.error
                }
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// `currentRunID`'s previous audit run's findings compared against
    /// `currentFindings`, or `nil` when there's no previous run to compare
    /// against (`currentRunID == nil`, or it's the first audit run ever).
    /// A `static` helper (not an instance method) so `runAudit`'s
    /// `Task.detached` closure can call it without capturing `self` --
    /// shared between that (fresh-run) call site and `openRoot` (restoring
    /// the diff across launches) so the two never compute it differently.
    private static nonisolated func loadAuditDiff(
        currentRunID: Int64?,
        currentFindings: [Finding],
        db: Database,
        config: AstroConfig
    ) -> AuditDiff.Result? {
        guard let currentRunID,
              let previousRunID = try? db.previousCompletedRunID(before: currentRunID, kind: "audit")
        else {
            return nil
        }
        let previousFindings = (try? db.findings(runID: previousRunID)) ?? []
        let previousIncludedDuplicates: Bool?
        if let run = try? db.runSummary(id: previousRunID) {
            previousIncludedDuplicates = AuditEngine.decodeRunConfig(run.configJSON)?.includeDuplicates
        } else {
            previousIncludedDuplicates = nil
        }
        let currentIncludedDuplicates: Bool?
        if let run = try? db.runSummary(id: currentRunID) {
            currentIncludedDuplicates = AuditEngine.decodeRunConfig(run.configJSON)?.includeDuplicates
        } else {
            currentIncludedDuplicates = nil
        }
        return AuditDiff.compute(
            previous: previousFindings,
            current: currentFindings,
            config: config,
            previousIncludedDuplicates: previousIncludedDuplicates,
            currentIncludedDuplicates: currentIncludedDuplicates
        )
    }

    // MARK: - Verify (R11-T14/F9)

    private static nonisolated func composeAuditFindings(
        audit: [Finding], verify: [Finding]
    ) -> [Finding] {
        var seen = Set<String>()
        return (audit + verify).filter { finding in
            seen.insert("\(finding.category)|\(finding.path)|\(finding.message)").inserted
        }
    }

    /// Cheap synchronous estimate of how many files `runVerify()` would
    /// actually re-hash -- the app always runs verify over the WHOLE
    /// library (unlike the CLI's `--target`/`--path`, there is no scoping
    /// UI here), so this is a plain unscoped count. Backs the
    /// "Integritás-ellenőrzés…" confirmation sheet's "N fájl — ez akár X
    /// percig is tarthat" estimate; `Database.countHashedFiles` is a
    /// dedicated `COUNT(*)` query (not `FixityVerifier.eligibleFiles(...)
    /// .count`) specifically so this stays fast enough to call synchronously
    /// right before presenting the sheet, even on a library with tens of
    /// thousands of files. `0` if there's no open DB or the query fails.
    func countVerifyEligibleFiles() -> Int {
        guard let db else { return 0 }
        return (try? db.countHashedFiles()) ?? 0
    }

    /// Refreshes hash coverage using only database counts.
    func loadVerifyCoverage() {
        guard let db else {
            verifyCoverage = nil
            return
        }
        verifyCoverage = try? FixityVerifier.coverage(db: db)
    }

    /// Computes missing baseline hashes while leaving every library file
    /// byte-for-byte untouched. Only Astro Tool's DB cache is updated.
    func runVerifyBaseline() {
        guard let db else { return }
        let cfg = config
        let opID = beginOperation("Hiányzó ellenőrző-összegek pótlása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                    try FixityVerifier.baseline(db: db, config: cfg) { done, total in
                        Task { @MainActor in
                            self?.progressText = "Hash kész: \(done)/\(total)"
                        }
                    }
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.verifyBaselineErrors = result.errors
                self.verifyCoverage = try? FixityVerifier.coverage(db: db)
                self.progressText = result.errors.isEmpty
                    ? "Baseline kész: \(result.hashed) új ellenőrző-összeg"
                    : "Baseline: \(result.hashed) új hash, \(result.errors.count) hiba"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Runs a fixity/bitrot check over the whole library --
    /// `samplePercent`, when given, checks only a random N% of the
    /// already-hashed files instead of all of them (the confirmation
    /// sheet's "Csak minta (10%)" checkbox). Read-only against the library
    /// itself; see `FixityVerifier`'s own doc comment for the full
    /// contract (never rewrites the cached hash, never "fixes" anything).
    ///
    /// Audit and verify evidence remain separate and are recomposed after
    /// each run, so neither operation can erase the other's latest result.
    /// The persisted verify run is restored the same way after relaunch.
    func runVerify(samplePercent: Int? = nil) {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Integritás-ellenőrzés fut…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (runID, results, verifyFindings) = try await Task.detached(priority: .userInitiated) { [weak self] in
                    try FixityVerifier.run(db: db, config: cfg, samplePercent: samplePercent) { done, total in
                        Task { @MainActor in
                            self?.progressText = "Ellenőrizve: \(done)/\(total)"
                        }
                    }
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }

                self.lastVerifyRunID = runID
                let summary = FixityVerifier.summarize(results)
                self.verifyFindings = verifyFindings
                self.findings = Self.composeAuditFindings(
                    audit: self.auditFindings, verify: self.verifyFindings
                )
                self.lastVerifyDate = (try? db.runSummary(id: runID))?.startedAt ?? Date()
                self.lastVerifySummary = summary
                self.verifyCoverage = try? FixityVerifier.coverage(db: db)
                let mismatchCount = summary.checked - summary.ok
                self.progressText = "Integritás: \(summary.ok) fájl rendben, \(mismatchCount) eltérés"
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
    /// `md`) under `.astro_tool/exports/` and reveals it in Finder --
    /// `AllTargetsPage`'s per-target row context menu's "Exportálás" submenu.
    func exportAcquisition(target: String, format: ExportFormat) {
        guard let db else { return }
        let cfg = config
        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        let writeGuard = WriteGuard(root: root)

        let opID = beginOperation("Exportálás…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                // R11-T16/F20: for an `astrobin` export, also check for
                // filters with no `config.astrobin.filterIds` entry -- the
                // toast below surfaces the gap instead of a bare name
                // silently going out unmapped every time.
                let (url, unmappedFilters) = try await Task.detached(priority: .userInitiated) {
                    let url = try AcquisitionExport.write(
                        target: target, format: format, timestamp: Date(), db: db, config: cfg, using: writeGuard
                    )
                    let unmapped = format == .astrobin
                        ? try AcquisitionExport.unmappedAstrobinFilters(target: target, db: db, config: cfg)
                        : []
                    return (url, unmapped)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.progressText = "Exportálva: \(url.lastPathComponent)"
                if !unmappedFilters.isEmpty {
                    self.pushToast(
                        .info,
                        "Nincs AstroBin ID: \(unmappedFilters.joined(separator: ", ")) — Beállítások ▸ Könyvtár"
                    )
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Refreshes Settings' library-wide list without occupying/cancelling the
    /// app's global operation slot; this is a small read-only convenience
    /// query and stale results are harmless until the next settings open.
    func loadUsedUnmappedAstroBinFilters() {
        guard let db else {
            usedUnmappedAstroBinFilters = []
            return
        }
        let cfg = config
        Task { [weak self] in
            guard let self else { return }
            do {
                let names = try await Task.detached(priority: .utility) {
                    let targets = try StatsQueries.perTarget(db: db, config: cfg).map(\.target)
                    var result = Set<String>()
                    for target in targets {
                        result.formUnion(
                            try AcquisitionExport.unmappedAstrobinFilters(
                                target: target, db: db, config: cfg
                            )
                        )
                    }
                    return result.sorted {
                        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                    }
                }.value
                self.usedUnmappedAstroBinFilters = names
            } catch {
                self.usedUnmappedAstroBinFilters = []
            }
        }
    }

    // MARK: - Cleanup

    private struct QuarantineLoad: Sendable {
        let state: QuarantineState?
        let error: String?
    }

    private static nonisolated func inspectQuarantine(config: AstroConfig) -> QuarantineLoad {
        do {
            let state = try QuarantineSummary.inspect(
                root: URL(fileURLWithPath: config.rootPath, isDirectory: true), config: config
            )
            return QuarantineLoad(state: state, error: nil)
        } catch {
            return QuarantineLoad(state: nil, error: (error as NSError).localizedDescription)
        }
    }

    /// Loads the size-ordered cleanup report (residue + duplicate-content
    /// groups) for the Audit page's "Takarítható" segment. Safe to call any
    /// time the DB has data -- unlike `runAudit`, this never runs
    /// duplicate-content hashing itself, it only reads whatever's already
    /// cached. Called from `openRoot` (via `loadDashboardData`, R9-D2/D3)
    /// and `AuditPage.onAppear` (when `cleanupSummary` is still `nil`, e.g.
    /// the user opened the Audit page directly without visiting a page that
    /// already triggered `loadDashboardData`).
    func loadCleanup() {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Takarítási riport számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                // R11-T8/F19: the Takarítható segment's "Tárhely" block sits
                // above this same report's content and is loaded on the
                // exact same trigger, so it's fetched alongside rather than
                // via a separate on-appear/operation.
                let (result, storage, quarantine) = try await Task.detached(priority: .userInitiated) {
                    (
                        try CleanupReport.build(db: db, config: cfg),
                        try StorageQueries.perTarget(db: db, config: cfg),
                        Self.inspectQuarantine(config: cfg)
                    )
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.cleanupSummary = result
                self.storageSummary = storage
                self.quarantineState = quarantine.state
                self.quarantineInspectionError = quarantine.error
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

    /// Bundles the same five queries `loadStats()` needs so they can share
    /// ONE background hop -- factored out (R10-A5) so `runIngestDSS()`'s own
    /// best-effort post-ingest refresh can reuse the exact same query set
    /// WITHOUT calling the public `loadStats()` itself, which would call
    /// its OWN `beginOperation` and reassign `currentOperationID` out from
    /// under the ingest operation's still-pending `endOperation(opID)` call
    /// (same race `runRate`'s doc comment describes for
    /// `loadQualitySummaries`/`loadExposureAdvice` -- see `runIngestDSS()`
    /// for exactly where this bit).
    private struct StatsBundle {
        var stats: [TargetStats]
        var sessionsByTarget: [String: [SessionDetail]]
        var panelsByTarget: [String: PanelReport]
        var stacksByTarget: [String: TargetStacks]
        var stackGroupsByTarget: [String: [StackGroup]]
    }

    /// Plain (non-actor-isolated) function so it can run inside a
    /// `Task.detached` closure -- same "no `self` capture needed" shape as
    /// `resolveCoordinateInfo`/`loadCalibBundle`.
    private static nonisolated func loadStatsBundle(db: Database, config: AstroConfig) throws -> StatsBundle {
        let stats = try StatsQueries.perTarget(db: db, config: config)
        var sessionsByTarget: [String: [SessionDetail]] = [:]
        var panelsByTarget: [String: PanelReport] = [:]
        var stackGroupsByTarget: [String: [StackGroup]] = [:]
        let discoveredStacks = try StackDiscovery.discover(db: db, config: config)
        let stacksByTarget = Dictionary(uniqueKeysWithValues: discoveredStacks.map { ($0.target, $0) })
        for stat in stats {
            sessionsByTarget[stat.target] = try SessionStatsQueries.sessions(
                target: stat.target, db: db, config: config
            )
            panelsByTarget[stat.target] = try FieldGeometry.panels(
                target: stat.target, db: db, config: config
            )
            // R8-3: only worth grouping targets that actually have
            // discovered stacks -- same "don't do useless work" stance as
            // skipping an empty `stacksByTarget` entry.
            if let report = stacksByTarget[stat.target], !report.stacks.isEmpty {
                stackGroupsByTarget[stat.target] = try StackDiscovery.groupedStacks(
                    target: stat.target, db: db, config: config
                )
            }
        }
        return StatsBundle(
            stats: stats, sessionsByTarget: sessionsByTarget, panelsByTarget: panelsByTarget,
            stacksByTarget: stacksByTarget, stackGroupsByTarget: stackGroupsByTarget
        )
    }

    /// Loads `stats` plus every target's session detail rows in one go (one
    /// `SessionStatsQueries.sessions` call per target, on the same
    /// background operation) -- with the library's target count this is
    /// cheap, and it's what lets `AllTargetsPage`'s hierarchical `Table` show
    /// session sub-rows without a separate lazy-load-on-expand step.
    func loadStats() {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Statisztika számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let bundle = try await Task.detached(priority: .userInitiated) {
                    try Self.loadStatsBundle(db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.stats = bundle.stats
                self.sessionDetailsByTarget = bundle.sessionsByTarget
                self.panelReportsByTarget = bundle.panelsByTarget
                self.stackReportsByTarget = bundle.stacksByTarget
                self.stackGroupsByTarget = bundle.stackGroupsByTarget
                self.progressText = "Statisztika kész: \(bundle.stats.count) célpont"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Nights (R10-B3)

    /// Loads every session across every target (`NightsQueries.allNights`)
    /// for the "Éjszakák" page -- always UNFILTERED (`year`/`month` stay at
    /// their `nil` default) since `NightsPage` derives its own year/month
    /// Picker options from this full list and filters client-side rather
    /// than re-querying per Picker change. The query's own `year`/`month`
    /// parameters are exercised by the CLI (`astrotool nights --year/
    /// --month`) and its tests instead -- left unused here rather than
    /// removed, per the plan's "keep the core API's params unused rather
    /// than stripping them" call.
    ///
    /// Never triggered by `loadDashboardData()` -- lazily loaded from
    /// `NightsPage.onAppear` only, same "time/data-volume-sensitive, don't
    /// auto-refresh" stance `loadMonthPlan()` already takes for its own
    /// on-demand dataset.
    func loadNights() {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Éjszakák betöltése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try NightsQueries.allNights(db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.nights = result
                self.progressText = "Éjszakák betöltve: \(result.count) session"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// R11-T17: keyed by `Task` identity so a second `loadTargetDetail` call
    /// (switching targets quickly) never launches a duplicate fetch on top
    /// of one already in flight.
    @ObservationIgnored
    private var libraryFWHMArcsecBaselineTask: Task<Void, Never>?

    /// See `libraryFWHMArcsecBaseline`'s own doc comment for what this feeds
    /// and why. A no-op whenever `nights` is already loaded (that's the
    /// authoritative superset, nothing left for this baseline to add), this
    /// baseline is already populated, or a fetch is already running.
    ///
    /// Deliberately does NOT go through `beginOperation`/`currentTask` --
    /// unlike every other loader in this file, this one must never flip
    /// `isBusy` (a spinner over the whole target-detail page just for a
    /// color dot would be absurd) and must never be cancelled by, or itself
    /// cancel, an unrelated operation (`beginOperation` always cancels
    /// `currentTask` first, which would otherwise tear down whatever
    /// `loadTargetDetail` itself just started). Failures are silently
    /// swallowed (`try?`): worst case the dot just doesn't appear yet, the
    /// same "no dot" state a too-small library already produces -- this is a
    /// cosmetic nicety, not a page the user is depending on to load at all.
    func loadLibraryFWHMArcsecBaselineIfNeeded() {
        guard nights == nil, libraryFWHMArcsecBaseline == nil, libraryFWHMArcsecBaselineTask == nil, let db else { return }
        let cfg = config
        libraryFWHMArcsecBaselineTask = Task { [weak self] in
            let values = try? await Task.detached(priority: .utility) {
                try LibraryPercentiles.libraryFWHMArcsecValues(db: db, config: cfg)
            }.value
            guard let self else { return }
            if let values {
                self.libraryFWHMArcsecBaseline = values
            }
            self.libraryFWHMArcsecBaselineTask = nil
        }
    }

    // MARK: - Previous night (R11-T9/F5)

    /// Builds one `PreviousNightCard` per `keys` entry -- reuses
    /// `NightsQueries.allNights` (the exact same per-session bundle
    /// `NightsPage`/`SessionsSegment` already show: display name, usable
    /// frame count, integration, `FilterBreakdown`, median FWHM) rather than
    /// re-deriving any of that, then adds the two fields that query doesn't
    /// carry: `NightHealth.report`'s cooler/focus verdicts, and an outlier
    /// ratio from `Rater.cachedScores`. Cheap even though `allNights` walks
    /// every session in the library: `keys` is normally a small handful of
    /// sessions (this run's fresh ones), and `NightsPage`'s own "Éjszakák"
    /// page already pays this exact same full-library cost on every visit.
    /// `nonisolated static` (not an instance method) so it can run inside
    /// `Task.detached` without capturing `self`, same convention
    /// `loadAuditDiff`/`loadVerdicts` above already use.
    private nonisolated static func buildPreviousNightCards(
        keys: [ScanSummary.SessionKey], db: Database, config: AstroConfig
    ) throws -> [PreviousNightCard] {
        guard !keys.isEmpty else { return [] }
        let keySet = Set(keys)
        let allRows = try NightsQueries.allNights(db: db, config: config)
        let matched = allRows.filter { keySet.contains(ScanSummary.SessionKey(target: $0.target, date: $0.date)) }

        var cards: [PreviousNightCard] = []
        cards.reserveCapacity(matched.count)
        for row in matched {
            let health = try NightHealth.report(target: row.target, date: row.date, db: db, config: config)
            let scores = try Rater.cachedScores(target: row.target, date: row.date, db: db, config: config)
            let outlierRatio: Double? = scores.isEmpty
                ? nil
                : Double(scores.count { $0.isOutlier }) / Double(scores.count)
            cards.append(PreviousNightCard(
                target: row.target,
                displayName: row.displayName,
                date: row.date,
                usableLightCount: row.usableLightCount,
                integrationSeconds: row.integrationSeconds,
                filterBreakdown: row.filterBreakdown,
                medianFWHMArcsec: row.medianFWHMArcsec,
                medianFWHMPixels: row.medianFWHMPixels,
                coolerVerdict: health.cooler.verdict,
                focusVerdict: health.focus.verdict,
                ratedFrameCount: scores.count,
                outlierRatio: outlierRatio
            ))
        }
        // Most-recent-night-first -- the whole point of a MORNING triage
        // page is "what did I shoot last", so last night's session(s)
        // should be the very first cards, not wherever `changedSessions`'
        // target-then-date sort happens to put them.
        return cards.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.target < rhs.target
        }
    }

    /// `PreviousNightPage`'s own load -- called from its `onAppear` and
    /// whenever `freshSessionKeys` changes while the page is visible (a
    /// rescan while already looking at this page). A no-op DB round-trip
    /// skip (not just an empty result) when there's nothing fresh at all,
    /// so opening this page with zero fresh sessions never shows even a
    /// momentary spinner before the empty state renders.
    func loadPreviousNight() {
        guard let db else { return }
        let cfg = config
        let keys = freshSessionKeys
        guard !keys.isEmpty else {
            previousNightCards = []
            return
        }

        let opID = beginOperation("Előző éjszaka betöltése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let cards = try await Task.detached(priority: .userInitiated) {
                    try Self.buildPreviousNightCards(keys: keys, db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.previousNightCards = cards
                self.progressText = "Előző éjszaka betöltve: \(cards.count) session"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// One triage card's "Pontozás" button -- the same `Rater.rate` a
    /// single-target `runRate(target:date:)` call runs, but refreshes only
    /// THIS card's own derived fields in `previousNightCards` afterward
    /// (not the target-detail page's `frameScores`/`qualitySummaries`/
    /// `exposureAdvice` bundle, which this page never shows) -- kept as its
    /// own method rather than reusing `runRate` so the two post-rate
    /// refreshes can never race each other (see `runRate`'s own doc comment
    /// on why chaining two `beginOperation`-based calls back-to-back drops
    /// all but the last one).
    func runRateFreshSession(target: String, date: String) {
        guard let db else { return }
        let cfg = config
        let key = ScanSummary.SessionKey(target: target, date: date)

        let opID = beginOperation("Pontozás indul…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await Task.detached(priority: .userInitiated) { [weak self] in
                    var provider: StarMetricsProvider?
                    if FileManager.default.isExecutableFile(atPath: cfg.rating.sirilPath) {
                        provider = try? SirilCLI(path: cfg.rating.sirilPath)
                    }
                    let rater = Rater(db: db, config: cfg, provider: provider)
                    return try rater.rate(target: target, date: date, force: false) { done, total in
                        Task { @MainActor in
                            self?.progressText = "Pontozás: \(done)/\(total)"
                        }
                    }
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }

                let refreshed = try await Task.detached(priority: .userInitiated) {
                    try Self.buildPreviousNightCards(keys: [key], db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                if let card = refreshed.first, let index = self.previousNightCards.firstIndex(where: { $0.id == card.id }) {
                    self.previousNightCards[index] = card
                }
                self.progressText = "Pontozás kész: \(target) \(date)"
                // R12-U1 item 5: this session's metrics just changed --
                // see `runScan`'s own `trendPoints = nil` comment for why
                // this is a blunt but cheap invalidation rather than trying
                // to patch just this one point in place.
                self.trendPoints = nil
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// "Új sessionök pontozása" -- rates every CURRENTLY fresh session, one
    /// after another, then rebuilds every card from scratch (an outlier
    /// ratio/FWHM this run just changed for one session never leaves
    /// another session's card stale). No confirmation sheet (F5 spec: "csak
    /// az újakra megy", a small, self-limiting set unlike "Minden célpont
    /// pontozása…"'s whole-library scope) -- reuses the same `isBusy`/
    /// `progressText`/"Mégse" toolbar infrastructure every other batch
    /// operation in this file already surfaces through `beginOperation`.
    func runRateFreshSessions() {
        guard let db else { return }
        let cfg = config
        let keys = freshSessionKeys
        guard !keys.isEmpty else { return }

        let opID = beginOperation("Új sessionök pontozása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) { [weak self] in
                    var provider: StarMetricsProvider?
                    if FileManager.default.isExecutableFile(atPath: cfg.rating.sirilPath) {
                        provider = try? SirilCLI(path: cfg.rating.sirilPath)
                    }
                    let rater = Rater(db: db, config: cfg, provider: provider)
                    for (index, key) in keys.enumerated() {
                        _ = try rater.rate(target: key.target, date: key.date, force: false) { done, total in
                            Task { @MainActor in
                                self?.progressText =
                                    "Pontozás: \(key.target) \(key.date) (\(index + 1)/\(keys.count)) — \(done)/\(total)"
                            }
                        }
                    }
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }

                let cards = try await Task.detached(priority: .userInitiated) {
                    try Self.buildPreviousNightCards(keys: keys, db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.previousNightCards = cards
                self.progressText = "Pontozás kész: \(keys.count) session"
                // R12-U1 item 5: same invalidation `runScan`/
                // `runRateFreshSession` apply -- these sessions' metrics
                // just changed.
                self.trendPoints = nil
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// `PreviousNightReviewSheet`'s "Átnézés…" load -- see `reviewFrameScores`'
    /// own doc comment for why this is a dedicated property/method rather
    /// than reusing `loadFrameScores`/`frameScores`.
    ///
    /// R12-U1 item 3: guards every write-back with `reviewFramesRequest ==
    /// key`, not just `Task.isCancelled` -- see that property's own doc
    /// comment for the exact race this closes (the OLD sheet's load
    /// finishing in the brief window before the NEW sheet's `.onAppear` has
    /// actually cancelled it). Also writes into the dedicated
    /// `reviewFrameVerdicts` now, never the shared `frameVerdicts` -- see
    /// THAT property's own doc comment for why a straight `self.frameVerdicts
    /// = verdicts` here used to silently discard every other target's
    /// cached verdict.
    func loadReviewFrames(target: String, date: String) {
        guard let db else { return }
        let cfg = config
        let key = ScanSummary.SessionKey(target: target, date: date)
        reviewFramesRequest = key

        let opID = beginOperation("Keretek betöltése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await Task.detached(priority: .userInitiated) {
                    try Rater.cachedScores(target: target, date: date, db: db, config: cfg)
                }.value
                guard !Task.isCancelled, self.reviewFramesRequest == key else { self.endOperation(opID); return }
                self.reviewFrameScores = results

                // R10-B1: manual verdicts alongside the scores, same as
                // `loadFrameScores`/`runRate` -- `FrameReviewSheet`'s A/X/U
                // keys read/write `reviewFrameVerdicts` (R12-U1 item 3)
                // regardless of which array loaded the frames it's blinking
                // through.
                let verdicts = try await Task.detached(priority: .userInitiated) {
                    try Self.loadVerdicts(forScores: results, db: db)
                }.value
                guard !Task.isCancelled, self.reviewFramesRequest == key else { self.endOperation(opID); return }
                self.reviewFrameVerdicts = verdicts
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// `PreviousNightReviewSheet`'s own `onDisappear` -- cancels
    /// `loadReviewFrames` if it's still in flight (belt-and-suspenders
    /// alongside the `reviewFramesRequest` key-check above: this sheet is
    /// always presented modally, one session at a time, via `.sheet(item:)`,
    /// so nothing else should be racing `currentTask` while it's open) and
    /// clears both `reviewFrameScores`/`reviewFrameVerdicts` so the NEXT
    /// "Átnézés…" open never flashes a previous session's frames before its
    /// own load lands.
    func cancelReviewFrames() {
        reviewFramesRequest = nil
        currentTask?.cancel()
        reviewFrameScores = nil
        reviewFrameVerdicts = [:]
    }

    // MARK: - Discovery (R10-B4)

    /// Loads the "Felfedezés" page's catalog sweep for tonight. Resolves
    /// the site itself (`Planner.resolveSite`, cached into `resolvedSite`
    /// the same way `loadPlan()`/`loadDashboardData()` already do) rather
    /// than trusting whatever `resolvedSite` already holds -- a user who
    /// navigates straight to "Felfedezés" without ever visiting "Ma este"
    /// this session would otherwise see the stale, unresolved default
    /// `SiteRule()`. `existingDesignations` is computed off whatever
    /// `stats` already holds (empty when `stats` itself is still empty --
    /// this does NOT itself trigger `loadStats()`/`loadDashboardData()`,
    /// same "loader is only responsible for its own dataset" stance every
    /// other loader here takes). `date` is always "now" -- unlike
    /// `loadPlan(date:)`, this page has no "Terv erre az éjszakára"
    /// calendar hand-off to revisit a different night for.
    ///
    /// Never triggered by `loadDashboardData()` -- lazily loaded from
    /// `DiscoveryPage.onAppear` only, same stance `loadNights()` takes for
    /// its own on-demand dataset.
    func loadDiscovery() {
        guard let db else { return }
        let cfg = config
        let currentStats = stats
        // R11-T15/F16: read on the main actor before the background hop --
        // same "capture, don't touch `self` inside `Task.detached`" shape
        // `cfg`/`currentStats` above already follow.
        let siteName = effectiveSiteName

        let opID = beginOperation("Felfedezés számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (rows, fov, site) = try await Task.detached(priority: .userInitiated) {
                    let site = try Planner.resolveSite(db: db, config: cfg, siteName: siteName)
                    let existing = DiscoveryPlanner.existingDesignations(stats: currentStats)
                    let fov = try FieldGeometry.dominantFOV(db: db, config: cfg)
                    let rows = DiscoveryPlanner.discover(
                        date: Date(), site: site, minAltitudeDeg: plannerDefaultMinAltitudeDeg,
                        existingDesignations: existing,
                        setupFOVDeg: fov.map { (width: $0.widthDeg, height: $0.heightDeg) }
                    )
                    return (rows, fov, site)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.discovery = rows
                self.discoveryFOV = fov.map { DiscoveryFOV(widthDeg: $0.widthDeg, heightDeg: $0.heightDeg) }
                self.resolvedSite = site
                self.progressText = "Felfedezés kész: \(rows.count) katalógustétel"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// R11-T17 (F4 "Felismerés a képeim fejlécéből"): `DiscoveryPage`'s
    /// no-site empty state offers this as an alternative to opening
    /// Settings -- tries `Planner.detectSiteFromFITSHeaders` (the RAW
    /// FITS-median, regardless of whatever `config.site`/`config.sites`
    /// currently hold -- see that function's own doc comment for why this
    /// can find a coordinate even in a state `resolvedSite` itself came up
    /// empty for, e.g. a "Kézi helyszínek" mode with an incomplete manual
    /// entry) and, if it finds one, runs the exact same discovery
    /// computation `loadDiscovery()` itself would -- deliberately inlined
    /// here (rather than detecting the site and then calling
    /// `loadDiscovery()` as a second step) so this stays the ONE
    /// `beginOperation`/`Task` for the whole action: chaining a second
    /// `beginOperation`-based call after this one completes would silently
    /// drop THIS operation's own toast/activity-log entry (see
    /// `runRateFreshSession`'s own doc comment for the same trap).
    ///
    /// Throws an honest `AstroError.invalidInput`, routed through the
    /// ordinary `lastError`/toast/activity-log channel by `endOperation`,
    /// when NOTHING is extractable -- the empty state's whole point is that
    /// this button must never silently do nothing. Never writes
    /// `resolvedSite` to disk, same "cache in-memory only" contract every
    /// other assignment to it already follows elsewhere in this file --
    /// Settings ▸ Helyszín remains the only path that persists a site.
    func recognizeSiteFromImageHeaders() {
        guard let db else { return }
        let cfg = config
        let currentStats = stats

        let opID = beginOperation("Helyszín felismerése a képek fejléceiből…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (rows, fov, site) = try await Task.detached(priority: .userInitiated) {
                    guard let site = try Planner.detectSiteFromFITSHeaders(db: db) else {
                        throw AstroError.invalidInput(
                            "egyetlen kép fejlécében sem található SITELAT/SITELONG -- állítsd be kézzel a helyszínt a Beállítások ▸ Helyszín lapon"
                        )
                    }
                    let existing = DiscoveryPlanner.existingDesignations(stats: currentStats)
                    let fov = try FieldGeometry.dominantFOV(db: db, config: cfg)
                    let rows = DiscoveryPlanner.discover(
                        date: Date(), site: site, minAltitudeDeg: plannerDefaultMinAltitudeDeg,
                        existingDesignations: existing,
                        setupFOVDeg: fov.map { (width: $0.widthDeg, height: $0.heightDeg) }
                    )
                    return (rows, fov, site)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.discovery = rows
                self.discoveryFOV = fov.map { DiscoveryFOV(widthDeg: $0.widthDeg, heightDeg: $0.heightDeg) }
                self.resolvedSite = site
                let latText = String(format: "%.4f", site.latitudeDeg ?? 0)
                let lonText = String(format: "%.4f", site.longitudeDeg ?? 0)
                self.progressText = "Helyszín felismerve: \(latText)°, \(lonText)° — Felfedezés kész: \(rows.count) katalógustétel"
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
        let siteName = effectiveSiteName

        let opID = beginOperation("Terv számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (result, resolvedSite, night) = try await Task.detached(priority: .userInitiated) {
                    let plans = try Planner.plan(date: date, siteName: siteName, db: db, config: cfg)
                    let site = try Planner.resolveSite(db: db, config: cfg, siteName: siteName)
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
    /// R7-B5) for `TonightPage`'s "Következő 30 éjszaka" segment (R9-T4:
    /// the old standalone "Hónap" sheet is gone). Never triggered
    /// automatically, same "time-of-day-sensitive" reasoning as `loadPlan()`.
    func loadMonthPlan() {
        guard let db else { return }
        let cfg = config
        let siteName = effectiveSiteName

        let opID = beginOperation("Havi terv számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Planner.month(siteName: siteName, db: db, config: cfg)
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

    /// R10-B6: fetches the opt-in Open-Meteo cloud-cover forecast for
    /// `resolvedSite`'s coordinate. The "never network unless opted in"
    /// guard is deliberately the first two lines -- nothing above them, so
    /// it can't be bypassed by an early return added later without also
    /// touching this exact spot: a no-op, instantly, with no
    /// `beginOperation` at all (so it never even flips `isBusy`) whenever
    /// `config.weather.enabled == false` or `resolvedSite` has no
    /// coordinate.
    ///
    /// Otherwise a completely ordinary `beginOperation`/`endOperation`
    /// background op like every other loader in this class -- a failure
    /// toasts the same way any other operation's does (`lastError` is set
    /// directly rather than via `handle(_:)`, since `WeatherError` isn't an
    /// `AstroError`). `weatherError` is set ADDITIONALLY, purely so the
    /// "Felhőzet" tile has something to show even after the toast that
    /// reported the SAME failure has already faded.
    ///
    /// Called fire-and-forget from `loadDashboardData`'s completion (never
    /// awaited -- a slow or failed weather fetch must never delay or fail
    /// the planner) and from `LocationSettingsView`'s save path.
    func loadWeather() {
        guard config.weather.enabled else { return }
        guard let lat = resolvedSite.latitudeDeg, let lon = resolvedSite.longitudeDeg else { return }

        let opID = beginOperation("Felhőzet-előrejelzés lekérése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (forecast, summaries) = try await WeatherService.shared.fetch(latitude: lat, longitude: lon)
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.nightForecast = forecast
                self.weatherDailySummaries = summaries
                self.weatherError = nil
                self.progressText = "Felhőzet-előrejelzés kész."
            } catch {
                // R10 review (item 23): deliberately does NOT set
                // `lastError` -- this fetch runs silently in the background
                // on every dashboard load, and `lastError` drives 8 other
                // pages' own inline error banners (plus, via
                // `endOperation`'s `outcome`, the activity log's ok/error
                // split); a flaky weather API shouldn't make an unrelated
                // page suddenly show an error banner. `weatherError` (the
                // "Felhőzet" tile's own caption) still gets set, and the
                // failure still toasts -- pushed explicitly here since
                // `endOperation`'s own error toast is driven by `lastError`,
                // which stays `nil` on this path, matching the "silent,
                // non-blocking" intent this function's own doc comment
                // already describes.
                let message = (error as? WeatherError)?.message ?? "\(error)"
                self.weatherError = message
                self.pushToast(.error, "\(Self.toastLabel(for: "Felhőzet-előrejelzés lekérése…")) — \(message)")
            }
            self.endOperation(opID)
        }
    }

    /// Bundles every query `loadSiteScopedData` needs so it can all load
    /// inside ONE `Task`/`beginOperation` -- same shape/reasoning as
    /// `DashboardBundle`.
    private struct SiteScopedBundle {
        var plan: [TargetPlan]
        var site: SiteRule
        var night: NightInfo
        /// `nil` when the caller didn't ask for it (`monthPlan` wasn't
        /// loaded this session yet) -- distinct from "computed, zero
        /// nights", which `Planner.month` itself can legitimately return.
        var month: [NightSummary]?
        /// `discovery`/`discoveryFOV` are only ever MEANINGFUL together --
        /// both stay at their default (`[]`/`nil`) when `discovery` wasn't
        /// loaded this session yet; the caller gates on its own captured
        /// `wantsDiscovery` flag rather than trying to tell "not requested"
        /// apart from "requested, nothing found" from these two alone.
        var discovery: [DiscoveryRow] = []
        var discoveryFOV: (widthDeg: Double, heightDeg: Double)?
    }

    /// R12-U1 item 1: `loadDashboardData`'s sibling for whatever depends on
    /// the EFFECTIVE SITE rather than the whole library -- `plan`/
    /// `resolvedSite`/`nightInfo` always, PLUS `monthPlan`/`discovery` (each
    /// only if already loaded this session, same "refresh what's already on
    /// screen, don't eagerly load what wasn't" stance those two datasets'
    /// own loaders already take), all computed in ONE background operation
    /// against the SAME resolved site -- `loadWeather()` fires only AFTER
    /// that site has actually landed (same "fire-and-forget, after this
    /// op's own `endOperation`" shape `loadDashboardData` already uses).
    ///
    /// Fixes the site-switch bug this ticket exists for: `TonightPage`'s
    /// site-Picker setter and `LocationSettingsView.save()` used to call
    /// `loadPlan()`/`loadMonthPlan()`/`loadDiscovery()`/`loadWeather()`
    /// back-to-back with no `await` between them -- each one's own
    /// `beginOperation` cancels whatever `currentTask` the PREVIOUS call in
    /// that same chain just started (see `currentTask`'s own doc comment),
    /// so only the LAST call's dataset ever actually landed. In practice
    /// that meant `plan`/`resolvedSite`/`nightInfo` silently stayed on the
    /// OLD site whenever `monthPlan` or `discovery` had ever been loaded
    /// this session (their own trailing calls kept winning the race), and
    /// `loadWeather()` -- called synchronously right after `loadPlan()`,
    /// before its result could possibly have landed yet -- fetched the OLD
    /// site's coordinate even when it DIDN'T lose that race. Called by
    /// `TonightPage`'s site-Picker setter and `LocationSettingsView.save()`
    /// -- the only two places a user actually changes which site is in
    /// effect.
    func loadSiteScopedData(date: Date? = nil) {
        guard let db else { return }
        let cfg = config
        let siteName = effectiveSiteName
        let currentStats = stats
        let wantsMonth = monthPlan != nil
        let wantsDiscovery = discovery != nil

        let opID = beginOperation("Helyszín-adatok frissítése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let bundle = try await Task.detached(priority: .userInitiated) {
                    let site = try Planner.resolveSite(db: db, config: cfg, siteName: siteName)
                    let plans = try Planner.plan(date: date, siteName: siteName, db: db, config: cfg)
                    let night = Planner.nightInfo(date: date, site: site)

                    let month: [NightSummary]?
                    if wantsMonth {
                        month = try Planner.month(siteName: siteName, db: db, config: cfg)
                    } else {
                        month = nil
                    }

                    var bundle = SiteScopedBundle(plan: plans, site: site, night: night, month: month)
                    if wantsDiscovery {
                        let existing = DiscoveryPlanner.existingDesignations(stats: currentStats)
                        let fov = try FieldGeometry.dominantFOV(db: db, config: cfg)
                        bundle.discovery = DiscoveryPlanner.discover(
                            date: Date(), site: site, minAltitudeDeg: plannerDefaultMinAltitudeDeg,
                            existingDesignations: existing,
                            setupFOVDeg: fov.map { (width: $0.widthDeg, height: $0.heightDeg) }
                        )
                        bundle.discoveryFOV = fov
                    }
                    return bundle
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.plan = bundle.plan
                self.resolvedSite = bundle.site
                self.nightInfo = bundle.night
                self.planDate = date
                if let month = bundle.month {
                    self.monthPlan = month
                }
                if wantsDiscovery {
                    self.discovery = bundle.discovery
                    self.discoveryFOV = bundle.discoveryFOV.map { DiscoveryFOV(widthDeg: $0.widthDeg, heightDeg: $0.heightDeg) }
                }
                self.progressText = "Terv kész: \(bundle.plan.count) célpont"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
            // R10-B6 pattern (see `loadDashboardData`'s own comment on its
            // identical trailing call): fire-and-forget, deliberately AFTER
            // this operation's OWN `endOperation(opID)` above, and only now
            // that `resolvedSite` actually holds the NEW site's coordinate.
            self.loadWeather()
        }
    }

    // MARK: - Plan export (R11-T6/F18a)

    /// Copies `plans` to the general pasteboard as tab-separated text
    /// (`PlanExport.renderClipboardText`) -- "Terv exportálása… ▸ Vágólapra".
    /// Synchronous (pasteboard-only, no `Database`/filesystem access), so
    /// unlike `exportStackList`/`exportTargetReport` this skips
    /// `beginOperation` entirely and just toasts directly.
    func copyPlanToClipboard(_ plans: [TargetPlan]) {
        let text = PlanExport.renderClipboardText(plans)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pushToast(.success, "Terv vágólapra másolva (\(plans.count) célpont)")
    }

    /// Prompts an `NSSavePanel` and writes `plans` as CSV (`PlanExport.
    /// renderCSV`) to the chosen path -- "Terv exportálása… ▸ CSV-fájlba…".
    /// Writes to an arbitrary user-chosen destination via plain
    /// `FileManager` (same "outside the library, no `WriteGuard` needed"
    /// reasoning `cmdExport --out PATH` already documents for the CLI's own
    /// `--out`) -- cancel leaves no trace and shows nothing.
    func exportPlanToCSV(_ plans: [TargetPlan]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "terv.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let csv = PlanExport.renderCSV(plans)
            try Data(csv.utf8).write(to: url)
            pushToast(.success, "Terv exportálva: \(url.lastPathComponent)")
        } catch {
            pushToast(.error, "Terv exportálása — \(error.localizedDescription)")
        }
    }

    /// Copies tonight's calibration shopping list (`CalibShoppingList.
    /// markdown`) to the general pasteboard -- `TonightPage`'s "Kalibrációs
    /// teendők ma estére" section's "Másolás Markdownként" button
    /// (R11-T6/F18b). Same synchronous, direct-toast shape as
    /// `copyPlanToClipboard` above.
    func copyCalibShoppingListToClipboard(_ items: [CalibShoppingList.Item]) {
        let text = CalibShoppingList.markdown(items)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pushToast(.success, "Kalibrációs teendők vágólapra másolva (\(items.count) tétel)")
    }

    // MARK: - Project pipeline status

    /// Bundles every query `loadDashboardData()` needs so they can all
    /// load inside ONE `Task`/`beginOperation` -- same shape as
    /// `TargetDetailBundle` below.
    private struct DashboardBundle {
        var stats: [TargetStats]
        var sessionsByTarget: [String: [SessionDetail]]
        var panelsByTarget: [String: PanelReport]
        var stacksByTarget: [String: TargetStacks]
        var stackGroupsByTarget: [String: [StackGroup]]
        var plan: [TargetPlan]
        var site: SiteRule
        var night: NightInfo
        var projects: [ProjectState]
        var cleanup: CleanupSummary
        /// R11-T8/F19: fetched alongside `cleanup` (same trigger, same
        /// segment) so a fresh launch's Audit page shows the "Tárhely"
        /// block without a separate on-demand load.
        var storage: StorageSummary
        var quarantine: QuarantineLoad
        // N7 (R9 round 3): the sidebar's Kalibráció/Szenzor-profilok badges
        // read `calibNeeds`/`sensorProfiles` directly -- without these in
        // the SAME bundle, a fresh launch showed both badges stuck at 0
        // until the user separately visited the Kalibráció page (the only
        // other place anything populated them).
        var calib: CalibBundle
    }

    /// The three Kalibráció-oldal queries (`CalibAnalyzer.coverage`,
    /// `CalibHealth.report`, `db.allSensorProfiles()`) bundled together --
    /// shared by `loadDashboardData` (N7: sidebar badges need them on every
    /// launch, not just when the Kalibráció page has been visited) AND
    /// `loadCalibrationData` (N2: `CalibrationPage`'s own onAppear/
    /// "Újraszámolás", so the two never duplicate the query trio).
    private struct CalibBundle {
        var needs: [CalibNeed]
        var health: CalibHealthReport
        var sensorProfiles: [SensorProfileRecord]
    }

    /// Plain (non-actor-isolated) function so it can run inside a
    /// `Task.detached` closure -- same "no `self` capture needed" shape as
    /// `resolveCoordinateInfo`.
    private static nonisolated func loadCalibBundle(db: Database, config: AstroConfig) throws -> CalibBundle {
        // R11-T16/F17: darks + flats concatenated into ONE list for display
        // (coverage table, Teendők action cards, sidebar badge, the Tonight
        // shopping list) -- `CalibAnalyzer.coverage`/`flatCoverage` stay
        // separate functions (see `CalibAnalyzer`'s own top-level doc
        // comment for why), this is the one place their results merge for
        // the app layer.
        let needs = try CalibAnalyzer.coverage(db: db, config: config) + CalibAnalyzer.flatCoverage(db: db, config: config)
        return CalibBundle(
            needs: needs,
            health: try CalibHealth.report(db: db, config: config),
            sensorProfiles: try db.allSensorProfiles()
        )
    }

    /// Loads `stats` (+ session/panel/stack details), `plan`/`resolvedSite`/
    /// `nightInfo`, `projectStates`, AND `cleanupSummary` -- everything the
    /// sidebar's badges/phase dots, "Ma este"'s Állapot/Hiányzik columns, and
    /// "Minden célpont"'s tiles need -- all in ONE background operation
    /// (R9-D3). Firing the equivalent standalone `loadStats()`/`loadPlan()`/
    /// a since-removed `loadProjects()` back-to-back from an `onAppear`
    /// would race: `beginOperation` cancels whatever `currentTask` is
    /// already running, so each new call cancels the previous one's outer
    /// `Task` before its own `guard !Task.isCancelled` line ever runs --
    /// only the LAST call's result would actually land (see `currentTask`'s
    /// doc comment). Bundling avoids that entirely; reused from
    /// `TonightPage.onAppear`, `AllTargetsPage.onAppear`, AND `openRoot` (so
    /// a fresh launch with an already-scanned root shows a fully populated
    /// dashboard without re-running scan/audit).
    func loadDashboardData(date: Date? = nil) {
        guard let db else { return }
        let cfg = config
        let siteName = effectiveSiteName

        let opID = beginOperation("Áttekintés adatok betöltése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let bundle = try await Task.detached(priority: .userInitiated) {
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
                        if let report = stacksByTarget[stat.target], !report.stacks.isEmpty {
                            stackGroupsByTarget[stat.target] = try StackDiscovery.groupedStacks(
                                target: stat.target, db: db, config: cfg
                            )
                        }
                    }
                    let plans = try Planner.plan(date: date, siteName: siteName, db: db, config: cfg)
                    let site = try Planner.resolveSite(db: db, config: cfg, siteName: siteName)
                    let night = Planner.nightInfo(date: date, site: site)
                    let projects = try ProjectStatusQueries.projects(db: db, config: cfg)
                    let cleanup = try CleanupReport.build(db: db, config: cfg)
                    let storage = try StorageQueries.perTarget(db: db, config: cfg)
                    let quarantine = Self.inspectQuarantine(config: cfg)
                    let calib = try Self.loadCalibBundle(db: db, config: cfg)
                    return DashboardBundle(
                        stats: stats, sessionsByTarget: sessionsByTarget, panelsByTarget: panelsByTarget,
                        stacksByTarget: stacksByTarget, stackGroupsByTarget: stackGroupsByTarget,
                        plan: plans, site: site, night: night, projects: projects, cleanup: cleanup,
                        storage: storage, quarantine: quarantine, calib: calib
                    )
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.stats = bundle.stats
                self.sessionDetailsByTarget = bundle.sessionsByTarget
                self.panelReportsByTarget = bundle.panelsByTarget
                self.stackReportsByTarget = bundle.stacksByTarget
                self.stackGroupsByTarget = bundle.stackGroupsByTarget
                self.plan = bundle.plan
                self.resolvedSite = bundle.site
                self.nightInfo = bundle.night
                self.planDate = date
                self.projectStates = bundle.projects
                self.cleanupSummary = bundle.cleanup
                self.storageSummary = bundle.storage
                self.quarantineState = bundle.quarantine.state
                self.quarantineInspectionError = bundle.quarantine.error
                // N7 (R9 round 3): see `DashboardBundle.calib`'s doc comment
                // -- this is what makes the sidebar's Kalibráció/Szenzor-
                // profilok badges non-zero on a fresh launch.
                self.calibNeeds = bundle.calib.needs
                self.calibHealth = bundle.calib.health
                self.sensorProfiles = bundle.calib.sensorProfiles
                self.progressText = "Áttekintés kész: \(bundle.stats.count) célpont"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
            // R10-B6: fire-and-forget, deliberately AFTER this operation's
            // OWN `endOperation(opID)` above -- `loadWeather()` calls
            // `beginOperation` too, which reassigns `currentOperationID`,
            // so calling it any earlier would make THIS operation's own
            // `endOperation` (still pending at that point) a silent no-op
            // (see `endOperation`'s `guard currentOperationID == id`).
            // Weather is opt-in and must never delay or fail the planner --
            // this doesn't `await` anything, it only kicks off `loadWeather`'s
            // own independent background `Task` and returns immediately.
            self.loadWeather()
        }
    }

    /// Loads `calibNeeds`/`calibHealth`/`sensorProfiles` together in ONE
    /// background operation -- `CalibrationPage`'s `onAppear` and
    /// "Újraszámolás" both used to fire `loadCalib()`/`loadCalibHealth()`
    /// back-to-back, which raced the same way `loadDashboardData`'s doc
    /// comment describes: the second call's `beginOperation` cancelled the
    /// first's outer `Task`, so `calibNeeds` (the coverage table AND the
    /// Teendők action cards) never actually landed. Shares
    /// `loadCalibBundle` with `loadDashboardData` (N7) rather than
    /// duplicating the three-query trio.
    func loadCalibrationData() {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Kalibráció adatok betöltése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let calib = try await Task.detached(priority: .userInitiated) {
                    try Self.loadCalibBundle(db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.calibNeeds = calib.needs
                self.calibHealth = calib.health
                self.sensorProfiles = calib.sensorProfiles
                self.progressText = "Kalibráció kész: \(calib.needs.count) kombináció"
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

    /// Writes/replaces a target's overall `goal:Xh` tag (R9-T3/B11's inline
    /// hour-stepper popover): removes every existing OVERALL `goal:*` tag
    /// first (there should only ever be at most one, but this is defensive
    /// against a manually-edited DB with more), then adds the new one --
    /// unless `hours` is `nil`/`0`, which just clears the goal entirely
    /// ("Nincs cél"). Refreshes `stats` (+ this target's
    /// `sessionDetailsByTarget` entry, via the same helper a plain tag edit
    /// uses), `projectStates` (so `missingSeconds`/phase reflect the new
    /// goal), and `plan` (if already loaded -- so "Ma este"'s Cél/Hiányzik
    /// columns don't need a separate manual refresh) -- the three places
    /// acceptance ⓓ checks.
    ///
    /// R11-T5/F2: `GoalTag.isOverallGoalTag` (not a bare
    /// `hasPrefix("goal:")`) is what keeps this from also deleting any
    /// per-filter `goal:<filter>=<hours>h` tag the target might have --
    /// those two conventions coexist independently (see `setFilterGoals`
    /// below, which is the mirror-image fix for the per-filter side).
    func setGoal(target: String, hours: Double?) {
        guard let db else { return }
        let cfg = config
        let existingGoalTags = (stats.first { $0.target == target }?.tags ?? []).filter {
            GoalTag.isOverallGoalTag($0)
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
                let siteName = self.effectiveSiteName
                if self.plan != nil, let planResult = try? await Task.detached(priority: .userInitiated, operation: {
                    try Planner.plan(date: planDate, siteName: siteName, db: db, config: cfg)
                }).value {
                    self.plan = planResult
                }
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Saves the overall goal and the complete desired per-filter goal set
    /// as one user operation. All tag mutations run serially in one detached
    /// task, followed by one stats/project/plan refresh, so the sheet cannot
    /// cancel half of its own save by starting a second operation.
    func saveGoals(
        target: String,
        overallHours: Double?,
        filterRows: [FilterGoalEditRow]
    ) {
        guard let db else { return }
        let cfg = config
        let desiredRows = filterRows.map { row in
            FilterGoalEditRow(
                filter: GoalTag.normalizedFilterGoalName(row.filter),
                usableSeconds: row.usableSeconds,
                goalHours: row.goalHours
            )
        }
        let desiredOverallTag = overallHours.flatMap { hours in
            hours > 0 ? GoalTag.format(hours: hours) : nil
        }
        let desiredFilterTags = desiredRows.compactMap { row -> String? in
            guard row.goalHours > 0, !row.filter.isEmpty else { return nil }
            return GoalTag.formatFilter(filter: row.filter, hours: row.goalHours)
        }
        let desiredGoalTags = (desiredOverallTag.map { [$0] } ?? []) + desiredFilterTags

        let opID = beginOperation("Célok mentése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try db.replaceTargetGoalTagsAtomically(target: target, with: desiredGoalTags)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                await self.reloadStatsAfterTagChange(db: db, config: cfg, target: target)
                if let projectsResult = try? await Task.detached(priority: .userInitiated, operation: {
                    try ProjectStatusQueries.projects(db: db, config: cfg)
                }).value {
                    self.projectStates = projectsResult
                    if case .target(let visibleTarget) = self.currentPage,
                       visibleTarget == target,
                       let refreshedProject = projectsResult.first(where: { $0.target == target }) {
                        self.targetPublishingReadiness = PublishingReadiness.evaluate(
                            project: refreshedProject,
                            unmappedFilters: self.targetUnmappedAstroBinFilters,
                            hasProcessedOutput: refreshedProject.latestProcessedDate != nil
                        )
                    }
                }
                let planDate = self.planDate
                let siteName = self.effectiveSiteName
                if self.plan != nil, let planResult = try? await Task.detached(priority: .userInitiated, operation: {
                    try Planner.plan(date: planDate, siteName: siteName, db: db, config: cfg)
                }).value {
                    self.plan = planResult
                }
                self.filterGoalEditorRows = desiredRows
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

    // MARK: - Per-filter goals (R11-T5/F2)

    /// One row of `GoalEditSheet`'s "Szűrőnként" DisclosureGroup -- a filter
    /// this target has actually shot at least once (from
    /// `FilterBreakdownQueries.breakdown`), or one it only has a goal tag
    /// for so far (0 usable) -- paired with its current goal, in hours
    /// (`0` = no goal = the tag gets removed on save, same "0 clears it"
    /// convention the overall goal stepper already uses).
    struct FilterGoalEditRow: Identifiable, Equatable {
        let filter: String
        let usableSeconds: Double
        var goalHours: Double
        var id: String { filter }
    }

    /// `nil` until `loadFilterGoalEditor(target:)` has run for the sheet
    /// currently open; `GoalEditSheet` hides its "Szűrőnként" section
    /// entirely while this is `nil` or empty (nothing to show for an
    /// OSC/DSLR target with no per-filter data at all).
    var filterGoalEditorRows: [FilterGoalEditRow]?

    /// Loads `target`'s per-filter goal-editor rows (`GoalEditSheet`'s
    /// "Szűrőnként" section, opened on appear same as `CalibLinkSheet`/
    /// `StackListSheet`'s own "load on appear" sheets) -- every filter with
    /// usable frames (`FilterBreakdownQueries.breakdown`, the sentinel
    /// no-filter bucket excluded: a per-filter goal makes no sense for
    /// "no filter recorded") merged with every `goal:<filter>=<hours>h` tag
    /// already on the target (`GoalTag.parseFilterGoals`), so a filter
    /// that's been GOALED but never shot yet still gets its own row (0h
    /// usable, its set goal).
    func loadFilterGoalEditor(target: String) {
        guard let db else { return }
        let cfg = config
        filterGoalEditorRows = nil

        let opID = beginOperation("Szűrőnkénti célok betöltése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let rows = try await Task.detached(priority: .userInitiated) {
                    let breakdown = try FilterBreakdownQueries.breakdown(db: db, config: cfg, target: target)
                    let tags = try db.tags(target: target, sessionDate: nil)
                    let goals = GoalTag.parseFilterGoals(tags: tags)
                    var goalHoursByLowercasedFilter: [String: Double] = [:]
                    for goal in goals { goalHoursByLowercasedFilter[goal.filter.lowercased()] = goal.seconds / 3600.0 }

                    var seenLowercasedFilters = Set<String>()
                    var rows: [FilterGoalEditRow] = []
                    for entry in breakdown where entry.filter != FilterBreakdownQueries.noFilterSentinel {
                        let key = entry.filter.lowercased()
                        seenLowercasedFilters.insert(key)
                        rows.append(FilterGoalEditRow(
                            filter: entry.filter,
                            usableSeconds: entry.integrationSeconds,
                            goalHours: goalHoursByLowercasedFilter[key] ?? 0
                        ))
                    }
                    for goal in goals where !seenLowercasedFilters.contains(goal.filter.lowercased()) {
                        rows.append(FilterGoalEditRow(filter: goal.filter, usableSeconds: 0, goalHours: goal.seconds / 3600.0))
                    }
                    return rows
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.filterGoalEditorRows = rows
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Clears `filterGoalEditorRows` -- `GoalEditSheet.onDisappear`, same
    /// "clear on close" pattern `CalibLinkSheet`/`StackListSheet` already
    /// follow for their own loaded state.
    func clearFilterGoalEditor() {
        filterGoalEditorRows = nil
    }

    /// Writes/removes every filter's `goal:<filter>=<hours>h` tag from
    /// `GoalEditSheet`'s "Szűrőnként" save in ONE operation (rather than one
    /// `beginOperation` per filter row): for each row, removes any existing
    /// tag for THAT filter (`GoalTag.isFilterGoalTag`, case-insensitive --
    /// never touches another filter's tag, or the overall `goal:<hours>h`
    /// one), then adds a fresh tag when `goalHours > 0`. Refreshes `stats`
    /// (the "Szűrők" card's/"Hiányzik" tile's own live re-derivation reads
    /// straight off its `tags`) and `plan` (so `TonightPage`'s "Hiányzik"
    /// popover reflects the change immediately) -- same two refreshes
    /// `setGoal` above performs for the overall goal.
    func setFilterGoals(target: String, rows: [FilterGoalEditRow]) {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Szűrőnkénti célok mentése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let existingTags = try db.tags(target: target, sessionDate: nil)
                    for row in rows {
                        for tag in existingTags where GoalTag.isFilterGoalTag(tag, filter: row.filter) {
                            try db.removeTag(TagRecord(kind: "target", target: target, sessionDate: nil, tag: tag))
                        }
                        if row.goalHours > 0 {
                            let tag = GoalTag.formatFilter(filter: row.filter, hours: row.goalHours)
                            try db.addTag(TagRecord(kind: "target", target: target, sessionDate: nil, tag: tag))
                        }
                    }
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                await self.reloadStatsAfterTagChange(db: db, config: cfg, target: target)
                let planDate = self.planDate
                let siteName = self.effectiveSiteName
                if self.plan != nil, let planResult = try? await Task.detached(priority: .userInitiated, operation: {
                    try Planner.plan(date: planDate, siteName: siteName, db: db, config: cfg)
                }).value {
                    self.plan = planResult
                }
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Wide-field classification (R11-T3/F20)

    /// "Besorolás" context menu (`AllTargetsPage` row menu / `TargetDetailPage`
    /// header) manual override of `WideFieldHeuristic`'s automatic wide-field
    /// vs. deep-sky guess -- writes straight into `config.wideField.overrides`
    /// via the same WriteGuard-gated `AstroConfig.save` every
    /// `Views/Settings/*SettingsView.swift` tab's own `save()` already uses
    /// (there's no dedicated "mutate config + save" helper to call instead).
    /// `value == nil` clears the override back to "Automatikus (felismerés)";
    /// `true`/`false` pins it to wide-field/deep-sky regardless of what
    /// `WideFieldHeuristic.isWideField` would otherwise guess.
    ///
    /// Unlike the Settings tabs (which show `saveError` inline right next to
    /// their own "Mentés" button), this fires from a context menu with
    /// nowhere inline to put an error -- so it goes through the same
    /// `beginOperation`/`handle(_:)`/`endOperation` toast+activity-log path
    /// every other menu-triggered mutation (`addTag`/`setGoal`/…) already
    /// uses, then reuses `reloadStatsAfterTagChange` to refresh `stats` --
    /// the "wide-field" badge's one source, read by both `AllTargetsPage`
    /// and `TargetDetailPage` -- for this target immediately. Not added to
    /// `successToastTitles`: same quiet-on-success precedent as
    /// `addTag`/`setGoal`, whose titles aren't in that set either.
    func setWideFieldOverride(target: String, value: Bool?) {
        guard let db else { return }

        var newConfig = config
        var wideField = newConfig.wideField
        if let value {
            wideField.overrides[target] = value
        } else {
            wideField.overrides.removeValue(forKey: target)
        }
        newConfig.wideField = wideField

        let opID = beginOperation("Besorolás mentése…")
        do {
            let writeGuard = WriteGuard(root: URL(fileURLWithPath: newConfig.rootPath, isDirectory: true))
            try newConfig.save(using: writeGuard)
            config = newConfig
        } catch {
            handle(error)
            endOperation(opID)
            return
        }

        let cfg = newConfig
        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.reloadStatsAfterTagChange(db: db, config: cfg, target: target)
            self.endOperation(opID)
        }
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
    /// D12: per-target memo of `resolveCoordinateInfo`'s result, so
    /// re-opening a target already visited this session skips its whole-
    /// library-files-plus-batched-`fitsMeta` query entirely. Keyed by
    /// target name; the dictionary's own optional-on-lookup means "not
    /// computed yet", while the STORED `TargetCoordinateInfo?` is the
    /// legitimate "resolved, but this target has no coordinate" case --
    /// hence the double optional. Invalidated wholesale on `runScan()`
    /// (any target's frames may have changed) and per-target on
    /// `runPlateSolve(target:)`/`runPlateSolveAll()` (a fresh solve can only
    /// ever change what would be resolved for the target(s) just solved).
    private var coordinateInfoCache: [String: TargetCoordinateInfo?] = [:]
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
    /// R11-T5/F1: the target's whole-history per-filter usable-integration
    /// breakdown (`FilterBreakdownQueries.breakdown`, seconds-descending) --
    /// the Áttekintés segment's new "Szűrők" card, the header's "Valós
    /// integráció" tile caption (top 3 filters), and the "Hiányzik" tile's
    /// per-filter-deficit caption (merged with goal tags via
    /// `FilterGoalQueries` right where each of those reads it, rather than
    /// stored pre-merged here -- this array itself never carries goal data).
    var targetFilterBreakdown: [FilterIntegration] = []
    /// R11-T5/F1: one `FilterBreakdownQueries.breakdown(..., date:)` per
    /// session date, keyed by `dateRaw` -- the Áttekintés segment's
    /// "Integráció-halmozódás" chart needs each session's OWN per-filter
    /// contribution to build the per-filter cumulative lines, the same way
    /// `targetNightHealthByDate` above is keyed for the Sessionök table.
    var targetFilterBreakdownByDate: [String: [FilterIntegration]] = [:]
    var targetPublishingReadiness: PublishingReadiness?
    var targetUnmappedAstroBinFilters: [String] = []

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
        var filterBreakdown: [FilterIntegration]
        var filterBreakdownByDate: [String: [FilterIntegration]]
        var publishingReadiness: PublishingReadiness?
        var unmappedAstroBinFilters: [String]
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
        let siteName = effectiveSiteName
        // R11-T17: fire-and-forget, non-blocking -- see the function's own
        // doc comment for why this never touches `isBusy`/`currentTask`.
        loadLibraryFWHMArcsecBaselineIfNeeded()
        targetCoordinateInfo = nil
        targetSetupDescriptors = []
        targetSessionCalibrations = []
        targetNightHealthByDate = [:]
        targetFilterBreakdown = []
        targetFilterBreakdownByDate = [:]
        targetPublishingReadiness = nil
        targetUnmappedAstroBinFilters = []
        qualitySummaries = []
        exposureAdvice = nil
        sessionTimeline = nil
        nightHealth = nil
        // N1 (R9 round 3): without this, switching from target A (whose
        // Minőség segment had frame scores loaded) straight to target B
        // left A's `frameScores` on screen until B's own quality data (if
        // any) happened to load -- a target with no rated frames at all
        // would show A's table forever.
        frameScores = []
        // R10-B1: same staleness class as `frameScores` immediately above --
        // without this, switching targets could leave A's verdicts showing
        // against B's (path-keyed, so a same-named file under a different
        // target would silently show the wrong verdict) until B's own
        // `loadFrameScores`/`runRate` happened to run.
        frameVerdicts = [:]

        // D12: looked up on the main actor BEFORE the background hop, so the
        // detached closure below can stay a plain (non-isolated) function of
        // its captures -- `nil` here means "never computed for this target",
        // vs. a present-but-`nil` INNER value meaning "computed, no
        // coordinate found".
        let cachedCoordInfo = coordinateInfoCache[target]

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
                    let plan = try Planner.plan(siteName: siteName, db: db, config: cfg)
                    let site = try Planner.resolveSite(db: db, config: cfg, siteName: siteName)
                    let calibHealth = try CalibHealth.report(db: db, config: cfg)
                    let coordInfo: TargetCoordinateInfo?
                    if let cachedCoordInfo {
                        coordInfo = cachedCoordInfo
                    } else {
                        coordInfo = try Self.resolveCoordinateInfo(target: target, db: db)
                    }
                    let setupDescriptors = Array(Set(sessions.compactMap(\.setupDescriptor))).sorted()
                    var calibs: [SessionCalibration] = []
                    var nightHealthByDate: [String: NightHealthReport] = [:]
                    // R11-T5/F1: one per-session filter breakdown alongside
                    // the per-session calib/night-health lookups this loop
                    // already builds -- the Áttekintés segment's per-filter
                    // cumulative chart needs each session's OWN contribution.
                    var filterBreakdownByDate: [String: [FilterIntegration]] = [:]
                    for session in sessions {
                        calibs.append(try SessionMatcher.match(target: target, date: session.dateRaw, db: db, config: cfg))
                        nightHealthByDate[session.dateRaw] = try NightHealth.report(target: target, date: session.dateRaw, db: db, config: cfg)
                        filterBreakdownByDate[session.dateRaw] = try FilterBreakdownQueries.breakdown(
                            db: db, config: cfg, target: target, date: session.dateRaw
                        )
                    }
                    let filterBreakdown = try FilterBreakdownQueries.breakdown(db: db, config: cfg, target: target)
                    let unmappedAstroBinFilters = try AcquisitionExport.unmappedAstrobinFilters(
                        target: target, db: db, config: cfg
                    )
                    let publishingReadiness = projects.first(where: { $0.target == target }).map {
                        PublishingReadiness.evaluate(
                            project: $0,
                            unmappedFilters: unmappedAstroBinFilters,
                            hasProcessedOutput: $0.latestProcessedDate != nil
                        )
                    }
                    let qualitySummaries = try SessionQuality.summaries(target: target, db: db, config: cfg)
                    let advice = try ExposureAdvisor.advise(target: target, db: db, config: cfg)
                    return TargetDetailBundle(
                        stats: stats, sessions: sessions, panels: panels, stacksByTarget: stacksByTarget,
                        stackGroups: stackGroups, projects: projects, plan: plan, site: site,
                        calibHealth: calibHealth, coordInfo: coordInfo, setupDescriptors: setupDescriptors,
                        calibs: calibs, nightHealthByDate: nightHealthByDate,
                        qualitySummaries: qualitySummaries, advice: advice,
                        filterBreakdown: filterBreakdown, filterBreakdownByDate: filterBreakdownByDate,
                        publishingReadiness: publishingReadiness,
                        unmappedAstroBinFilters: unmappedAstroBinFilters
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
                if cachedCoordInfo == nil {
                    // N4 (R9 round 3): `coordinateInfoCache` is
                    // `[String: TargetCoordinateInfo?]` -- subscript
                    // assignment with an Optional VALUE (`bundle.coordInfo`
                    // being `nil`, i.e. "resolved, no coordinate found") is
                    // indistinguishable from removing the key entirely, so
                    // the memo never actually cached the "no coordinate"
                    // case: every future open re-ran `resolveCoordinateInfo`
                    // as if this target had never been looked up.
                    // `updateValue(_:forKey:)` sets the key's value (even
                    // when that value is `nil`) instead of deleting it.
                    self.coordinateInfoCache.updateValue(bundle.coordInfo, forKey: target)
                }
                self.targetSetupDescriptors = bundle.setupDescriptors
                self.targetSessionCalibrations = bundle.calibs
                self.targetNightHealthByDate = bundle.nightHealthByDate
                self.targetFilterBreakdown = bundle.filterBreakdown
                self.targetFilterBreakdownByDate = bundle.filterBreakdownByDate
                self.targetPublishingReadiness = bundle.publishingReadiness
                self.targetUnmappedAstroBinFilters = bundle.unmappedAstroBinFilters
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

        // D12: was one `fitsMeta` query per light frame (thousands for a big
        // target, on EVERY page open) -- batched into chunked `IN (...)`
        // queries instead.
        let metaByFileID = try db.fitsMetaBatch(fileIDs: targetLights.compactMap(\.id))

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
    /// appears AND every time its keep-slider (common or per-filter,
    /// R11-T11) settles on a new value. `stackListExportDir` is reset too,
    /// so adjusting the slider after a successful export goes back to
    /// showing the (now stale) selection preview rather than the old export
    /// result. `keepFractionPerFilter` overrides `keepFraction` for the
    /// named filter buckets only -- see `StackList.select`'s own doc; the
    /// sheet passes `[:]` (no overrides) whenever the common slider itself
    /// last moved.
    func loadStackListSelection(
        target: String, date: String, keepFraction: Double, keepFractionPerFilter: [String: Double] = [:]
    ) {
        guard let db else { return }
        let cfg = config
        stackListSelection = nil
        stackListExportDir = nil
        stackListRemovedStaleCount = 0

        let opID = beginOperation("Stack-lista számítása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let selection = try await Task.detached(priority: .userInitiated) {
                    try StackList.select(
                        target: target, date: date, keepFraction: keepFraction,
                        keepFractionPerFilter: keepFractionPerFilter, db: db, config: cfg
                    )
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
    /// `stackListExportDir` is set so the sheet can switch to a "kész" state;
    /// `stackListRemovedStaleCount` (R12-U2, point 2) carries how many
    /// left-over hardlinks this same re-export sync just removed, if any.
    func exportStackList() {
        guard let selection = stackListSelection else { return }
        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        let writeGuard = WriteGuard(root: root)

        let opID = beginOperation("Stack-lista exportálása…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try StackList.export(selection, root: root, using: writeGuard)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.stackListExportDir = result.directory
                self.stackListRemovedStaleCount = result.removedStaleCount
                self.progressText = "Exportálva: \(result.directory.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([result.directory])
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
        stackListRemovedStaleCount = 0
    }

    // MARK: - Night report (R7-B5)

    /// Renders and writes one session's HTML night-report card
    /// (`NightReport.write`) under `.astro_tool/reports/`, then opens it in
    /// the user's default browser -- `AllTargetsPage`'s and
    /// `SessionsSegment`'s per-session row context menu's "Éjszaka-riport
    /// készítése" item.
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
    /// opens it in the user's default browser -- `AllTargetsPage`'s and
    /// `TargetDetailPage`'s "Célpont-riport készítése" context-menu item,
    /// same open-in-browser convention as `exportNightReport`.
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

    // MARK: - Sensor profiles (R7-B1 item C)

    /// Loads whatever's already persisted in `sensor_profile` -- read-only,
    /// never runs a measurement itself. Shown as the "Szenzor-profilok" list
    /// on its own Szenzor-profilok oldal (`SensorPage`, `Page.sensor`).
    /// R11-T10/F8: also loads each profile's full `sensor_profile_history`
    /// (one query per combo -- the same "N+1 is fine at this scale" stance
    /// `SensorProfiler.measure` itself already takes per-file) into
    /// `sensorProfileHistoryByCombo`, for the page's per-row expandable
    /// history/sparkline.
    func loadSensorProfiles() {
        guard let db else { return }

        let opID = beginOperation("Szenzor-profilok betöltése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (profiles, historyByCombo) = try await Task.detached(priority: .userInitiated) {
                    let profiles = try db.allSensorProfiles()
                    var historyByCombo: [String: [SensorProfileHistoryRecord]] = [:]
                    for profile in profiles {
                        historyByCombo[profile.comboKey] = try db.sensorProfileHistory(
                            camera: profile.camera, gain: profile.gain, offset: profile.offset
                        )
                    }
                    return (profiles, historyByCombo)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.sensorProfiles = profiles
                self.sensorProfileHistoryByCombo = historyByCombo
                self.progressText = "Szenzor-profilok betöltve: \(profiles.count) kombináció"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Runs `SensorProfiler.measure` in the background (the "Mérés" button):
    /// re-derives every `(camera, gain, offset)` combo's bias level/read
    /// noise/dark rate/EGAIN from tracked BIAS/DARK frames, appending a new
    /// `sensor_profile_history` row per combo as it goes (R11-T10/F8), then
    /// refreshes `sensorProfiles`/`sensorProfileHistoryByCombo` with the
    /// fresh set.
    func measureSensorProfiles() {
        guard let db else { return }
        let cfg = config
        let root = URL(fileURLWithPath: cfg.rootPath, isDirectory: true)

        let opID = beginOperation("Szenzor-mérés indul…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (result, historyByCombo) = try await Task.detached(priority: .userInitiated) { [weak self] in
                    let result = try SensorProfiler.measure(db: db, config: cfg, root: root) { message in
                        Task { @MainActor in
                            self?.progressText = message
                        }
                    }
                    var historyByCombo: [String: [SensorProfileHistoryRecord]] = [:]
                    for profile in result {
                        historyByCombo[profile.comboKey] = try db.sensorProfileHistory(
                            camera: profile.camera, gain: profile.gain, offset: profile.offset
                        )
                    }
                    return (result, historyByCombo)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.sensorProfiles = result
                self.sensorProfileHistoryByCombo = historyByCombo
                self.progressText = "Szenzor-mérés kész: \(result.count) kombináció"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - Trends (R11-T10/F7)

    /// Loads every session's trend-relevant metrics across every target
    /// (`TrendQueries.points`, UNFILTERED -- see `trendPoints`'s own doc
    /// comment for why), backing the "Trendek" page.
    func loadTrends() {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Trendek betöltése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try TrendQueries.points(db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.trendPoints = result
                self.progressText = "Trendek betöltve: \(result.count) session"
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    // MARK: - DSS ingest (R7-B2)

    /// Runs `DSSIngest.ingest` in the background (the toolbar's
    /// "Műveletek" ▸ "DSS-döntések importálása" menu item): harvests every
    /// tracked `<frame>.info.txt`'s star metrics and every tracked
    /// `.dssfilelist`'s accept/reject decisions already sitting in the
    /// library. Refreshes `stats`/`sessionDetailsByTarget` afterward (via
    /// `loadStatsBundle`) so a newly recorded DSS verdict count shows up on
    /// `AllTargetsPage` without a separate manual reload.
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
                // R10-A5: was `self.loadStats()` -- that calls its OWN
                // `beginOperation`, which reassigns `currentOperationID`
                // away from THIS operation's `opID` before the
                // `self.endOperation(opID)` below ever runs (same race
                // `runRate`'s doc comment describes for
                // `loadQualitySummaries`/`loadExposureAdvice`), so this
                // operation's `endOperation` always hit the "superseded"
                // guard and silently no-opped -- no activityLog entry, and
                // (now) no success toast either, for an operation that had
                // genuinely just succeeded. Reuses `loadStats()`'s own query
                // bundle inline instead, under THIS operation's `opID`,
                // `try?` best-effort (a refresh failure here shouldn't turn
                // an otherwise-successful ingest into a reported error, and
                // shouldn't stomp the "DSS beolvasás kész: …" message above
                // -- same stance `runScan`'s own post-scan stats refresh
                // takes).
                let statsBundleTask = Task.detached(priority: .userInitiated) {
                    try Self.loadStatsBundle(db: db, config: cfg)
                }
                if let bundle = try? await statsBundleTask.value {
                    self.stats = bundle.stats
                    self.sessionDetailsByTarget = bundle.sessionsByTarget
                    self.panelReportsByTarget = bundle.panelsByTarget
                    self.stackReportsByTarget = bundle.stacksByTarget
                    self.stackGroupsByTarget = bundle.stackGroupsByTarget
                }
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

                // R10-B1: `frameVerdicts` alongside `frameScores` -- same
                // "extend the bundle, don't leave it stale" shape as the
                // `qualitySummaries`/`exposureAdvice` reload just above.
                let verdicts = try await Task.detached(priority: .userInitiated) {
                    try Self.loadVerdicts(forScores: results, db: db)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.frameVerdicts = verdicts
                // R12-U1 item 5: see `runScan`'s own `trendPoints = nil`
                // comment -- this session's rated metrics just changed.
                self.trendPoints = nil
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Loads `frameScores` from whatever's already persisted (`ratings`
    /// table), WITHOUT running `Rater.rate` -- never touches the filesystem
    /// or invokes Siril. R9-D6's fix: `QualitySegment` previously only ever
    /// populated `frameScores` as a side effect of `runRate()`, so simply
    /// opening a target's Minőség segment (without pressing "Keretek
    /// pontozása" again) showed the false "Nincsenek pontozott keretek"
    /// empty state even for a target rated in a PREVIOUS session. Called
    /// from `QualitySegment.onAppear` when `frameScores.isEmpty`.
    func loadFrameScores(target: String, date: String?) {
        guard let db else { return }
        let cfg = config

        let opID = beginOperation("Pontszámok betöltése…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await Task.detached(priority: .userInitiated) {
                    try Rater.cachedScores(target: target, date: date, db: db, config: cfg)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.frameScores = results
                self.progressText = "Pontszámok betöltve: \(results.count) frame"

                // R10-B1: `frameVerdicts` alongside `frameScores`, same as
                // `runRate` above -- opening the Minőség segment (this is
                // its own on-appear load, see the doc comment above) must
                // show manual verdicts too, not just scores.
                let verdicts = try await Task.detached(priority: .userInitiated) {
                    try Self.loadVerdicts(forScores: results, db: db)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.frameVerdicts = verdicts
            } catch {
                self.handle(error)
            }
            self.endOperation(opID)
        }
    }

    /// Resolves `scores`' recorded verdicts, keyed back to each frame's own
    /// `path` -- shared by `runRate`/`loadFrameScores`/`runRateAll` so all
    /// three populate `frameVerdicts` the exact same way. `FrameScore`
    /// carries no file id, so this resolves one via `fileID(path:)` per
    /// frame first (an indexed point lookup, same cost class as any other
    /// single-row query in this file), THEN batches the actual verdict
    /// fetch through `userVerdicts(forFileIDs:)` -- the part that would
    /// otherwise be one query per frame, chunked by 500 like every other
    /// batch lookup `Database` exposes. Explicitly `nonisolated` (touches
    /// only its parameters, never `self`) -- `AppState` itself is
    /// `@MainActor`, so a plain `static func` on it would STILL be
    /// main-actor-isolated by default and couldn't be called from inside
    /// `Task.detached`'s off-actor closure below, the same way
    /// `Rater.cachedScores`/`StatsQueries.perTarget` (plain AstroCore
    /// functions, never actor-isolated at all) already can be.
    private nonisolated static func loadVerdicts(forScores scores: [FrameScore], db: Database) throws -> [String: Bool] {
        var idByPath: [String: Int64] = [:]
        for score in scores {
            if let id = try db.fileID(path: score.path) { idByPath[score.path] = id }
        }
        guard !idByPath.isEmpty else { return [:] }

        let verdictsByID = try db.userVerdicts(forFileIDs: Array(idByPath.values))
        guard !verdictsByID.isEmpty else { return [:] }

        var result: [String: Bool] = [:]
        for (path, id) in idByPath {
            if let verdict = verdictsByID[id] { result[path] = verdict }
        }
        return result
    }

    /// Sets (`accepted` non-`nil`) or clears (`nil`) one frame's manual
    /// verdict -- `QualitySegment`'s frame context menu ("Elfogadás" /
    /// "Elvetés" / "Döntés törlése") and `FrameReviewSheet`'s `A`/`X`/`U`
    /// keys (R10-B1). Always writes `source == "app"`, distinguishing this
    /// from a `DSSIngest`-harvested `.dssfilelist` verdict --
    /// `StackList.select` doesn't care which source wrote a given row, only
    /// `accepted`.
    ///
    /// Deliberately a plain, synchronous, unwrapped DB call -- the same
    /// "small enough to just do it, no `beginOperation`/spinner ceremony"
    /// shape `ackFindingGroup`/`unackFindingGroup` already use for their own
    /// single-row writes -- rather than the `Task`/`Task.detached` dance
    /// every OTHER mutation in this file goes through. `FrameReviewSheet`
    /// calls this once per keystroke while blinking through a whole
    /// session; it must never make the UI wait on a spinner for a
    /// single-row SQLite write. `frameVerdicts` is patched in place instead
    /// of re-running `loadFrameScores`: a verdict never adds, removes, or
    /// reorders a `frameScores` row, so a full reload would only add
    /// latency for zero behavioral difference.
    func setFrameVerdict(path: String, accepted: Bool?) {
        guard let db else { return }
        do {
            guard try writeFrameVerdict(path: path, accepted: accepted, db: db) else { return }
            frameVerdicts[path] = accepted
        } catch {
            handle(error)
        }
    }

    /// R12-U1 item 3: `FrameReviewSheet`'s review-scoped counterpart to
    /// `setFrameVerdict` -- same single-row DB write, but patches
    /// `reviewFrameVerdicts` instead of the shared `frameVerdicts`, for a
    /// verdict recorded while blinking through `AppState.reviewFrameScores`
    /// (the "Előző éjszaka" triage sheet) rather than `QualitySegment`'s own
    /// `frameScores`. See `reviewFrameVerdicts`'s own doc comment for why
    /// the two dictionaries are kept apart at all.
    func setReviewFrameVerdict(path: String, accepted: Bool?) {
        guard let db else { return }
        do {
            guard try writeFrameVerdict(path: path, accepted: accepted, db: db) else { return }
            reviewFrameVerdicts[path] = accepted
        } catch {
            handle(error)
        }
    }

    /// The actual DB write `setFrameVerdict`/`setReviewFrameVerdict` share --
    /// factored out so the two differ ONLY in which in-memory dictionary
    /// they patch afterward, never in how the write itself happens. Returns
    /// `false` (nothing thrown) exactly when `path` doesn't resolve to a
    /// tracked file at all -- the caller must skip patching its own
    /// dictionary in that case too, same as the pre-refactor inline code
    /// did (a bare `return` from inside its `do` block already exited the
    /// whole function before ever reaching its own dictionary write).
    private func writeFrameVerdict(path: String, accepted: Bool?, db: Database) throws -> Bool {
        guard let fileID = try db.fileID(path: path) else { return false }
        if let accepted {
            try db.setUserVerdict(fileID: fileID, accepted: accepted, source: "app")
        } else {
            try db.clearUserVerdict(fileID: fileID)
        }
        return true
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
                // D12: this target's coordinate may have just been resolved
                // for the first time (or changed) -- drop its memo entry.
                self.coordinateInfoCache[target] = nil
            } catch {
                self.handle(error)
            }
            // R10 review: same ordering fix as `runPlateSolveAll` --
            // `endOperation(opID)` must run BEFORE `loadDashboardData()`,
            // whose own `beginOperation` reassigns `currentOperationID` and
            // would turn this `endOperation` into a silent no-op (no
            // activity-log entry, no completion toast).
            self.endOperation(opID)
            // N3 (R9 round 3): `loadStats()` immediately followed by
            // `loadPlan()` raced each other's `currentTask` the same way
            // `loadDashboardData`'s own doc comment describes -- one bundled
            // call avoids that.
            self.loadDashboardData()
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
                    // D12: batched instead of one `fitsMeta` query per light
                    // frame across the whole library.
                    let metaByFileID = try db.fitsMetaBatch(fileIDs: lights.compactMap(\.id))
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
                // D12: drop the memo for every target just attempted.
                for t in targets { self.coordinateInfoCache[t] = nil }
            } catch {
                self.handle(error)
            }
            // R10 review: `endOperation(opID)` moved to BEFORE
            // `loadDashboardData()` -- same ordering `loadDashboardData`
            // itself uses before its own fire-and-forget `loadWeather()`
            // call. `loadDashboardData()` immediately reassigns
            // `currentOperationID` via its own `beginOperation`, which would
            // make THIS `endOperation(opID)` a silent no-op (see its
            // `guard currentOperationID == id`) if called any later than
            // this -- dropping both the activity-log entry and the
            // "Plate-solve kész: …" success toast for every run.
            self.endOperation(opID)
            // N3 (R9 round 3): same bundling fix as `runPlateSolve` --
            // see its comment.
            self.loadDashboardData()
        }
    }

    // MARK: - Session quality (absolute metrics + night timeline)

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
                // D22: Enter should open the obvious single answer instead of
                // making the user click through a results page that only
                // has one row worth clicking. Simplest honest reading of
                // "exactly one hit" -- a single target match with no
                // session/file/note hits alongside it -- skips the results
                // page entirely; anything less unambiguous (multiple
                // targets, or a target plus session/file/note hits) still
                // lands on `Page.searchResults` as before. N13 (R9 round 3):
                // `result.notes` was missing from this check -- a target
                // match alongside note hits used to auto-navigate and
                // silently discard the note hits the user never got to see.
                if result.targets.count == 1, result.sessions.isEmpty, result.files.isEmpty, result.notes.isEmpty {
                    self.currentPage = .target(result.targets[0].target)
                }
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

                // D33: rating every target used to leave `stats` (and, for
                // whichever target page happens to be open, `frameScores`/
                // `qualitySummaries`) showing whatever they held BEFORE the
                // run -- even though rating just changed the numbers behind
                // all three. Reloaded here, INLINE in this same Task/opID
                // (not via the public `loadStats()`/`loadFrameScores()`/
                // `loadQualitySummaries()`, each of which cancels
                // `currentTask` on its own -- see `runRate`'s doc comment
                // above for why chaining those back-to-back would race and
                // silently drop all but the last one).
                let openTarget: String? = {
                    if case .target(let name) = self.currentPage { return name }
                    return nil
                }()
                let (newStats, targetReload) = try await Task.detached(priority: .userInitiated) {
                    let newStats = try StatsQueries.perTarget(db: db, config: cfg)
                    var targetReload: ([FrameScore], [SessionQualitySummary], [String: Bool])?
                    if let openTarget {
                        let scores = try Rater.cachedScores(target: openTarget, date: nil, db: db, config: cfg)
                        let summaries = try SessionQuality.summaries(target: openTarget, db: db, config: cfg)
                        // R10-B1: same staleness class D33 already fixed for
                        // `scores`/`summaries` -- without this, rating every
                        // target left the open target's "Saját döntés"
                        // column showing whatever it held before the run.
                        let verdicts = try Self.loadVerdicts(forScores: scores, db: db)
                        targetReload = (scores, summaries, verdicts)
                    }
                    return (newStats, targetReload)
                }.value
                guard !Task.isCancelled else { self.endOperation(opID); return }
                self.stats = newStats
                if let targetReload {
                    self.frameScores = targetReload.0
                    self.qualitySummaries = targetReload.1
                    self.frameVerdicts = targetReload.2
                }
                self.progressText = "Pontozás kész: \(targets.count) célpont"
                // R12-U1 item 5: every target's metrics may have changed.
                self.trendPoints = nil
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
        lastAstroError = nil
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
    ///
    /// R10-A5: also the one hook point for the toast layer, same reasoning.
    /// Failures ALWAYS toast (this is what makes `lastError` visible even on
    /// pages that never rendered it inline -- `lastError`'s own inline
    /// displays and this activity log stay exactly as they were, belt and
    /// suspenders). Successes only toast for `successToastTitles` --
    /// routine background loads (Áttekintés/Célpont-részletek/Statisztika/
    /// Terv/…) already show their result directly on the page that
    /// triggered them, so a success toast on top would just be noise.
    private func endOperation(_ id: UUID) {
        let title = pendingActivityTitle.removeValue(forKey: id)
        guard currentOperationID == id else { return }
        isBusy = false
        if let title {
            // R11-T1: `advice` (the "Mit tehetsz: …" follow-up) rides along
            // ONLY for the activity-log popover -- the toast built right
            // below still uses just `message`, unchanged, so it stays short.
            let outcome: ActivityEntry.Outcome = lastError.map { message in
                .error(message, advice: lastAstroError.flatMap(errorAdvice(for:)))
            } ?? .ok
            activityLog.insert(ActivityEntry(date: Date(), title: title, outcome: outcome), at: 0)
            if activityLog.count > 50 {
                activityLog.removeLast(activityLog.count - 50)
            }
            switch outcome {
            case .error(let message, _):
                pushToast(.error, "\(Self.toastLabel(for: title)) — \(message)")
            case .ok:
                if Self.successToastTitles.contains(title) {
                    pushToast(.success, progressText)
                }
            }
        }
    }

    /// `beginOperation` titles whose SUCCESSFUL completion is worth a toast
    /// (R10-A5) -- exports, reports, generated scripts, note saves,
    /// calibration link-apply, session creation, the two whole-library batch
    /// actions ("Batch actions (R9-T6/B14)" above: Minden célpont pontozása…/
    /// Expozíció-tanácsadó…), DSS ingest, scans (R10 review), and the
    /// whole-library plate-solve batch (R10 review). Every string here must
    /// match a `beginOperation(_:)` call site's argument EXACTLY -- all of
    /// them are static literals, never interpolated, so this is safe.
    /// Deliberately just this fixed set rather than a per-call-site flag, so
    /// the ~20 unrelated call sites (routine loads, audit, tag/goal edits,
    /// single-target rate/plate-solve, …) don't all need touching; failure
    /// toasting is unconditional (see `endOperation` above) and doesn't
    /// consult this list at all.
    private static let successToastTitles: Set<String> = [
        "Exportálás…",
        "Stack-lista exportálása…",
        "Éjszaka-riport készítése…",
        "Célpont-riport készítése…",
        "Javaslat-script írása…",
        "Takarítási script írása…",
        // R10 review (item 2): `runScan`'s two titles -- so its "Kész — új:
        // N, frissült: …" summary reaches the user as a toast, not just the
        // toolbar's own transient `progressText` caption.
        "Könyvtár beolvasása…",
        "Almappa beolvasása…",
        // R10 review (item 3): `runPlateSolveAll`'s title -- so its
        // "Plate-solve kész: …" summary toasts too.
        "Plate-solve (minden célpont) indul…",
        "Jegyzet mentése…",
        "Kalibráció linkelése…",
        "Session létrehozása…",
        "Minden célpont pontozása…",
        "Expozíció-tanácsadó (minden célpont)…",
        "DSS-adatok beolvasása…",
        // R11-T9/F5: "Előző éjszaka"'s own batch rate -- same "whole-set
        // batch operation toasts its summary" precedent as "Minden célpont
        // pontozása…" above.
        "Új sessionök pontozása…",
        // R11-T14/F9: `runVerify`'s title -- so its "Integritás: N fájl
        // rendben, M eltérés" summary toasts too.
        "Integritás-ellenőrzés fut…",
        // R11-T17/F4: `recognizeSiteFromImageHeaders`'s title -- unlike the
        // ordinary "Felfedezés számítása…" (which is NOT in this list, since
        // its own page already shows the result directly), this one starts
        // from a completely empty "nincs helyszín" state, so a toast
        // confirming exactly which coordinate got picked up is worth the
        // extra reassurance.
        "Helyszín felismerése a képek fejléceiből…",
    ]

    /// Strips the trailing "…" every `beginOperation` title ends with, so an
    /// error toast reads "Exportálás — <reason>" instead of "Exportálás… —
    /// <reason>".
    private static func toastLabel(for title: String) -> String {
        title.hasSuffix("…") ? String(title.dropLast()) : title
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

    /// D31: bumped by `mountObserver`/`activationObserver` -- has no meaning
    /// of its own, its only job is to be a stored, `@Observable`-tracked
    /// property that `scanIsStale` reads, so that bumping it marks every
    /// view that read `scanIsStale` as needing to re-evaluate it, even
    /// though `lastScanDate` (the value the 24h check actually depends on)
    /// didn't itself change.
    var staleCheckTick: Int = 0

    /// `true` once more than 24h have passed since `lastScanDate` -- drives
    /// the shell's dismissible "Új fájlok lehetnek. [Beolvasás]" banner
    /// (B6). `false` (no banner) before any scan has ever completed for
    /// this root, same "don't guess" stance used elsewhere in this file.
    var scanIsStale: Bool {
        _ = staleCheckTick
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
