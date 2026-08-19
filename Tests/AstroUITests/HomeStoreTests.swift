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
        // W7-A leftover (item 3b): `isGenuineCulmination` left unset (`nil`)
        // on this fixture -- exactly what every payload from before this
        // field existed decodes to -- must still read as genuine, not as a
        // window-edge sample.
        #expect(store.snapshot.tonightRecommendations[0].culminationDisplay == .genuine(localTime: "01:14"))
    }

    // MARK: - W7-A leftover (item 3b): honest culmination labeling

    @Test("A genuine culmination (isGenuineCulmination == true) renders as itself")
    func genuineCulminationRendersAsItself() async throws {
        let projects = ProjectsStore(metadataFactory: { _ in try MetadataStore.temporary() })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(tonightProvider: { _ in
            [TargetPlan(
                target: "IC_1396", displayName: "Elefántormány-köd",
                usableIntegrationSeconds: 7200,
                culminationLocal: "01:14", isGenuineCulmination: true, maxAltitudeDeg: 79,
                visibleWindowLocal: "22:10–03:36", visibleHours: 5.5,
                verdict: SkyVerdict.good, score: 0.92
            )]
        })

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 1)

        #expect(store.snapshot.tonightRecommendations.first?.culminationDisplay == .genuine(localTime: "01:14"))
    }

    @Test("A window-edge culmination still climbing at the window's own end never renders as a fake transit time")
    func windowEdgeCulminationStillRisingAtWindowEndRendersAsAfterWindow() async throws {
        let projects = ProjectsStore(metadataFactory: { _ in try MetadataStore.temporary() })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(tonightProvider: { _ in
            [TargetPlan(
                target: "IC_1396", displayName: "Elefántormány-köd",
                usableIntegrationSeconds: 7200,
                // The recorded "culmination" is exactly the window's own end
                // -- the target was still climbing when the scan stopped
                // looking, so its real transit lies past tonight's window.
                culminationLocal: "03:36", isGenuineCulmination: false, maxAltitudeDeg: 79,
                visibleWindowLocal: "22:10–03:36", visibleHours: 5.5,
                verdict: SkyVerdict.good, score: 0.92
            )]
        })

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 1)

        #expect(store.snapshot.tonightRecommendations.first?.culminationDisplay == .afterWindow)
    }

    @Test("A window-edge culmination already declining at the window's own start renders the window's own end, never a fake transit time")
    func windowEdgeCulminationAlreadyPastPeakAtWindowStartRendersWindowEnd() async throws {
        let projects = ProjectsStore(metadataFactory: { _ in try MetadataStore.temporary() })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(tonightProvider: { _ in
            [TargetPlan(
                target: "IC_1396", displayName: "Elefántormány-köd",
                usableIntegrationSeconds: 7200,
                // The recorded "culmination" is exactly the window's own
                // start -- the target was already declining from the very
                // first sample, so its real transit already happened before
                // the scan began.
                culminationLocal: "22:10", isGenuineCulmination: false, maxAltitudeDeg: 79,
                visibleWindowLocal: "22:10–03:36", visibleHours: 5.5,
                verdict: SkyVerdict.good, score: 0.92
            )]
        })

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 1)

        #expect(store.snapshot.tonightRecommendations.first?.culminationDisplay == .pastPeakAtWindowStart(windowEndLocal: "03:36"))
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

    // MARK: - W7-E workflow #1 (rating gate)

    @Test("An unrated-nights fixture surfaces the rating gate with the query's own numbers")
    func configureSurfacesRatingGateWhenSomethingIsUnrated() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(
            tonightProvider: { _ in [] },
            ratingGateProvider: { _ in HomeSnapshot.RatingGate(unratedNightCount: 3, sensorProfileMeasured: false) }
        )

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)

        #expect(store.snapshot.ratingGate.unratedNightCount == 3)
        #expect(store.snapshot.ratingGate.sensorProfileMeasured == false)
    }

    @Test("A fully rated library reports the honest clear rating gate -- the card has nothing to show")
    func configureReportsClearRatingGateWhenNothingIsUnrated() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(
            tonightProvider: { _ in [] },
            ratingGateProvider: { _ in .clear }
        )

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)

        #expect(store.snapshot.ratingGate.unratedNightCount == 0)
        #expect(store.snapshot.ratingGate == .clear)
    }

    @Test("A CR3-heavy library's unmeasurable frame count passes through the gate honestly")
    func configureSurfacesUnmeasurableFrameCount() async throws {
        // OWNER BUG (2026-08-19 real-library audit): 1550 CR3 frames sit
        // forever outside `unratedNightCount` (RatingCoverageQuery's own
        // fix), but the card must still be able to say WHY the gate never
        // reaches zero for them, rather than silently going quiet.
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(
            tonightProvider: { _ in [] },
            ratingGateProvider: { _ in
                HomeSnapshot.RatingGate(unratedNightCount: 2, sensorProfileMeasured: true, unmeasurableFrameCount: 1550)
            }
        )

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)

        #expect(store.snapshot.ratingGate.unmeasurableFrameCount == 1550)
    }

    @Test("No open library means no rating gate to compute, not a stale one carried forward")
    func configureFallsBackToClearRatingGateWithNoRoot() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let store = HomeStore()

        await store.configure(libraryName: "Astro", projectsStore: projects, nightCount: 0)

        #expect(store.snapshot.ratingGate == .clear)
    }

    // MARK: - W7-E workflow #2 (name the next clear night) -- pure decision

    @Test("A clear tonight names nothing -- there's no gate to drive through")
    func cloudOutlookIsQuietWhenTonightIsClear() throws {
        let outlook = HomeStore.cloudOutlook(
            tonightKey: "2026-08-18",
            dailySummaries: [
                "2026-08-18": DailyCloudSummary(date: "2026-08-18", minPercent: 10, maxPercent: 30, meanPercent: 20),
                "2026-08-19": DailyCloudSummary(date: "2026-08-19", minPercent: 80, maxPercent: 95, meanPercent: 90),
            ]
        )

        #expect(outlook.isCloudyTonight == false)
        #expect(outlook.nextClearNight == nil)
    }

    @Test("A cloudy tonight names the first later night whose own mean drops back under the threshold")
    func cloudOutlookNamesTheFirstQualifyingLaterNight() throws {
        let outlook = HomeStore.cloudOutlook(
            tonightKey: "2026-08-18",
            dailySummaries: [
                "2026-08-18": DailyCloudSummary(date: "2026-08-18", minPercent: 93, maxPercent: 100, meanPercent: 97),
                "2026-08-19": DailyCloudSummary(date: "2026-08-19", minPercent: 70, maxPercent: 85, meanPercent: 78),
                "2026-08-20": DailyCloudSummary(date: "2026-08-20", minPercent: 0, maxPercent: 73, meanPercent: 40),
                "2026-08-21": DailyCloudSummary(date: "2026-08-21", minPercent: 0, maxPercent: 10, meanPercent: 5),
            ]
        )

        #expect(outlook.isCloudyTonight == true)
        #expect(outlook.nextClearNight == .found(date: "2026-08-20", minPercent: 0, maxPercent: 73))
    }

    @Test("A cloudy tonight with no qualifying night in the whole 7-day horizon is honestly unavailable")
    func cloudOutlookIsHonestWhenNoLaterNightQualifies() throws {
        let outlook = HomeStore.cloudOutlook(
            tonightKey: "2026-08-18",
            dailySummaries: [
                "2026-08-18": DailyCloudSummary(date: "2026-08-18", minPercent: 93, maxPercent: 100, meanPercent: 97),
                "2026-08-19": DailyCloudSummary(date: "2026-08-19", minPercent: 70, maxPercent: 85, meanPercent: 78),
            ]
        )

        #expect(outlook.isCloudyTonight == true)
        #expect(outlook.nextClearNight == .unavailable)
    }

    @Test("Tonight missing from the daily summaries entirely reads as clear, never a guess")
    func cloudOutlookTreatsAMissingTonightAsClear() throws {
        let outlook = HomeStore.cloudOutlook(tonightKey: "2026-08-18", dailySummaries: [:])

        #expect(outlook.isCloudyTonight == false)
        #expect(outlook.nextClearNight == nil)
    }

    // MARK: - W7-E workflow #3 (cloudy night = darks night)

    @Test("A cloudy tonight with a non-empty shopping list is exactly what the darks card needs")
    func configureSurfacesCloudyNightWithMissingDarks() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(
            tonightProvider: { _ in
                [TargetPlan(target: "M31", displayName: "M31", usableIntegrationSeconds: 0, verdict: SkyVerdict.good, score: 0.5)]
            },
            calibCoverageProvider: { _ in
                [CalibNeed(
                    kind: .dark, exposureSeconds: 300, tempC: -10, lightCount: 68,
                    targets: ["M31"], matchedMasterPath: nil, masterAgeDays: nil, isStale: false,
                    todo: "Készíts 300 s / -10 °C darkot (68 light frame-hez)"
                )]
            },
            weatherProvider: { _ in
                HomeSnapshot.NightCloud(duskPercent: 95, dawnPercent: 98, fetchedAt: Date(), isCloudyTonight: true)
            }
        )

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)
        await store.pendingWeatherLoad?.value

        #expect(store.snapshot.nightCloud?.isCloudyTonight == true)
        #expect(!store.calibShoppingItems.isEmpty)
        #expect(store.calibShoppingItems.first?.targets == ["M31"])
    }

    @Test("A clear tonight never triggers the darks card, even with a non-empty shopping list")
    func configureNeverSurfacesDarksCardOnAClearNight() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(
            tonightProvider: { _ in
                [TargetPlan(target: "M31", displayName: "M31", usableIntegrationSeconds: 0, verdict: SkyVerdict.good, score: 0.5)]
            },
            calibCoverageProvider: { _ in
                [CalibNeed(
                    kind: .dark, exposureSeconds: 300, tempC: -10, lightCount: 68,
                    targets: ["M31"], matchedMasterPath: nil, masterAgeDays: nil, isStale: false,
                    todo: "Készíts 300 s / -10 °C darkot (68 light frame-hez)"
                )]
            },
            weatherProvider: { _ in
                HomeSnapshot.NightCloud(duskPercent: 10, dawnPercent: 15, fetchedAt: Date(), isCloudyTonight: false)
            }
        )

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)
        await store.pendingWeatherLoad?.value

        #expect(store.snapshot.nightCloud?.isCloudyTonight == false)
        #expect(!store.calibShoppingItems.isEmpty)
    }

    private func makeSeries(project: UUID, night: UUID, exposure: Double) -> SeriesRecord {
        SeriesRecord(id: UUID(), projectID: project, nightID: night, setupID: nil,
            setupDescriptor: "Test", sensorMode: .osc, passband: .broadband,
            exposureSeconds: exposure, filterName: nil, filterID: nil, gain: nil,
            offset: nil, binning: "1x1")
    }

    // MARK: - Expert ideation spec #5 (First-Light Anniversaries + honest
    // milestones): `composeHighlights`'s own priority/cap rule.

    @Test("Anniversaries and milestones both fit when there is room under the cap")
    func composeHighlightsKeepsBothWhenUnderCap() {
        let anniversary = AnniversaryHit(
            projectID: UUID(), catalogID: "IC 1805", displayName: "IC 1805", yearsAgo: 3, firstLightDate: "2023-08-19"
        )
        let milestone = MilestoneHit(
            projectID: UUID(), catalogID: "NGC 7000", displayName: "NGC 7000", thresholdHours: 100
        )

        let highlights = HomeStore.composeHighlights(anniversaries: [anniversary], milestones: [milestone])

        #expect(highlights.count == 2)
        #expect(highlights[0].kind == .anniversary(yearsAgo: 3))
        #expect(highlights[1].kind == .milestone(hours: 100))
    }

    @Test("Anniversaries outrank milestones outright -- a milestone is dropped once two anniversaries fill the card")
    func composeHighlightsPrioritizesAnniversariesOverMilestones() {
        let bigAnniversary = AnniversaryHit(
            projectID: UUID(), catalogID: "M 31", displayName: "M 31", yearsAgo: 5, firstLightDate: "2021-08-19"
        )
        let smallAnniversary = AnniversaryHit(
            projectID: UUID(), catalogID: "IC 1805", displayName: "IC 1805", yearsAgo: 1, firstLightDate: "2025-08-19"
        )
        let milestone = MilestoneHit(
            projectID: UUID(), catalogID: "NGC 7000", displayName: "NGC 7000", thresholdHours: 250
        )

        let highlights = HomeStore.composeHighlights(
            anniversaries: [bigAnniversary, smallAnniversary], milestones: [milestone]
        )

        #expect(highlights.count == 2)
        #expect(highlights.allSatisfy { if case .anniversary = $0.kind { true } else { false } })
    }

    @Test("Three anniversaries firing the same day show only the two largest")
    func composeHighlightsCapsAtTwo() {
        let anniversaries = [
            AnniversaryHit(projectID: UUID(), catalogID: "M 31", displayName: "M 31", yearsAgo: 5, firstLightDate: "2021-08-19"),
            AnniversaryHit(projectID: UUID(), catalogID: "IC 1805", displayName: "IC 1805", yearsAgo: 3, firstLightDate: "2023-08-19"),
            AnniversaryHit(projectID: UUID(), catalogID: "M 42", displayName: "M 42", yearsAgo: 1, firstLightDate: "2025-08-19"),
        ]

        let highlights = HomeStore.composeHighlights(anniversaries: anniversaries, milestones: [])

        #expect(highlights.count == 2)
        #expect(highlights.map(\.catalogID) == ["M 31", "IC 1805"])
    }

    @Test("An ordinary day with neither anniversaries nor milestones shows nothing")
    func composeHighlightsIsEmptyOnAnOrdinaryDay() {
        #expect(HomeStore.composeHighlights(anniversaries: [], milestones: []).isEmpty)
    }

    // MARK: - Ideation #9 ("Éjszaka-tanulságok banner"): lessons rank below
    // celebrations and share their same cap.

    @Test("A lesson shows when there is room under the cap, ranked after every anniversary/milestone")
    func composeHighlightsShowsLessonWhenThereIsRoom() {
        let anniversary = AnniversaryHit(
            projectID: UUID(), catalogID: "IC 1805", displayName: "IC 1805", yearsAgo: 2, firstLightDate: "2024-08-19"
        )
        let lesson = NightHealthLesson(kind: .coolerNotHoldingSetpoint, failingCount: 4, sessionCount: 6)

        let highlights = HomeStore.composeHighlights(anniversaries: [anniversary], milestones: [], lessons: [lesson])

        #expect(highlights.count == 2)
        #expect(highlights[0].kind == .anniversary(yearsAgo: 2))
        #expect(highlights[1].kind == .coolerLesson(failingCount: 4, sessionCount: 6))
    }

    @Test("A lesson is dropped entirely once two anniversaries/milestones already fill the card")
    func composeHighlightsDropsLessonWhenCelebrationsFillTheCap() {
        let anniversary = AnniversaryHit(
            projectID: UUID(), catalogID: "M 31", displayName: "M 31", yearsAgo: 5, firstLightDate: "2021-08-19"
        )
        let milestone = MilestoneHit(
            projectID: UUID(), catalogID: "NGC 7000", displayName: "NGC 7000", thresholdHours: 100
        )
        let lesson = NightHealthLesson(kind: .focusDrift, failingCount: 5, sessionCount: 8)

        let highlights = HomeStore.composeHighlights(
            anniversaries: [anniversary], milestones: [milestone], lessons: [lesson]
        )

        #expect(highlights.count == 2)
        #expect(!highlights.contains { $0.kind == .focusLesson(failingCount: 5, sessionCount: 8) })
    }

    @Test("Lessons alone (no celebrations at all) still show, up to the same cap")
    func composeHighlightsShowsLessonsAloneUpToCap() {
        let coolerLesson = NightHealthLesson(kind: .coolerNotHoldingSetpoint, failingCount: 4, sessionCount: 6)
        let focusLesson = NightHealthLesson(kind: .focusDrift, failingCount: 5, sessionCount: 8)

        let highlights = HomeStore.composeHighlights(anniversaries: [], milestones: [], lessons: [coolerLesson, focusLesson])

        #expect(highlights.count == 2)
        #expect(highlights[0].kind == .coolerLesson(failingCount: 4, sessionCount: 6))
        #expect(highlights[1].kind == .focusLesson(failingCount: 5, sessionCount: 8))
    }

    // MARK: - Expert ideation reserve #5 (Clear-Night Countdown)

    @Test("The featured project's own completion forecast is resolved for the SAME project 'next' names")
    func featuredCompletionForecastIsResolvedForTheNextProject() async throws {
        let project = ProjectRecord(
            id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting
        )
        let metadata = try MetadataStore.temporary()
        try await metadata.save(project)
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let expectedTarget = ProjectsQuery.canonicalFolderName(for: project)
        let estimate = CompletionForecastEstimate(nightsNeeded: 4, paceSecondsPerNight: 10_800, isCapped: false)
        let store = HomeStore(
            tonightProvider: { _ in [] },
            completionOutlookProvider: { selectedRoot, target in
                #expect(selectedRoot == root)
                #expect(target == expectedTarget)
                return estimate
            }
        )

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)

        #expect(store.snapshot.featuredCompletionForecast == estimate)
    }

    @Test("No active project at all means no completion forecast is even attempted")
    func featuredCompletionForecastIsNilWithoutANextProject() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(
            tonightProvider: { _ in [] },
            completionOutlookProvider: { _, _ in
                Issue.record("completionOutlookProvider must not be called with no next project to forecast")
                return nil
            }
        )

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)

        #expect(store.snapshot.featuredCompletionForecast == nil)
    }

    @Test("A later weather update never clobbers the featured completion forecast configure() already resolved")
    func weatherUpdatePreservesFeaturedCompletionForecast() async throws {
        let project = ProjectRecord(
            id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting
        )
        let metadata = try MetadataStore.temporary()
        try await metadata.save(project)
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let estimate = CompletionForecastEstimate(nightsNeeded: 6, paceSecondsPerNight: 7200, isCapped: false)
        let store = HomeStore(
            tonightProvider: { _ in [] },
            weatherProvider: { _ in HomeSnapshot.NightCloud(duskPercent: 10, dawnPercent: 20, fetchedAt: Date(), clearNightsInHorizon: 2) },
            completionOutlookProvider: { _, _ in estimate }
        )

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)
        await store.pendingWeatherLoad?.value

        #expect(store.snapshot.featuredCompletionForecast == estimate)
        #expect(store.snapshot.nightCloud?.clearNightsInHorizon == 2)
    }

    @Test("No weather at all leaves clearNightsInHorizon nil, distinct from a genuine zero")
    func noWeatherLeavesClearNightsInHorizonNil() async throws {
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
    }

    // MARK: - Pre-flight Checklist (ideation #1, "Indulás előtti lista")
    //
    // `PreflightChecklistTests` (AstroApplicationTests) already exercises
    // `PreflightChecklist.build`'s own pure ✓/✗/n-a rules directly with
    // fixture values. These tests instead pin `HomeStore.preflightChecklist`
    // -- the seam that unpacks a REAL, `configure()`-loaded `HomeSnapshot`/
    // `calibShoppingItems` into that pure function's plain-value inputs --
    // so a future change to what `configure()` resolves can't silently
    // stop reaching the checklist at all.

    @Test("A library with current calibration, a clear sky, and no Moon interference is all-clear")
    func preflightChecklistIsAllClearForAHealthyLibrary() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(
            tonightProvider: { _ in
                [TargetPlan(
                    target: "IC_1396", displayName: "Elefántormány-köd", usableIntegrationSeconds: 0,
                    visibleWindowLocal: "21:48–01:23", verdict: SkyVerdict.good, score: 0.9
                )]
            },
            calibCoverageProvider: { _ in [] },
            weatherProvider: { _ in HomeSnapshot.NightCloud(duskPercent: 10, dawnPercent: 15, fetchedAt: Date(), isCloudyTonight: false) }
        )

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)
        await store.pendingWeatherLoad?.value

        #expect(store.preflightChecklist.allClear)
    }

    @Test("A real calibration shortfall reaches the checklist as its own red line")
    func preflightChecklistSurfacesRealCalibrationShortfall() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(
            tonightProvider: { _ in
                [TargetPlan(target: "M31", displayName: "M31", usableIntegrationSeconds: 0, verdict: SkyVerdict.good, score: 0.5)]
            },
            calibCoverageProvider: { _ in
                [CalibNeed(
                    kind: .dark, exposureSeconds: 300, tempC: -10, lightCount: 68,
                    targets: ["M31"], matchedMasterPath: nil, masterAgeDays: nil, isStale: false,
                    todo: "Készíts 300 s / -10 °C darkot (68 light frame-hez)"
                )]
            }
        )

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)

        let calibItem = store.preflightChecklist.items.first {
            if case .calibrationCurrent = $0.kind { true } else { false }
        }
        #expect(calibItem?.status == .attention)
        #expect(!store.preflightChecklist.allClear)
    }

    @Test("No open library means no weather/tonight plan was ever fetched -- the sky/Moon/altitude lines read n/a, never a red ✗")
    func preflightChecklistIsHonestlyNotApplicableWithNoOpenLibrary() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let store = HomeStore()

        await store.configure(libraryName: "Astro", projectsStore: projects, nightCount: 0)

        let checklist = store.preflightChecklist
        let skyItem = checklist.items.first { $0.kind == .skyClear }
        let moonItem = checklist.items.first { if case .moonImpact = $0.kind { true } else { false } }
        let altitudeItem = checklist.items.first { if case .altitudeWindow = $0.kind { true } else { false } }
        #expect(skyItem?.status == .notApplicable)
        #expect(moonItem?.status == .notApplicable)
        #expect(altitudeItem?.status == .notApplicable)
        #expect(checklist.items.allSatisfy { $0.status != .attention })
    }

    @Test("A cloudy tonight fetched by the real weather provider reaches the checklist as its own red sky line")
    func preflightChecklistSurfacesRealCloudyForecast() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(
            tonightProvider: { _ in [] },
            weatherProvider: { _ in HomeSnapshot.NightCloud(duskPercent: 92, dawnPercent: 97, fetchedAt: Date(), isCloudyTonight: true) }
        )

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)
        await store.pendingWeatherLoad?.value

        let skyItem = store.preflightChecklist.items.first { $0.kind == .skyClear }
        #expect(skyItem?.status == .attention)
    }

    @Test("A Moon-interferes verdict on the real top tonight recommendation reaches the checklist as its own red Moon line")
    func preflightChecklistSurfacesRealMoonInterference() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(tonightProvider: { _ in
            [TargetPlan(
                target: "M 42", displayName: "M 42", usableIntegrationSeconds: 0,
                visibleWindowLocal: "20:00–23:00",
                verdict: SkyVerdict.moonInterferes(separationDeg: 34, illuminationPercent: 62), score: 0.8
            )]
        })

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)

        let moonItem = store.preflightChecklist.items.first { if case .moonImpact = $0.kind { true } else { false } }
        #expect(moonItem?.status == .attention)
        if case let .moonImpact(separationDeg, illuminationPercent) = moonItem?.kind {
            #expect(separationDeg == 34)
            #expect(illuminationPercent == 62)
        } else {
            Issue.record("Expected a .moonImpact item")
        }
    }

    @Test("The real top tonight recommendation's own visible window feeds the altitude line's clear time")
    func preflightChecklistReadsRealVisibleWindowStart() async throws {
        let metadata = try MetadataStore.temporary()
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(tonightProvider: { _ in
            [TargetPlan(
                target: "IC_1396", displayName: "IC 1396", usableIntegrationSeconds: 0,
                visibleWindowLocal: "21:48–01:23", verdict: SkyVerdict.good, score: 0.9
            )]
        })

        await store.configure(libraryName: "Astro", rootURL: root, projectsStore: projects, nightCount: 0)

        let altitudeItem = store.preflightChecklist.items.first { if case .altitudeWindow = $0.kind { true } else { false } }
        #expect(altitudeItem?.status == .ready)
        if case let .altitudeWindow(targetDisplayName, clearsAtLocal) = altitudeItem?.kind {
            #expect(targetDisplayName == "IC 1396")
            #expect(clearsAtLocal == "21:48")
        } else {
            Issue.record("Expected a .altitudeWindow item")
        }
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
