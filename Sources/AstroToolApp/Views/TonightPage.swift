import AstroCore
import SwiftUI

/// R9-T4/A.1 -- "Ma este" + "Naptár" merged into one page behind a
/// `Picker(.segmented)`: the plan for tonight (or, after a calendar row's
/// "Terv erre az éjszakára", a different night) alongside the 30-night
/// planning calendar (`Planner.month`, formerly the standalone `CalendarPage`
/// R9-T1 carried over unchanged). Replaces the old `OverviewView`
/// (scan/audit/cleanup/projects boxes moved to `AuditPage`/the toolbar/the
/// sidebar phase-dots/the plan table's own "Állapot" column) and the old
/// `CalendarPage` (now `AppState.TonightSegment.calendar`, reached via the
/// sidebar's "Naptár" row or ⌘2 navigating to `Page.calendar` -- the segment
/// itself is DERIVED from `currentPage`, see `AppState.tonightSegment`'s own
/// doc comment; same "one page, no separate page for the sub-view" idea the
/// sidebar's "Takarítás" row already established for `AppState.auditSegment`).
struct TonightPage: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    @State private var sortOrder = [KeyPathComparator(\PlanRow.score, order: .reverse)]
    @State private var goalEditingTarget: GoalEditingTarget?
    @State private var solvingTarget: SolvingTarget?
    /// R9-D11: row-scoped selection for `planTable`'s
    /// `.contextMenu(forSelectionType:)` -- previously the context menu/
    /// double-click were attached to just the "Célpont" cell's `Text`, so
    /// right-clicking or double-clicking anywhere else in a row did nothing.
    @State private var selectedPlanTarget: String?
    /// Same idea for `calendarTable`.
    @State private var selectedCalendarNight: String?
    /// R11-T6/F18b: "Kalibrációs teendők ma estére" DisclosureGroup at the
    /// bottom of the "Ma este" segment -- always starts collapsed (spec:
    /// "Alapból csukva... akkor is csukva indulhat, de a badge látszódjon"),
    /// the item-count badge on its label is what surfaces whether there's
    /// anything in it without forcing it open.
    @State private var calibShoppingExpanded = false

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                // R11-T13/F13: binds straight to `appState.tonightSegment`,
                // which is itself now DERIVED from (and writes straight back
                // to) `currentPage` -- see that property's own doc comment.
                // No separate binding needed anymore to also keep
                // `currentPage` in sync (N8, R9 round 3's original fix for
                // this).
                Picker("", selection: $appState.tonightSegment) {
                    Text("Ma este").tag(AppState.TonightSegment.tonight)
                    Text("Következő 30 éjszaka").tag(AppState.TonightSegment.calendar)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)

                sitePickerIfNeeded
            }

            switch appState.tonightSegment {
            case .tonight: tonightSegmentView
            case .calendar: calendarSegmentView
            }
        }
        .padding()
        .onAppear {
            // R9-D3: `loadStats()` and `loadPlan()` fired back-to-back here
            // used to race (each `beginOperation` cancels the previous
            // `currentTask`, so only the second call's result ever landed --
            // `stats`/sidebar phase dots stayed empty). `loadDashboardData()`
            // loads both (+ projects/cleanup) in one background operation.
            // N9 (R9 round 3): `!appState.isBusy` stops this from firing a
            // SECOND redundant `loadDashboardData()` right behind the one
            // `openRoot` already kicked off at launch -- without it, a
            // fresh launch landing on "Ma este" (its default page) ran the
            // whole dashboard query set twice back-to-back.
            if !appState.isBusy && (appState.stats.isEmpty || appState.plan == nil) {
                appState.loadDashboardData()
            }
        }
        .sheet(item: $goalEditingTarget) { editing in
            GoalEditSheet(target: editing.target, initialHours: editing.currentHours)
        }
        .sheet(item: $solvingTarget) { solving in
            PlateSolveSheet(target: solving.target)
        }
        .toolbar {
            // R11-T6/F18a: only meaningful for the "Ma este" plan table
            // itself, not the "Következő 30 éjszaka" calendar segment (which
            // has no per-target RA/Dec/window/verdict to export at all).
            if appState.tonightSegment == .tonight {
                ToolbarItem {
                    Menu("Terv exportálása…") {
                        Button("Vágólapra") { appState.copyPlanToClipboard(rowsToExport) }
                        Button("CSV-fájlba…") { appState.exportPlanToCSV(rowsToExport) }
                    }
                    .disabled(rowsToExport.isEmpty)
                }
            }
        }
    }

    // MARK: - Site picker (R11-T15/F16)

    /// Only appears once more than one site is configured -- a single (or
    /// zero) configured site has nothing to disambiguate, so the picker
    /// would just be permanently stuck on its one option. Selection is
    /// always a concrete site NAME (never `nil`): `sitePickerSelection`'s
    /// getter falls back to the configured default whenever `appState.
    /// selectedSiteName` is unset or no longer names a real site (a
    /// deleted-mid-session site, same forgiving stance `AppState.
    /// effectiveSiteName` itself documents), so the control never shows a
    /// blank/invalid selection.
    @ViewBuilder
    private var sitePickerIfNeeded: some View {
        if appState.config.sites.count > 1 {
            Picker("Helyszín", selection: sitePickerSelection) {
                ForEach(appState.config.sites) { site in
                    Text(site.name).tag(site.name)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
        }
    }

    private var sitePickerSelection: Binding<String> {
        Binding(
            get: {
                appState.effectiveSiteName ?? SiteProfile.defaultSite(in: appState.config.sites)?.name ?? ""
            },
            set: { newName in
                appState.selectedSiteName = newName
                // Every dataset that plans against a site recomputes --
                // `plan`/`resolvedSite`/`nightInfo` always (this page's own
                // tiles/table), `monthPlan`/`discovery` only if they were
                // ever loaded this session (same "refresh what's already on
                // screen, don't eagerly load what wasn't" stance
                // `LocationSettingsView.save()` already takes for these same
                // two datasets).
                appState.loadPlan(date: appState.planDate)
                if appState.monthPlan != nil { appState.loadMonthPlan() }
                if appState.discovery != nil { appState.loadDiscovery() }
                appState.loadWeather()
            }
        )
    }

    // MARK: - "Ma este" segment

    private var tonightSegmentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // R11-T12/F12: dismissible, at the very top -- gone for good
            // (persisted, `AppState.firstStepsCardDismissed`) once the user
            // waves it off, and never shown again once 4+ of the 6 steps
            // are already done (spec: "amíg < 4 pipa").
            if showsFirstStepsCard {
                firstStepsCard
            }

            HStack {
                if appState.planDate != nil {
                    dateScopedCaption
                }
                Spacer()
                if appState.isBusy {
                    ProgressView().controlSize(.small)
                }
                Button("Frissítés") { appState.loadDashboardData(date: appState.planDate) }
                    .disabled(appState.isBusy || appState.db == nil)
            }

            if !hasResolvedSite {
                noSiteBanner
            }

            tilesRow

            Group {
                if let plan = appState.plan {
                    if plan.isEmpty {
                        noTargetsState
                    } else if plan.allSatisfy({ $0.raDeg == nil }) {
                        noCoordinatesState
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            if showsCloudContextBanner {
                                cloudContextBanner
                            }
                            HStack {
                                Spacer()
                                MetricInfoButton(metrics: Self.planMetricInfo)
                            }
                            planTable
                            // R10-B2: the selected row's altitude-over-the-
                            // night chart, below the table (resizes better
                            // than a trailing side panel -- the table stays
                            // full-width and the chart just takes a fixed
                            // band at the bottom).
                            if let selectedPlanTarget {
                                selectedTargetChartSection(selectedPlanTarget)
                            }
                        }
                    }
                } else if appState.isBusy {
                    ProgressView("Terv számítása…")
                } else {
                    ContentUnavailableView("Még nincs számolva", systemImage: "moon.stars")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // R11-T6/F18b: lap alján, mindig -- akkor is renderelődik, ha
            // épp nincs tétel (az üres állapot szövege a "minden friss"
            // visszajelzés).
            calibShoppingSection
        }
    }

    /// R11-T6/F18a: rows the "Terv exportálása…" toolbar menu hands to
    /// `PlanExport` -- the selected row when there is one (`planTable`'s
    /// selection is single-row only, so "kijelölt sorok" here means "the one
    /// currently selected row"), else every "ma jó"-verdict row, else every
    /// row on the table.
    private var rowsToExport: [TargetPlan] {
        guard let plan = appState.plan else { return [] }
        if let selectedPlanTarget, let selected = plan.first(where: { $0.target == selectedPlanTarget }) {
            return [selected]
        }
        let recommended = plan.filter { $0.verdict.hasPrefix("ma jó") }
        return recommended.isEmpty ? plan : recommended
    }

    private var dateScopedCaption: some View {
        HStack(spacing: 8) {
            if let date = appState.planDate {
                Text("\(Self.isoDateFormatter.string(from: date)) éjszakájára")
                    .foregroundStyle(.secondary)
            }
            Button("Vissza a mai estéhez") { appState.loadPlan() }
                .buttonStyle(.link)
        }
        .font(.callout)
    }

    /// R9-T4/A.1's yellow inline banner: shown whenever the site can't be
    /// resolved at all (neither an explicit `config.site` nor a library-wide
    /// SITELAT/SITELONG median) -- the genuine empty state, distinct from
    /// the Helyszín tile's own "FITS-fejlécekből" caption for the common
    /// (working, just invisible) auto-derived case.
    private var noSiteBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("Nincs megfigyelési helyszín beállítva — a magasság/kulmináció a FITS-fejlécekből becsült.")
                .font(.callout)
            Spacer()
            Button("Beállítás…") {
                appState.settingsTab = .location
                openSettings()
            }
            .buttonStyle(.link)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.15)))
    }

    // MARK: - Első lépések card (R11-T12/F12)

    private var showsFirstStepsCard: Bool {
        !appState.firstStepsCardDismissed && appState.firstSteps.count { $0.isDone } < 4
    }

    /// Dismissible "Első lépések" nudge -- same "`Text` + trailing plain
    /// `xmark` button" shape `cloudContextBanner` already establishes below,
    /// just persisted (`firstStepsCardDismissed`) rather than session-only.
    private var firstStepsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Első lépések").font(.subheadline).bold()
                Spacer()
                Button {
                    appState.firstStepsCardDismissed = true
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            FirstStepsChecklistView()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - Calibration shopping list (R11-T6/F18b)

    /// Tonight's actionable dark-calibration items (`CalibShoppingList.
    /// build`) -- purely derived from data `loadDashboardData()` already
    /// loads (`calibNeeds`/`plan`), so this needs no state of its own.
    private var tonightCalibShoppingList: [CalibShoppingList.Item] {
        CalibShoppingList.build(coverage: appState.calibNeeds, plans: appState.plan ?? [])
    }

    /// "Kalibrációs teendők ma estére" -- always starts collapsed (see
    /// `calibShoppingExpanded`'s own doc comment); the badge on the label is
    /// what tells the user there's something inside without opening it.
    private var calibShoppingSection: some View {
        DisclosureGroup(isExpanded: $calibShoppingExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if tonightCalibShoppingList.isEmpty {
                    Text("Minden szükséges kalibráció friss — nincs teendő ma estére.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(tonightCalibShoppingList.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "square").foregroundStyle(.secondary)
                            Text(item.summary).font(.callout)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Másolás Markdownként") {
                            appState.copyCalibShoppingListToClipboard(tonightCalibShoppingList)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Text("Kalibrációs teendők ma estére")
                if !tonightCalibShoppingList.isEmpty {
                    Text("\(tonightCalibShoppingList.count)")
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
    }

    // MARK: - Empty states (A.1)

    private var noTargetsState: some View {
        ContentUnavailableView {
            Label("Még nincs célpont", systemImage: "moon.stars")
        } description: {
            Text("Olvasd be a könyvtárat, vagy hozz létre egy új sessiont.")
        } actions: {
            Button("Beolvasás") { appState.runScan() }
                .disabled(appState.isBusy || appState.db == nil)
            Button("Új session…") { NotificationCenter.default.post(name: .newSession, object: nil) }
                .disabled(appState.db == nil)
        }
    }

    private var noCoordinatesState: some View {
        ContentUnavailableView {
            Label("Még nincs célpont", systemImage: "moon.stars")
        } description: {
            Text("Egyik célpontnak sincs koordinátája.")
        } actions: {
            Button("Plate-solve mindenre…") { appState.runPlateSolveAll() }
                .disabled(appState.isBusy || appState.db == nil)
        }
    }

    // MARK: - 4 tiles

    private var hasResolvedSite: Bool {
        appState.resolvedSite.latitudeDeg != nil && appState.resolvedSite.longitudeDeg != nil
    }

    // R10 review (item 20): TILES use "n/a" for a missing value, not "-"
    // (which reads as a dash/minus rather than "no data" at tile scale) --
    // see `TDFormat`'s own doc comment for the full rule. `darkHoursText`/
    // `moonTileText`/`locationValueText` feed `StatTile`s below; `cloudTile`
    // already used "n/a" correctly (R10-B6).
    private var darkHoursText: String {
        guard let hours = appState.nightInfo?.darkHours else { return TDFormat.missingTile }
        return String(format: "%.1f óra", hours)
    }

    private var moonTileText: String {
        guard let info = appState.nightInfo else { return TDFormat.missingTile }
        var text = TDFormat.percent(info.moonIlluminationPercent)
        if let label = info.moonEventLabel { text += " · \(label)" }
        return text
    }

    private var recommendedCount: Int {
        // R11-T6/F3: `hasPrefix`, not `==` -- an NB-augmented verdict
        // ("ma jó — Ha-ra") is still a "shoot this tonight" recommendation.
        appState.plan?.count { $0.verdict.hasPrefix("ma jó") } ?? 0
    }

    private var locationValueText: String {
        guard hasResolvedSite, let lat = appState.resolvedSite.latitudeDeg, let lon = appState.resolvedSite.longitudeDeg else {
            return TDFormat.missingTile
        }
        let latDir = lat >= 0 ? "N" : "S"
        let lonDir = lon >= 0 ? "E" : "W"
        return String(format: "%.2f° %@  %.2f° %@", abs(lat), latDir, abs(lon), lonDir)
    }

    private var locationCaptionText: String {
        guard hasResolvedSite else { return "nincs beállítva" }
        let isManual = appState.config.site.latitudeDeg != nil || appState.config.site.longitudeDeg != nil
        return isManual ? "kézzel beállítva" : "FITS-fejlécekből"
    }

    private var tilesRow: some View {
        HStack(spacing: 12) {
            StatTile(title: "Sötét idő", value: darkHoursText, caption: appState.nightInfo?.note, compact: true)
            StatTile(title: "Hold", value: moonTileText, compact: true)
            StatTile(title: "Ajánlott", value: "\(recommendedCount)", compact: true)
            Button {
                appState.settingsTab = .location
                openSettings()
            } label: {
                StatTile(title: "Helyszín", value: locationValueText, caption: locationCaptionText, compact: true)
            }
            .buttonStyle(.plain)
            cloudTile
        }
    }

    // MARK: - Felhőzet tile (R10-B6)

    /// Only wrapped in a `Button` (same "tappable tile opens Settings ▸
    /// Helyszín" pattern the "Helyszín" tile above always uses) while the
    /// feature is OFF -- once it's on, the tile just shows data/state, same
    /// as "Sötét idő"/"Hold"/"Ajánlott".
    @ViewBuilder
    private var cloudTile: some View {
        let info = cloudTileInfo
        if appState.config.weather.enabled {
            StatTile(title: "Felhőzet", value: info.value, caption: info.caption, compact: true)
        } else {
            Button {
                appState.settingsTab = .location
                openSettings()
            } label: {
                StatTile(title: "Felhőzet", value: info.value, caption: info.caption, compact: true)
            }
            .buttonStyle(.plain)
        }
    }

    /// The tile's four states (R10-B6 spec): disabled / enabled-with-data /
    /// enabled-but-still-loading / fetch-failed. `nightForecast` and
    /// `weatherError` are mutually exclusive in practice -- `WeatherService`
    /// only ever throws when there was NO cached forecast to fall back on,
    /// so a non-`nil` `nightForecast` always wins when both happen to be
    /// set (a stale forecast is still more informative than the error that
    /// prompted the LATEST refetch attempt).
    private var cloudTileInfo: (value: String, caption: String) {
        guard appState.config.weather.enabled else {
            return ("ki", "Bekapcsolás…")
        }
        if let forecast = appState.nightForecast {
            if let (dusk, dawn) = cloudDuskDawn(forecast) {
                let text = "\(TDFormat.percent(dusk)) → \(TDFormat.percent(dawn))"
                return (text, "Open-Meteo · \(Self.hmFormatter.string(from: forecast.fetchedAt))")
            }
            return (TDFormat.missingTile, "a 7 napos előrejelzésen túl")
        }
        if let weatherError = appState.weatherError {
            return (TDFormat.missingTile, weatherError)
        }
        return ("…", "betöltés")
    }

    /// Cloud cover at dusk/dawn for whichever night the tiles row currently
    /// shows (`planDate`, or tonight) -- real astronomical dusk/dawn via
    /// `SkyTrack.nightWindowMarkers` when the site is resolved (the same
    /// source `selectedTargetChartSection`'s chart already uses), else a
    /// fixed 22:00/04:00 local fallback (R10-B6 spec). `nil` when the night
    /// falls outside `forecast`'s window -- `NightForecast.cloudPercent`'s
    /// own 90-minute tolerance is what actually enforces that, e.g. for a
    /// calendar night picked beyond Open-Meteo's 7-day horizon.
    private func cloudDuskDawn(_ forecast: NightForecast) -> (dusk: Double, dawn: Double)? {
        let night = appState.planDate ?? Date()
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: night)

        var duskTarget = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: dayStart) ?? night
        var dawnTarget = calendar.date(byAdding: .day, value: 1, to: dayStart)
            .flatMap { calendar.date(bySettingHour: 4, minute: 0, second: 0, of: $0) } ?? night

        if let lat = appState.resolvedSite.latitudeDeg, let lon = appState.resolvedSite.longitudeDeg {
            let markers = SkyTrack.nightWindowMarkers(nightOf: night, latDeg: lat, lonDeg: lon)
            if let duskUTC = markers.astroDuskUTC { duskTarget = duskUTC }
            if let dawnUTC = markers.astroDawnUTC { dawnTarget = dawnUTC }
        }

        guard let duskPercent = forecast.cloudPercent(nearestTo: duskTarget),
              let dawnPercent = forecast.cloudPercent(nearestTo: dawnTarget) else { return nil }
        return (duskPercent, dawnPercent)
    }

    private static let hmFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    // MARK: - Cloud-context banner (R11-T2)

    /// `true` when weather is on AND tonight's mean cloud cover (Open-Meteo's
    /// own daily summary, the same `weatherDailySummaries` dictionary
    /// `calendarSegmentView`'s "Felhő" column already reads) is above 70% --
    /// gates `cloudContextBanner`, a one-line nudge above `planTable` toward
    /// a clearer night on the calendar. Keyed on TODAY's date specifically
    /// (not `appState.planDate`, which can point at a different night after
    /// "Terv erre az éjszakára") -- this is about TONIGHT regardless of
    /// which night's plan happens to be on screen.
    private var showsCloudContextBanner: Bool {
        guard appState.config.weather.enabled, !appState.cloudBannerDismissed else { return false }
        guard let summary = appState.weatherDailySummaries[Self.todayString] else { return false }
        return summary.meanPercent > 70
    }

    private var cloudContextBannerText: String {
        let percent = Int((appState.weatherDailySummaries[Self.todayString]?.meanPercent ?? 0).rounded())
        return "Ma este ~\(percent)% felhő várható —"
    }

    /// One-line, dismissible (session-scoped -- `AppState.cloudBannerDismissed`,
    /// see its own doc comment for why not a plain `@State` here) nudge
    /// toward a clearer night: "a következő derült éjszakát" is itself the
    /// link, switching to the Naptár segment (simple segment-switch, not a
    /// specific night highlight -- the spec allows either).
    private var cloudContextBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "cloud.fill").foregroundStyle(.orange)
            Text(cloudContextBannerText).font(.callout)
            Button("nézd meg a következő derült éjszakát") {
                // R11-T13/F13: `currentPage` alone is enough now --
                // `tonightSegment` is derived from it, see that property's
                // own doc comment.
                appState.currentPage = .calendar
            }
            .buttonStyle(.link)
            .font(.callout)
            Spacer()
            Button {
                appState.cloudBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    // MARK: - Plan table

    /// Flattened, sortable view of a `TargetPlan` + its `ProjectState` --
    /// same "one `Identifiable`/`KeyPathComparator`-friendly row struct"
    /// pattern `QualitySegment.Row` established.
    private struct PlanRow: Identifiable {
        let id: String
        let plan: TargetPlan
        let phase: ProjectPhase?
        let missingSeconds: Double?

        var displayName: String { plan.displayName }
        /// Sidebar's own fixed phase order (gyűjtés/stackelhető/
        /// feldolgozásra vár/kész), un-phased last -- reused here so the
        /// "Állapot" column sorts the same way the sidebar's dots do.
        var phaseRank: Int {
            switch phase {
            case .collecting: return 0
            case .readyToStack: return 1
            case .stacked: return 2
            case .done: return 3
            case nil: return 4
            }
        }
        var integrationSeconds: Double { plan.usableIntegrationSeconds }
        var goalSortKey: Double { plan.goalSeconds ?? -1 }
        var missingSortKey: Double { missingSeconds ?? -1 }
        var culminationSortKey: String { plan.culminationLocal ?? "" }
        var maxAltSortKey: Double { plan.maxAltitudeDeg ?? -999 }
        var visibleHoursSortKey: Double { plan.visibleHours ?? -1 }
        var moonSortKey: Double { plan.moonIlluminationPercent ?? -1 }
        var verdictSortKey: String { plan.verdict }
        var score: Double { plan.score }
        /// R11-T6/F3: same chip text `filterAdviceCell` shows -- `""` sorts
        /// first, same "-" cell convention every other missing-value column
        /// already sorts before real values.
        var filterAdviceSortKey: String {
            guard let advice = plan.filterAdvice else { return "" }
            return FilterAdvisor.chipText(advice: advice, filterGoals: plan.filterGoals) ?? ""
        }
    }

    private var planRows: [PlanRow] {
        guard let plan = appState.plan else { return [] }
        let phaseByTarget = Dictionary(uniqueKeysWithValues: appState.projectStates.map { ($0.target, $0.phase) })
        let missingByTarget: [String: Double?] = Dictionary(
            uniqueKeysWithValues: appState.projectStates.map { ($0.target, $0.missingSeconds) }
        )
        return plan.map { p in
            PlanRow(
                id: p.target,
                plan: p,
                phase: phaseByTarget[p.target],
                missingSeconds: missingByTarget[p.target].flatMap { $0 }
            )
        }.sorted(using: sortOrder)
    }

    /// D32: this table's computed-metric columns, explained -- same
    /// "one button per table" `MetricInfoButton` pattern
    /// `SessionsSegment`/`QualitySegment` already established.
    private static let planMetricInfo: [MetricInfoButton.Metric] = [
        .init(
            title: "Max. mag.",
            explanation: "A célpont legnagyobb magassága fokban a ma esti látszó ívén (nem fényesség!). Mikor hazudik: helyszín nélkül a FITS-fejlécekből becsült, pontatlanabb koordinátát használ."
        ),
        .init(
            title: "Látható",
            explanation: "A célpont horizont feletti (vagy egyéb minimum-magasság feletti) ideje a mai éjszaka sötét szakaszában, óra:perc formátumban. Mikor hazudik: koordináta vagy helyszín nélkül „-”."
        ),
        .init(
            title: "Hold",
            explanation: "A Hold megvilágítottsága százalékban, plusz a célponttól mért szögtávolsága fokban. Mikor hazudik: nagy szögtávolságnál a megvilágítottság önmagában túlbecsülheti a valós zavarást."
        ),
        .init(
            title: "Döntés",
            // R10 review (item 10): quoted verdicts now match the REAL
            // strings `NightSweep`/`Planner.plan` actually produce (was
            // „nem látható ma éjjel”/„túl alacsony”, neither of which this
            // app ever shows -- the real ones are „nem látszik ma éjjel”
            // and „alacsony (max N°)”) -- copied from `DiscoveryPage`'s own
            // (correct) copy of this same explanation.
            explanation: "Összesítő ajánlás („ma jó” / „Hold zavar (…)” / „nem látszik ma éjjel” / „alacsony (max N°)” / „nincs koordináta”) a magasság, a láthatósági ablak és a Hold-közelség alapján. Mikor hazudik: csak MA éjjelre szól, egy korábban jó célpont holnap már más döntést kaphat."
        ),
        .init(
            title: "Szűrő ma",
            explanation: "Hold-tudatos szűrő-ajánlás: a Hold megvilágítottsága (>40%) vagy a célponttól mért kis szögtávolság (<60°) esetén keskenysáv-éjszakát javasol, egyébként sötét eget — szűrőnkénti célok (T5) esetén a legnagyobb hiányú, kategóriába illő szűrőt nevezi meg óraszámmal. Mikor hazudik: csak ajánlás, sosem kényszerítő szabály; szűrőnkénti cél nélkül „-”."
        ),
    ]

    private var planTable: some View {
        Table(planRows, selection: $selectedPlanTarget, sortOrder: $sortOrder) {
            TableColumn("Célpont", value: \.displayName) { row in targetCell(row) }
                .width(min: 200, ideal: 240)
            TableColumn("Állapot", value: \.phaseRank) { row in PhaseChip(phase: row.phase) }
                .width(130)
            TableColumn("Integráció", value: \.integrationSeconds) { row in
                Text(TDFormat.hm(row.integrationSeconds))
            }
            .width(90)
            TableColumn("Cél", value: \.goalSortKey) { row in goalCell(row) }
                .width(110)
            TableColumn("Hiányzik", value: \.missingSortKey) { row in missingCell(row) }
                .width(90)
            // R10-B7: grouped so the table stays AT (not over) `Table`'s
            // 10-top-level-column cap once the trailing "⋯" actions column
            // below needs its own slot -- same `Group { }` workaround
            // `QualitySegment.frameTable` already established. R11-T6/F3
            // added "Szűrő ma" into the same group for the same reason
            // (adding it as its own top-level column would push the table
            // past the cap).
            Group {
                TableColumn("Szűrő ma", value: \.filterAdviceSortKey) { row in filterAdviceCell(row) }
                    .width(110)
                TableColumn("Kulminál", value: \.culminationSortKey) { row in
                    Text(culminationText(row))
                }
                .width(80)
                TableColumn("Max. mag.", value: \.maxAltSortKey) { row in Text(maxAltText(row)) }
                    .width(80)
            }
            TableColumn("Látható", value: \.visibleHoursSortKey) { row in Text(visibleText(row)) }
                .width(150)
            TableColumn("Hold", value: \.moonSortKey) { row in Text(moonRowText(row)) }
                .width(110)
            // R11-T12/F11(d): clickable -- popover with the numbers behind
            // tonight's verdict (max magasság, látható órák, Hold-illum%,
            // Hold-szeparáció), all straight off this same `TargetPlan`.
            TableColumn("Döntés", value: \.verdictSortKey) { row in
                VerdictExplainPopover(
                    verdict: row.plan.verdict,
                    maxAltitudeDeg: row.plan.maxAltitudeDeg,
                    visibleHours: row.plan.visibleHours,
                    moonIlluminationPercent: row.plan.moonIlluminationPercent,
                    moonSeparationDeg: row.plan.moonSeparationDeg
                )
            }
            .width(140)
            // R10-B7: visible row-actions -- mirrors `planContextMenuItems`
            // exactly (same function, both call sites), so the right-click
            // menu and this borderless "⋯" button can never drift apart.
            TableColumn("") { row in
                Menu {
                    planContextMenuItems(row)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .width(actionColumnWidth)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        // R9-D11: row-scoped context menu + double-click-to-open, same
        // pattern `SessionsSegment.table` uses -- replaces the old per-cell
        // `.contextMenu`/`.onTapGesture` that only fired over the "Célpont"
        // cell's own text.
        .contextMenu(forSelectionType: String.self) { targets in
            if let target = targets.first, let row = planRows.first(where: { $0.id == target }) {
                planContextMenuItems(row)
            }
        } primaryAction: { targets in
            if let target = targets.first {
                appState.currentPage = .target(target)
            }
        }
    }

    // MARK: - Selected-row sky chart (R10-B2)

    /// Below-table panel for `selectedPlanTarget`: the industry-standard
    /// altitude-over-the-night chart when the row has a coordinate AND a
    /// site is resolved, an explanatory one-liner otherwise. `appState`'s
    /// `planDate`/`resolvedSite` are read directly (not cached), so this
    /// naturally recomputes whenever "Terv erre az éjszakára" loads a
    /// different night's plan.
    @ViewBuilder
    private func selectedTargetChartSection(_ targetID: String) -> some View {
        if let row = planRows.first(where: { $0.id == targetID }) {
            if let raDeg = row.plan.raDeg, let decDeg = row.plan.decDeg {
                if let lat = appState.resolvedSite.latitudeDeg, let lon = appState.resolvedSite.longitudeDeg {
                    let night = appState.planDate ?? Date()
                    SkyChartView(
                        targetName: row.displayName,
                        targetTrack: SkyTrack.altitudeTrack(raDeg: raDeg, decDeg: decDeg, nightOf: night, latDeg: lat, lonDeg: lon),
                        moonTrack: SkyTrack.moonAltitudeTrack(nightOf: night, latDeg: lat, lonDeg: lon),
                        markers: SkyTrack.nightWindowMarkers(nightOf: night, latDeg: lat, lonDeg: lon),
                        minAltitudeDeg: plannerDefaultMinAltitudeDeg,
                        isTonight: appState.planDate == nil,
                        nightOf: night,
                        moonIlluminationPercent: row.plan.moonIlluminationPercent
                    )
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                    .padding(.top, 6)
                } else {
                    noSiteChartHint
                }
            } else {
                noCoordinateChartHint
            }
        }
    }

    private var noCoordinateChartHint: some View {
        Text("Nincs koordináta — plate-solve után lesz ív.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }

    // R10 review (item 15): a real deep link (same `settingsTab = .location;
    // openSettings()` pattern the "Helyszín" tile/`noSiteBanner` above
    // already use), replacing a plain sentence that just NAMED the
    // settings location without a way to jump there.
    private var noSiteChartHint: some View {
        HStack(spacing: 8) {
            Text("Nincs megfigyelési helyszín beállítva.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Beállítás…") {
                appState.settingsTab = .location
                openSettings()
            }
            .buttonStyle(.link)
        }
        .padding(.top, 6)
    }

    // MARK: Cell content

    private func targetCell(_ row: PlanRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.displayName).bold().lineLimit(1)
            if row.displayName != row.plan.target {
                Text(row.plan.target).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func goalCell(_ row: PlanRow) -> some View {
        if let goal = row.plan.goalSeconds {
            Text(TDFormat.hm(goal)).foregroundStyle(.secondary)
        } else {
            Button("Cél beállítása…") {
                goalEditingTarget = GoalEditingTarget(target: row.plan.target, currentHours: 10)
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    @ViewBuilder
    private func missingCell(_ row: PlanRow) -> some View {
        HStack(spacing: 4) {
            if let missing = row.missingSeconds {
                Text(TDFormat.hm(missing)).foregroundStyle(missing > 0 ? .red : .secondary)
            } else {
                // R10 review (item 20): table CELLS use "-", not "—" -- see
                // `TDFormat`'s own doc comment for the full rule.
                Text(TDFormat.missingCell).foregroundStyle(.secondary)
            }
            // R11-T5/F2: only for a target with at least one
            // `goal:<filter>=<hours>h` tag -- the table cell itself always
            // stays the aggregated number, this is one click away from the
            // per-filter breakdown behind it.
            if !row.plan.filterGoals.isEmpty {
                FilterGoalsPopoverButton(filterGoals: row.plan.filterGoals)
            }
        }
    }

    /// R11-T6/F3: the "Szűrő ma" chip -- `FilterAdvisor.chipText` off this
    /// row's own `filterAdvice`/`filterGoals`, tooltipped with the Moon-based
    /// justification (`Advice.reason`). A target with no filter goal at all
    /// (a plain OSC/broadband project) gets the plain missing-cell glyph,
    /// same as `missingCell` above -- there's no per-filter recommendation
    /// to show for it.
    @ViewBuilder
    private func filterAdviceCell(_ row: PlanRow) -> some View {
        if let advice = row.plan.filterAdvice,
           let text = FilterAdvisor.chipText(advice: advice, filterGoals: row.plan.filterGoals)
        {
            Text(text)
                .font(.caption.bold())
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.purple.opacity(0.15), in: Capsule())
                .foregroundStyle(.purple)
                .help(advice.reason)
        } else {
            Text(TDFormat.missingCell).foregroundStyle(.secondary)
        }
    }

    /// R10-B7: pulled out of the "Kulminál" column's cell closure -- inlined
    /// directly (`Text(row.plan.culminationLocal ?? "-")`) inside the
    /// `Group { }` above, the type-checker couldn't resolve the whole
    /// `Table` builder expression in reasonable time. Routing through a
    /// plain helper (same convention `maxAltText` right below already
    /// follows) gives it a concrete return type to anchor on instead.
    private func culminationText(_ row: PlanRow) -> String {
        TDFormat.cell(row.plan.culminationLocal)
    }

    private func maxAltText(_ row: PlanRow) -> String {
        guard let alt = row.plan.maxAltitudeDeg else { return TDFormat.missingCell }
        return "\(Int(alt.rounded()))°"
    }

    private func visibleText(_ row: PlanRow) -> String {
        guard let window = row.plan.visibleWindowLocal, let hours = row.plan.visibleHours else { return TDFormat.missingCell }
        return "\(window)  (\(String(format: "%.1f", hours)) ó)"
    }

    private func moonRowText(_ row: PlanRow) -> String {
        guard let illum = row.plan.moonIlluminationPercent else { return TDFormat.missingCell }
        var text = TDFormat.percent(illum)
        if let sep = row.plan.moonSeparationDeg {
            text += " · \(Int(sep.rounded()))°"
        }
        return text
    }

    // MARK: Context menu

    @ViewBuilder
    private func planContextMenuItems(_ row: PlanRow) -> some View {
        Button("Célpont megnyitása") { appState.currentPage = .target(row.plan.target) }
        Button("Cél beállítása…") {
            goalEditingTarget = GoalEditingTarget(
                target: row.plan.target, currentHours: (row.plan.goalSeconds ?? 36000) / 3600.0
            )
        }
        if row.plan.raDeg == nil {
            Button("Plate-solve…") { solvingTarget = SolvingTarget(target: row.plan.target) }
        }
        Divider()
        if let lastDate = lastSessionDate(row.plan.target) {
            Button("Éjszaka-riport a legutóbbi sessionről") {
                appState.exportNightReport(target: row.plan.target, date: lastDate)
            }
        }
        Button("Célpont-riport") { appState.exportTargetReport(target: row.plan.target) }
        Divider()
        Button("Mappa megnyitása Finderben") { appState.revealPathInFinder("sessions/\(row.plan.target)") }
    }

    private func lastSessionDate(_ target: String) -> String? {
        appState.stats.first { $0.target == target }?.lastSessionDate
    }

    // MARK: - "Következő 30 éjszaka" (calendar) segment

    private var calendarSegmentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                if appState.isBusy {
                    ProgressView().controlSize(.small)
                }
                Button("Frissítés") { appState.loadMonthPlan() }
                    .disabled(appState.isBusy || appState.db == nil)
            }

            Group {
                if let month = appState.monthPlan {
                    if month.isEmpty {
                        ContentUnavailableView("Nincs adat", systemImage: "moon.stars")
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Spacer()
                                MetricInfoButton(metrics: Self.calendarMetricInfo)
                            }
                            calendarTable(month)
                        }
                    }
                } else if appState.isBusy {
                    ProgressView("Havi terv számítása…")
                } else {
                    ContentUnavailableView("Még nincs számolva", systemImage: "calendar")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            if appState.monthPlan == nil { appState.loadMonthPlan() }
        }
    }

    /// R10-B6: the calendar table's one computed-metric column not already
    /// self-explanatory from its own cell content -- same "one button per
    /// table" `MetricInfoButton` pattern `planMetricInfo` establishes above.
    private static let calendarMetricInfo: [MetricInfoButton.Metric] = [
        .init(
            title: "Felhő",
            explanation: "Az adott éjszaka 20:00-04:00 közti óránkénti Open-Meteo mintáinak átlagos felhőzete, százalékban. Mikor hazudik: a 7 napos előrejelzésen túl „-”; ha az előrejelzés ki van kapcsolva, „ki” (kattintható link a Beállítások ▸ Helyszín laphoz)."
        ),
        .init(
            title: "NB / sötét",
            explanation: "Hold-tudatos ajánlás a Hold megvilágítottsága alapján (>40% esetén „NB” — keskenysáv-éjszaka —, egyébként „sötét”). Mikor hazudik: itt nincs konkrét célpont, csak az illumináció számít — a `planTable`-ben a szögtávolság is beleszámít."
        ),
    ]

    /// `Table`'s non-`Identifiable`-data initializer (`id:` keypath) isn't
    /// available at this package's macOS 14 deployment target -- wrap
    /// `NightSummary` the same way `StatsRow`/`PlanRow` wrap their own
    /// AstroCore model types instead.
    private struct CalendarRow: Identifiable {
        let night: NightSummary
        var id: String { night.date }
    }

    private func calendarTable(_ month: [NightSummary]) -> some View {
        let rows = month.map(CalendarRow.init)
        return Table(rows, selection: $selectedCalendarNight) {
            TableColumn("Dátum") { row in dateCell(row.night) }
                .width(130)
            TableColumn("Sötét") { row in darkCell(row.night) }
                .width(90)
            TableColumn("Hold") { row in moonCell(row.night) }
                .width(100)
            TableColumn("Felhő") { row in cloudCell(row.night) }
                .width(60)
            TableColumn("Legjobb 3 célpont") { row in bestTargetsCell(row.night) }
            TableColumn("") { row in markerCell(row.night) }
                .width(30)
            // R10 review (item 6): the standard trailing "⋯" actions column
            // every other main table already has (`QualitySegment.frameTable`/
            // `NightsPage.table`/`DiscoveryPage.table`/`planTable` above) --
            // this table's own row action ("Terv erre az éjszakára") used to
            // be reachable ONLY via right-click or double-click, with no
            // always-visible affordance hinting it exists at all.
            TableColumn("") { row in
                Menu {
                    planForNightMenuItem(row.night)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .width(actionColumnWidth)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        // R9-D11: same row-scoped context-menu/double-click pattern as
        // `planTable` -- previously the context menu was attached only to
        // the "Dátum" cell's `Text`, and there was no double-click action at
        // all.
        .contextMenu(forSelectionType: String.self) { ids in
            if let date = ids.first, let row = rows.first(where: { $0.id == date }) {
                planForNightMenuItem(row.night)
            }
        } primaryAction: { ids in
            if let date = ids.first, let row = rows.first(where: { $0.id == date }) {
                openPlanForNight(row.night)
            }
        }
    }

    private func dateCell(_ night: NightSummary) -> some View {
        Text(dateLabel(night))
    }

    private func planForNightMenuItem(_ night: NightSummary) -> some View {
        Button("Terv erre az éjszakára") { openPlanForNight(night) }
    }

    private func openPlanForNight(_ night: NightSummary) {
        guard let date = Self.isoDateFormatter.date(from: night.date) else { return }
        // R11-T13/F13: `currentPage` alone -- this jumps from the calendar
        // segment (reached via `currentPage == .calendar`) back to the
        // tonight segment, and `tonightSegment` is derived straight from
        // `currentPage` now, so setting it separately would be redundant
        // (see that property's own doc comment).
        appState.currentPage = .tonight
        appState.loadPlan(date: date)
    }

    @ViewBuilder
    private func darkCell(_ night: NightSummary) -> some View {
        if let hours = night.astroDarkHours {
            Text(String(format: "%.1f ó", hours))
        } else {
            Text(TDFormat.cell(night.note)).font(.caption2).foregroundStyle(.orange)
        }
    }

    private func moonCell(_ night: NightSummary) -> some View {
        HStack(spacing: 6) {
            MoonGlyph(percent: night.moonIlluminationPercent)
            Text(TDFormat.percent(night.moonIlluminationPercent))
            // R11-T6/F3: illumination-only NB/sötét label -- no target
            // coordinate here to fold a separation into, unlike `planTable`'s
            // own per-target "Szűrő ma" chip.
            skyStateLabel(night)
        }
    }

    private func skyStateLabel(_ night: NightSummary) -> some View {
        let isNarrowband = FilterAdvisor.isNarrowbandByIlluminationAlone(moonIlluminationPercent: night.moonIlluminationPercent)
        return Text(isNarrowband ? "NB" : "sötét")
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background((isNarrowband ? Color.purple : Color.blue).opacity(0.15), in: Capsule())
            .foregroundStyle(isNarrowband ? .purple : .blue)
    }

    /// R10-B6/R10 review (item 16): `night.date` having no entry in
    /// `weatherDailySummaries` used to render the exact same "—" for two
    /// different reasons -- "feature disabled" (the dictionary never gets
    /// populated at all, see `loadWeather`'s guard) and "beyond Open-Meteo's
    /// 7-day horizon"/still loading (that date's bucket wasn't produced
    /// YET, or ever). The first is one click away from fixed (a deep link,
    /// same "ki" pattern `TonightPage.cloudTile` uses); the second genuinely
    /// has nothing to show. Table CELLS use "-" for that second, honest-n/a
    /// case -- see `TDFormat`'s own doc comment for the full rule.
    @ViewBuilder
    private func cloudCell(_ night: NightSummary) -> some View {
        if let summary = appState.weatherDailySummaries[night.date] {
            Text(TDFormat.percent(summary.meanPercent))
                .foregroundStyle(cloudColor(summary.meanPercent))
        } else if !appState.config.weather.enabled {
            Button("ki") {
                appState.settingsTab = .location
                openSettings()
            }
            .buttonStyle(.link)
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            Text(TDFormat.missingCell).foregroundStyle(.secondary)
        }
    }

    private func cloudColor(_ meanPercent: Double) -> Color {
        if meanPercent <= 30 { return .green }
        if meanPercent <= 60 { return .orange }
        return .red
    }

    /// R10-A5: each name is its own tappable link (was a single plain
    /// `Text`, joined -- a dead end, since a target visible only in the
    /// calendar's "best 3" list had no way to open it without first finding
    /// it elsewhere). The links are small `Button(.link)`s inside the row,
    /// same "interactive control living inside a `Table` row that ALSO has
    /// its own `.contextMenu(forSelectionType:primaryAction:)`" shape
    /// `goalCell`'s "Cél beállítása…" link already establishes below --
    /// clicking a name consumes just that click (only that Button's own
    /// hit-area), while the rest of the row (including the empty space
    /// after a short list) still selects/opens via the row's own primary
    /// action.
    @ViewBuilder
    private func bestTargetsCell(_ night: NightSummary) -> some View {
        if night.bestTargets.isEmpty {
            // R10 review (item 20): table CELLS use "-", not "—".
            Text(TDFormat.missingCell).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                ForEach(Array(night.bestTargets.enumerated()), id: \.offset) { index, best in
                    if index > 0 {
                        Text("·").foregroundStyle(.secondary)
                    }
                    Button(displayName(for: best.target)) {
                        appState.currentPage = .target(best.target)
                    }
                    .lineLimit(1)
                }
            }
            .buttonStyle(.link)
        }
    }

    private func displayName(for target: String) -> String {
        appState.stats.first { $0.target == target }?.displayName ?? target
    }

    @ViewBuilder
    private func markerCell(_ night: NightSummary) -> some View {
        if isHighlighted(night) {
            Image(systemName: "arrowtriangle.up.fill").font(.caption2).foregroundStyle(.green)
        }
    }

    private func isHighlighted(_ night: NightSummary) -> Bool {
        (night.astroDarkHours ?? 0) >= 4 && night.moonIlluminationPercent < 30
    }

    private func dateLabel(_ night: NightSummary) -> String {
        if night.date == Self.todayString { return "Ma" }
        if night.date == Self.tomorrowString { return "Holnap" }
        guard let date = Self.isoDateFormatter.date(from: night.date) else { return night.date }
        return Self.weekdayFormatter.string(from: date)
    }

    // MARK: - Date formatting

    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "hu_HU")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "EEE MM.dd."
        return formatter
    }()

    private static var todayString: String { isoDateFormatter.string(from: Date()) }
    private static var tomorrowString: String {
        isoDateFormatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
    }
}

// MARK: - Filter-goals popover (R11-T5/F2)

/// The "Hiányzik" cell's per-filter breakdown popover: Szűrő | Megvan | Cél |
/// Hiányzik for a target that has at least one `goal:<filter>=<hours>h` tag
/// (`TargetPlan.filterGoals`, already merged with goal tags via
/// `FilterGoalQueries.merge` in `Planner.plan`). Same self-contained "own
/// `showPopover` state" shape as `MetricInfoButton` -- no per-row `@State`
/// needed back in `TonightPage` itself.
private struct FilterGoalsPopoverButton: View {
    let filterGoals: [FilterIntegration]

    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Image(systemName: "chevron.down.circle")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Szűrőnkénti bontás")
        .popover(isPresented: $showPopover) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Szűrőnkénti bontás").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("Szűrő").font(.caption).foregroundStyle(.secondary)
                        Text("Megvan").font(.caption).foregroundStyle(.secondary)
                        Text("Cél").font(.caption).foregroundStyle(.secondary)
                        Text("Hiányzik").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(filterGoals, id: \.filter) { entry in
                        GridRow {
                            Text(entry.filter)
                            Text(TDFormat.hm(entry.integrationSeconds))
                            Text(entry.goalSeconds.map(TDFormat.hm) ?? TDFormat.missingCell)
                            Text(entry.missingSeconds.map(TDFormat.hm) ?? TDFormat.missingCell)
                                .foregroundStyle((entry.missingSeconds ?? 0) > 0 ? .orange : .secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            .padding(14)
            .frame(minWidth: 260)
        }
    }
}

// MARK: - Moon illumination glyph (calendar segment)

/// A small filled-circle glyph whose inner disc's AREA (not diameter, so the
/// visual weight tracks perceived brightness better at low percentages) is
/// proportional to `percent` -- the calendar segment's compact Moon-phase
/// indicator, paired with the numeric "34%" text.
private struct MoonGlyph: View {
    let percent: Double

    private static let diameter: CGFloat = 14

    var body: some View {
        let clamped = max(0, min(100, percent))
        let fillDiameter = Self.diameter * CGFloat((clamped / 100).squareRoot())
        return ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                .frame(width: Self.diameter, height: Self.diameter)
            Circle()
                .fill(Color.secondary)
                .frame(width: fillDiameter, height: fillDiameter)
        }
        .frame(width: Self.diameter, height: Self.diameter)
    }
}
