import AppKit
import AstroCore
import SwiftUI

/// R10-B3's "Éjszakák" page (sidebar KÖNYVTÁR section, ⌘4): every session
/// across every target flattened into one sortable, filterable table -- the
/// cross-target counterpart to `AllTargetsPage`'s hierarchical table, which
/// still nests sessions under their own target and has no year/month filter
/// of its own. Backed by `NightsQueries.allNights` (R10-A3):
/// `AppState.loadNights()` loads the whole (unfiltered) list exactly once;
/// the year/month Pickers below filter it CLIENT-SIDE (`filteredNightRows`)
/// rather than re-querying per Picker change -- cheap at this scale (one
/// pass over an in-memory array), and it means flipping a Picker never
/// kicks off a new background operation.
struct NightsPage: View {
    @Environment(AppState.self) private var appState

    /// `nil` means "Minden év". The Hónap picker only makes sense once a
    /// year is actually chosen (a bare month filter has no anchor) --
    /// mirrors `NightsQueries.matchesFilter`'s own "month without year is
    /// ignored" note, enforced here by simply disabling the control instead.
    @State private var selectedYear: Int?
    @State private var selectedMonth: Int?
    @State private var sortOrder = [KeyPathComparator(\NightTableRow.sortDateKey, order: .reverse)]
    @State private var selection: NightTableRow.ID?

    /// The session currently shown in `SessionNoteSheet` (R9-T6/B4's
    /// "Éjszaka-jegyzet szerkesztése…"), `nil` when closed -- same
    /// row-scoped sheet-trigger pattern `AllTargetsPage`/`SessionsSegment`
    /// already use.
    @State private var noteEditingSession: LinkingSession?

    private static let monthNames = [
        "Január", "Február", "Március", "Április", "Május", "Június",
        "Július", "Augusztus", "Szeptember", "Október", "November", "December",
    ]

    // MARK: - Year/month derivation + client-side filter

    /// Parses one row's raw date-dir text the exact same way
    /// `NightsQueries.allNights` does internally for its own `year`/`month`
    /// filter (`SessionDateParser`, with the library's configured
    /// `IntentionalPatterns`) -- kept in sync here since this page filters
    /// client-side instead of re-querying with the core API's own
    /// `year`/`month` parameters.
    private func parsedDate(_ row: NightRow) -> SessionDate? {
        SessionDateParser.parse(row.date, patterns: appState.config.intentional)
    }

    private func parsedYearMonth(_ row: NightRow) -> (year: Int, month: Int)? {
        guard let start = parsedDate(row)?.start else { return nil }
        let parts = start.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
        return (year, month)
    }

    /// Every distinct year among the FULL (unfiltered) load, newest first --
    /// a row whose date-dir doesn't parse as a real calendar date at all
    /// contributes no year (same "no filter attaches to it" stance
    /// `NightsQueries.matchesFilter` takes for an active `year` filter).
    private var availableYears: [Int] {
        guard let nights = appState.nights else { return [] }
        return Array(Set(nights.compactMap { parsedYearMonth($0)?.year })).sorted(by: >)
    }

    private var filteredNightRows: [NightRow] {
        guard let nights = appState.nights else { return [] }
        guard let selectedYear else { return nights }
        return nights.filter { row in
            guard let parsed = parsedYearMonth(row), parsed.year == selectedYear else { return false }
            guard let selectedMonth else { return true }
            return parsed.month == selectedMonth
        }
    }

    private var filterDescriptionText: String {
        var parts: [String] = []
        if let selectedYear { parts.append(String(selectedYear)) }
        if let selectedMonth { parts.append(Self.monthNames[selectedMonth - 1]) }
        return parts.joined(separator: " ")
    }

    // MARK: - Table row

