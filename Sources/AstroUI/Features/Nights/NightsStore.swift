import AstroApplication
import AstroCore
import Foundation
import Observation

public struct NightRow: Equatable, Sendable, Identifiable {
    public enum TriageState: String, Sendable {
        case ready = "Ready"
        case needsReview = "Needs review"
        case empty = "No usable frames"
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
    public var filterSummary: String {
        let filters = Array(Set(snapshot.series.compactMap(\.filterName))).sorted()
        return filters.isEmpty ? "No filter metadata" : filters.joined(separator: ", ")
    }
    public var integrationSummary: String {
        let minutes = Int(snapshot.integrationSeconds.rounded()) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
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

public struct PlanningNightRow: Equatable, Sendable, Identifiable {
    public let summary: NightSummary
    public var id: String { summary.date }
    /// `KeyPathComparator` needs a non-optional `Comparable` value --
    /// `astroDarkHours` is `nil` on nights that never reach true
    /// astronomical darkness (`NightSummary.astroDarkHours`'s own doc
    /// comment), which sorts lowest (as if darkness were 0h) rather than
    /// crashing the column's sort.
    public var astroDarkHoursSortKey: Double { summary.astroDarkHours ?? -1 }
    public var darkHours: String {
        summary.astroDarkHours.map { "\($0.formatted(.number.precision(.fractionLength(1)))) h" }
            ?? (summary.note ?? "No astronomical darkness")
    }
    public var moon: String {
        "\(summary.moonIlluminationPercent.formatted(.number.precision(.fractionLength(0))))%"
    }
    public var bestTargets: String {
        summary.bestTargets.map {
            "\($0.target) (\($0.usableHours.formatted(.number.precision(.fractionLength(1)))) h)"
        }.joined(separator: ", ")
    }
}

@MainActor
@Observable
public final class NightsStore {
    public typealias MetadataFactory = @MainActor @Sendable (URL) throws -> MetadataStore
    public typealias CalendarProvider = @Sendable (URL) async throws -> [NightSummary]
    public private(set) var nights: [NightRow] = []
    public private(set) var planningNights: [NightSummary] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var selectedMonth: String?
    public private(set) var selectedNightID: UUID?
    private let metadataFactory: MetadataFactory
    private let calendarProvider: CalendarProvider

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
        calendarProvider: CalendarProvider? = nil
    ) {
        self.metadataFactory = metadataFactory
        self.calendarProvider = calendarProvider ?? NightsStore.productionCalendar
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
    /// `selectedMonth`, `sortOrder`) -- never re-derived from `body`, which
    /// is the render-path cost that froze this app repeatedly (see
    /// `PlanningStore.filteredRecommendations`'s own doc comment for the
    /// same fix applied first).
    public private(set) var visibleNights: [NightRow] = []

    private func recomputeVisibleNights() {
        var rows = selectedMonth.map { month in nights.filter { $0.date.hasPrefix(month) } } ?? nights
        if !sortOrder.isEmpty { rows.sort(using: sortOrder) }
        visibleNights = rows
    }

    public func setSortOrder(_ newValue: [KeyPathComparator<NightRow>]) {
        guard newValue != sortOrder else { return }
        sortOrder = newValue
        recomputeVisibleNights()
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
}
