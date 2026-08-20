import AstroApplication
import AstroCore
import Charts
import SwiftUI

/// V2 UI/UX audit (2026-08-14) systemic pattern S8: this used to be a
/// `private final class` with `InsightsQuery.production` called directly
/// inside `load`, so this whole screen had zero unit-test surface. Follows
/// `LibraryHealthStore`'s query-factory injection pattern so tests can
/// supply a fixture-backed `InsightsQuery` without touching the
/// filesystem-resolving `production` constructor.
@MainActor
@Observable
public final class InsightsStore {
    public typealias QueryFactory = @Sendable (URL) throws -> InsightsQuery
    /// W7-E workflow #1 (2026-08-18 owner audit, "rating is the gate on half
    /// the app, and nothing drives you through it"): the matching empty-trend
    /// hint's own number -- `RatingCoverageQuery`'s unrated-night count, the
    /// exact same query (and vocabulary) Home's own rating-gate card reads,
    /// never a second one invented for Insights. Sync `throws`, not `async`,
    /// so this default can stay a plain function-default (like `queryFactory`
    /// above) rather than the `Optional`+resolve-in-init shape `HomeStore`'s
    /// own `async` providers need -- see `AsyncContextSizeGateTests`'s doc
    /// comment for why that distinction matters.
    public typealias RatingGapProvider = @Sendable (URL) throws -> Int
    /// OWNER BUG (2026-08-19 real-library audit): whether ANY sensor profile
    /// has been measured for this library -- `HomeStore.productionRatingGate`'s
    /// exact same `SensorProfilesQuery` read, never a second one invented for
    /// Insights. `async`, unlike `RatingGapProvider`, since
    /// `SensorProfilesQuery.snapshot()` itself is `async throws`. Feeds the
    /// Background trend's own hint: `backgroundEPerSecPerArcsec2` is `nil`
    /// for EVERY capture until a sensor profile exists (`SessionQuality`'s
    /// own "no bias level, no honest e-/s/arcsec2 number" rule) -- a
    /// completely different blocker than FWHM's (needs an actual star
    /// measurement pass), so the hint must never conflate the two.
    public typealias SensorProfileMeasuredProvider = @Sendable (URL) async throws -> Bool

    public private(set) var snapshot: InsightsSnapshot?
    public private(set) var availableYears: [Int] = []
    public private(set) var errorMessage: String?
    public private(set) var isLoading = false
    public private(set) var unratedNightCount = 0
    public private(set) var sensorProfileMeasured = true

    private let queryFactory: QueryFactory
    private let ratingGapProvider: RatingGapProvider
    private let sensorProfileMeasuredProvider: SensorProfileMeasuredProvider

    public init(
        queryFactory: @escaping QueryFactory = { rootURL in try InsightsQuery.production(rootURL: rootURL) },
        ratingGapProvider: @escaping RatingGapProvider = { rootURL in
            try RatingCoverageQuery.production(rootURL: rootURL).snapshot().unratedNightCount
        },
        sensorProfileMeasuredProvider: @escaping SensorProfileMeasuredProvider = { rootURL in
            try await !SensorProfilesQuery.production(rootURL: rootURL).snapshot().profiles.isEmpty
        }
    ) {
        self.queryFactory = queryFactory
        self.ratingGapProvider = ratingGapProvider
        self.sensorProfileMeasuredProvider = sensorProfileMeasuredProvider
    }

    public func load(rootURL: URL?, year: Int? = nil) async {
        guard let rootURL else { snapshot = nil; unratedNightCount = 0; sensorProfileMeasured = true; return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await queryFactory(rootURL).snapshot(year: year)
            if year == nil, let snapshot {
                availableYears = Array(Set(snapshot.months.compactMap { Int($0.month.prefix(4)) })).sorted(by: >)
            }
            // Best-effort, same "honest zero on failure, never a thrown
            // error over a secondary hint" posture `HomeStore.configure`
            // already applies to its own `(try? await ...) ?? .clear`
            // provider calls -- a rating-coverage read failing must never
            // block the trends this screen exists to show.
            unratedNightCount = (try? ratingGapProvider(rootURL)) ?? 0
            sensorProfileMeasured = (try? await sensorProfileMeasuredProvider(rootURL)) ?? true
        }
        catch { errorMessage = error.localizedDescription }
    }
}

public struct InsightsView: View {
    let librarySnapshot: LibrarySnapshot?
    let rootURL: URL?
    let chooseLibrary: () -> Void
    /// Consumed once, on this view's very first appearance -- `NightActionMenu`'s
    /// "Open in Insights" action presets the Setup Trends filter to the
    /// night's own setup via `AppRouter.navigateToInsights(presetSetupFilter:)`
    /// / `pendingInsightsSetupFilter`. `nil` leaves `selectedSetup` at its
    /// usual "All setups" default.
    let initialSetupFilter: String?
    @State private var store: InsightsStore
    @State private var selectedYear: Int?
    @State private var selectedSetup: String?
    /// OWNER BUG (2026-08-19 real-library audit): the button the owner
    /// literally asked for ("erre kell valami gomb, akár ide a felületre" --
    /// "there needs to be some button, maybe right here on this screen").
    /// Already provided globally by `V2RootView`'s `.environment(operationHost)`
    /// -- reading it here needs no wiring change anywhere else, exactly like
    /// `HomeView`'s own `@Environment(OperationHost.self)`.
    @Environment(OperationHost.self) private var operationHost

    public init(
        snapshot: LibrarySnapshot?,
        rootURL: URL?,
        initialSetupFilter: String? = nil,
        chooseLibrary: @escaping () -> Void,
        store: InsightsStore = InsightsStore()
    ) {
        self.librarySnapshot = snapshot
        self.rootURL = rootURL
        self.initialSetupFilter = initialSetupFilter
        self.chooseLibrary = chooseLibrary
        _store = State(initialValue: store)
        _selectedSetup = State(initialValue: initialSetupFilter)
    }

