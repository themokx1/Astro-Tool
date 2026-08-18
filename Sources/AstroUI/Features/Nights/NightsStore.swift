import AstroApplication
import AstroCore
import Foundation
import Observation
import SwiftUI

public struct NightRow: Equatable, Sendable, Identifiable {
    public enum TriageState: String, Sendable {
        case ready = "Ready"
        case needsReview = "Needs review"
        case empty = "No usable frames"

        /// W3-9: `NightsView`'s "Triage" column and `ProjectWorkspaceView`'s
        /// own copy of this table both used to render `.rawValue` directly
        /// (`Label(night.triageState.rawValue, ...)`) -- a `String`, so
        /// `Label` always chose its verbatim overload no matter what
        /// `hu.lproj` said. Same dual-property fix as
        /// `ProjectNextActionKind.titleKey`/`.localizedTitle`
        /// (`ProjectsStore.swift`): `displayLabel` for view bodies that take
        /// `LocalizedStringKey` directly (`Label`/`Text`), `localizedText`
        /// for `MetricCard.value`, which stays `String`-typed by design.
        var displayLabel: LocalizedStringKey { LocalizedStringKey(rawValue) }
        var localizedText: String { NSLocalizedString(rawValue, bundle: .main, comment: "") }
    }

    public let snapshot: NightSnapshot
    public var id: UUID { snapshot.id }
    public var date: String { snapshot.night.localDate }
    public var seriesCount: Int { snapshot.series.count }
    public var projectSummary: String {
        snapshot.projects.map(\.catalogID).joined(separator: ", ")
    }
    public var exposureSummary: String {
        Array(Set(snapshot.series.map { Int($0.exposureSeconds.rounded()) }))
            .sorted().map { "\($0) s" }.joined(separator: ", ")
    }
    /// `NightWorkspaceView`'s only caller already wraps this in
    /// `LocalizedStringKey(row.filterSummary)` (the ternary-of-literals
    /// workaround `PlanningView`'s Save/Saved button also uses) -- the
    /// English fallback below just needs its `hu.lproj` entry.
    public var filterSummary: String {
        let filters = Array(Set(snapshot.series.compactMap(\.filterName))).sorted()
        return filters.isEmpty ? "No filter metadata" : filters.joined(separator: ", ")
    }
    public var integrationSummary: String {
        AstroFormat.duration(seconds: snapshot.integrationSeconds)
    }
    public var excludedFrames: Int { max(0, snapshot.totalFrames - snapshot.usableFrames) }
    /// V2 product/UX audit (2026-08-15) section 2.3, CRITICAL: this used to
    /// be `excludedFrames > 0`, which meant *rejecting* a bad frame during
    /// morning triage flipped the night to "Needs review" forever -- there
    /// was no way back to `.ready` short of un-rejecting it. "Needs review"
    /// now means what it says: frames whose verdict is still `.undecided`.
    /// A night where every frame has been decided -- accepted, rejected, or
    /// a mix -- does not need review, even though some frames may have been
    /// rejected along the way. A night with zero usable frames (nothing
    /// left to review, whether because it has no frames at all or because
    /// everything in it was rejected) is `.empty` rather than `.needsReview`
    /// -- there is nothing left to triage in either case.
    public var triageState: TriageState {
        if snapshot.usableFrames == 0 { return .empty }
        return snapshot.undecidedFrames > 0 ? .needsReview : .ready
    }
}

/// W4-3b: the Nights page's triage filter -- deliberately just `.all` plus
/// the same two states the row badge itself already collapses non-`.ready`
/// nights into (`night.triageState == .ready` is the only distinction the
/// existing badge color/icon ever drew). `.needsReview` here therefore
/// matches `NightRow.TriageState.empty` too, the same way it already did
/// inside `NightsStore.needsReviewCount`'s own `!= .ready` filter -- this
/// never invents a third filterable bucket the row UI didn't already have.
public enum NightTriageFilter: String, CaseIterable, Sendable {
    case all = "All"
    case needsReview = "Needs review"
    case ready = "Ready"

    /// Same `Mode.displayLabel` shape immediately above in `NightsView` --
    /// `.needsReview`/`.ready` reuse `NightRow.TriageState`'s own rawValues
    /// verbatim, so they inherit its existing `hu.lproj` translations;
    /// only `.all`'s "All" is genuinely new vocabulary.
    public var displayLabel: LocalizedStringKey { LocalizedStringKey(rawValue) }
}

