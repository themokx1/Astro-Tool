import SwiftUI
import AstroApplication
import AstroCore
import UniformTypeIdentifiers

public struct HomeView: View {
    @Bindable private var store: HomeStore
    private let rootURL: URL?
    /// W5-2 finding 5 (owner pixel review): true while a configured library
    /// (one `V2RootView`'s `onboardingStore` already knows the root of) is
    /// still being opened/scanned/materialized -- the ~10-20s window a cold
    /// start on a spun-down SSD spent, in the owner's own report, before
    /// `store.snapshot` ever stops being `.unconfigured`. See
    /// `V2RootView.DetailHost.isLibraryLoading`'s own doc comment for
    /// exactly how this is derived. Distinguishes "a library IS configured,
    /// just not open yet" from the genuine "nothing configured at all" case
    /// `emptyLibrary` below still owns.
    private let isLibraryLoading: Bool
    private let chooseLibrary: () -> Void
    private let openProject: (ProjectRecord) -> Void
    private let openProjectID: (UUID) -> Void
    /// W7-E workflow #1: the rating-gate card's secondary action -- pushes
    /// the Sensor Profiles screen so the owner can close the "szenzorprofil
    /// nincs mérve" half of the gate the "Rate Everything" button itself
    /// can't (that button only ever invokes `FrameRatingCommand`, never
    /// `SensorMeasurementCommand` -- two different measurements, two
    /// different entry points, same as `ProjectsView`/`NightActionMenu`
    /// already keep them).
    private let openSensorProfiles: () -> Void
    /// W7-E workflow #3: the "cloudy night = darks night" card's action --
    /// pushes the Calibration screen where the missing/stale masters
    /// `CalibShoppingList` already lists can actually be worked.
    private let openCalibration: () -> Void
    /// W7-E workflow #2: the "name the next clear night" line's link --
    /// pushes the Nights calendar, the same screen `NightsView`'s own
    /// per-date "Cloud" column already renders this exact min-max forecast
    /// against.
    private let openNightsCalendar: () -> Void
    @AppStorage("v2.general.showGuidance") private var showGuidance = true
    /// Wave W6-A section B: the "nothing to shoot tonight, no site
    /// configured" placeholder's own escape hatch -- the same
    /// `@Environment(\.openSettings)` pattern `V2RootView`'s own calls use
    /// everywhere else a placeholder points at Settings.
    @Environment(\.openSettings) private var openSettings
    /// W7-E workflow #1: backs the rating-gate card's "Rate Everything"
    /// button -- reuses `ProjectRatingRunner`, the exact same batching layer
    /// over `FrameRatingCommand` that `ProjectsView`'s own "Rate All
    /// Projects" button uses, so there is exactly one rating pipeline, not a
    /// second one reinvented for Home. Also lets the card watch
    /// `activeOperations` for that same operation's progress instead of
    /// keeping its own separate "is it running" state.
    @Environment(OperationHost.self) private var operationHost

    public init(
        store: HomeStore,
        rootURL: URL? = nil,
        isLibraryLoading: Bool = false,
        chooseLibrary: @escaping () -> Void,
        openProject: @escaping (ProjectRecord) -> Void,
        openProjectID: @escaping (UUID) -> Void = { _ in },
        openSensorProfiles: @escaping () -> Void = {},
        openCalibration: @escaping () -> Void = {},
        openNightsCalendar: @escaping () -> Void = {}
    ) {
        _store = Bindable(store)
        self.rootURL = rootURL
        self.isLibraryLoading = isLibraryLoading
        self.chooseLibrary = chooseLibrary
        self.openProject = openProject
        self.openProjectID = openProjectID
        self.openSensorProfiles = openSensorProfiles
        self.openCalibration = openCalibration
        self.openNightsCalendar = openNightsCalendar
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.spacious) {
                header
                NightContextRail(
                    context: store.snapshot.nightContext,
                    cloud: store.snapshot.nightCloud,
                    cloudError: store.snapshot.nightCloudError,
                    isLoading: isLibraryLoading,
                    // Wave W6-A section C: the rail renders unconditionally,
                    // above the `store.snapshot.libraryName == nil` branch
                    // right below -- so its own "no site" copy needs the same
                    // signal that branch already uses, to tell "no library at
                    // all" (Settings ▸ Location is locked, nothing to point
                    // at) apart from "library open, no site yet" (the
                    // pointer is honest there).
                    hasLibrary: store.snapshot.libraryName != nil,
                    openNightsCalendar: openNightsCalendar
                )
                if store.snapshot.libraryName == nil {
                    if isLibraryLoading {
                        openingLibrary
                    } else {
                        emptyLibrary
                    }
                } else {
                    libraryOverview
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(AstroTokens.Spacing.spacious)
        }
        // Task 7b (2026-08-17): the 36% `ground` self-tint is gone, not
        // made opaque. This view is only ever rendered inside `V2RootView`'s
        // detail column, which now owns the page backdrop for all 21 routes
        // -- see the `.background(AstroTokens.Color.ground)` there.
        .navigationTitle("Home")
        .accessibilityLabel("Home")
        .accessibilityIdentifier("v2.detail.home")
    }