    public var body: some View {
        WorkspacePage(subtitle: "See what you photographed, how much signal you collected, and how your activity changes over time.") {
            if let insight = store.snapshot {
                Picker("Period", selection: $selectedYear) {
                    Text("All years").tag(Int?.none)
                    ForEach(store.availableYears, id: \.self) { year in
                        Text(String(year)).tag(Optional(year))
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("v2.insights.period")
                .onChange(of: selectedYear) { _, year in
                    Task { await store.load(rootURL: rootURL, year: year) }
                }
                metrics(insight)
                // Expert ideation reserve #9 ("Év-összegző Wrapped", wow
                // 5/5): a year's story, not "Minden év"'s -- there is no
                // single year to celebrate when every year is blended
                // together, and `insight.yearWrapped` is already `nil` in
                // that case (`InsightsQuery.snapshot` only ever builds it
                // when `year` itself is non-nil). The `selectedYear != nil`
                // half of this guard is what `InsightsWrappedSurfaceTests`
                // pins: the card must never render on "Minden év" even if a
                // future change somehow left a stale `yearWrapped` behind.
                if selectedYear != nil, let wrapped = insight.yearWrapped {
                    yearWrappedCard(wrapped)
                }
                // Ideation #3 ("Ez a hónap tavalyhoz képest", "This month vs
                // last year"): a small, always-fresh companion to the Year
                // Wrapped card above -- visible year-round (unlike Year
                // Wrapped, which only makes sense once a specific PAST year
                // is chosen) since "this month" always means the real
                // current calendar month, never whatever the Period picker
                // happens to be scoped to. Judgment call on visibility:
                // shown on "Minden év" (`selectedYear == nil`) AND when the
                // picker is on THIS calendar year (`selectedYear ==
                // insight.currentYear`) -- browsing an older year (say 2024)
                // would show a "this month" comparison unrelated to what's
                // on screen, so it drops there even though
                // `InsightsQuery.snapshot` always computes the underlying
                // data regardless of scope (`InsightsSnapshot.
                // yearOverYearComparison`'s own doc comment). Unlike the
                // guard above, this one does not gate on the comparison
                // itself being non-nil: the card still renders (with an
                // honest empty state) when there is no prior-year data yet
                // -- see `monthOverYearCard`'s own doc comment.
                if selectedYear == nil || selectedYear == insight.currentYear {
                    monthOverYearCard(insight.yearOverYearComparison, currentMonth: insight.currentMonth)
                }
                if insight.hasDuplicateExposure {
                    Text("Duplicate frames in the index were counted once — raw index total before dedup: \(duration(insight.grossIntegrationSeconds))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                qualitySummary(insight)
                qualityTrends(insight)
                moonSkyCorrelationCard(insight)
                nightLeaderboardCard(insight)
                HStack(alignment: .top, spacing: AstroTokens.Spacing.standard) {
                    activityChart(insight).frame(maxWidth: .infinity)
                    targetRanking(insight).frame(width: 320)
                }
                HStack(alignment: .top, spacing: AstroTokens.Spacing.standard) {
                    filterBreakdown(insight).frame(maxWidth: .infinity)
                    setupBreakdown(insight).frame(maxWidth: .infinity)
                }
                Label("Calculated from AstroTool's external read-only index", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            } else if store.isLoading {
                ProgressView("Calculating capture history…").frame(maxWidth: .infinity, minHeight: 280)
            } else if rootURL == nil {
                ContentUnavailableView {
                    Label("Open a library for insights", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("AstroTool will calculate nights, integration time and target history locally.")
                } actions: {
                    Button("Open Library…", action: chooseLibrary).buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView {
                    Label("Insights unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    // V2 localization sweep (W3-13): `store.errorMessage` is
                    // `String?` -- `?? "..."` used to resolve the whole
                    // expression to `String`, so `Text(String)` picked the
                    // verbatim overload and the fallback phrase never
                    // localized. Two real `Text` values keep the dynamic
                    // message verbatim while the fallback goes through
                    // `Text`'s own `LocalizedStringKey` initializer.
                    store.errorMessage.map(Text.init) ?? Text("The external index does not contain reportable sessions yet.")
                } actions: {
                    // Wave W6-A: this placeholder used to have no way back
                    // short of leaving the page -- see `RetryButton`'s own
                    // doc comment.
                    RetryButton(identifier: "v2.insights.try-again") {
                        Task { await store.load(rootURL: rootURL, year: selectedYear) }
                    }
                }
            }
        }
        .navigationTitle("Insights")
        .astroSectionMarker("v2.detail.insights", label: "Insights")
        .task(id: rootURL) { await store.load(rootURL: rootURL) }
        // Reloads once "Start Measuring" (or Home's "Rate Everything",
        // sharing the same `ProjectRatingRunner.kind`) transitions from
        // running to finished, so the just-filled FWHM/background trends
        // actually appear without the owner having to leave and reopen this
        // screen. `measuringOperation` is `nil` on both sides of a run that
        // never started here at all, so this never fires spuriously.
        .onChange(of: operationHost.activeOperations) { old, new in
            guard let rootURL else { return }
            let kind = ProjectRatingRunner.kind(for: .allProjects(libraryName: rootURL.lastPathComponent))
            let wasRunning = old.contains { $0.kind == kind }
            let stillRunning = new.contains { $0.kind == kind }
            if wasRunning, !stillRunning {
                Task { await store.load(rootURL: rootURL, year: selectedYear) }
            }
        }
    }

    private func qualityTrends(_ insight: InsightsSnapshot) -> some View {
        // Task 7 (2026-08-17, GroupBox removal): `GroupBox`'s opaque grey
        // panel is gone from here for good. Task 7c gives the section back a
        // real presence in the one shared way -- see the `.astroRaisedSurface()`
        // at the bottom of this function.
        //
        // W6-B (owner screenshot review): this card used to plot one point
        // per SESSION -- but a session (night) can hold more than one
        // capture group, each its own optics/filter/exposure combination,
        // and the owner's own table mixed a Canon EOS R8·16mm widefield row
        // with a ZWO ASI2600MC narrowband row into one "Efficiency" trend
        // line. FWHM/background/efficiency are properties of a CAPTURE, not
        // a session -- `CaptureTrendPoint` (`InsightsQuery.swift`) is the
        // reworked per-capture unit; the "Összeállítás" setup filter below
        // now finally means something (one setup = one comparable series).
        // OWNER BUG (2026-08-19 real-library audit): the owner's own words,
        // "1 mért capture — a trendhez több mérés kell, erre kell valami
        // gomb" -- ONE point is not "empty" (`insight.captureTrendPoints.
        // isEmpty` was false in his exact case, so the old generic hint
        // below never even rendered for him), and pressing "Minden projekt
        // értékelése" a second time changed nothing because that button's
        // `.nativeOnly` mode structurally can never populate FWHM (see
        // `ProjectRatingRunner.run`'s own doc comment). Computed once, up
        // front, so both the new hints below and the three charts share the
        // exact same filtered point lists.
        let fwhmPoints = trendData(insight) { $0.fwhmValue?.value }
        let backgroundPoints = trendData(insight) { $0.backgroundEPerSecPerArcsec2 }
        let efficiencyPoints = trendData(insight) { $0.efficiencyPercent }

        return VStack(alignment: .leading, spacing: 12) {
            Text("Capture quality trends").font(.headline)
            // Two DISTINCT blockers, never one conflated hint: FWHM needs an
            // actual star-measurement pass (Siril, `.fullReMeasure`) that
            // background/score-only rating can never provide; Background
            // needs a measured sensor profile (bias level), an unrelated
            // one-time calibration `SessionQuality` requires before it will
            // ever report a e-/s/arcsec2 number (see its own doc comment on
            // that guard -- reporting one computed against an unsubtracted
            // bias pedestal is the very bug that rule exists to prevent).
            if fwhmPoints.count < 2 {
                fwhmMeasurementHint(measuredCount: fwhmPoints.count)
            }
            if backgroundPoints.isEmpty, !store.sensorProfileMeasured {
                Label("No sensor profile has been measured yet — measure it from Home to convert background into e⁻/s/arcsec².", systemImage: "camera.aperture")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("v2.insights.sensor-profile-hint")
            }
            HStack {
                Text("Compare measured captures over time. Lower FWHM and background are better; higher efficiency is better.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("Setup", selection: $selectedSetup) {
                    Text("All setups").tag(String?.none)
                    ForEach(insight.setupChoices, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .frame(maxWidth: 280)
            }
            HStack(alignment: .top, spacing: 12) {
                trendChart(title: "FWHM", unit: "arcsec / px", points: fwhmPoints, color: AstroTokens.Color.accent)
                trendChart(title: "Background", unit: "e⁻/s/arcsec²", points: backgroundPoints, color: AstroTokens.Color.accent)
                trendChart(title: "Efficiency", unit: "%", points: efficiencyPoints, color: AstroTokens.Color.accent)
            }
            recentTrendSessions(insight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Task 7c: ONE surface for this whole section. The three
        // `trendChart(...)` sub-blocks and `recentTrendSessions` inside it
        // stay bare on purpose -- they are groupings WITHIN a card, and
        // grouping within a card is a heading plus spacing, never a second
        // card. (Were one of them to grow its own `.astroRaisedSurface()`
        // anyway, the modifier's environment guard would collapse it rather
        // than paint the box-in-box the owner reported.)
        .astroRaisedSurface()
        .accessibilityIdentifier("v2.insights.quality-trends")
    }

    /// OWNER BUG (2026-08-19 real-library audit): the "Mérés indítása"/
    /// "Start Measuring" button the owner asked for, right on this screen --
    /// same `ProjectRatingRunner` engine and `OperationHost` progress Home's
    /// "Rate Everything" card already uses, just a second entry point that
    /// asks for `.fullReMeasure` instead of defaulting to `.nativeOnly`, so
    /// pressing it can actually fill FWHM in (unlike the button he already
    /// tried).
    @ViewBuilder
    private func fwhmMeasurementHint(measuredCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // An `if`/`else` `Text(...)` branch, not a ternary: the ELSE
            // branch interpolates `measuredCount`, and `LocalizedStringKey(
            // aTernary)` would resolve to `LocalizedStringKey.init(_ value:
            // String)` -- the PLAIN string-wrapping initializer, which bakes
            // the already-interpolated number straight into the "key" itself
            // (a different key per count!) rather than producing the "%lld
            // ..." pattern `Text("\(count) ...")`'s own interpolation-literal
            // initializer produces (the same "%lld nights still have unrated
            // frames" key already proven elsewhere in this file/`hu.lproj`).
            if measuredCount == 0 {
                Text("FWHM has never been measured — background/score alone can never fill this trend in.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("\(measuredCount) measured capture so far — FWHM needs an actual star-measurement pass, not just background/score.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let measuringOperation {
                HStack(spacing: 8) {
                    ProgressView(
                        value: measuringOperation.total.map { Double(measuringOperation.completed) / Double(max($0, 1)) }
                    )
                    if let total = measuringOperation.total {
                        Text(verbatim: "\(measuringOperation.completed) / \(total)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("v2.insights.measure-progress")
            } else {
                Button("Start Measuring", action: startMeasuring)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("v2.insights.start-measuring")
            }
        }
        .accessibilityIdentifier("v2.insights.fwhm-measurement-hint")
    }

    /// Mirrors `HomeView.ratingOperation` exactly -- looked up by
    /// `ProjectRatingRunner.kind(for:)` so an in-flight run started from
    /// EITHER entry point (Home's "Rate Everything" or this screen's "Start
    /// Measuring") shows its progress here too, rather than this button
    /// silently starting a second, redundant run.
    private var measuringOperation: OperationHost.ActiveOperation? {
        guard let rootURL else { return nil }
        let kind = ProjectRatingRunner.kind(for: .allProjects(libraryName: rootURL.lastPathComponent))
        return operationHost.activeOperations.first { $0.kind == kind }
    }

    private func startMeasuring() {
        guard let rootURL else { return }
        Task {
            await ProjectRatingRunner.run(
                scope: .allProjects(libraryName: rootURL.lastPathComponent),
                rootURL: rootURL,
                metadataFactory: ProjectsStore.productionMetadata,
                operationHost: operationHost,
                mode: .fullReMeasure
            )
        }
    }

    private func trendData(
        _ insight: InsightsSnapshot,
        value: (CaptureTrendPoint) -> Double?
    ) -> [InsightTrendDatum] {
        insight.captureTrendPoints.compactMap { point in
            guard selectedSetup == nil || point.setupDescriptor == selectedSetup,
                  let metric = value(point) else { return nil }
            return InsightTrendDatum(
                id: point.id,
                date: point.sessionStartDate ?? point.date,
                target: point.target,
                value: metric
            )
        }
    }

    // V2 localization sweep (W3-13): `title` used to be a plain `String`
    // function parameter -- every call site (`"FWHM"`/`"Background"`/
    // `"Efficiency"`) passed a literal, but `Text(title)` inside this
    // function still resolved to the verbatim `StringProtocol` overload
    // because the PARAMETER's declared type, not the call-site literal,
    // decides which `Text` initializer is picked. "Background"/"Efficiency"
    // already had `hu.lproj` entries and still never localized; "FWHM" stays
    // untranslated on purpose either way (see `GlossaryView`'s own
    // convention -- technical vocabulary stays English, and this file's
    // `qualityMetricInfo`-style titles already follow it).
    private func trendChart(
        title: LocalizedStringKey,
        unit: String,
        points: [InsightTrendDatum],
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            // Task 6 (owner review wave 4-4): with fewer than two measured
            // sessions there is no TREND to draw -- a lone `PointMark` (one
            // dot, nothing to compare it to) or the old `ContentUnavailableView`
            // graphic both used to render here regardless, implying there
            // was something worth charting. `InsightTrendChartState` names
            // the honest reason instead; the chart itself only ever renders
            // once it can actually show a trend.
            switch InsightTrendChartState(pointCount: points.count) {
            case .noData, .singleSession:
                Text(InsightTrendChartState.unavailableMessage(pointCount: points.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
            case .trend:
                Chart(points) { point in
                    LineMark(x: .value("Date", point.date), y: .value(unit, point.value))
                        .foregroundStyle(color)
                    PointMark(x: .value("Date", point.date), y: .value(unit, point.value))
                        .foregroundStyle(color)
                }
                .chartYAxisLabel(unit)
                // Task 6: this axis is categorical (one distinct `String`
                // session date per point, not a continuous scale), so Swift
                // Charts' own default -- one tick per category -- used to
                // cram a dozen-plus session dates into a third of the row's
                // width until every single label shrank to nothing but its
                // own ellipsis ("…"), worse than no label at all (the
                // Efficiency chart's own defect, since it typically has the
                // most measured sessions of the three). Explicit tick
                // values thin that down to real, readable dates.
                .chartXAxis {
                    AxisMarks(values: InsightTrendChartState.thinnedAxisDates(points.map(\.date))) { value in
                        AxisGridLine()
                        AxisTick()
                        if let date = value.as(String.self) {
                            AxisValueLabel(InsightTrendChartState.shortAxisLabel(for: date))
                        }
                    }
                }
                .frame(minHeight: 180)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recentTrendSessions(_ insight: InsightsSnapshot) -> some View {
        // W6-B: "Legutóbbi session" -> "Legutóbbi capture-ök" -- one row per
        // CAPTURE now, not per session, so a mixed-rig night contributes one
        // row per rig instead of one blended row. `\.id` (stable: target +
        // date + capture-group key) rather than `\.date`, which used to
        // collide whenever more than one row shared a date -- exactly the
        // case this rework introduces on purpose.
        let points = insight.captureTrendPoints.filter {
            selectedSetup == nil || $0.setupDescriptor == selectedSetup
        }.suffix(8).reversed()
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            GridRow {
                Text("Recent captures").font(.caption.weight(.semibold))
                Text("Filter").font(.caption.weight(.semibold))
                Text("FWHM").font(.caption.weight(.semibold))
                Text("Background").font(.caption.weight(.semibold))
                Text("Efficiency").font(.caption.weight(.semibold))
                Text("Setup").font(.caption.weight(.semibold))
            }
            Divider().gridCellColumns(6)
            ForEach(Array(points), id: \.id) { point in
                GridRow {
                    Text("\(point.date) · \(point.target)").lineLimit(1)
                    // `filterLabel` is arbitrary filter-wheel data (or the
                    // literal "—" placeholder), never UI copy -- verbatim,
                    // same convention `NightWorkspaceView`'s own Capture
                    // Groups table uses for `CaptureGroupSummary.filters`.
                    Text(point.filterLabel).lineLimit(1)
                    // W6-B item 7 (audit finding, InsightsView.swift:278):
                    // this used to format the raw number with no unit at
                    // all, silently hiding whether it was arcsec or the
                    // px-fallback (`isPixelFallback`) -- `AstroFormat.
                    // fwhmArcsec`/`fwhmPixels` are the ONE canonical
                    // formatter per unit this codebase already establishes
                    // (see that type's own doc comment), same "arcsec when
                    // derivable, else pixels" branch `NightWorkspaceView.
                    // fwhmText` already uses for the night workspace's own
                    // Capture Groups table.
                    Text(point.fwhmValue.map { $0.isPixelFallback ? AstroFormat.fwhmPixels($0.value) : AstroFormat.fwhmArcsec($0.value) } ?? "—").monospacedDigit()
                    Text(point.backgroundEPerSecPerArcsec2?.formatted(.number.precision(.significantDigits(2...3))) ?? "—").monospacedDigit()
                    Text(point.efficiencyPercent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "—").monospacedDigit()
                    // `setupDescriptor` is arbitrary equipment data (never
                    // `nil` in a translatable sense) -- only the "Unknown"
                    // fallback is UI copy, so it alone needs to route
                    // through `Text`'s `LocalizedStringKey` initializer
                    // rather than the whole `?? "Unknown"` expression
                    // collapsing to `String` (same leak class as this file's
                    // other two `?? "..."` fallbacks above).
                    (point.setupDescriptor.map(Text.init) ?? Text("Unknown")).lineLimit(1)
                }
                .font(.caption)
            }
        }
        .accessibilityIdentifier("v2.insights.recent-quality-table")
    }

    // Expert ideation spec #3 (2026-08-19): every rated session already
    // carries a bias-corrected sky background (`SessionQuality`'s
    // `backgroundEPerSecPerArcsec2`), and the Moon engine knows the
    // illumination fraction on any date -- crossing them gives this owner a
    // personal SQM history nobody else could hand him: "my sky reads N
    // times brighter near full Moon than under a dark one." Pure bucketing
    // lives in `MoonSkyCorrelation` (`AstroCore`), the mag/arcsec2 reading
    // is `MeasuredSkyQuery`'s own conversion applied per bucket
    // (`InsightsQuery.moonSkyCorrelationSummary`) -- this view only renders
    // what those two already computed.
    //
    // Current reality (2026-08-19 real-index replay, read-only, this
    // owner's own cached index): 26 sessions on record, ZERO with a
    // measured (bias-corrected) background yet -- `Rate` has never been run
    // against a sensor profile that could subtract the bias pedestal. That
    // makes the EMPTY state below what he will actually see first; it says
    // so honestly (ties into the same rating-gap hint `qualityTrends`
    // above already surfaces) rather than a bare "no data" dead end.
    private func moonSkyCorrelationCard(_ insight: InsightsSnapshot) -> some View {
        let moonSky = insight.moonSkyCorrelation
        return VStack(alignment: .leading, spacing: 12) {
            Text("Sky brightness vs. Moon phase").font(.headline)
            if moonSky.hasEnoughDataToDisplay {
                if let ratio = moonSky.headlineRatio {
                    Text("Your sky background reads about \(ratio.formatted(.number.precision(.fractionLength(1))))× brighter under a bright Moon (≥75% illuminated) than under a dark one (<25%).")
                        .font(.callout.weight(.semibold))
                        .accessibilityIdentifier("v2.insights.moon-sky-headline")
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                    GridRow {
                        Text("Moon phase").font(.caption.weight(.semibold))
                        Text("Sessions").font(.caption.weight(.semibold))
                        Text("Background").font(.caption.weight(.semibold))
                        Text("Sky brightness").font(.caption.weight(.semibold))
                    }
                    Divider().gridCellColumns(4)
                    ForEach(moonSky.buckets) { bucket in
                        GridRow {
                            Text(moonPhaseBandLabel(bucket.band))
                            Text("\(bucket.sampleCount)").monospacedDigit()
                            if bucket.isLowConfidence {
                                Text("Too few sessions").foregroundStyle(.secondary)
                            } else {
                                Text(bucket.medianBackgroundEPerSecPerArcsec2?.formatted(.number.precision(.significantDigits(2...3))) ?? "—")
                                    .monospacedDigit()
                            }
                            if bucket.isLowConfidence {
                                Text("—").foregroundStyle(.secondary)
                            } else {
                                Text(bucket.medianMagnitudePerArcsec2.map {
                                    "μ≈\($0.formatted(.number.precision(.fractionLength(1))))"
                                } ?? "—").monospacedDigit()
                            }
                        }
                        .font(.caption)
                    }
                }
            } else {
                // W7-E workflow #1's own convention (see `qualityTrends`
                // above): name the rating gate plainly when it's the reason
                // there's nothing to show yet, rather than a bare "no data".
                if store.unratedNightCount > 0 {
                    Label("\(store.unratedNightCount) nights still have unrated frames — rate them from Home to start measuring the Moon's effect on your sky.", systemImage: "star.leadinghalf.filled")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("v2.insights.moon-sky-rating-gap-hint")
                } else {
                    Text("Not enough measured sessions across different Moon phases yet to show this — rate a few more nights under different Moon conditions to build up your own sky-brightness history.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
        .accessibilityIdentifier("v2.insights.moon-sky-correlation")
    }

    private func moonPhaseBandLabel(_ band: MoonSkyCorrelation.IlluminationBand) -> LocalizedStringKey {
        switch band {
        case .veryDark: return "Dark Moon (<25%)"
        case .dark: return "25–50% Moon"
        case .bright: return "50–75% Moon"
        case .veryBright: return "Bright Moon (≥75%)"
        }
    }

    // Ideation #7 ("Legjobb/legrosszabb éjszakák ranglistája" -- "best/worst
    // nights leaderboard"): ranks measured CAPTURES, not whole nights --
    // `NightLeaderboard` (`AstroCore`)/`InsightsQuery.nightLeaderboardSummary`'s
    // own doc comments spell out why: the "Capture quality trends" chart
    // above already moved off whole-session `TrendPoint`s for the identical
    // reason (a night can mix more than one rig, and blending them into one
    // number hides which half was actually good), so the leaderboard ranks
    // the exact same per-capture grain rather than reintroducing that blend.
    // No hidden score is ever shown -- `nightLeaderboardTable` below prints
    // each row's own raw FWHM/efficiency/background, exactly the three
    // numbers `NightLeaderboard`'s composite was computed from, so the order
    // is auditable by eye without trusting an opaque figure.
    private func nightLeaderboardCard(_ insight: InsightsSnapshot) -> some View {
        let leaderboard = insight.nightLeaderboard
        return VStack(alignment: .leading, spacing: 12) {
            Text("Nights leaderboard").font(.headline)
            if leaderboard.hasEnoughDataToDisplay {
                Text("Ranks measured captures by FWHM, accept rate and background — one row per rig/filter combination, since a single night can mix more than one.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: AstroTokens.Spacing.standard) {
                    nightLeaderboardTable(
                        title: "Best", rows: leaderboard.best,
                        accessibilityIdentifier: "v2.insights.night-leaderboard-best"
                    ).frame(maxWidth: .infinity, alignment: .leading)
                    nightLeaderboardTable(
                        title: "Worst", rows: leaderboard.worst,
                        accessibilityIdentifier: "v2.insights.night-leaderboard-worst"
                    ).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // Coordinates with (never duplicates) the "Start Measuring"
                // button `fwhmMeasurementHint` above already put on this
                // same screen (OWNER BUG, 2026-08-19) -- this section grows
                // no second button of its own, only a pointer back to that
                // one.
                Text("Not enough measured nights for a leaderboard yet (at least 5 needed) — use “Start Measuring” above to build up FWHM and background history.")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("v2.insights.night-leaderboard-hint")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
        .accessibilityIdentifier("v2.insights.night-leaderboard")
    }

    /// One `title` (`"Best"`/`"Worst"`) column of the leaderboard -- `rows`
    /// already arrives best-first/worst-first respectively
    /// (`NightLeaderboard.rank`'s own ordering), so this only renders, never
    /// re-sorts.
    private func nightLeaderboardTable(
        title: LocalizedStringKey,
        rows: [NightLeaderboardRow],
        accessibilityIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    Text("Night").font(.caption.weight(.semibold))
                    Text("FWHM").font(.caption.weight(.semibold))
                    Text("Efficiency").font(.caption.weight(.semibold))
                    Text("Background").font(.caption.weight(.semibold))
                }
                Divider().gridCellColumns(4)
                ForEach(rows) { row in
                    GridRow {
                        Text("\(row.sessionStartDate ?? row.date) · \(row.target)").lineLimit(1)
                        // Same "arcsec when derivable, else pixels" unit
                        // convention `recentTrendSessions` already uses --
                        // `NightLeaderboard` only ever RANKS the arcsec
                        // figure (mixing units in a composite would be
                        // physically meaningless), but a row still DISPLAYS
                        // whatever raw FWHM it has, ranked on or not.
                        Text(row.fwhmValue.map {
                            $0.isPixelFallback ? AstroFormat.fwhmPixels($0.value) : AstroFormat.fwhmArcsec($0.value)
                        } ?? "—").monospacedDigit()
                        Text(row.efficiencyPercent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "—")
                            .monospacedDigit()
                        Text(row.backgroundEPerSecPerArcsec2?.formatted(.number.precision(.significantDigits(2...3))) ?? "—")
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    // Expert ideation reserve #9 ("Év-összegző Wrapped", wow 5/5): one
    // emotional, screenshot-worthy year card built entirely from
    // `AstroCore.YearWrapped` -- every number here is a real aggregate
    // (`InsightsQuery.snapshot` builds it from the exact same trend points
    // the Moon-sky card above reads), never a second, independently-derived
    // figure. Sparse-data honesty carries all the way through: the best-
    // FWHM tile is the one most likely to have nothing to show (this
    // owner's own library has ~1 measured session at the time this card
    // shipped) and simply does not render rather than showing a fabricated
    // "best" over zero measurements.
    private func yearWrappedCard(_ wrapped: YearWrapped) -> some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            Text("Year in review").font(.headline)
            yearWrappedHeadline(wrapped)
                .astroDisplay()
                .accessibilityIdentifier("v2.insights.year-wrapped-headline")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: AstroTokens.Spacing.compact)],
                spacing: AstroTokens.Spacing.compact
            ) {
                yearWrappedTile(
                    title: "Favorite target",
                    value: wrapped.mostShotTarget?.target ?? "—",
                    detail: wrapped.mostShotTarget.map { Text(duration($0.integrationSeconds)) } ?? Text("No sessions yet"),
                    systemImage: "star.fill"
                )
                yearWrappedTile(
                    title: "Light frames",
                    value: AstroFormat.count(wrapped.totalUsableFrameCount),
                    detail: Text("Usable, deduplicated"),
                    systemImage: "photo.stack"
                )
                yearWrappedTile(
                    title: "Biggest month",
                    value: wrapped.biggestMonth?.month ?? "—",
                    detail: wrapped.biggestMonth.map { Text(duration($0.integrationSeconds)) } ?? Text("No monthly data"),
                    systemImage: "calendar"
                )
                yearWrappedTile(
                    title: "New targets",
                    value: "\(wrapped.firstLights.count)",
                    detail: yearWrappedFirstLightsDetail(wrapped),
                    systemImage: "sparkles"
                )
                // Sparse-data honesty: this tile drops entirely (not a
                // placeholder) when no session this year carries a measured
                // FWHM at all -- a fabricated "best" over zero measurements
                // would be worse than no tile.
                if let best = wrapped.bestFWHMNight {
                    yearWrappedTile(
                        title: "Best FWHM night",
                        value: best.isPixelFallback ? AstroFormat.fwhmPixels(best.value) : AstroFormat.fwhmArcsec(best.value),
                        detail: Text("\(best.target) · \(best.date)"),
                        systemImage: "star.circle.fill"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
        .accessibilityIdentifier("v2.insights.year-wrapped")
    }

    /// Both branches interpolate ONLY pre-formatted `String`s (`String(wrapped.year)`,
    /// `duration(...)`, `String(wrapped.sessionCount)`, and `mostShotTarget.
    /// target` itself is already one) -- same rule `HomeView.highlightText`'s
    /// own doc comment states: an `Int`/`Double` interpolated straight into a
    /// `Text` emits a `%lld`/`%lf` runtime key, while this codebase's hand-
    /// added `hu.lproj` entries are written against the `%@` key the
    /// extraction script normalizes every interpolation to.
    private func yearWrappedHeadline(_ wrapped: YearWrapped) -> Text {
        let yearText = String(wrapped.year)
        let hoursText = duration(wrapped.totalIntegrationSeconds)
        let nightsText = String(wrapped.sessionCount)
        guard let target = wrapped.mostShotTarget?.target else {
            return Text("In \(yearText), you spent \(hoursText) collecting light across \(nightsText) nights.")
        }
        return Text("In \(yearText), you spent \(hoursText) collecting light across \(nightsText) nights — your favorite was \(target).")
    }

    /// `firstLights` is arbitrary target/catalog data, not UI copy -- joined
    /// verbatim (same convention `recentTrendSessions`' `filterLabel` row
    /// already uses for arbitrary filter-wheel text), only the zero-count
    /// and "too many to list" fallbacks route through `Text`'s
    /// `LocalizedStringKey` initializer.
    private func yearWrappedFirstLightsDetail(_ wrapped: YearWrapped) -> Text {
        guard !wrapped.firstLights.isEmpty else { return Text("None this year") }
        let shown = wrapped.firstLights.prefix(3).joined(separator: ", ")
        return wrapped.firstLights.count > 3 ? Text(verbatim: "\(shown), …") : Text(verbatim: shown)
    }

    private func yearWrappedTile(
        title: LocalizedStringKey,
        value: String,
        detail: Text,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value).astroDataHero()
            detail
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRecessedSurface()
    }

    // Ideation #3 ("Ez a hónap tavalyhoz képest", "This month vs last
    // year"): unlike `yearWrappedCard` above, this card takes its data as
    // an OPTIONAL and still renders (with an honest empty state) when
    // `comparison` is `nil` -- a fresh library's very first August, say,
    // has genuinely nothing to compare against yet, and the whole point of
    // this card (checking in every single month, not once a year) means it
    // should say so rather than silently vanish the way `yearWrappedCard`
    // does for an empty year. Reuses `yearWrappedTile` verbatim for its own
    // stat tiles -- same raised/recessed surface vocabulary, no second
    // near-duplicate tile helper.
    private func monthOverYearCard(_ comparison: YearOverYearComparison?, currentMonth: Int) -> some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            Text("This month vs last year").font(.headline)
            if let comparison {
                monthOverYearHeadline(comparison)
                    .astroDisplay()
                    .accessibilityIdentifier("v2.insights.month-over-year-headline")
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160), spacing: AstroTokens.Spacing.compact)],
                    spacing: AstroTokens.Spacing.compact
                ) {
                    yearWrappedTile(
                        title: "Integration",
                        value: signedDuration(comparison.integrationSecondsDelta),
                        detail: monthOverYearIntegrationDetail(comparison),
                        systemImage: "timer"
                    )
                    yearWrappedTile(
                        title: "Sessions",
                        value: signedCount(comparison.sessionCountDelta),
                        detail: monthOverYearSessionDetail(comparison),
                        systemImage: "moon.stars"
                    )
                    // Sparse-data honesty, same posture `yearWrappedCard`'s
                    // own best-FWHM tile already takes: this tile drops
                    // entirely (not a placeholder) unless BOTH months carry
                    // a measured session in the SAME unit -- see
                    // `YearOverYearComparison.bestFWHM(thisPoints:lastPoints:)`'s
                    // own doc comment for why a unit mismatch also drops it.
                    if let fwhm = comparison.bestFWHM {
                        yearWrappedTile(
                            title: "Best FWHM",
                            value: signedFWHM(fwhm),
                            detail: monthOverYearFWHMDetail(fwhm),
                            systemImage: "star.circle.fill"
                        )
                    }
                }
            } else {
                Text(monthOverYearEmptyStateText(month: currentMonth))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("v2.insights.month-over-year-empty")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
        .accessibilityIdentifier("v2.insights.month-over-year")
    }

    /// Same "interpolate ONLY pre-formatted Strings" rule
    /// `yearWrappedHeadline`'s own doc comment states -- `hoursText`/
    /// `nightsText`/`deltaText` are all already-formatted `String`s, never a
    /// raw `Int`/`Double` handed straight to `Text`.
    private func monthOverYearHeadline(_ comparison: YearOverYearComparison) -> Text {
        let hoursText = duration(comparison.thisYearIntegrationSeconds)
        let nightsText = String(comparison.thisYearSessionCount)
        let deltaText = signedDuration(comparison.integrationSecondsDelta)
        return Text("This month you've collected \(hoursText) across \(nightsText) nights — \(deltaText) vs last year.")
    }

    private func monthOverYearIntegrationDetail(_ comparison: YearOverYearComparison) -> Text {
        let thisText = duration(comparison.thisYearIntegrationSeconds)
        let lastText = duration(comparison.lastYearIntegrationSeconds)
        return Text("\(thisText) this month vs \(lastText) last year")
    }

    private func monthOverYearSessionDetail(_ comparison: YearOverYearComparison) -> Text {
        let thisText = String(comparison.thisYearSessionCount)
        let lastText = String(comparison.lastYearSessionCount)
        return Text("\(thisText) this month vs \(lastText) last year")
    }

    private func monthOverYearFWHMDetail(_ fwhm: YearOverYearComparison.FWHMComparison) -> Text {
        let thisText = fwhm.isPixelFallback ? AstroFormat.fwhmPixels(fwhm.thisYearValue) : AstroFormat.fwhmArcsec(fwhm.thisYearValue)
        let lastText = fwhm.isPixelFallback ? AstroFormat.fwhmPixels(fwhm.lastYearValue) : AstroFormat.fwhmArcsec(fwhm.lastYearValue)
        return Text("\(thisText) this month vs \(lastText) last year")
    }

    /// This year's total minus last year's, rendered with an explicit
    /// `+`/`-` sign and `AstroFormat`'s own duration unit -- never a bare
    /// unsigned number a reader could mistake for an absolute total rather
    /// than a delta. `duration(_:)` itself only ever accepts a
    /// non-negative value (see its own doc comment on floor/round
    /// behavior), so the magnitude always goes through `abs(_:)` first and
    /// the sign is prepended afterward.
    private func signedDuration(_ secondsDelta: Double) -> String {
        let magnitude = duration(abs(secondsDelta))
        return secondsDelta < 0 ? "-\(magnitude)" : "+\(magnitude)"
    }

    private func signedCount(_ delta: Int) -> String {
        delta < 0 ? "-\(abs(delta))" : "+\(delta)"
    }

    private func signedFWHM(_ fwhm: YearOverYearComparison.FWHMComparison) -> String {
        let magnitude = fwhm.isPixelFallback
            ? AstroFormat.fwhmPixels(abs(fwhm.delta))
            : AstroFormat.fwhmArcsec(abs(fwhm.delta))
        return fwhm.delta < 0 ? "-\(magnitude)" : "+\(magnitude)"
    }

    /// One literal sentence per calendar month rather than a single
    /// %@-templated one -- judgment call: Hungarian month names take
    /// different, vowel-harmony-dependent grammatical suffixes ("augusztusban"
    /// vs "szeptemberben"), so no single template with an interpolated
    /// English month name could ever translate correctly for every month.
    /// Same per-case-literal posture `moonPhaseBandLabel`'s own switch
    /// already takes for band-specific text, just switched over `Int`
    /// instead of an enum.
    private func monthOverYearEmptyStateText(month: Int) -> LocalizedStringKey {
        switch month {
        case 1: return "No prior-year data yet for January — next year you'll have something to compare."
        case 2: return "No prior-year data yet for February — next year you'll have something to compare."
        case 3: return "No prior-year data yet for March — next year you'll have something to compare."
        case 4: return "No prior-year data yet for April — next year you'll have something to compare."
        case 5: return "No prior-year data yet for May — next year you'll have something to compare."
        case 6: return "No prior-year data yet for June — next year you'll have something to compare."
        case 7: return "No prior-year data yet for July — next year you'll have something to compare."
        case 8: return "No prior-year data yet for August — next year you'll have something to compare."
        case 9: return "No prior-year data yet for September — next year you'll have something to compare."
        case 10: return "No prior-year data yet for October — next year you'll have something to compare."
        case 11: return "No prior-year data yet for November — next year you'll have something to compare."
        default: return "No prior-year data yet for December — next year you'll have something to compare."
        }
    }

    private func metrics(_ insight: InsightsSnapshot) -> some View {
        HStack(spacing: AstroTokens.Spacing.standard) {
            MetricCard(title: "Integration", value: duration(insight.integrationSeconds), detail: "Deduplicated, verified exposure", systemImage: "timer")
            // W6-E item 3, applied by the coordinator (this file was another
            // agent's during that wave): this count is target×date session
            // pairs, NOT deduplicated calendar nights -- Home's 16 vs this 26
            // confused the owner until each label said what it counts.
            MetricCard(title: "Capture Sessions", value: "\(insight.nightCount)", detail: "One night with two targets counts twice", systemImage: "moon.stars")
            MetricCard(title: "Targets", value: "\(insight.targetCount)", detail: "Unique objects", systemImage: "scope")
            MetricCard(title: "Light frames", value: "\(insight.frameCount)", detail: "Indexed and present", systemImage: "photo.stack")
            MetricCard(title: "Average night", value: duration(insight.averageIntegrationPerNight), detail: averageNightDetail(insight), systemImage: "chart.bar.fill")
        }
    }

    // V2 localization sweep (W3-13): this used to build a plain `String` via
    // ordinary interpolation (`"Best month: \($0.month)"`) and wrap the
    // ALREADY-SUBSTITUTED result in `LocalizedStringKey(...)` afterward --
    // that produces a key equal to the finished sentence ("Best month:
    // March 2026"), which matches no `hu.lproj` entry, instead of a key with
    // a real `%@` argument ("Best month: %@", which DOES have one). Writing
    // the interpolation directly in a function whose return type is already
    // `LocalizedStringKey` (matching `SkyVerdictKind.displayLabel`'s own
    // pattern) keeps the substituted month a genuine format argument.
    private func averageNightDetail(_ insight: InsightsSnapshot) -> LocalizedStringKey {
        guard let bestMonth = insight.bestMonth else { return "No monthly data" }
        return "Best month: \(bestMonth.month)"
    }

    private func qualitySummary(_ insight: InsightsSnapshot) -> some View {
        // Task 7 (2026-08-17, GroupBox removal): heading plus spacing, same
        // reasoning as `qualityTrends` above.
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("Capture efficiency").font(.headline)
            HStack(spacing: AstroTokens.Spacing.spacious) {
                Label("\(insight.usableFrameCount) usable", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AstroTokens.Color.ok)
                Label("\(insight.rejectedFrameCount) rejected", systemImage: "xmark.circle.fill")
                    .foregroundStyle(insight.rejectedFrameCount == 0 ? Color.secondary : AstroTokens.Color.attention)
                Spacer()
                Text(insight.captureEfficiency, format: .percent.precision(.fractionLength(0)))
                    .font(.title2.weight(.semibold).monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
        .accessibilityIdentifier("v2.insights.quality")
    }

    private func filterBreakdown(_ insight: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("Filters and passbands").font(.headline)
            ForEach(insight.filterUsage.prefix(8)) { item in
                HStack {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(AstroTokens.Color.accent)
                    Text(item.name).lineLimit(1)
                    Spacer()
                    Text("\(item.frameCount) · \(duration(item.integrationSeconds))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if insight.filterUsage.isEmpty {
                Text("No filter metadata yet").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
        .accessibilityIdentifier("v2.insights.filters")
    }

    private func setupBreakdown(_ insight: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("Equipment usage").font(.headline)
            ForEach(insight.setupUsage.prefix(8)) { item in
                HStack {
                    Image(systemName: "camera.aperture")
                        .foregroundStyle(AstroTokens.Color.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.camera).lineLimit(1)
                        if let focalLength = item.focalLength {
                            Text("\(focalLength.formatted(.number.precision(.fractionLength(0...1)))) mm")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("\(item.frameCount) · \(duration(item.integrationSeconds))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if insight.setupUsage.isEmpty {
                Text("No equipment metadata yet").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
        .accessibilityIdentifier("v2.insights.equipment")
    }

    private func activityChart(_ insight: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("Capture activity").font(.headline)
            Chart(insight.months) { month in
                BarMark(x: .value("Month", month.month), y: .value("Hours", month.integrationSeconds / 3600))
                    .foregroundStyle(AstroTokens.Color.accent.gradient)
                    .cornerRadius(4)
            }
            .chartYAxisLabel("Integration hours")
            .frame(minHeight: 260)
            .accessibilityIdentifier("v2.insights.activity")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
    }

    private func targetRanking(_ insight: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("Most photographed").font(.headline)
            ForEach(Array(insight.topTargets.enumerated()), id: \.element.id) { index, target in
                HStack {
                    Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.target).lineLimit(1)
                        Text("\(duration(target.integrationSeconds)) · \(target.nightCount) nights")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            if insight.topTargets.isEmpty { Text("No light frames yet").foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
    }

    private func duration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

}

private struct InsightTrendDatum: Identifiable {
    let id: String
    let date: String
    let target: String
    let value: Double
}

/// W4-4 item 6 (owner review): "with <2 measured sessions the three trend
/// charts render" a lone dot, an empty-state graphic, and an x-axis of
/// nothing but "…" -- three different symptoms of the same underlying
/// problem, a chart drawn for data that cannot show a trend. This is the
/// honest classification `InsightsView.trendChart` switches on instead of
/// rendering `Chart` unconditionally; `internal` (not `private`), so
/// `InsightTrendChartStateTests` can exercise it directly without rendering
/// a view.
enum InsightTrendChartState: Equatable {
    /// No session has a measured value for this metric at all.
    case noData
    /// Exactly one session does -- a single point has nothing to compare
    /// against and cannot show a trend, even though `Chart` would happily
    /// draw one lone dot.
    case singleSession
    /// Two or more measured sessions -- enough to actually show a trend.
    case trend

    init(pointCount: Int) {
        switch pointCount {
        case 0: self = .noData
        case 1: self = .singleSession
        default: self = .trend
        }
    }

    /// The owner's own two phrasings ("1 mért capture — a trendhez több
    /// mérés kell" / "Nincsenek mért értékek") -- hand-added at the
    /// `hu.lproj` tail since both keys reach `Text` through a ternary here,
    /// which the extraction script does not see. Never called for
    /// `.trend`, which renders the chart itself instead. W6-B: the singular
    /// key reads "capture", not "session", now that this chart's points are
    /// per-capture (`CaptureTrendPoint`) rather than per-session.
    static func unavailableMessage(pointCount: Int) -> LocalizedStringKey {
        pointCount == 1
            ? "Only one measured capture — more measurements are needed for a trend"
            : "No measured values"
    }

    /// Caps how many x-axis ticks a categorical (`String`-dated) trend
    /// chart draws. With one tick per session and a dozen-plus measured
    /// sessions crammed into a third of the row's width, Swift Charts used
    /// to shrink every single label down to nothing but its own ellipsis
    /// ("…") -- worse than no label at all (the Efficiency chart's own
    /// defect, since it typically has the most measured sessions of the
    /// three). Every Nth date, capped at `maxTicks`, keeps each surviving
    /// label wide enough to actually read; below `maxTicks` sessions, every
    /// date still gets its own tick, exactly as before this task.
    static func thinnedAxisDates(_ dates: [String], maxTicks: Int = 6) -> [String] {
        guard dates.count > maxTicks else { return dates }
        let stride = Int((Double(dates.count) / Double(maxTicks)).rounded(.up))
        return dates.enumerated().compactMap { index, date in
            index.isMultiple(of: stride) ? date : nil
        }
    }

    /// W5-2 finding 2 (owner pixel review): capping ticks at `maxTicks`
    /// (above) was not enough on its own -- every surviving label still
    /// rendered as a bare "…" on the real screen. `qualityTrends` lays the
    /// three charts (FWHM/Background/Efficiency) out as equal thirds of one
    /// row (`HStack(spacing: 12)`, each `.frame(maxWidth: .infinity)`); at a
    /// typical ~900pt workspace width that is roughly 292pt per chart, and
    /// with 6 ticks that is ~49pt of budget PER TICK including its grid
    /// line's own spacing. A full `YYYY-MM-DD` label ("2026-08-14", 10
    /// characters) is ~65-75pt at caption size -- wider than the whole
    /// per-tick budget, so Swift Charts collapsed it to its own ellipsis
    /// exactly as the owner saw. `MM-dd` ("08-14", 5 characters, ~33-38pt)
    /// fits inside that budget with room for tick spacing; the year is
    /// implicit and never ambiguous within one chart's date range. Called
    /// from the ONE shared `trendChart` function's `AxisValueLabel`, so the
    /// FWHM/Background/Efficiency charts can never drift apart on this. A
    /// date that doesn't parse as `YYYY-MM-DD` (e.g. a raw, non-date
    /// session-dir name -- `TrendPoint.date`'s documented possibility)
    /// renders verbatim rather than being mangled by a false-positive split.
    static func shortAxisLabel(for date: String) -> String {
        let parts = date.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return date }
        return "\(parts[1])-\(parts[2])"
    }
}