public struct PlanningNightRow: Equatable, Sendable, Identifiable {
    public let summary: NightSummary
    public var id: String { summary.date }
    /// `KeyPathComparator` needs a non-optional `Comparable` value --
    /// `astroDarkHours` is `nil` on nights that never reach true
    /// astronomical darkness (`NightSummary.astroDarkHours`'s own doc
    /// comment), which sorts lowest (as if darkness were 0h) rather than
    /// crashing the column's sort.
    public var astroDarkHoursSortKey: Double { summary.astroDarkHours ?? -1 }
    /// `note` (when present) is already Hungarian text `Planner` generates
    /// directly for its V1/CLI consumers (e.g. "nincs site-koordináta") --
    /// passing it through `LocalizedStringKey` at the call site
    /// (`NightsView.swift`) is harmless (an unmatched key just displays as
    /// itself). Only the English fallback below, for the rarer case where
    /// even `note` is `nil`, needed its own `hu.lproj` entry.
    public var darkHours: String {
        summary.astroDarkHours.map { AstroFormat.duration(seconds: $0 * 3600) }
            ?? (summary.note ?? NSLocalizedString("No astronomical darkness", bundle: .main, comment: ""))
    }
    public var moon: String {
        "\(summary.moonIlluminationPercent.formatted(.number.precision(.fractionLength(0))))%"
    }
    public var bestTargets: String {
        summary.bestTargets.map {
            "\($0.target) (\(AstroFormat.duration(seconds: $0.usableHours * 3600)))"
        }.joined(separator: ", ")
    }
}

@MainActor
@Observable
public final class NightsStore {
    public typealias MetadataFactory = @MainActor @Sendable (URL) throws -> MetadataStore
    public typealias CalendarProvider = @Sendable (URL) async throws -> [NightSummary]
    /// W4-2: per-date cloud summaries for the open library's resolved site --
    /// `nil` when weather is off or no site resolves (the honest "no data"
    /// case `calendarTable`'s "Felhő" column then renders as "—" for every
    /// row, the same way a date simply missing from the dictionary already
    /// does for "beyond the 7-day horizon"). Injectable for the same reason
    /// `calendarProvider` is: tests supply a fixed result without a real
    /// network call.
    public typealias WeatherProvider = @Sendable (URL) async throws -> [String: DailyCloudSummary]?
    public private(set) var nights: [NightRow] = []
    public private(set) var planningNights: [NightSummary] = []
    /// Keyed the same "yyyy-MM-dd, named by the night's start" way
    /// `PlanningNightRow.id`/`summary.date` already are, so `calendarTable`
    /// can look a night's cloud summary up by that same date string with no
    /// extra formatting.
    public private(set) var nightWeather: [String: DailyCloudSummary] = [:]
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var selectedMonth: String?
    public private(set) var selectedNightID: UUID?
    /// W4-3b (owner's second Projects complaint, same disease on this page):
    /// a per-row amber "Needs review" badge is only informative when the
    /// table actually mixes states -- when every row already agrees, 16
    /// repeats of the same badge are noise the sidebar's own `.badge()`
    /// count already covers. This filter lets the user narrow to exactly
    /// one state; `uniformVisibleTriageState` below is what decides whether
    /// the Triage column collapses into one summary sentence.
    public private(set) var triageFilter: NightTriageFilter = .all
    private let metadataFactory: MetadataFactory
    private let calendarProvider: CalendarProvider
    private let weatherProvider: WeatherProvider

    /// `calendarProvider` is `Optional`/`nil` rather than defaulted directly
    /// to `NightsStore.productionCalendar`, and MUST stay that way: an
    /// `async` default argument is emitted as a `weak`/`linkonce_odr`
    /// closure plus an async function pointer record into every module that
    /// uses the default, and Swift 6.3.3 gives those copies different async
    /// context sizes (80 bytes here, 64 in a client module). The linker
    /// coalesces body and size record independently, so it can pair the big
    /// body with the small record -- the callee then writes past the context
    /// `swift_task_alloc` handed it and corrupts the task allocator, which
    /// aborts the process with `freed pointer was not the last allocation`.
    /// That is not hypothetical: it crashed
    /// `GlobalSearchStoreTests.searchesAcrossWorkflowObjects` 100% of the
    /// time on a clean build, and which way it fell depended only on this
    /// file's object layout. Resolving the default in the initializer body
    /// keeps the closure private to this module, so no client emits a
    /// competing copy. `AsyncContextSizeGateTests` gates this and carries
    /// the full account; `metadataFactory` is not `async`, emits no such
    /// record, and is deliberately left as an ordinary default.
    public init(
        metadataFactory: @escaping MetadataFactory = ProjectsStore.productionMetadata,
        calendarProvider: CalendarProvider? = nil,
        /// Same `Optional`-not-async-default shape as `calendarProvider`
        /// immediately above, for the identical reason.
        weatherProvider: WeatherProvider? = nil
    ) {
        self.metadataFactory = metadataFactory
        self.calendarProvider = calendarProvider ?? NightsStore.productionCalendar
        self.weatherProvider = weatherProvider ?? NightsStore.productionWeather
    }

