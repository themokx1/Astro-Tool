@testable import AstroUI
import AstroApplication
@testable import AstroCore
import Foundation
import Testing

@MainActor
struct HomeStoreTests {
    @Test("Opening a real library replaces the empty home with useful project context")
    func configuredLibraryProducesHomeSummary() {
        let store = HomeStore()
        let project = ProjectRecord(
            id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting
        )

        store.configure(libraryName: "Astro", projects: [project], nightCount: 16)

        #expect(store.snapshot.libraryName == "Astro")
        #expect(store.snapshot.projectCount == 1)
        #expect(store.snapshot.nightCount == 16)
        #expect(store.snapshot.nextProject == project)
    }

    @Test("Home ranks real tonight plans and links them to V2 projects")
    func homeShowsAstronomicalTonightRecommendations() async throws {
        let project = ProjectRecord(
            id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting
        )
        let metadata = try MetadataStore.temporary()
        try await metadata.save(project)
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(tonightProvider: { selectedRoot in
            #expect(selectedRoot == root)
            return [TargetPlan(
                target: "IC_1396", displayName: "Elefántormány-köd",
                usableIntegrationSeconds: 7200, goalSeconds: 36_000,
                culminationLocal: "01:14", maxAltitudeDeg: 79,
                visibleWindowLocal: "22:10–03:36", visibleHours: 5.5,
                moonIlluminationPercent: 11, moonSeparationDeg: 87,
                verdict: "ma jó", score: 0.92
            )]
        })

        await store.configure(
            libraryName: "Astro", rootURL: root,
            projectsStore: projects, nightCount: 1
        )

        #expect(store.snapshot.tonightRecommendations.count == 1)
        #expect(store.snapshot.tonightRecommendations[0].projectID == project.id)
        #expect(store.snapshot.tonightRecommendations[0].visibleWindow == "22:10–03:36")
        #expect(store.snapshot.tonightRecommendations[0].verdict == "ma jó")
    }

    @Test("Home prioritizes the least collected active project")
    func homeRecommendationUsesAcquisitionProgress() async throws {
        let metadata = try MetadataStore.temporary()
        let rich = ProjectRecord(id: UUID(), catalogID: "M 42", displayName: "Orion-köd", phase: .collecting)
        let lean = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting)
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let richSeries = makeSeries(project: rich.id, night: night.id, exposure: 300)
        let leanSeries = makeSeries(project: lean.id, night: night.id, exposure: 30)
        try await metadata.save(MetadataWriteBatch(projects: [rich, lean], nights: [night], series: [richSeries, leanSeries]))
        try await metadata.save(MetadataWriteBatch(frameDecisions:
            (0..<10).map { FrameDecisionRecord(id: UUID(), seriesID: richSeries.id, relativePath: "r\($0).fit", verdict: .accepted, logicallyExcluded: false) }
            + [FrameDecisionRecord(id: UUID(), seriesID: leanSeries.id, relativePath: "l.fit", verdict: .accepted, logicallyExcluded: false)]
        ))
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        try await projects.open(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        let store = HomeStore()

        await store.configure(libraryName: "Astro", projectsStore: projects, nightCount: 1)

        #expect(store.snapshot.nextProject == lean)
        #expect(store.snapshot.nextProjectIntegrationSeconds == 30)
    }

    @Test("Best targets tonight never includes a comet, a coordinate-less target, or a low-altitude target")
    func homeExcludesTargetsTheEngineKnowsAreUnshootable() async throws {
        // Task 1 (owner feedback wave 3): `Planner.plan`/`DiscoveryPlanner.discover`
        // share the exact same `SkyVerdict` engine and already stamp these
        // three cases with an unambiguous, unusable verdict -- `HomeStore`
        // must act on that verdict instead of blindly taking `prefix(8)`.
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(tonightProvider: { _ in
            [
                TargetPlan(
                    target: "C2025_R3_Panstarrs", displayName: "C/2025 R3 (Panstarrs)",
                    usableIntegrationSeconds: 1200,
                    verdict: SkyVerdict.cometStaleCoordinate, score: 0.9
                ),
                TargetPlan(
                    target: "IC4604_RhoOphiuchi", displayName: "IC 4604 Rho Ophiuchi",
                    usableIntegrationSeconds: 600,
                    verdict: SkyVerdict.noCoordinate, score: 0.7
                ),
                TargetPlan(
                    target: "M42_Orion", displayName: "M 42 Orion (Orion)",
                    usableIntegrationSeconds: 900, maxAltitudeDeg: 9,
                    verdict: SkyVerdict.tooLow(9), score: 0.6
                ),
                TargetPlan(
                    target: "IC_1396", displayName: "Elefántormány-köd",
                    usableIntegrationSeconds: 7200, goalSeconds: 36_000,
                    culminationLocal: "01:14", maxAltitudeDeg: 79,
                    visibleWindowLocal: "22:10–03:36", visibleHours: 5.5,
                    moonIlluminationPercent: 11, moonSeparationDeg: 87,
                    verdict: SkyVerdict.good, score: 0.92
                ),
            ]
        })

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 1)

