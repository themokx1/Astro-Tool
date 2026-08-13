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
    public var triageState: TriageState {
        if snapshot.usableFrames == 0 { return .empty }
        return excludedFrames > 0 ? .needsReview : .ready
    }
}

public struct PlanningNightRow: Equatable, Sendable, Identifiable {
    public let summary: NightSummary
    public var id: String { summary.date }
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

    public init(
        metadataFactory: @escaping MetadataFactory = ProjectsStore.productionMetadata,
        calendarProvider: @escaping CalendarProvider = NightsStore.productionCalendar
    ) {
        self.metadataFactory = metadataFactory
        self.calendarProvider = calendarProvider
    }

    public var availableMonths: [String] {
        Array(Set(nights.map { String($0.date.prefix(7)) })).sorted(by: >)
    }

    public var visibleNights: [NightRow] {
        guard let selectedMonth else { return nights }
        return nights.filter { $0.date.hasPrefix(selectedMonth) }
    }

    public var selectedNight: NightRow? {
        nights.first { $0.id == selectedNightID }
    }

    public var planningRows: [PlanningNightRow] { planningNights.map(PlanningNightRow.init) }

    public var needsReviewCount: Int {
        visibleNights.filter { $0.triageState != .ready }.count
    }

    public func selectMonth(_ month: String?) {
        selectedMonth = month
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