    /// Flattened, `KeyPathComparator`-friendly wrapper -- same "one
    /// `Identifiable` row struct per table" pattern `TonightPage.PlanRow`/
    /// `AllTargetsPage.StatsRow` already establish. `sortDateKey` is the
    /// parsed canonical `YYYY-MM-DD` start date, falling back to the raw
    /// date-dir text when it doesn't parse -- the identical fallback
    /// `NightsQueries.allNights`'s own sort uses, so this table's default
    /// (date-descending) order matches what the query already returns.
    private struct NightTableRow: Identifiable {
        let row: NightRow
        let sortDateKey: String

        var id: String { "\(row.target):\(row.date)" }
        var target: String { row.target }
        var displayName: String { row.displayName }
        var date: String { row.date }
        var usableLightCount: Int { row.usableLightCount }
        var integrationSeconds: Double { row.integrationSeconds }
        var exposureSummary: String { row.exposureSummary }
        var filtersText: String { row.filters.isEmpty ? "-" : row.filters.joined(separator: ", ") }
        var medianFWHMArcsec: Double? { row.medianFWHMArcsec }
        /// R10 review (item 11): `fwhmText`'s pixel-only fallback (like
        /// `SessionsSegment.fwhmText`) for a rated session with no
        /// derivable arcsec value.
        var medianFWHMPixels: Double? { row.medianFWHMPixels }
        var backgroundEPerSecPerArcsec2: Double? { row.backgroundEPerSecPerArcsec2 }
        var dutyCyclePercent: Double? { row.dutyCyclePercent }
        var hasNotes: Bool { row.hasNotes }
        var isExcludedFromTotals: Bool { row.isExcludedFromTotals }

        // Sentinel sort keys for the nullable metric columns -- missing
        // sorts first on an ascending sort, same "-1 sentinel" convention
        // `TonightPage.PlanRow.goalSortKey`/`missingSortKey` already use.
        var fwhmSortKey: Double { medianFWHMArcsec ?? -1 }
        var backgroundSortKey: Double { backgroundEPerSecPerArcsec2 ?? -1 }
        var dutySortKey: Double { dutyCyclePercent ?? -1 }
        var noteSortKey: Int { hasNotes ? 1 : 0 }
    }

    private var tableRows: [NightTableRow] {
        filteredNightRows.map { row in
            NightTableRow(row: row, sortDateKey: parsedDate(row)?.start ?? row.date)
        }.sorted(using: sortOrder)
    }

    private func row(withID id: NightTableRow.ID) -> NightTableRow? {
        tableRows.first { $0.id == id }
    }

    // MARK: - Tiles

    /// The best (lowest) FWHM row within the CURRENT year/month filter,
    /// `nil` when none of the filtered rows has a rated value at all.
    private var bestFWHMRow: NightRow? {
        filteredNightRows
            .filter { $0.medianFWHMArcsec != nil }
            .min { $0.medianFWHMArcsec! < $1.medianFWHMArcsec! }
    }

    private var bestFWHMValueText: String {
        guard let value = bestFWHMRow?.medianFWHMArcsec else { return "-" }
        return String(format: "%.2f″", value)
    }

    // R10 review (item 11): this tile stays arcsec-only (unlike the
    // "FWHM″" column, it has no pixel-fallback -- comparing pixel FWHM
    // across different targets/setups isn't meaningful the way comparing
    // it within one session's own frames is), so the caption spells out
    // the unit rather than leaving it to the "″" in the tile's own title.
    private var bestFWHMCaptionText: String? {
        bestFWHMRow.map { "\($0.displayName) · \($0.date) (″-ben mérve)" }
    }

    private var totalIntegrationSeconds: Double {
        filteredNightRows.reduce(0) { $0 + $1.integrationSeconds }
    }