        #expect(store.snapshot.tonightRecommendations.count == 1)
        #expect(store.snapshot.tonightRecommendations.first?.target == "IC_1396")
    }

    @Test("Best targets tonight is an honest empty list, not a padded one, when nothing shootable remains")
    func homeTonightRecommendationsEmptyWhenEverythingIsUnshootable() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(tonightProvider: { _ in
            [
                TargetPlan(
                    target: "C2025_R3_Panstarrs", displayName: "C/2025 R3 (Panstarrs)",
                    usableIntegrationSeconds: 1200,
                    verdict: SkyVerdict.cometStaleCoordinate, score: 0.9
                ),
            ]
        })

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 1)

        #expect(store.snapshot.tonightRecommendations.isEmpty)
    }

    @Test("Continue where it matters never recommends a project whose only target is unshootable tonight")
    func continueWhereItMattersSkipsUnshootableProjects() async throws {
        // The owner's exact complaint: a comet with a stale coordinate was
        // surfaced as "least collected active project" with an Open Project
        // button, even though it cannot meaningfully be continued.
        let metadata = try MetadataStore.temporary()
        let comet = ProjectRecord(
            id: UUID(), catalogID: "C2025_R3_Panstarrs_Wide", displayName: "C/2025 R3 (Panstarrs_Wide)",
            phase: .collecting
        )
        let good = ProjectRecord(id: UUID(), catalogID: "IC_1396", displayName: "Elefántormány-köd", phase: .collecting)
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        // The comet has FAR less collected time -- if the filter didn't run,
        // "least collected" would still pick it over `good`.
        let cometSeries = makeSeries(project: comet.id, night: night.id, exposure: 20)
        let goodSeries = makeSeries(project: good.id, night: night.id, exposure: 300)
        try await metadata.save(MetadataWriteBatch(projects: [comet, good], nights: [night], series: [cometSeries, goodSeries]))
        try await metadata.save(MetadataWriteBatch(frameDecisions: [
            FrameDecisionRecord(id: UUID(), seriesID: cometSeries.id, relativePath: "c.fit", verdict: .accepted, logicallyExcluded: false),
            FrameDecisionRecord(id: UUID(), seriesID: goodSeries.id, relativePath: "g.fit", verdict: .accepted, logicallyExcluded: false),
        ]))
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(tonightProvider: { _ in
            [
                TargetPlan(
                    target: comet.catalogID, displayName: comet.displayName,
                    usableIntegrationSeconds: 20, verdict: SkyVerdict.cometStaleCoordinate, score: 0.9
                ),
                TargetPlan(
                    target: good.catalogID, displayName: good.displayName,
                    usableIntegrationSeconds: 90_000, verdict: SkyVerdict.good, score: 0.4
                ),
            ]
        })

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 1)

        #expect(store.snapshot.nextProject == good)
    }

    @Test("Continue where it matters says so honestly when every active project is unshootable tonight")
    func continueWhereItMattersReportsWhenNothingQualifies() async throws {
        let metadata = try MetadataStore.temporary()
        let comet = ProjectRecord(
            id: UUID(), catalogID: "C2025_R3_Panstarrs_Wide", displayName: "C/2025 R3 (Panstarrs_Wide)",
            phase: .collecting
        )
        try await metadata.save(comet)
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(tonightProvider: { _ in
            [
                TargetPlan(
                    target: comet.catalogID, displayName: comet.displayName,
                    usableIntegrationSeconds: 20, verdict: SkyVerdict.cometStaleCoordinate, score: 0.9
                ),
            ]
        })

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 1)

        #expect(store.snapshot.nextProject == nil)
        #expect(store.snapshot.hasActiveProjectsExcludedTonight == true)
    }

    @Test("Home renders whatever the night-context provider reports, honestly, instead of a fixed fake dusk/dawn plot")
    func configureUsesNightContextProviderResult() async throws {
        // V2 UI/UX audit (2026-08-14) section 4: `HomeStore.configure` used
        // to carry `snapshot.nightContext` forward completely unchanged, so
        // `NightContextRail` always drew the same hardcoded-geometry dusk/
        // observation-window/dawn plot no matter what library was open.
        // `nightContextProvider` is the injection point that lets
        // `configure` ask for the real, per-library context (real site
        // coordinates resolved -> real dusk/dawn; no resolvable site ->
        // an honest "not configured" state) without this test needing a
        // real FITS-backed library.
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let expected = HomeSnapshot.NightContext(
            isConfigured: true, leadingLabel: "Dusk 21:04", centerLabel: "3h 12m to dawn",
            trailingLabel: "Dawn 05:16", nowFraction: 0.4
        )
        let store = HomeStore(
            tonightProvider: { _ in [] },
            nightContextProvider: { selectedRoot in
                #expect(selectedRoot == root)
                return expected
            }
        )

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)

        #expect(store.snapshot.nightContext == expected)
    }

    @Test("An unresolvable night context (no site, no rootURL) falls back to the honest unconfigured state")
    func configureFallsBackToUnconfiguredNightContext() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let store = HomeStore()

        await store.configure(libraryName: "Astro", projectsStore: projects, nightCount: 0)

        #expect(store.snapshot.nightContext == .unconfigured)
        #expect(store.snapshot.nightContext.isConfigured == false)
    }

    // MARK: - W4-2 (cloud forecast)

    @Test("Tonight's cloud picture lands on the snapshot after configure()")
    func configureLoadsNightCloud() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let store = HomeStore(
            tonightProvider: { _ in [] },
            weatherProvider: { _ in HomeSnapshot.NightCloud(duskPercent: 20, dawnPercent: 55, fetchedAt: fetchedAt) }
        )

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)
        await store.pendingWeatherLoad?.value

        #expect(store.snapshot.nightCloud?.duskPercent == 20)
        #expect(store.snapshot.nightCloud?.dawnPercent == 55)
        // Honesty check: the store must carry the fetch's own `fetchedAt`
        // through unchanged, even when it's the OLD timestamp a
        // cache-on-failure fallback would return -- never silently
        // re-stamped with "now".
        #expect(store.snapshot.nightCloud?.fetchedAt == fetchedAt)
        #expect(store.snapshot.nightCloudError == nil)
    }

    @Test("No site configured means no weather row and no error")
    func configureShowsNoRowWhenProviderReportsNothing() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(
            tonightProvider: { _ in [] },
            weatherProvider: { _ in nil }
        )

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)
        await store.pendingWeatherLoad?.value

        #expect(store.snapshot.nightCloud == nil)
        #expect(store.snapshot.nightCloudError == nil)
    }

    @Test("A fetch failure with no cached forecast surfaces the mapped error, not silence")
    func configureSurfacesWeatherFetchFailure() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(
            tonightProvider: { _ in [] },
            weatherProvider: { _ in throw WeatherError.decode }
        )

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)
        await store.pendingWeatherLoad?.value

        #expect(store.snapshot.nightCloud == nil)
        #expect(store.snapshot.nightCloudError == .decode)
    }

    @Test("A night beyond Open-Meteo's 7-day horizon reports honestly, not a stale dusk/dawn guess")
    func configureReportsBeyondHorizonHonestly() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(
            tonightProvider: { _ in [] },
            weatherProvider: { _ in HomeSnapshot.NightCloud(duskPercent: nil, dawnPercent: nil, fetchedAt: Date()) }
        )

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)
        await store.pendingWeatherLoad?.value

        #expect(store.snapshot.nightCloud?.duskPercent == nil)
        #expect(store.snapshot.nightCloud?.dawnPercent == nil)
    }

    private func makeSeries(project: UUID, night: UUID, exposure: Double) -> SeriesRecord {
        SeriesRecord(id: UUID(), projectID: project, nightID: night, setupID: nil,
            setupDescriptor: "Test", sensorMode: .osc, passband: .broadband,
            exposureSeconds: exposure, filterName: nil, filterID: nil, gain: nil,
            offset: nil, binning: "1x1")
    }
}