    public var availableMonths: [String] {
        Array(Set(nights.map { String($0.date.prefix(7)) })).sorted(by: >)
    }

    /// V2 UI/UX audit (2026-08-14) systemic pattern S7: the observed-nights
    /// table's header used to look clickable and do nothing. Default is
    /// newest night first -- `NightsQuery.nights()` already returns that
    /// order, so this default reproduces today's behavior exactly; only a
    /// user click changes it.
    public private(set) var sortOrder: [KeyPathComparator<NightRow>] = [
        KeyPathComparator(\NightRow.date, order: .reverse)
    ]
    /// Cached, re-sorted/filtered on every input change (`nights`,
    /// `selectedMonth`, `triageFilter`, `sortOrder`) -- never re-derived from
    /// `body`, which is the render-path cost that froze this app repeatedly
    /// (see `PlanningStore.filteredRecommendations`'s own doc comment for the
    /// same fix applied first).
    public private(set) var visibleNights: [NightRow] = []

    private func recomputeVisibleNights() {
        var rows = selectedMonth.map { month in nights.filter { $0.date.hasPrefix(month) } } ?? nights
        switch triageFilter {
        case .all: break
        case .needsReview: rows = rows.filter { $0.triageState != .ready }
        case .ready: rows = rows.filter { $0.triageState == .ready }
        }
        if !sortOrder.isEmpty { rows.sort(using: sortOrder) }
        visibleNights = rows
    }

    public func setSortOrder(_ newValue: [KeyPathComparator<NightRow>]) {
        guard newValue != sortOrder else { return }
        sortOrder = newValue
        recomputeVisibleNights()
    }

    /// W4-3b: mirrors `selectMonth`'s own "drop a selection the new view no
    /// longer contains" rule immediately below.
    public func setTriageFilter(_ newValue: NightTriageFilter) {
        guard newValue != triageFilter else { return }
        triageFilter = newValue
        recomputeVisibleNights()
        if let selectedNightID, !visibleNights.contains(where: { $0.id == selectedNightID }) {
            self.selectedNightID = nil
        }
    }

    /// W4-3b: `nil` when the currently visible nights mix triage states (the
    /// per-row Triage column badge is still the only way to tell them
    /// apart); the shared state when every visible night already agrees --
    /// whether because the user picked a specific `triageFilter` (where this
    /// is true by construction) or the underlying data just happens to,
    /// which is exactly the "16 rows shout the same badge" case the owner
    /// flagged. `NightsView` uses this to replace the Triage column with one
    /// summary sentence instead of repeating the same badge on every row.
    public var uniformVisibleTriageState: NightRow.TriageState? {
        guard let first = visibleNights.first else { return nil }
        return visibleNights.allSatisfy { $0.triageState == first.triageState } ? first.triageState : nil
    }

    public var selectedNight: NightRow? {
        nights.first { $0.id == selectedNightID }
    }

    /// The planning calendar's own sort -- default soonest-night-first,
    /// which is also the order `Planner.month` already returns.
    public private(set) var planningSortOrder: [KeyPathComparator<PlanningNightRow>] = [
        KeyPathComparator(\PlanningNightRow.summary.date, order: .forward)
    ]
    /// Cached the same way as `visibleNights`, re-sorted on `planningNights`/
    /// `planningSortOrder` changes.
    public private(set) var planningRows: [PlanningNightRow] = []

    private func recomputePlanningRows() {
        var rows = planningNights.map(PlanningNightRow.init)
        if !planningSortOrder.isEmpty { rows.sort(using: planningSortOrder) }
        planningRows = rows
    }

    public func setPlanningSortOrder(_ newValue: [KeyPathComparator<PlanningNightRow>]) {
        guard newValue != planningSortOrder else { return }
        planningSortOrder = newValue
        recomputePlanningRows()
    }

    public var needsReviewCount: Int {
        visibleNights.filter { $0.triageState != .ready }.count
    }

    public func selectMonth(_ month: String?) {
        selectedMonth = month
        recomputeVisibleNights()
        if let selectedNightID, !visibleNights.contains(where: { $0.id == selectedNightID }) {
            self.selectedNightID = nil
        }
    }

    public func selectNight(_ id: UUID?) { selectedNightID = id }

