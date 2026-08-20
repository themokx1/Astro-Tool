@testable import AstroApplication
import Foundation
import Testing

/// Pins `AnniversaryQuery.anniversaries`'s pure date-matching rules --
/// expert ideation spec #5 ("First-Light Anniversaries"). Real dates only:
/// an anniversary fires on the EXACT month+day match, never a day early or
/// late, and never for a project shot less than a year ago.
struct AnniversaryQueryTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func today() -> Date { calendar.date(from: DateComponents(year: 2026, month: 8, day: 19))! }

    @Test("Fires when the project's first light lands on today's exact month+day, N years ago")
    func firesOnExactAnniversary() {
        let snapshot = projectSnapshot(catalogID: "IC 1805", firstLightDate: "2023-08-19")

        let hits = AnniversaryQuery.anniversaries(projects: [snapshot], today: today(), calendar: calendar)

        #expect(hits.count == 1)
        #expect(hits.first?.catalogID == "IC 1805")
        #expect(hits.first?.yearsAgo == 3)
    }

    @Test("Does not fire one day early")
    func doesNotFireADayEarly() {
        // First light was the 20th, three years back -- one day AFTER
        // today's date, so no anniversary today.
        let snapshot = projectSnapshot(catalogID: "IC 1805", firstLightDate: "2023-08-20")

        let hits = AnniversaryQuery.anniversaries(projects: [snapshot], today: today(), calendar: calendar)

        #expect(hits.isEmpty)
    }

    @Test("Does not fire one day late")
    func doesNotFireADayLate() {
        // First light was the 18th, three years back -- one day BEFORE
        // today's date, so no anniversary today either.
        let snapshot = projectSnapshot(catalogID: "IC 1805", firstLightDate: "2023-08-18")

        let hits = AnniversaryQuery.anniversaries(projects: [snapshot], today: today(), calendar: calendar)

        #expect(hits.isEmpty)
    }

    @Test("Never fires for a project shot less than a year ago, even on the exact same month+day")
    func doesNotFireUnderOneYear() {
        // Same month+day as today, but this calendar year -- "0 years ago"
        // is not an anniversary.
        let snapshot = projectSnapshot(catalogID: "IC 1805", firstLightDate: "2026-08-19")

        let hits = AnniversaryQuery.anniversaries(projects: [snapshot], today: today(), calendar: calendar)

        #expect(hits.isEmpty)
    }

    @Test("A project with no recorded nights at all never fires")
    func projectWithNoNightsNeverFires() {
        let project = ProjectRecord(id: UUID(), catalogID: "IC 1805", displayName: "IC 1805", phase: .collecting)
        let snapshot = ProjectSnapshot(
            project: project, canonicalFolderName: "IC 1805", series: [], nights: [], orphanedSeries: [],
            nextAction: ProjectNextAction(kind: .keepCollecting, title: "Keep collecting", explanation: "")
        )

        let hits = AnniversaryQuery.anniversaries(projects: [snapshot], today: today(), calendar: calendar)

        #expect(hits.isEmpty)
    }

    @Test("Uses the EARLIEST session as first light, not the latest")
    func usesEarliestNightAsFirstLight() {
        // The project has a later session too (e.g. a second imaging run
        // over the same target) -- only the earliest one counts as "first
        // light", so this must still anniversary off 2023-08-19, not the
        // 2025 date.
        let snapshot = projectSnapshot(
            catalogID: "IC 1805",
            firstLightDate: "2023-08-19",
            extraNightDates: ["2025-08-19", "2024-01-05"]
        )

        let hits = AnniversaryQuery.anniversaries(projects: [snapshot], today: today(), calendar: calendar)

        #expect(hits.first?.yearsAgo == 3)
    }

    @Test("Multiple targets firing the same day are capped and prioritize the larger anniversary")
    func multipleAnniversariesPrioritizeLarger() {
        let fiveYearAgo = projectSnapshot(catalogID: "M 31", firstLightDate: "2021-08-19")
        let oneYearAgo = projectSnapshot(catalogID: "M 42", firstLightDate: "2025-08-19")
        let threeYearAgo = projectSnapshot(catalogID: "IC 1805", firstLightDate: "2023-08-19")

        let hits = AnniversaryQuery.anniversaries(
            projects: [oneYearAgo, fiveYearAgo, threeYearAgo], today: today(), calendar: calendar
        )

        #expect(hits.map(\.yearsAgo) == [5, 3, 1])
        #expect(hits.map(\.catalogID) == ["M 31", "IC 1805", "M 42"])
    }

    // MARK: - Fixtures

    private func projectSnapshot(
        catalogID: String,
        firstLightDate: String,
        extraNightDates: [String] = []
    ) -> ProjectSnapshot {
        let project = ProjectRecord(id: UUID(), catalogID: catalogID, displayName: catalogID, phase: .collecting)
        let allDates = [firstLightDate] + extraNightDates
        let nights = allDates.map { date in
            ProjectNightSnapshot(
                night: NightRecord(id: UUID(), localDate: date, timeZoneID: "Europe/Budapest"),
                series: []
            )
        }
        return ProjectSnapshot(
            project: project, canonicalFolderName: catalogID, series: [], nights: nights, orphanedSeries: [],
            nextAction: ProjectNextAction(kind: .keepCollecting, title: "Keep collecting", explanation: "")
        )
    }
}