/// W5-2 finding 5 (owner pixel review): cold start on a spun-down SSD spent
/// ~10-20s with Home showing "No library open"/"Site not set" while the
/// library was already known and opening -- the empty state lied during
/// loading. `HomeLibraryLoading.isLoading` (`V2RootView.swift`) is the pure
/// predicate `DetailHost.isLibraryLoading` delegates to; tested directly
/// here (fixture booleans/URLs) rather than through a real
/// `OnboardingStore`/`HomeStore` pair, matching this codebase's usual
/// "extract the pure decision, test it directly" shape
/// (`ArchiveStripLayout`, `InsightTrendChartState`).
@MainActor
struct HomeLibraryLoadingTests {
    private let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)

    @Test("A configured-but-unopened library (root selected, Home not yet configured) is loading")
    func configuredButLoadingIsTrue() {
        #expect(HomeLibraryLoading.isLoading(selectedRoot: root, homeLibraryName: nil, hasAccessProblem: false))
    }

    @Test("No selected root at all -- genuinely unconfigured -- is never loading")
    func unconfiguredIsNeverLoading() {
        #expect(!HomeLibraryLoading.isLoading(selectedRoot: nil, homeLibraryName: nil, hasAccessProblem: false))
    }

    @Test("Once Home has been configured for the open library, it is no longer loading")
    func configuredHomeIsNotLoading() {
        #expect(!HomeLibraryLoading.isLoading(selectedRoot: root, homeLibraryName: "Astro", hasAccessProblem: false))
    }

    @Test("An access problem for the selected root means nothing is still in flight -- never a permanent spinner")
    func accessProblemIsNotLoading() {
        #expect(!HomeLibraryLoading.isLoading(selectedRoot: root, homeLibraryName: nil, hasAccessProblem: true))
    }
}