    private var libraryOverview: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            HStack(spacing: AstroTokens.Spacing.standard) {
                MetricCard(title: "Projects", value: "\(store.snapshot.projectCount)", detail: "In \(store.snapshot.libraryName ?? "library")", systemImage: "scope")
                // W6-E item 3: "Indexed observing sessions" read as though
                // this counted the same thing Insights' own session count
                // does -- it doesn't. This is the deduplicated, one-row-
                // per-calendar-date count (`HomeStore.HomeSnapshot
                // .nightCount`'s own doc comment), the smallest of this
                // app's three "night-shaped" numbers by design.
                MetricCard(title: "Nights", value: "\(store.snapshot.nightCount)", detail: "Deduplicated calendar nights", systemImage: "moon.stars")
            }
            highlightsCard
            // Task 7 (2026-08-17, GroupBox removal): a heading plus spacing,
            // not a box on a box -- `GroupBox` painted macOS's default
            // opaque grey panel here, which is exactly the "strange grey
            // background" the owner reported.
            //
            // Task 7c: "no GroupBox" left this as bare text on the grey
            // backdrop, which is the opposite failure. It is a real content
            // block -- a heading, a recommendation, an action -- so it gets
            // the one raised surface, lighter than `ground` rather than
            // `GroupBox`'s grey-over-white.
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                Text("Continue where it matters").font(.headline)
                if let project = store.snapshot.nextProject {
                    HStack(spacing: 14) {
                        Image(systemName: "arrow.forward.circle.fill")
                            .font(.title2).foregroundStyle(AstroTokens.Color.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.displayName).font(.headline)
                            // Two distinct `Text("literal")` branches, not a
                            // ternary of two literals -- a ternary infers
                            // `String`, not `LocalizedStringKey` (same trap
                            // `planExportMenu`'s own comment below documents,
                            // and `PlanningView`'s Save/Saved fix works
                            // around a second way -- see
                            // `LocalizationCoverageTests.saveTargetLocalizesDespiteTernary`).
                            if project.phase == .collecting {
                                Text("Least collected active project · \(AstroFormat.duration(seconds: store.snapshot.nextProjectIntegrationSeconds)) so far.")
                                    .font(.callout).foregroundStyle(.secondary)
                                if let caption = featuredClearNightCaption {
                                    caption
                                        .font(.caption).foregroundStyle(.secondary)
                                        .accessibilityIdentifier("v2.home.featured-clear-night")
                                }
                            } else {
                                Text("Open the project and plan its first capture series.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Open Project") {
                            openProject(project)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("v2.home.open-project")
                    }
                } else if store.snapshot.hasActiveProjectsExcludedTonight {
                    // Task 1 (owner feedback wave 3): the owner's own words --
                    // a comet with a stale coordinate was recommended as
                    // "least collected active project" with an Open Project
                    // button, even though it can't meaningfully be continued.
                    // "Least collected" must never mean "least collected
                    // among things you cannot shoot" -- when nothing
                    // qualifies, say so instead of picking the worst
                    // candidate.
                    ContentUnavailableView {
                        Label("Nothing continuable tonight", systemImage: "moon.zzz")
                    } description: {
                        Text("Every active project's target is one the app already knows it cannot point at right now -- a comet with a stale coordinate, a missing coordinate, or an altitude too low tonight.")
                    }
                    .frame(minHeight: 140)
                } else {
                    Text("Create a project to start planning your next night.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .astroRaisedSurface()
            ratingGateCard
            tonightRecommendations
            cloudyDarksCard
        }
        .accessibilityIdentifier("v2.home.library-overview")
    }

    /// Expert ideation spec #5 ("First-Light Anniversaries + honest
    /// milestones"): the card the owner screenshots -- real dates, real
    /// integration-hour thresholds, zero invented scoring. Renders nothing
    /// on an ordinary day (`store.snapshot.highlights.isEmpty`), the same
    /// only-when-there's-something-real pattern `ratingGateCard`/
    /// `cloudyDarksCard` already follow. `HomeStore.composeHighlights`
    /// already capped/prioritized this list -- this view only ever renders
    /// what it was handed, never counts or re-sorts anything itself.
    @ViewBuilder
    private var highlightsCard: some View {
        let highlights = store.snapshot.highlights
        if !highlights.isEmpty {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                Text("Worth celebrating").font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(highlights) { highlight in
                        HStack(spacing: 8) {
                            Image(systemName: highlightSystemImage(highlight.kind))
                                .foregroundStyle(AstroTokens.Color.accent)
                            highlightText(highlight)
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .astroRaisedSurface()
            .accessibilityIdentifier("v2.home.highlights")
        }
    }

    /// Expert ideation reserve #5 ("Clear-Night Countdown"): the "Continue
    /// where it matters" card's own extra caption line, "~6 clear nights to
    /// the goal · 2 chances this week" -- only rendered when BOTH real
    /// numbers exist (`store.snapshot.featuredCompletionForecast`, the
    /// featured project's own pace-based estimate, AND
    /// `nightCloud?.clearNightsInHorizon`, this library's fetched 7-day
    /// weather); `nil` whenever either is missing, so a library with
    /// weather disabled (or too little session history for a pace) simply
    /// shows no extra line rather than a half-true one. Deliberately never
    /// shows the "if this rate holds ~N weeks" extrapolation
    /// `ProjectWorkspaceView`'s own Overview forecast row does -- a
    /// one-line dashboard caption has no room for the qualifying language
    /// that soft projection needs to stay honest (`ClearNightOutlook`'s own
    /// doc comment), so this only ever states the two hard facts.
    private var featuredClearNightCaption: Text? {
        guard let estimate = store.snapshot.featuredCompletionForecast,
              let clearNights = store.snapshot.nightCloud?.clearNightsInHorizon
        else { return nil }
        // Same "+"-suffix-when-capped convention `ProjectWorkspaceView
        // .completionForecastText` already uses for this exact estimate.
        let nightsText = estimate.isCapped
            ? "\(AstroFormat.count(estimate.nightsNeeded))+"
            : AstroFormat.count(estimate.nightsNeeded)
        let chancesText = AstroFormat.count(clearNights)
        return Text("~\(nightsText) clear nights to the goal · \(chancesText) chances this week")
    }

    private func highlightSystemImage(_ kind: HomeSnapshot.Highlight.Kind) -> String {
        switch kind {
        case .anniversary: "birthday.cake.fill"
        case .milestone: "trophy.fill"
        }
    }

    /// Both branches interpolate ONLY pre-formatted `String`s
    /// (`String(yearsAgo)`/`String(hours)`, `highlight.displayName` is
    /// already one) -- an `Int` interpolated straight into a
    /// `LocalizedStringKey` emits a `%lld` runtime key while this
    /// codebase's own extraction script normalizes every interpolation to
    /// `%@` (see `NightContextRail`'s "Nearest clear night" comment for the
    /// same rule applied there); pre-formatting keeps the hand-added
    /// `hu.lproj` key matching what actually renders at runtime.
    private func highlightText(_ highlight: HomeSnapshot.Highlight) -> Text {
        switch highlight.kind {
        case .anniversary(let yearsAgo):
            Text("\(String(yearsAgo)) years ago today: first light on \(highlight.displayName)")
        case .milestone(let hours):
            Text("Reached the \(String(hours))-hour milestone on \(highlight.displayName)")
        }
    }

    /// W7-E workflow #1 (2026-08-18 owner audit, "rating is the gate on half
    /// the app, and nothing drives you through it"): the drive-through card
    /// -- states `HomeSnapshot.RatingGate`'s own numbers (never counted
    /// here), offers ONE button that runs the exact same
    /// `ProjectRatingRunner` batching layer `ProjectsView`'s "Rate All
    /// Projects" button already uses, and disappears once nothing is
    /// unrated. `FrameRatingCommand`/`ProjectRatingRunner` are never invoked
    /// a second, Home-specific way -- this only adds the invocation, not a
    /// new rating path.
    @ViewBuilder
    private var ratingGateCard: some View {
        let gate = store.snapshot.ratingGate
        if gate.unratedNightCount > 0 {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                Text("Frame rating").font(.headline)
                ratingGateMessage(gate)
                    .font(.callout).foregroundStyle(.secondary)
                if let ratingOperation {
                    HStack(spacing: 8) {
                        ProgressView(
                            value: ratingOperation.total.map { Double(ratingOperation.completed) / Double(max($0, 1)) }
                        )
                        if let total = ratingOperation.total {
                            Text(verbatim: "\(ratingOperation.completed) / \(total)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("v2.home.rating-gate-progress")
                } else {
                    HStack(spacing: AstroTokens.Spacing.standard) {
                        Button("Rate Everything") { runRatingGate() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("v2.home.rating-gate-run")
                        if !gate.sensorProfileMeasured {
                            Button("Measure Sensor Profile…", action: openSensorProfiles)
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("v2.home.rating-gate-sensor")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .astroRaisedSurface()
            .accessibilityIdentifier("v2.home.rating-gate")
        }
    }

    /// "N nights still have unrated frames", plus " · No sensor profile has
    /// been measured yet" when true -- two distinct `Text` values combined
    /// with `+`, not a ternary of two literals (the same trap this file's
    /// own `libraryOverview` comment above already documents), so the
    /// sensor clause's own presence/absence can never silently break
    /// localization.
    @ViewBuilder
    private func ratingGateMessage(_ gate: HomeSnapshot.RatingGate) -> some View {
        let nightsPart = Text("\(gate.unratedNightCount) nights still have unrated frames")
        if gate.sensorProfileMeasured {
            nightsPart
        } else {
            nightsPart + Text(verbatim: " · ") + Text("No sensor profile has been measured yet")
        }
    }

    /// The `ProjectRatingRunner` operation this card's own "Rate Everything"
    /// button would start (or already did) -- looked up by
    /// `ProjectRatingRunner.kind(for:)` so this can never drift from the
    /// exact key that function registers under, including when the SAME
    /// operation was started from `ProjectsView`'s "Rate All Projects"
    /// button instead: either entry point coalesces into one tracked run.
    private var ratingOperation: OperationHost.ActiveOperation? {
        guard let rootURL else { return nil }
        let kind = ProjectRatingRunner.kind(for: .allProjects(libraryName: rootURL.lastPathComponent))
        return operationHost.activeOperations.first { $0.kind == kind }
    }

    private func runRatingGate() {
        guard let rootURL else { return }
        Task {
            await ProjectRatingRunner.run(
                scope: .allProjects(libraryName: rootURL.lastPathComponent),
                rootURL: rootURL,
                metadataFactory: ProjectsStore.productionMetadata,
                operationHost: operationHost
            )
        }
    }

    /// W7-E workflow #3 (2026-08-18 owner audit, "cloudy night = darks
    /// night"): tonight being cloudy is exactly the night to shoot the
    /// calibration frames `CalibShoppingList` already knows this library is
    /// missing -- data `HomeStore.configure` already computed for the
    /// export menu's "Copy Calibration Shopping List" item; this only adds
    /// the visible push, never a second shopping-list computation.
    @ViewBuilder
    private var cloudyDarksCard: some View {
        if store.snapshot.nightCloud?.isCloudyTonight == true, !store.calibShoppingItems.isEmpty {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                Text("Cloudy night, clear task").font(.headline)
                Text("Tonight looks cloudy — a good night to shoot the calibration frames this library is still missing.")
                    .font(.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(store.calibShoppingItems.prefix(3).enumerated()), id: \.offset) { _, item in
                        // `item.summary` is domain data (already a composed
                        // Hungarian sentence with real target names, e.g.
                        // "Készíts 300 s / -10 °C darkot (68 light
                        // frame-hez) — M31, M42 használná") -- verbatim, same
                        // convention `NightRow.filterSummary`/`point
                        // .filterLabel` already use for arbitrary equipment/
                        // calibration text that isn't UI vocabulary.
                        Text(item.summary).font(.caption)
                    }
                }
                Button("Open Calibration…", action: openCalibration)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("v2.home.cloudy-darks-open")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .astroRaisedSurface()
            .accessibilityIdentifier("v2.home.cloudy-darks")
        }
    }

    private var tonightRecommendations: some View {
        // Task 7 (2026-08-17, GroupBox removal): same heading-plus-spacing
        // fix as `libraryOverview` above -- the header row (title, info
        // button, export menu) is `ReviewWorkspace.frameReview`'s own
        // "HStack header, Divider, content" shape, not a `GroupBox` label.
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            HStack {
                Text("Best targets tonight").font(.headline)
                MetricInfoButton(metrics: Self.tonightMetricInfo)
                Spacer()
                ExportMenu(
                    title: "Export Plan",
                    systemImage: "square.and.arrow.up",
                    items: planExportItems,
                    accessibilityID: "v2.home.plan-export"
                )
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Divider()
            planExportMenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Task 7c: same reasoning as `libraryOverview`'s "Continue where it
        // matters" block above -- a heading, a divider and a list of rows is
        // a content block, and a content block belongs on the raised layer.
        .astroRaisedSurface()
        .accessibilityIdentifier("v2.home.tonight-recommendations")
    }

    private var planExportItems: [ExportMenuItem] {
        guard let rootURL else { return [] }
        let plans = store.tonightPlans
        let shoppingItems = store.calibShoppingItems
        return [
            .file(title: "Plan CSV…", systemImage: "tablecells", contentType: .commaSeparatedText) {
                let export = try ExportService.production(rootURL: rootURL).planCSV(plans: plans)
                return (export.content, export.suggestedFilename, [])
            },
            .clipboard(title: "Copy Plan", systemImage: "doc.on.clipboard") {
                try ExportService.production(rootURL: rootURL).planClipboardText(plans: plans)
            },
            .clipboard(title: "Copy Calibration Shopping List", systemImage: "list.bullet.clipboard") {
                try ExportService.production(rootURL: rootURL).calibShoppingListMarkdown(items: shoppingItems)
            },
        ]
    }

    @ViewBuilder private var planExportMenu: some View {
        if store.snapshot.tonightRecommendations.isEmpty {
            // Task 1 (owner feedback wave 3): after filtering out targets the
            // shared `SkyVerdict` engine already knows can't be shot tonight
            // (comet stale coordinate, no coordinate, low altitude), this
            // library may legitimately have nothing left to recommend. An
            // empty, explained list is the honest outcome here -- not a list
            // padded with unusable rows, and not a silent blank box either.
            ContentUnavailableView {
                Label("Nothing to shoot tonight", systemImage: "sparkles.slash")
            } description: {
                // Two distinct `Text("literal")` branches, not a ternary of
                // two literals -- a ternary infers `String`, not
                // `LocalizedStringKey`, and would silently stop localizing
                // (see `LocalizationCoverageTests.saveTargetLocalizesDespiteTernary`).
                if store.snapshot.nightContext.isConfigured {
                    Text("Every target in this library is one the app already knows it cannot point at right now -- a comet with a stale coordinate, a missing coordinate, or an altitude too low tonight.")
                } else {
                    Text("Add a site or scan FITS coordinates to enable tonight planning.")
                }
            } actions: {
                // Wave W6-A section B: `libraryOverview` (this panel's own
                // parent) only renders once a library is open, so Settings ▸
                // Location is never locked here -- see this view's own
                // `body` switch above. Only offered for the "no site" branch;
                // a comet/altitude verdict has no Settings panel that fixes it.
                if !store.snapshot.nightContext.isConfigured {
                    Button("Open Settings…") { openSettings() }.buttonStyle(.borderedProminent)
                }
            }
            .frame(minHeight: 160)
        } else {
            VStack(spacing: 0) {
                ForEach(store.snapshot.tonightRecommendations) { recommendation in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(recommendation.displayName).font(.headline)
                            recommendationDetailText(recommendation)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        // `HomeTonightRecommendation.verdict` is still
                        // `Planner.plan`'s own raw Hungarian sentence (V1/CLI's
                        // own consumer, unchanged) -- `SkyVerdict.parse(...)`
                        // gives the structured `SkyVerdictKind` `PlanningView`
                        // also renders from. W3-9: `.english` used to be
                        // rendered directly (a domain-layer `String`, so
                        // `Text(String)` always chose the verbatim overload,
                        // "good tonight" leaking straight through the
                        // Hungarian UI) -- `.displayLabel` maps the case to a
                        // `LocalizedStringKey` instead, at this view layer
                        // (see `PlanningStore.swift`'s `SkyVerdictKind`
                        // extension, next to `PlanningFit.displayLabel`).
                        Text(SkyVerdict.parse(recommendation.verdict).displayLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AstroTokens.Color.accent)
                        if let projectID = recommendation.projectID {
                            Button("Open") { openProjectID(projectID) }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("v2.home.open-recommendation.\(recommendation.id)")
                        }
                    }
                    .padding(.vertical, 9)
                    if recommendation.id != store.snapshot.tonightRecommendations.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    /// W3-9: this used to be a single `Text(String)` built by joining an
    /// array of optionally-`nil` interpolated `String` fragments
    /// ("Visible …", "Culminates …", "…° max") with `" · "` -- exactly the
    /// store/view-composed-`String` leak this task's own doc names, and
    /// invisible to the extraction script twice over (the fragments are
    /// nested inside a `.map` closure, and the whole thing is joined before
    /// ever reaching `Text`). Building one `Text` per present fragment and
    /// concatenating them with `+` keeps each fragment a real `Text("…")`
    /// literal call site -- the same recipe `ArchiveVerdictHeader.reclaimText`
    /// already uses for its own two-clause sentence.
    @ViewBuilder
    private func recommendationDetailText(_ recommendation: HomeTonightRecommendation) -> some View {
        let parts: [Text] = [
            recommendation.visibleWindow.map { Text("Visible \($0)") },
            culminationText(recommendation.culminationDisplay),
            recommendation.maxAltitude.map { Text("\($0.formatted(.number.precision(.fractionLength(0))))° max") },
        ].compactMap { $0 }
        if let first = parts.first {
            parts.dropFirst().reduce(first) { $0 + Text(verbatim: " · ") + $1 }
        } else {
            Text(verbatim: "")
        }
    }

    /// W7-A leftover (item 3b): renders `HomeTonightRecommendation
    /// .culminationDisplay` instead of `Text("Culminates \(culmination)")`
    /// -- `PlanningCulminationDisplay.derive(...)`'s own doc explains why a
    /// window-edge sample (`isGenuineCulmination == false`) must never be
    /// presented as a real "Culminates HH:mm" transit time. `nil` omits the
    /// fragment entirely, exactly like `recommendation.culmination.map {
    /// ... }` used to for a target with no culmination at all -- this is the
    /// same "omit rather than guess" contract for the two additional honest
    /// cases (`.none`/`.unknownDirection`).
    private func culminationText(_ display: PlanningCulminationDisplay) -> Text? {
        switch display {
        case .none, .unknownDirection:
            return nil
        case let .genuine(localTime):
            // W7-F item 1: a genuine (inside-window) culmination is exactly
            // when `PlanningCulminationDisplay.suggestsMeridianFlip` is true
            // (see that property's own doc) -- a GEM-class mount is likely
            // to need a meridian flip mid-capture. Mount-agnostic honesty
            // (no pier-side/mount-type data exists), not a scheduler.
            return Text("Culminates \(localTime) — meridian flip likely")
        case .afterWindow:
            return Text("Culminates after tonight's window")
        case let .pastPeakAtWindowStart(windowEndLocal):
            return Text("Window ends \(windowEndLocal)")
        }
    }

    /// Backs the "Best targets tonight" header's ⓘ button.
    private static let tonightMetricInfo: [MetricInfoButton.Metric] = [
        .init(title: "Culmination", explanation: "When the target crosses the meridian at its highest altitude this night -- usually the best time to capture it.", glossaryTerm: "Culmination"),
        .init(title: "Max altitude", explanation: "The target's highest point above the horizon tonight. A higher altitude means a shorter, clearer path through the atmosphere.", glossaryTerm: "Airmass"),
        .init(title: "Verdict", explanation: "A short, honest summary of tonight's visibility for this target, combining its visible window and altitude."),
    ]

    private var header: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("OBSERVATORY WORKSPACE")
                .astroMicro()
                .foregroundStyle(AstroTokens.Color.accent)
            Text("Prepare the next clear night")
                .font(.largeTitle.weight(.semibold))
            if showGuidance {
                Text("Keep plans, observing nights, and library health in one quiet workspace.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("v2.home.guidance-caption")
            }
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No library open", systemImage: "sparkles.rectangle.stack")
        } description: {
            Text("Choose an image folder, then explore the Library workspace through a local, read-only index.")
        } actions: {
            Button("Choose Image Library…", action: chooseLibrary)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Choose Image Library")
        }
        .frame(maxWidth: .infinity, minHeight: 250)
    }

    /// W5-2 finding 5 (owner pixel review): a configured library is still
    /// opening -- same `ProgressView(title)` shape `InsightsView`/
    /// `ArchiveView`/every other loading state in this app already uses,
    /// never `emptyLibrary`'s "choose a library" prompt, which would tell
    /// the owner to pick a library the app is already opening.
    private var openingLibrary: some View {
        ProgressView("Opening the library…")
            .frame(maxWidth: .infinity, minHeight: 250)
            .accessibilityIdentifier("v2.home.opening-library")
    }
}

/// V2 UI/UX audit (2026-08-14) section 4: this used to draw a dusk/
/// observation-window/dawn timeline from hardcoded, fixed fractions of the
/// available width, with permanently fixed labels -- nothing ever supplied
/// it real data, so it read as a genuine plot while always showing the same
/// thing regardless of which library was open or what time it was. It now
/// renders `context`'s own `isConfigured` flag honestly: a real dusk-to-dawn
/// bar with a real "now" marker when a site resolved, or a plain
/// unconfigured state -- never a decorative fake plot.
private struct NightContextRail: View {
    let context: HomeSnapshot.NightContext
    /// W4-2: tonight's Open-Meteo cloud picture, `nil` whenever there is
    /// nothing honest to show (weather off, no site resolved, or the fetch
    /// hasn't landed yet) -- per spec, that means no row at all, not a
    /// loading placeholder or an invented value.
    let cloud: HomeSnapshot.NightCloud?
    /// The one case something IS shown despite `cloud` being `nil`: a fetch
    /// that failed outright with no cached forecast to fall back on.
    let cloudError: WeatherError?
    /// W5-2 finding 5 (owner pixel review): while a configured library is
    /// still opening, `context` is still its neutral `.unconfigured`
    /// default -- indistinguishable, on its own, from a library that
    /// genuinely has no site configured. Without this flag the rail told
    /// the owner "Site not set" during the very same cold start where the
    /// real site was only seconds away from resolving.
    let isLoading: Bool
    /// Wave W6-A section C (onboarding honesty): this rail renders
    /// unconditionally, whether or not a library is open at all -- without
    /// this flag its "not configured" copy pointed at Settings ▸ Location
    /// even with NO library open, though that panel is locked
    /// (`LocationSettingsView`'s own "no library" branch) until one is.
    let hasLibrary: Bool
    /// W7-E workflow #2: the "name the next clear night" line's link target
    /// -- pushes the Nights calendar, where `NightsView`'s own "Cloud"
    /// column renders this exact min-max forecast per date.
    let openNightsCalendar: () -> Void
    /// Wave W6-A section C: the "library open, no site yet" state's own
    /// escape hatch, same `@Environment(\.openSettings)` pattern used
    /// everywhere else in this file a placeholder points at Settings.
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Night context", systemImage: "moon.stars")
                    .font(.headline)
                Spacer()
                if isLoading {
                    Text("Opening the library…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !context.isConfigured {
                    // Wave W6-A section C: Settings ▸ Location only exists
                    // to point at once a library is open (see
                    // `LocationSettingsView`'s own "no library" branch) --
                    // naming it with none open would be a dead pointer.
                    if hasLibrary {
                        Text("Site not set — add it in Settings ▸ Location")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Open a library — the site will resolve automatically from the FITS files")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if context.isConfigured {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        AstroTokens.Color.accent.opacity(0.45),
                                        AstroTokens.Color.accent.opacity(0.88),
                                        AstroTokens.Color.accent.opacity(0.45),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(height: 2)
                        if let nowFraction = context.nowFraction {
                            Circle()
                                .fill(AstroTokens.Color.accent)
                                .frame(width: 7, height: 7)
                                .offset(x: proxy.size.width * nowFraction - 3.5)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 12)

                HStack {
                    Text(context.leadingLabel)
                    Spacer()
                    Text(context.centerLabel)
                    Spacer()
                    Text(context.trailingLabel)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                cloudRow
                nextClearNightRow
            } else if isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Tonight's site will appear once the library finishes opening.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if hasLibrary {
                // Wave W6-A section C: this used to claim the site "derives
                // automatically ... once indexed" in the SAME render where
                // the caption above it points at a manual Settings field --
                // two contradictory stories about how a site gets set,
                // shown at once. One consistent story now: both paths are
                // real (`SiteSettingsStore.effectiveSite` prefers a manually
                // saved site but falls back to one derived from FITS
                // headers), so this says both, and offers the one this rail
                // can actually act on.
                VStack(alignment: .leading, spacing: 6) {
                    Text("No observing site is resolved for this library yet, so tonight's dusk-to-dawn window can't be shown here. Set your coordinates in Settings ▸ Location, or scan FITS files that carry site coordinates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings…") { openSettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                // No library open at all -- Settings ▸ Location is locked
                // (see the caption branch above), so this stays honest about
                // the one thing that actually happens next: opening a
                // library, after which the site resolves on its own.
                Text("Open a library first. Once one is open, AstroTool resolves the observing site automatically from your FITS files' own site coordinates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Task 7c: this was a hand-rolled card -- `.regularMaterial` plus its
        // own stroke, padding and radius -- i.e. a third convention next to
        // the table slot's flat `surface` fill and `MetricCard`'s glass. The
        // material was also the wrong layer for a rail that sits ON the page
        // rather than floating above it: it refracts the backdrop instead of
        // reading as content. One treatment now, same as every other block.
        .astroRaisedSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isLoading
                ? "Night context: the library is still opening."
                : context.isConfigured
                    ? "Night context: \(context.leadingLabel), \(context.centerLabel), \(context.trailingLabel)."
                    : "Night context: no site configured for this library yet."
        )
        .accessibilityIdentifier("v2.home.night-context")
    }

    /// W4-2: V1's Tonight page "Felhőzet" tile vocabulary (dusk-to-dawn
    /// percent transition plus an "Open-Meteo · HH:mm" fetched-at caption),
    /// added as one more row on the same card rather than a separate tile --
    /// this rail is already keyed to the same dusk/dawn window the cloud
    /// numbers themselves are computed against.
    @ViewBuilder
    private var cloudRow: some View {
        if let cloud {
            HStack(spacing: 6) {
                Image(systemName: "cloud.fill").foregroundStyle(.secondary)
                Text("Cloudiness")
                cloudValueText(cloud)
                Spacer()
                Text("Open-Meteo · \(Self.hmFormatter.string(from: cloud.fetchedAt))")
                    .foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
            .accessibilityIdentifier("v2.home.night-cloud")
        } else if let cloudError {
            HStack(spacing: 6) {
                Image(systemName: "cloud.fill").foregroundStyle(.secondary)
                Text("Cloudiness")
                Text(cloudError.captionKey)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("v2.home.night-cloud-error")
        }
    }

    /// `nil` dusk/dawn (both, per `HomeStore.productionWeather`'s own
    /// contract) means tonight falls beyond Open-Meteo's 7-day horizon --
    /// the same honest message `PlanningView`'s cloud indicator shows for
    /// the identical case, rather than a blank or a guess.
    private func cloudValueText(_ cloud: HomeSnapshot.NightCloud) -> Text {
        guard let dusk = cloud.duskPercent, let dawn = cloud.dawnPercent else {
            return Text("Forecast horizon is 7 days")
        }
        return Text(verbatim: "\(Int(dusk.rounded()))% → \(Int(dawn.rounded()))%")
    }

    private static let hmFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// W7-E workflow #2 (2026-08-18 owner audit, "cloudy tonight, name the
    /// next clear night"): one more line on this same card -- Home already
    /// knows tonight is cloudy and used to only ever talk about tonight.
    /// `nil` `nextClearNight` (a clear night, or `cloud` itself absent) means
    /// nothing to add, per `HomeSnapshot.NightCloud.nextClearNight`'s own
    /// contract.
    @ViewBuilder
    private var nextClearNightRow: some View {
        if let nextClearNight = cloud?.nextClearNight {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                switch nextClearNight {
                case .found(let date, let minPercent, let maxPercent):
                    Button {
                        openNightsCalendar()
                    } label: {
                        // Int interpolation emits a %lld runtime key while the
                        // extraction script normalizes every interpolation to
                        // %@ -- the two can never match, so the range is
                        // pre-formatted into ONE String argument (the same
                        // convention "eddig %@" already uses).
                        let range = "\(Int(minPercent.rounded()))–\(Int(maxPercent.rounded()))"
                        Text("Nearest clear night: \(date) (\(range)% cloud)")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AstroTokens.Color.accent)
                case .unavailable:
                    Text("The 7-day forecast has no clear night")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .accessibilityIdentifier("v2.home.next-clear-night")
        }
    }
}

/// W4-2: `WeatherError.message` is a raw Hungarian `String` (V1's own
/// display convention, read straight by `TonightPage`) -- handing that to
/// `Text(_:)` in V2 would always select the verbatim `StringProtocol`
/// overload and never resolve through `hu.lproj`. Same dual-representation
/// split as `NightRow.TriageState.displayLabel`/`.localizedText`
/// (`NightsStore.swift`): this is the `LocalizedStringKey` side, for V2 only.
extension WeatherError {
    var captionKey: LocalizedStringKey {
        switch self {
        case .network: "No connection to Open-Meteo"
        case .invalidResponse: "Open-Meteo returned an invalid response"
        case .decode: "Open-Meteo's response could not be processed"
        }
    }
}
