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
/// sidebar's "Naptár" row or ⌘2 preselecting the segment before navigating
/// to `Page.tonight` -- the same "preselect a segment, don't add a page"
/// pattern the sidebar's "Takarítás" row already established for
/// `AppState.auditSegment`).
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

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $appState.tonightSegment) {
                Text("Ma este").tag(AppState.TonightSegment.tonight)
                Text("Következő 30 éjszaka").tag(AppState.TonightSegment.calendar)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
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
            if appState.stats.isEmpty || appState.plan == nil {
                appState.loadDashboardData()
            }
        }
        .sheet(item: $goalEditingTarget) { editing in
            GoalEditSheet(target: editing.target, initialHours: editing.currentHours)
        }
        .sheet(item: $solvingTarget) { solving in
            PlateSolveSheet(target: solving.target)
        }
    }

    // MARK: - "Ma este" segment

    private var tonightSegmentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if appState.planDate != nil {
                    dateScopedCaption
                }
                Spacer()
                if appState.isBusy {
                    ProgressView().controlSize(.small)
                }
                Button("Frissítés") { appState.loadPlan(date: appState.planDate) }
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
                            HStack {
                                Spacer()
                                MetricInfoButton(metrics: Self.planMetricInfo)
                            }
                            planTable
                        }
                    }
                } else if appState.isBusy {
                    ProgressView("Terv számítása…")
                } else {
                    ContentUnavailableView("Még nincs számolva", systemImage: "moon.stars")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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

    private var darkHoursText: String {
        guard let hours = appState.nightInfo?.darkHours else { return "-" }
        return String(format: "%.1f óra", hours)
    }

    private var moonTileText: String {
        guard let info = appState.nightInfo else { return "-" }
        var text = TDFormat.percent(info.moonIlluminationPercent)
        if let label = info.moonEventLabel { text += " · \(label)" }
        return text
    }

    private var recommendedCount: Int {
        appState.plan?.count { $0.verdict == "ma jó" } ?? 0
    }

    private var locationValueText: String {
        guard hasResolvedSite, let lat = appState.resolvedSite.latitudeDeg, let lon = appState.resolvedSite.longitudeDeg else {
            return "-"
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
            tile(title: "Sötét idő", value: darkHoursText, caption: appState.nightInfo?.note)
            tile(title: "Hold", value: moonTileText)
            tile(title: "Ajánlott", value: "\(recommendedCount)")
            Button {
                appState.settingsTab = .location
                openSettings()
            } label: {
                tile(title: "Helyszín", value: locationValueText, caption: locationCaptionText)
            }
            .buttonStyle(.plain)
        }
    }

    private func tile(title: String, value: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).bold()
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
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
            explanation: "Összesítő ajánlás („ma jó”/„Hold zavar”/„nem látható ma éjjel”/„túl alacsony”/…) a magasság, a láthatósági ablak és a Hold-közelség alapján. Mikor hazudik: csak MA éjjelre szól, egy korábban jó célpont holnap már más döntést kaphat."
        ),
    ]

    private var planTable: some View {
        Table(planRows, selection: $selectedPlanTarget, sortOrder: $sortOrder) {
            TableColumn("Célpont", value: \.displayName) { row in targetCell(row) }
                .width(min: 200, ideal: 240)
            TableColumn("Állapot", value: \.phaseRank) { row in phaseChip(row.phase) }
                .width(130)
            TableColumn("Integráció", value: \.integrationSeconds) { row in
                Text(TDFormat.hm(row.integrationSeconds))
            }
            .width(90)
            TableColumn("Cél", value: \.goalSortKey) { row in goalCell(row) }
                .width(110)
            TableColumn("Hiányzik", value: \.missingSortKey) { row in missingCell(row) }
                .width(90)
            TableColumn("Kulminál", value: \.culminationSortKey) { row in
                Text(row.plan.culminationLocal ?? "-")
            }
            .width(80)
            TableColumn("Max. mag.", value: \.maxAltSortKey) { row in Text(maxAltText(row)) }
                .width(80)
            TableColumn("Látható", value: \.visibleHoursSortKey) { row in Text(visibleText(row)) }
                .width(150)
            TableColumn("Hold", value: \.moonSortKey) { row in Text(moonRowText(row)) }
                .width(110)
            TableColumn("Döntés", value: \.verdictSortKey) { row in verdictChip(row.plan.verdict) }
                .width(140)
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
        if let missing = row.missingSeconds {
            Text(TDFormat.hm(missing)).foregroundStyle(missing > 0 ? .red : .secondary)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    private func maxAltText(_ row: PlanRow) -> String {
        guard let alt = row.plan.maxAltitudeDeg else { return "-" }
        return "\(Int(alt.rounded()))°"
    }

    private func visibleText(_ row: PlanRow) -> String {
        guard let window = row.plan.visibleWindowLocal, let hours = row.plan.visibleHours else { return "-" }
        return "\(window)  (\(String(format: "%.1f", hours)) ó)"
    }

    private func moonRowText(_ row: PlanRow) -> String {
        guard let illum = row.plan.moonIlluminationPercent else { return "-" }
        var text = TDFormat.percent(illum)
        if let sep = row.plan.moonSeparationDeg {
            text += " · \(Int(sep.rounded()))°"
        }
        return text
    }

    // MARK: Chips

    private func phaseChip(_ phase: ProjectPhase?) -> some View {
        Text(phaseLabel(phase))
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(phaseColor(phase).opacity(0.15), in: Capsule())
            .foregroundStyle(phaseColor(phase))
    }

    private func phaseLabel(_ phase: ProjectPhase?) -> String {
        switch phase {
        case .collecting: return "gyűjtés"
        case .readyToStack: return "stackelhető"
        case .stacked: return "feldolgozásra vár"
        case .done: return "kész"
        case nil: return "-"
        }
    }

    private func phaseColor(_ phase: ProjectPhase?) -> Color {
        switch phase {
        case .collecting: return .blue
        case .readyToStack: return .yellow
        case .stacked: return .orange
        case .done: return .green
        case nil: return .gray
        }
    }

    private func verdictChip(_ verdict: String) -> some View {
        Text(verdict)
            .font(.caption.bold())
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(verdictColor(verdict).opacity(0.15), in: Capsule())
            .foregroundStyle(verdictColor(verdict))
    }

    private func verdictColor(_ verdict: String) -> Color {
        if verdict == "ma jó" { return .green }
        if verdict.hasPrefix("Hold zavar") { return .yellow }
        if verdict.hasPrefix("alacsony") || verdict == "nem látszik ma éjjel" { return .orange }
        return .gray // "nincs koordináta" / üstökös
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
                        calendarTable(month)
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
            TableColumn("Legjobb 3 célpont") { row in bestTargetsCell(row.night) }
            TableColumn("") { row in markerCell(row.night) }
                .width(30)
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
        appState.tonightSegment = .tonight
        appState.loadPlan(date: date)
    }

    @ViewBuilder
    private func darkCell(_ night: NightSummary) -> some View {
        if let hours = night.astroDarkHours {
            Text(String(format: "%.1f ó", hours))
        } else {
            Text(night.note ?? "n/a").font(.caption2).foregroundStyle(.orange)
        }
    }

    private func moonCell(_ night: NightSummary) -> some View {
        HStack(spacing: 6) {
            MoonGlyph(percent: night.moonIlluminationPercent)
            Text(TDFormat.percent(night.moonIlluminationPercent))
        }
    }

    private func bestTargetsCell(_ night: NightSummary) -> some View {
        Text(night.bestTargets.isEmpty ? "—" : night.bestTargets.map { displayName(for: $0.target) }.joined(separator: ", "))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(night.bestTargets.isEmpty ? Color.secondary : Color.primary)
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

// MARK: - Goal-editing sheet (row context menu + "Cél" column link)

/// Identifies which target's goal is being edited so a `@State` of this type
/// can drive `.sheet(item:)` -- a SHEET (not the popover `TargetDetailPage`'s
/// header goal-tile uses) because this one is triggered from BOTH a `Table`
/// cell's plain link AND a row context-menu item, and a popover needs a
/// still-on-screen anchor view to attach to, which a context-menu item
/// (which closes immediately on selection) can't provide. Not `private`:
/// `AllTargetsPage`'s target row context menu reuses this same sheet for
/// its own "Cél beállítása…" item (R9-D8/e) rather than duplicating it.
struct GoalEditingTarget: Identifiable {
    let target: String
    let currentHours: Double
    var id: String { target }
}

struct GoalEditSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: String
    @State private var hours: Double

    init(target: String, initialHours: Double) {
        self.target = target
        _hours = State(initialValue: initialHours)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cél (óra)").font(.headline)
            Text(target).foregroundStyle(.secondary)
            Stepper(value: $hours, in: 0...300, step: 0.5) {
                Text(String(format: "%.1f óra", hours))
            }
            HStack {
                Button("Cél törlése") {
                    appState.setGoal(target: target, hours: nil)
                    dismiss()
                }
                Spacer()
                Button("Mégse") { dismiss() }
                Button("Mentés") {
                    appState.setGoal(target: target, hours: hours)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 280)
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
