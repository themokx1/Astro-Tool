import AstroCore
import SwiftUI

/// R10-B4's "Felfedezés" page: what should I shoot tonight from the
/// built-in catalog (`TargetCatalog`, 217 Messier + bright NGC/IC/Sharpless
/// targets, R10-A4) that I'm not already collecting? Backed by
/// `DiscoveryPlanner.discover` -- the exact same altitude/Moon/verdict/score
/// math `Planner.plan` runs for the user's OWN library, just swept over the
/// static catalog instead, plus the selected manual imaging setup (falling
/// back to `FieldGeometry.dominantFOV`) for the FOV-fit column/tile.
/// `AppState.loadDiscovery()` is lazily triggered from this
/// page's own `onAppear`, same "don't auto-refresh, this is tonight-
/// specific" stance `TonightPage`/`NightsPage` already take for their own
/// on-demand datasets.
struct DiscoveryPage: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    /// Default ON (spec) -- most visits are "what's NEW to shoot", not a
    /// reminder of what's already being collected.
    @State private var hideAlreadyInLibrary = true
    @State private var kindFilter: KindFilter = .all
    @State private var sortOrder = [KeyPathComparator(\DiscoveryTableRow.score, order: .reverse)]
    @State private var selectedDesignation: String?
    @State private var skyArcItem: SkyArcItem?
    @State private var newSessionPrefill: NewSessionPrefillItem?
    @State private var showFocalLengthPopover = false

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controlRow

            if !hasResolvedSite {
                noSiteBanner
                noSiteUnavailableView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Group {
                    if appState.discovery != nil {
                        VStack(alignment: .leading, spacing: 12) {
                            tilesRow
                            if filteredRows.isEmpty {
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
                    } else if appState.isBusy {
                        // R10 review (item 18): `appState.progressText`, not
                        // a hardcoded "Felfedezés számítása…" -- `discovery
                        // == nil` alone doesn't mean THIS page's own load is
                        // what's running; some unrelated busy operation can
                        // be true here just as easily. `progressText`
                        // always reflects whatever operation is ACTUALLY in
                        // flight.
                        ProgressView(appState.progressText)
                    } else {
                        notLoadedState
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding()
        .onAppear {
            if appState.discovery == nil && !appState.isBusy { appState.loadDiscovery() }
        }
        .sheet(item: $skyArcItem) { item in
            SkyArcSheet(row: item.row)
        }
        .sheet(item: $newSessionPrefill) { item in
            NewSessionSheet(prefillDesignation: item.designation)
        }
    }

    // MARK: - Control row

    private var controlRow: some View {
        HStack {
            Toggle("Meglévő célpontok elrejtése", isOn: $hideAlreadyInLibrary)
            kindFilterMenu
            Spacer()
            if !appState.config.imagingSetups.isEmpty {
                setupPicker
                if appState.effectiveImagingSetup?.isZoom == true {
                    focalLengthButton
                }
            } else if appState.discoveryFOV == nil, appState.discovery != nil {
                Button("Setup beállítása…") { openEquipmentSettings() }
                    .buttonStyle(.link)
            }
            // R12-U1 item 6: this page has no site-Picker of its own (it
            // always uses whichever site `TonightPage`/Settings currently
            // has selected) -- a discreet reminder of WHICH one is in
            // effect, since every altitude/visibility number on this page
            // depends on it.
            if appState.config.sites.count > 1 {
                SiteChip(name: appState.effectiveSiteDisplayName)
            }
            if appState.isBusy {
                ProgressView().controlSize(.small)
            }
            Button("Frissítés") { appState.loadDiscovery() }
                .disabled(appState.isBusy || appState.db == nil)
        }
    }

    private var setupPicker: some View {
        Picker("Setup", selection: Binding(
            get: { appState.effectiveImagingSetup?.id ?? "" },
            set: { appState.selectImagingSetup($0) }
        )) {
            ForEach(appState.config.imagingSetups) { setup in
                Text(setup.name).tag(setup.id)
            }
        }
        .frame(width: 230)
        .disabled(appState.isBusy)
        .help("A FOV és a FOV-illeszkedés ehhez a setuphoz készül")
    }

    private var focalLengthButton: some View {
        Button {
            showFocalLengthPopover = true
        } label: {
            Label(focalLengthText, systemImage: "viewfinder")
        }
        .disabled(appState.isBusy)
        .popover(isPresented: $showFocalLengthPopover) {
            if let setup = appState.effectiveImagingSetup {
                focalLengthPopover(for: setup)
            }
        }
    }

    private var focalLengthText: String {
        guard let focal = appState.effectiveDiscoveryFocalLengthMM else { return "– mm" }
        return String(format: "%.0f mm", focal)
    }

    private var discoveryFocalLengthBinding: Binding<Double> {
        Binding(
            get: { appState.effectiveDiscoveryFocalLengthMM ?? 1 },
            set: { appState.setDiscoveryFocalLengthMM($0) }
        )
    }

    private func focalLengthPopover(for setup: ImagingSetupProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tervezési fókusztáv").font(.headline)
                Text(setup.name).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(String(format: "%.0f", setup.focalLengthMinMM))
                    .font(.caption).monospacedDigit()
                Slider(value: discoveryFocalLengthBinding, in: setup.focalLengthMinMM...setup.focalLengthMaxMM, step: 1)
                Text(String(format: "%.0f mm", setup.focalLengthMaxMM))
                    .font(.caption).monospacedDigit()
            }
            LabeledContent("Aktuális", value: focalLengthText)
                .monospacedDigit()
            Text("A FOV mindig ehhez az egy konkrét zoomálláshoz számolódik.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Alapérték") {
                    appState.setDiscoveryFocalLengthMM(setup.defaultFocalLengthMM)
                }
                Spacer()
                Button("Újraszámítás") {
                    showFocalLengthPopover = false
                    appState.loadDiscovery()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appState.isBusy || appState.db == nil)
            }
        }
        .padding()
        .frame(width: 330)
    }

    private func openEquipmentSettings() {
        appState.settingsTab = .equipment
        openSettings()
    }

    private var kindFilterMenu: some View {
        Menu {
            ForEach(KindFilter.allCases, id: \.self) { option in
                Button {
                    kindFilter = option
                } label: {
                    HStack {
                        if kindFilter == option { Image(systemName: "checkmark") }
                        Text(option.label)
                    }
                }
            }
        } label: {
            Label(kindFilter == .all ? "Típus" : "Típus: \(kindFilter.label)", systemImage: "line.3.horizontal.decrease.circle")
        }
        .frame(width: 220, alignment: .leading)
    }

    // MARK: - No-site state

    private var hasResolvedSite: Bool {
        appState.resolvedSite.latitudeDeg != nil && appState.resolvedSite.longitudeDeg != nil
    }

    /// Same yellow inline banner `TonightPage.noSiteBanner` uses, adapted
    /// wording -- unlike that page (which still shows an altitude/
    /// culmination table with a "FITS-fejlécekből becsült" fallback
    /// caveat), Felfedezés has no per-target frame history to fall back to
    /// AT ALL for a catalog target, so this page can't offer that same
    /// degraded-but-honest middle ground -- see `noSiteUnavailableView`.
    private var noSiteBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("Nincs megfigyelési helyszín beállítva — a Felfedezés helyszín nélkül nem tud magasságot/láthatóságot számolni.")
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

    /// R11-T17 (F4): now with a SECOND way out beside the Settings deep-link
    /// -- "Felismerés a képeim fejlécéből" runs
    /// `AppState.recognizeSiteFromImageHeaders()` right here, which tries
    /// the RAW FITS-median regardless of whatever's (not) configured (see
    /// that function's own doc comment) instead of making the user go type
    /// coordinates in by hand when their images already carry them (a common
    /// case: ASIAIR/NINA/… stamp `SITELAT`/`SITELONG` into every FITS header
    /// automatically). Never a silent no-op: a library with no extractable
    /// header data at all surfaces an honest error (toast + activity log)
    /// instead of doing nothing.
    private var noSiteUnavailableView: some View {
        ContentUnavailableView {
            Label("Nincs megfigyelési helyszín", systemImage: "location.slash")
        } description: {
            Text("A katalógus-objektumok láthatóságát csak a földrajzi helyed ismeretében lehet kiszámolni.")
        } actions: {
            Button("Helyszín beállítása…") {
                appState.settingsTab = .location
                openSettings()
            }
            Button("Felismerés a képeim fejlécéből") {
                appState.recognizeSiteFromImageHeaders()
            }
            .disabled(appState.isBusy || appState.db == nil)
        }
    }

    // MARK: - Not-loaded state

    private var notLoadedState: some View {
        ContentUnavailableView {
            Label("Még nincs betöltve", systemImage: "sparkles")
        } description: {
            Text("Töltsd be a katalógus-felfedezést, hogy lásd, mit érdemes ma este lefotózni a beépített katalógusból.")
        } actions: {
            Button("Betöltés") { appState.loadDiscovery() }
                .disabled(appState.db == nil)
        }
    }

    // MARK: - Rows / filtering

    private var allRows: [DiscoveryTableRow] {
        (appState.discovery ?? []).map(DiscoveryTableRow.init)
    }

    private var filteredRows: [DiscoveryTableRow] {
        allRows
            .filter { !hideAlreadyInLibrary || !$0.alreadyInLibrary }
            .filter { kindFilter.matches($0.kind) }
            .sorted(using: sortOrder)
    }

    private func row(withID id: String) -> DiscoveryTableRow? {
        filteredRows.first { $0.id == id }
    }

    /// Describes the currently-active filter combination -- feeds
    /// `ContentUnavailableView.search(text:)`'s "no results for…" message
    /// when a filter narrows the 217-entry catalog down to zero rows, same
    /// pattern `NightsPage.filterDescriptionText` already establishes for
    /// its own year/month filter.
    private var filterDescriptionText: String {
        var parts: [String] = []
        if kindFilter != .all { parts.append(kindFilter.label) }
        if hideAlreadyInLibrary { parts.append("meglévők elrejtve") }
        return parts.joined(separator: ", ")
    }

    /// Reverse of `DiscoveryPlanner.existingDesignations(stats:)`: maps a
    /// catalog designation back to the library's OWN target folder name, so
    /// an `alreadyInLibrary` row's context menu/double-click can navigate
    /// straight to `Page.target(_:)`. Built off `appState.stats` (already
    /// loaded, never triggers its own load) by re-running the exact same
    /// `TargetNameResolver.resolve(folderName:)` call `existingDesignations`
    /// itself uses -- pure/deterministic, so bucketing by `.designation`
    /// here can never disagree with what `discovery`'s own
    /// `alreadyInLibrary` flags were computed against. When two library
    /// targets somehow resolve to the SAME designation (shouldn't happen in
    /// a healthy library), the first one wins -- an arbitrary but stable
    /// tie-break, not something worth surfacing here.
    private var targetByDesignation: [String: String] {
        var map: [String: String] = [:]
        for stat in appState.stats {
            guard let designation = TargetNameResolver.resolve(folderName: stat.target).designation else { continue }
            if map[designation] == nil { map[designation] = stat.target }
        }
        return map
    }

    private func openOrCreate(_ row: DiscoveryTableRow) {
        if let target = targetByDesignation[row.designation] {
            appState.currentPage = .target(target)
        } else {
            newSessionPrefill = NewSessionPrefillItem(designation: row.designation)
        }
    }

    // MARK: - Tiles

    private var recommendedCount: Int {
        filteredRows.count { $0.verdict == SkyVerdictText.good }
    }

    private var fovTileValueText: String {
        guard let fov = appState.discoveryFOV else { return TDFormat.missingTile }
        return String(format: "%.1f° × %.1f°", fov.widthDeg, fov.heightDeg)
    }

    private var fovTileCaptionText: String? {
        if let setup = appState.effectiveImagingSetup,
           let focal = appState.effectiveDiscoveryFocalLengthMM {
            return "\(setup.name) · \(String(format: "%.0f mm", focal))"
        }
        return appState.discoveryFOV == nil
            ? "nincs kézi setup vagy WCS-adat"
            : "automatikus · könyvtárból"
    }

    private var tilesRow: some View {
        HStack(spacing: 12) {
            StatTile(title: "Ma ajánlott", value: "\(recommendedCount)", compact: true)
            StatTile(title: "Katalógus", value: "\(filteredRows.count) / \(TargetCatalog.all.count)", caption: "látható / teljes", compact: true)
            StatTile(title: "Setup látómező", value: fovTileValueText, caption: fovTileCaptionText, compact: true)
        }
    }

    // MARK: - Metric info (R9-T6/B16(a) convention)

    /// Mirrors `TonightPage.planMetricInfo`'s entries for the columns this
    /// page shares in spirit (Max. mag./Látható/Hold/Döntés), reworded only
    /// where the underlying data actually differs (this page's "Látható"
    /// has no visible-window range to show, just hours; "Hold" has no
    /// per-row illumination percent, just separation) -- plus a new "FOV"
    /// entry.
    private static let metricInfo: [MetricInfoButton.Metric] = [
        .init(
            title: "Max. mag.",
            explanation: "A célpont legnagyobb magassága fokban a ma esti látszó ívén (nem fényesség!). Mikor hazudik: helyszín nélkül ez az egész oszlop „-”."
        ),
        .init(
            title: "Látható",
            explanation: "A célpont horizont feletti (illetve az alapértelmezett minimum-magasság feletti) ideje a mai éjszaka sötét szakaszában, órában. Mikor hazudik: „-” marad, ha a célpont ma éjjel egyáltalán nem éri el a minimum-magasságot."
        ),
        .init(
            title: "Hold",
            explanation: "A célponttól mért szögtávolság a Holdtól, fokban, a mai sötét szakasz közepén becsülve. Mikor hazudik: ez önmagában nem mutatja a Hold megvilágítottságát -- egy távoli, de tele Hold is ronthatja a kontrasztot."
        ),
        .init(
            title: "FOV",
            explanation: "A célpont mérete a Felfedezésben kiválasztott kézi setup és konkrét zoom-fókusztáv látómezejéhez mérve („befér” / „mozaik kellene” / „túl kicsi a képmezőhöz”). Kézi setup nélkül a könyvtár domináns, WCS-ből felismert látómezeje a tartalék. A számítás a katalógus egyetlen méretadatából dolgozik, ezért elnyúlt vagy elforgatott célpontnál közelítés."
        ),
        .init(
            title: "Döntés",
            explanation: "Összesítő ajánlás („ma jó” / „Hold zavar (…)” / „nem látszik ma éjjel” / „alacsony (…)” / „nincs koordináta”) a magasság, a láthatósági ablak és a Hold-közelség alapján. Mikor hazudik: csak MA éjjelre szól -- egy ma jó célpont holnap már más döntést kaphat."
        ),
    ]

    // MARK: - Table

    private var table: some View {
        Table(filteredRows, selection: $selectedDesignation, sortOrder: $sortOrder) {
            TableColumn("Objektum", value: \.designationSortKey) { row in objektumCell(row) }
                .width(min: 170, ideal: 210)
            TableColumn("Típus", value: \.kindSortKey) { row in Text(kindLabel(row.kind)) }
                .width(min: 90, ideal: 120)
            // R10-B7: grouped so the table stays AT (not over) `Table`'s
            // 10-top-level-column cap once the trailing "⋯" actions column
            // below needs its own slot -- same `Group { }` workaround
            // `QualitySegment.frameTable` already established.
            Group {
                TableColumn("Méret", value: \.sizeSortKey) { row in Text(sizeText(row)) }
                    .width(min: 55, ideal: 65)
                TableColumn("Magn.", value: \.magnitudeSortKey) { row in Text(magnitudeText(row)) }
                    .width(min: 50, ideal: 60)
            }
            TableColumn("Kulminál", value: \.culminationSortKey) { row in Text(TDFormat.cell(row.culminationLocal)) }
                .width(min: 70, ideal: 80)
            TableColumn("Max. mag.", value: \.maxAltSortKey) { row in Text(maxAltText(row)) }
                .width(min: 70, ideal: 80)
            TableColumn("Látható", value: \.visibleHoursSortKey) { row in Text(visibleText(row)) }
                .width(min: 65, ideal: 80)
            TableColumn("Hold", value: \.moonSortKey) { row in Text(moonText(row)) }
                .width(min: 55, ideal: 65)
            TableColumn("FOV", value: \.fovFitSortKey) { row in fovCell(row) }
                .width(min: 90, ideal: 140)
            // R11-T12/F11(d): clickable -- `DiscoveryRow` carries no Moon-
            // illumination value of its own (only separation), so its
            // popover just omits that one row -- `VerdictExplainPopover`
            // handles a partial number set the same way it handles none at
            // all.
            TableColumn("Döntés", value: \.verdictSortKey) { row in
                VerdictExplainPopover(
                    verdict: row.verdict,
                    maxAltitudeDeg: row.maxAltitudeDeg,
                    visibleHours: row.visibleHours,
                    moonSeparationDeg: row.moonSeparationDeg
                )
            }
            .width(min: 120, ideal: 150)
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
            .width(actionColumnWidth)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        // Row-scoped context menu + double-click-to-open, same pattern
        // `TonightPage.planTable`/`NightsPage.table` use.
        .contextMenu(forSelectionType: DiscoveryTableRow.ID.self) { ids in
            if let id = ids.first, let row = row(withID: id) {
                contextMenuItems(for: row)
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = row(withID: id) {
                openOrCreate(row)
            }
        }
    }

    // MARK: - Cell content

    private func objektumCell(_ row: DiscoveryTableRow) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.designation).bold().lineLimit(1)
                if let commonNameHU = row.commonNameHU {
                    Text(commonNameHU).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if row.alreadyInLibrary {
                alreadyInLibraryBadge
            }
        }
    }

    private var alreadyInLibraryBadge: some View {
        Text("már gyűjtöd")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.gray.opacity(0.15)))
            .foregroundStyle(.gray)
    }

    private func sizeText(_ row: DiscoveryTableRow) -> String {
        guard let size = row.sizeArcmin else { return TDFormat.missingCell }
        return String(format: "%.1f′", size)
    }

    private func magnitudeText(_ row: DiscoveryTableRow) -> String {
        guard let magnitude = row.magnitude else { return TDFormat.missingCell }
        return String(format: "%.1f", magnitude)
    }

    private func maxAltText(_ row: DiscoveryTableRow) -> String {
        guard let alt = row.maxAltitudeDeg else { return TDFormat.missingCell }
        return "\(Int(alt.rounded()))°"
    }

    private func visibleText(_ row: DiscoveryTableRow) -> String {
        guard let hours = row.visibleHours else { return TDFormat.missingCell }
        return String(format: "%.1f ó", hours)
    }

    private func moonText(_ row: DiscoveryTableRow) -> String {
        guard let sep = row.moonSeparationDeg else { return TDFormat.missingCell }
        return "\(Int(sep.rounded()))°"
    }

    @ViewBuilder
    private func fovCell(_ row: DiscoveryTableRow) -> some View {
        if let label = row.fovFitLabel {
            Text(label).foregroundStyle(fovFitColor(label))
        } else {
            Text(TDFormat.missingCell).foregroundStyle(.secondary)
        }
    }

    /// "befér" = green, "mozaik kellene" = orange, everything else (i.e.
    /// "túl kicsi a képmezőhöz") = secondary -- exactly the three
    /// `DiscoveryPlanner.fovFitLabel` strings, spelled out rather than
    /// switched over an enum since that function's return type is a plain
    /// `String?` (see its own doc for why -- only two cutoffs actually
    /// distinguish three labels).
    private func fovFitColor(_ label: String) -> Color {
        switch label {
        case "befér": return .green
        case "mozaik kellene": return .orange
        default: return .secondary
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenuItems(for row: DiscoveryTableRow) -> some View {
        if let target = targetByDesignation[row.designation] {
            Button("Célpont megnyitása") { appState.currentPage = .target(target) }
        } else {
            Button("Új session létrehozása…") { newSessionPrefill = NewSessionPrefillItem(designation: row.designation) }
        }
        Divider()
        // R10 review (item 22): trailing "…" -- this menu item opens a
        // sheet (`SkyArcSheet`), same "action needs more input/opens
        // something" convention every other sheet-opening item in this app
        // already follows (e.g. "Plate-solve…", "Cél beállítása…").
        Button("Ma esti ív…") { skyArcItem = SkyArcItem(row: row.discoveryRow) }
    }
}

// MARK: - Hungarian kind label

/// The "Típus" column's cell text -- exhaustive over every
/// `CatalogTargetKind` case (including `.darkNebula`, unused by any of
/// `TargetCatalog.all`'s 217 entries today but still switched over here so
/// a future catalog addition can't silently fall through to nothing).
private func kindLabel(_ kind: CatalogTargetKind) -> String {
    switch kind {
    case .galaxy: return "Galaxis"
    case .emissionNebula: return "Emissziós köd"
    case .planetaryNebula: return "Planetáris köd"
    case .supernovaRemnant: return "Szupernóva-maradvány"
    case .openCluster: return "Nyílthalmaz"
    case .globularCluster: return "Gömbhalmaz"
    case .reflectionNebula: return "Reflexiós köd"
    case .darkNebula: return "Sötét köd"
    case .other: return "Egyéb"
    }
}

/// One of `SkyVerdict`'s own string constants, duplicated here (it isn't
/// `public` on the AstroCore side -- see that type's own doc) purely so
/// `recommendedCount` can compare against the exact value
/// `DiscoveryPlanner.discover` actually produces instead of a hand-typed
/// literal drifting out of sync with it. R10 review: `notVisibleTonight`
/// (the other constant this enum used to carry) dropped along with the
/// local `verdictColor` it only fed -- that color mapping now lives once,
/// shared, on `VerdictChip` (`SharedComponents.swift`).
private enum SkyVerdictText {
    static let good = "ma jó"
}

// MARK: - Type filter (control row's "Menu")

/// The type-filter Menu's own option set (spec: "Mind / Galaxis /
/// Emissziós köd / Planetáris köd / Szupernóva-maradvány / Nyílthalmaz /
/// Gömbhalmaz / Reflexiós köd / egyéb") -- 7 named kinds plus an "egyéb"
/// catch-all that groups BOTH `.other` and `.darkNebula` together (the two
/// `CatalogTargetKind` cases with no dedicated menu entry of their own),
/// rather than a 1:1 mirror of that enum's 9 cases.
private enum KindFilter: CaseIterable, Hashable {
    case all, galaxy, emissionNebula, planetaryNebula, supernovaRemnant, openCluster, globularCluster, reflectionNebula, other

    var label: String {
        switch self {
        case .all: return "Mind"
        case .galaxy: return "Galaxis"
        case .emissionNebula: return "Emissziós köd"
        case .planetaryNebula: return "Planetáris köd"
        case .supernovaRemnant: return "Szupernóva-maradvány"
        case .openCluster: return "Nyílthalmaz"
        case .globularCluster: return "Gömbhalmaz"
        case .reflectionNebula: return "Reflexiós köd"
        case .other: return "egyéb"
        }
    }

    func matches(_ kind: CatalogTargetKind) -> Bool {
        switch self {
        case .all: return true
        case .galaxy: return kind == .galaxy
        case .emissionNebula: return kind == .emissionNebula
        case .planetaryNebula: return kind == .planetaryNebula
        case .supernovaRemnant: return kind == .supernovaRemnant
        case .openCluster: return kind == .openCluster
        case .globularCluster: return kind == .globularCluster
        case .reflectionNebula: return kind == .reflectionNebula
        case .other: return kind == .other || kind == .darkNebula
        }
    }
}

// MARK: - Table row

/// Flattened, `KeyPathComparator`-friendly wrapper over `DiscoveryRow` --
/// same "one `Identifiable` row struct per table" pattern
/// `TonightPage.PlanRow`/`NightsPage.NightTableRow` already establish.
/// Sentinel sort keys for nullable numeric columns follow the SAME "-1,
/// missing sorts first on an ascending sort" convention those two types
/// document -- safe here too, since no field `TargetCatalog` actually
/// stores (size in arcmin, magnitude, altitude in degrees, hours, angular
/// separation in degrees) ever takes a negative value in practice.
private struct DiscoveryTableRow: Identifiable {
    let discoveryRow: DiscoveryRow

    var id: String { discoveryRow.target.designation }
    var designation: String { discoveryRow.target.designation }
    var commonNameHU: String? { discoveryRow.target.commonNameHU }
    var kind: CatalogTargetKind { discoveryRow.target.kind }
    var sizeArcmin: Double? { discoveryRow.target.sizeArcmin }
    var magnitude: Double? { discoveryRow.target.magnitude }
    var culminationLocal: String? { discoveryRow.culminationLocal }
    var maxAltitudeDeg: Double? { discoveryRow.maxAltitudeDeg }
    var visibleHours: Double? { discoveryRow.visibleHours }
    var moonSeparationDeg: Double? { discoveryRow.moonSeparationDeg }
    var fovFitLabel: String? { discoveryRow.fovFitLabel }
    var verdict: String { discoveryRow.verdict }
    var score: Double { discoveryRow.score }
    var alreadyInLibrary: Bool { discoveryRow.alreadyInLibrary }

    var designationSortKey: String { designation }
    var kindSortKey: String { kindLabel(kind) }
    var sizeSortKey: Double { sizeArcmin ?? -1 }
    var magnitudeSortKey: Double { magnitude ?? -1 }
    var culminationSortKey: String { culminationLocal ?? "" }
    var maxAltSortKey: Double { maxAltitudeDeg ?? -999 }
    var visibleHoursSortKey: Double { visibleHours ?? -1 }
    var moonSortKey: Double { moonSeparationDeg ?? -1 }
    var fovFitSortKey: String { fovFitLabel ?? "" }
    var verdictSortKey: String { verdict }
}

// MARK: - Row-scoped sheets

/// Identifies which row's "Ma esti ív" sheet is open -- same row-scoped
/// `.sheet(item:)` pattern `LinkingSession`/`SolvingTarget`
/// (`Views/TargetDetail/Shared.swift`) already establish elsewhere.
private struct SkyArcItem: Identifiable {
    let row: DiscoveryRow
    var id: String { row.target.designation }
}

/// Identifies which row's "Új session létrehozása…" sheet is open, carrying
/// just the designation `NewSessionSheet(prefillDesignation:)` needs to
/// split apart.
private struct NewSessionPrefillItem: Identifiable {
    let designation: String
    var id: String { designation }
}

/// "Ma esti ív" (spec): a small standalone sheet reusing `SkyChartView` for
/// one catalog target's altitude curve tonight -- cheap, pure math
/// (`SkyTrack.altitudeTrack`), no `Database` access, so this sheet needs
/// nothing beyond the row itself plus the already-resolved site. Only ever
/// presented from `DiscoveryPage`'s table, which itself only renders once
/// `hasResolvedSite` is true -- the `else` branch below is defensive, not
/// expected to be reachable in practice.
private struct SkyArcSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let row: DiscoveryRow

    private var displayName: String {
        guard let commonNameHU = row.target.commonNameHU else { return row.target.designation }
        return "\(row.target.designation) — \(commonNameHU)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Ma esti ív").font(.headline)
                Spacer()
                Button("Bezárás") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if let lat = appState.resolvedSite.latitudeDeg, let lon = appState.resolvedSite.longitudeDeg {
                let night = Date()
                SkyChartView(
                    targetName: displayName,
                    targetTrack: SkyTrack.altitudeTrack(raDeg: row.target.raDeg, decDeg: row.target.decDeg, nightOf: night, latDeg: lat, lonDeg: lon),
                    moonTrack: SkyTrack.moonAltitudeTrack(nightOf: night, latDeg: lat, lonDeg: lon),
                    markers: SkyTrack.nightWindowMarkers(nightOf: night, latDeg: lat, lonDeg: lon),
                    minAltitudeDeg: plannerDefaultMinAltitudeDeg,
                    isTonight: true,
                    nightOf: night,
                    moonIlluminationPercent: nil
                )
            } else {
                Text("Nincs megfigyelési helyszín beállítva.").foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 480, height: 320)
    }
}