    public func open(rootURL: URL) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let metadata = try metadataFactory(rootURL.standardizedFileURL)
            nights = try await NightsQuery(metadata: metadata).nights().map(NightRow.init)
            planningNights = (try? await calendarProvider(rootURL.standardizedFileURL)) ?? []
            // W4-2: weather is opt-in side data (same posture as V1's
            // `AppState.loadWeather`) -- a disabled toggle, no site, or an
            // outright fetch failure all fall back to `[:]` rather than
            // failing `open(rootURL:)` itself, so a flaky Open-Meteo call
            // never blocks the calendar the rest of this method just loaded.
            nightWeather = (try? await weatherProvider(rootURL.standardizedFileURL)) ?? [:]
            recomputeVisibleNights()
            recomputePlanningRows()
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    public static func productionCalendar(rootURL: URL) async throws -> [NightSummary] {
        try await Task.detached(priority: .utility) {
            let identity = LibraryIdentity(rootURL: rootURL)
            let paths = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
            let database = try Database(path: paths.indexDatabase.path)
            let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
            var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
            config.rootPath = rootURL.path
            return try Planner.month(nights: 30, db: database, config: config)
        }.value
    }

    /// W4-2: per-date cloud summaries for the library's resolved site, gated
    /// behind the exact same `config.weather.enabled` opt-in V1's
    /// `AppState.loadWeather` reads (the same `config.json`, so a toggle
    /// flipped from either V1's or V2's Settings takes effect here too).
    /// `nil` for "disabled" or "no site resolves" (both honest "no data"
    /// cases); resolves the site independently of `productionCalendar` --
    /// the same accepted duplication `HomeStore`/`PlanningStore`'s own
    /// production providers already have with each other.
    public static func productionWeather(rootURL: URL) async throws -> [String: DailyCloudSummary]? {
        struct ResolvedSite { let latitudeDeg: Double; let longitudeDeg: Double }
        let resolved: ResolvedSite? = try await Task.detached(priority: .utility) {
            let identity = LibraryIdentity(rootURL: rootURL)
            let paths = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
            let database = try Database(path: paths.indexDatabase.path)
            let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
            var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
            config.rootPath = rootURL.path
            guard config.weather.enabled else { return nil }
            let site = try Planner.resolveSite(db: database, config: config)
            guard let latitudeDeg = site.latitudeDeg, let longitudeDeg = site.longitudeDeg else { return nil }
            return ResolvedSite(latitudeDeg: latitudeDeg, longitudeDeg: longitudeDeg)
        }.value
        guard let resolved else { return nil }
        let (_, summaries) = try await WeatherService.shared.fetch(
            latitude: resolved.latitudeDeg, longitude: resolved.longitudeDeg
        )
        return summaries
    }
}

/// W3-9: `NightWorkspaceView`'s "Mode" column used to render
/// `$0.series.passband.rawValue.replacingOccurrences(of: "_", with: " ").capitalized`
/// -- deriving a display string from the raw case name (`"dual_band"` ->
/// "Dual band") rather than translating the case itself, so it stayed
/// English no matter what `hu.lproj` said. Same engine-enum-to-display-label
/// fix as `PlanningFit`/`ProjectWorkflowPhase`/`SkyVerdictKind`.
extension SeriesPassband {
    var displayLabel: LocalizedStringKey {
        switch self {
        case .broadband: "Broadband"
        case .dualBand: "Dual band"
        case .narrowband: "Narrowband"
        case .lrgb: "LRGB"
        case .luminance: "Luminance"
        case .unfiltered: "Unfiltered"
        case .other: "Other"
        case .unknown: "Unknown"
        }
    }

    /// For `LabeledContent(_:value:)` call sites (`InspectorView.swift`'s
    /// `SeriesSummaryPanel`) -- that specific SwiftUI initializer renders its
    /// `value:` with `Text(verbatim:)` regardless of the value's type, so
    /// only an eagerly-resolved `String` actually localizes there;
    /// `displayLabel` above (a lazy `LocalizedStringKey`) would silently stay
    /// English in that one call shape. Same dual-property split as
    /// `NightRow.TriageState.displayLabel`/`.localizedText`.
    var localizedText: String {
        switch self {
        case .broadband: NSLocalizedString("Broadband", bundle: .main, comment: "")
        case .dualBand: NSLocalizedString("Dual band", bundle: .main, comment: "")
        case .narrowband: NSLocalizedString("Narrowband", bundle: .main, comment: "")
        case .lrgb: NSLocalizedString("LRGB", bundle: .main, comment: "")
        case .luminance: NSLocalizedString("Luminance", bundle: .main, comment: "")
        case .unfiltered: NSLocalizedString("Unfiltered", bundle: .main, comment: "")
        case .other: NSLocalizedString("Other", bundle: .main, comment: "")
        case .unknown: NSLocalizedString("Unknown", bundle: .main, comment: "")
        }
    }
}