    private var tilesRow: some View {
        HStack(spacing: 12) {
            StatTile(title: "Éjszakák", value: "\(filteredNightRows.count)", color: .blue)
            StatTile(title: "Összes integráció", value: TDFormat.hm(totalIntegrationSeconds), color: .green)
            StatTile(title: "Legjobb FWHM", value: bestFWHMValueText, color: .orange, caption: bestFWHMCaptionText)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controlRow

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }

            Group {
                if let nights = appState.nights {
                    if nights.isEmpty {
                        ContentUnavailableView("Nincs session a könyvtárban", systemImage: "moon.zzz")
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            tilesRow
                            if filteredNightRows.isEmpty {
                                ContentUnavailableView.search(text: filterDescriptionText)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Spacer()
                                        MetricInfoButton(metrics: Self.metricInfo)
                                    }
                                    table
                                }
                            }
                        }
                    }
                } else if appState.isBusy {
                    // R10 review (item 18): `appState.progressText`, not a
                    // hardcoded "Éjszakák betöltése…" -- `nights == nil`
                    // alone doesn't mean THIS page's own load is what's
                    // running; some unrelated busy operation (e.g. a scan
                    // started from another page) can be true here just as
                    // easily, before this page's own `loadNights()` ever
                    // got a chance to run. `progressText` always reflects
                    // whatever operation is ACTUALLY in flight -- it reads
                    // "Éjszakák betöltése…" exactly when that's true, and
                    // something else's own description otherwise.
                    ProgressView(appState.progressText)
                } else {
                    notLoadedState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding()
        .onAppear {
            // R10 review (item 18): `&& !appState.isBusy`, same guard
            // `DiscoveryPage.onAppear` already uses -- without it, landing
            // here while an unrelated operation is still running (e.g. a
            // scan kicked off from another page) would fire `loadNights()`
            // anyway, whose `beginOperation` cancels that OTHER operation's
            // `currentTask` out from under it.
            if appState.nights == nil && !appState.isBusy { appState.loadNights() }
        }
        .sheet(item: $noteEditingSession) { session in
            SessionNoteSheet(target: session.target, date: session.date)
        }
    }

    // MARK: - Control row

    private var controlRow: some View {
        HStack {
            Picker("Év", selection: $selectedYear) {
                Text("Minden év").tag(Int?.none)
                ForEach(availableYears, id: \.self) { year in
                    Text(String(year)).tag(Int?.some(year))
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 150, alignment: .leading)
            .onChange(of: selectedYear) { _, newValue in
                // A month filter with no year anchor is meaningless (same
                // stance `NightsQueries.matchesFilter` takes) -- clearing
                // the year clears whatever month was chosen too, rather
                // than leaving a disabled Picker silently holding a value
                // that no longer filters anything.
                if newValue == nil { selectedMonth = nil }
            }

            Picker("Hónap", selection: $selectedMonth) {
                Text("Minden hónap").tag(Int?.none)
                ForEach(1...12, id: \.self) { month in
                    Text(Self.monthNames[month - 1]).tag(Int?.some(month))
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 170, alignment: .leading)
            .disabled(selectedYear == nil)

            Spacer()

            if appState.isBusy {
                ProgressView().controlSize(.small)
                Text(appState.progressText).foregroundStyle(.secondary)
            }
            Button("Frissítés") { appState.loadNights() }
                .disabled(appState.isBusy || appState.db == nil)
        }
    }

    // MARK: - Empty states

    private var notLoadedState: some View {
        ContentUnavailableView {
            Label("Még nincs betöltve", systemImage: "moon.zzz")
        } description: {
            Text("Töltsd be a könyvtár összes sessionjét, hogy céltól függetlenül böngészhesd őket.")
        } actions: {
            Button("Betöltés") { appState.loadNights() }
                .disabled(appState.db == nil)
        }
    }

    // MARK: - Metric info (R9-T6/B16(a) convention)

    /// This table's computed-metric columns, explained -- same "one button
    /// per table" `MetricInfoButton` pattern `SessionsSegment`/
    /// `QualitySegment`/`TonightPage` already establish. FWHM″/Háttér reuse
    /// `SessionsSegment`'s own wording verbatim (same underlying quantities,
    /// just per-session instead of per-frame); Hatékonyság is new here.
    private static let metricInfo: [MetricInfoButton.Metric] = [
        .init(
            title: "FWHM″",
            // R10 review (item 11): restored the "vagy pixelben" fallback
            // clause `SessionsSegment`'s own copy of this explanation
            // already has -- this column falls back to a pixel value (see
            // `fwhmText`) exactly when there's no pixel-scale metadata to
            // convert with, i.e. "nincs pixelskála".
            explanation: "A session kerete(i) félértékszélessége ívmásodpercben (pixelméret+fókusz ismeretében) vagy pixelben, ha nincs pixelskála a konverzióhoz. Mikor hazudik: pontozás nélkül „-”; „Siril nélkül” pontozásnál is mindig „-”."
        ),
        .init(
            title: "Háttér e⁻/s/″²",
            explanation: "A session égi hátterének valódi elektron/másodperc/ívmásodperc² rátája. Mikor hazudik: mért szenzor-profil nélkül (Szenzor-profilok oldal) ez nem számolható, „-” marad."
        ),
        .init(
            title: "Hatékonyság",
            explanation: "A session tényleges integrációs ideje a light-keretek első és utolsó felvétele közti ablakhoz mérve, százalékban. Mikor hazudik: „-” marad, ha nincs elég értelmezhető DATE-OBS időbélyeg a keretek fejléceiben."
        ),
    ]

    // MARK: - Table

    private var table: some View {
        Table(tableRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Dátum", value: \.sortDateKey) { row in dateCell(row) }
                .width(min: 110, ideal: 130)
            TableColumn("Célpont", value: \.displayName) { row in targetCell(row) }
                .width(min: 160, ideal: 200)
            TableColumn("Keretek", value: \.usableLightCount) { row in Text("\(row.usableLightCount)") }
                .width(min: 60, ideal: 70)
            TableColumn("Integráció", value: \.integrationSeconds) { row in Text(TDFormat.hm(row.integrationSeconds)) }
                .width(min: 80, ideal: 90)
            TableColumn("Expozíciók", value: \.exposureSummary) { row in
                Text(row.exposureSummary).lineLimit(1).truncationMode(.tail)
            }
            .width(min: 100, ideal: 140)
            TableColumn("FWHM″", value: \.fwhmSortKey) { row in Text(fwhmText(row)) }
                .width(min: 60, ideal: 70)
            TableColumn("Háttér e⁻/s/″²", value: \.backgroundSortKey) { row in Text(backgroundText(row)) }
                .width(min: 90, ideal: 120)
            TableColumn("Hatékonyság", value: \.dutySortKey) { row in Text(dutyText(row)) }
                .width(min: 80, ideal: 100)
            // R10-B7: grouped so the table stays AT (not over) `Table`'s
            // 10-top-level-column cap once the trailing "⋯" actions column
            // below needs its own slot -- same `Group { }` workaround
            // `QualitySegment.frameTable` already established.
            Group {
                TableColumn("Szűrők", value: \.filtersText) { row in filtersCell(row) }
                    .width(min: 80, ideal: 110)
                TableColumn("Jegyzet", value: \.noteSortKey) { row in
                    // R10 review (item 20): table CELLS use "-", not "—".
                    Text(row.hasNotes ? "✓" : "-").foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 60)
            }
            // R10-B7: visible row-actions -- mirrors `contextMenuItems(for:)`
            // exactly (same function, both call sites), so the right-click
            // menu and this borderless "⋯" button can never drift apart.
            TableColumn("") { row in
                Menu {
                    contextMenuItems(for: row)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .width(36)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        // Row-scoped context menu + double-click-to-open, same pattern
        // `AllTargetsPage.statsTable`/`TonightPage.planTable` use.
        .contextMenu(forSelectionType: NightTableRow.ID.self) { ids in
            if let id = ids.first, let row = row(withID: id) {
                contextMenuItems(for: row)
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = row(withID: id) {
                openInTargetDetail(row)
            }
        }
    }

    // MARK: - Cell content

    @ViewBuilder
    private func dateCell(_ row: NightTableRow) -> some View {
        HStack(spacing: 6) {
            Text(row.date)
            if row.isExcludedFromTotals {
                Text("kizárva")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.opacity(0.15)))
                    .foregroundStyle(.red)
            }
        }
        .lineLimit(1)
        // Same dimmed treatment `AllTargetsPage.nameCell` gives an excluded
        // session row's name/date cell -- this page has no separate
        // full-row style hook either (a `Table` here has no per-row
        // background modifier), so the cell itself carries the signal.
        .opacity(row.isExcludedFromTotals ? 0.5 : 1.0)
    }

    private func targetCell(_ row: NightTableRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.displayName).bold().lineLimit(1)
            if row.displayName != row.target {
                Text(row.target).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    // R10 review (item 11): falls back to the pixel-only value (like
    // `SessionsSegment.fwhmText`) when there's no derivable arcsec value --
    // was arcsec-or-"-" only, silently hiding a rated session's FWHM
    // whenever its frames had no pixel-scale metadata (`xpixsz`/`focallen`)
    // to convert with.
    private func fwhmText(_ row: NightTableRow) -> String {
        if let arcsec = row.medianFWHMArcsec { return String(format: "%.2f", arcsec) }
        if let px = row.medianFWHMPixels { return String(format: "%.2f px", px) }
        return "-"
    }

    private func backgroundText(_ row: NightTableRow) -> String {
        guard let value = row.backgroundEPerSecPerArcsec2 else { return "-" }
        return String(format: "%.3f", value)
    }

    private func dutyText(_ row: NightTableRow) -> String {
        guard let value = row.dutyCyclePercent else { return "-" }
        return String(format: "%.0f%%", value)
    }

    /// R10-B7: pulled out of the "Szűrők" column's cell closure -- inlined
    /// directly (`Text(row.filtersText).lineLimit(1).truncationMode(.tail)`)
    /// inside the `Group { }` below, the type-checker couldn't resolve the
    /// whole `Table` builder expression in reasonable time. Routing through
    /// a plain `@ViewBuilder` helper (same convention every other cell in
    /// this table already follows) gives it a concrete anchor instead.
    @ViewBuilder
    private func filtersCell(_ row: NightTableRow) -> some View {
        Text(row.filtersText).lineLimit(1).truncationMode(.tail)
    }

    // MARK: - Row interactions

    /// Both the row's double-click AND its context menu's "Célpont
    /// megnyitása" land here -- preselects the Sessionök segment with this
    /// exact date, then navigates, the identical `pendingTargetSegment`/
    /// `pendingSessionSelection` hand-off `SearchResultsPage.sessionRow`
    /// already uses for a search hit landing on the same target page.
    private func openInTargetDetail(_ row: NightTableRow) {
        appState.pendingTargetSegment = .sessions
        appState.pendingSessionSelection = row.date
        appState.currentPage = .target(row.target)
    }

    @ViewBuilder
    private func contextMenuItems(for row: NightTableRow) -> some View {
        // R10 review (item 8): "Célpont megnyitása" everywhere a row's
        // primary action navigates to the target page (`AllTargetsPage`
        // already uses this exact wording) -- was a bare "Megnyitás".
        Button("Célpont megnyitása") { openInTargetDetail(row) }
        Button("Megnyitás Finderben") { revealInFinder(target: row.target, date: row.date) }
        Divider()
        Button("Éjszaka-riport készítése") { appState.exportNightReport(target: row.target, date: row.date) }
        Button("Éjszaka-jegyzet szerkesztése…") { noteEditingSession = LinkingSession(target: row.target, date: row.date) }
    }

    private func revealInFinder(target: String, date: String) {
        let url = URL(fileURLWithPath: appState.config.rootPath, isDirectory: true)
            .appendingPathComponent("sessions/\(target)/\(date)")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
