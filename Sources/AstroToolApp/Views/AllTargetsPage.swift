import AppKit
import AstroCore
import SwiftUI
import UniformTypeIdentifiers

/// One row of the hierarchical stats `Table`: either a target roll-up (with
/// its sessions as children) or a single session detail nested under one.
/// View-layer only -- built fresh from `AppState.stats` /
/// `AppState.sessionDetailsByTarget` on every render, never persisted.
struct StatsRow: Identifiable {
    enum Kind {
        case target(TargetStats)
        case session(target: String, detail: SessionDetail)
    }

    /// "t:<target>" for a target row, "s:<target>:<dateRaw>" for a session
    /// row -- unique across the whole table since `dateRaw` is unique within
    /// one target's session list.
    let id: String
    let kind: Kind
    /// `nil` (not merely `[]`) when there are no sessions, so `Table` shows
    /// no disclosure chevron at all for a target with no session rows on
    /// record (e.g. stacks/processed-only targets).
    var children: [StatsRow]?
}

/// R9-T3/A.2's "Minden célpont" page -- every target/session in one
/// hierarchical table, PLUS (R9-D8, the re-review's completion pass) a
/// headline tile row, a "Fázis" column mirroring the sidebar's phase dots,
/// a "Stackek" column, read-only tag chips (mutation moved into the row
/// context menus), and real `ContentUnavailableView` empty states. Renamed
/// from `StatsView` -- it's the target/session browser now, not a bare
/// stats dump (the name predates R9-T1's sidebar and dates back to when
/// this was the only "list every target" surface in the app).
struct AllTargetsPage: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    /// The session currently shown in `CalibLinkSheet`, `nil` when the sheet
    /// is closed. Row-scoped by construction: only one "Kalibráció
    /// linkelése…" context-menu item can be triggered at a time. (Shared
    /// `LinkingSession`/`SolvingTarget` types, `Views/TargetDetail/
    /// Shared.swift` -- R9-T3 lifted these out of this file so
    /// `TargetDetailPage` could reuse the same sheets.)
    @State private var linkingSession: LinkingSession?
    /// R9-D8/h: previously declared but never read anywhere -- wired into
    /// `statsTable`'s `selection:`/`.contextMenu(forSelectionType:)` instead
    /// of being deleted, the same row-scoped context-menu/double-click
    /// pattern `SessionsSegment.table` (`Views/TargetDetail/
    /// SessionsSegment.swift:125`) already established.
    @State private var selection: StatsRow.ID?
    /// The target currently shown in `PlateSolveSheet`, `nil` when closed --
    /// same row-scoped pattern as `linkingSession`.
    @State private var solvingTarget: SolvingTarget?
    /// The session currently shown in `StackListSheet` (R7-B4/A.10
    /// "Stackelés előkészítése…"), `nil` when closed -- same row-scoped
    /// pattern as `linkingSession`.
    @State private var stackListingSession: LinkingSession?
    /// The session currently shown in `SessionNoteSheet` (R9-T6/B4's
    /// "Éjszaka-jegyzet szerkesztése…"), `nil` when closed -- same
    /// row-scoped pattern as `linkingSession`.
    @State private var noteEditingSession: LinkingSession?
    /// The target whose goal is being edited via `TonightPage`'s
    /// `GoalEditSheet` (R9-D8/e's "Cél beállítása…" context-menu item) --
    /// reuses that sheet rather than duplicating it, same "row-scoped sheet
    /// trigger" pattern as every other `@State` here.
    @State private var goalEditingTarget: GoalEditingTarget?
    /// The target (and, for a session row, its date) currently shown in
    /// `AddTagSheet` (R9-D8/d) -- `date == nil` means a target-level tag.
    @State private var addingTag: AddTagTarget?
    /// D23: a root-relative subpath just dropped onto this page, awaiting
    /// the confirmation dialog before `appState.runScan(subpath:)` actually
    /// runs -- `nil` means no dialog is up.
    @State private var pendingScanSubpath: String?
    /// Drop-highlight state for the folder-drop-to-scope-a-scan affordance,
    /// same visual language `WelcomeView`'s root-folder drop target uses.
    @State private var isDropTargeted = false

    /// `true` once `AppState.plan` has loaded and reports no resolvable
    /// coordinate for `target` at all -- gates the "Plate-solve…" action so
    /// it only shows up for targets that actually need it (ASIAIR lights are
    /// already plate-solved; this is for wide-field Canon CR3 targets).
    /// `false` (hidden) while `plan` hasn't loaded yet, same "don't guess"
    /// stance as the mosaic-panel button only showing once `panelReportsByTarget`
    /// has data.
    private func targetLacksCoordinate(_ target: String) -> Bool {
        guard let plan = appState.plan else { return false }
        return plan.first(where: { $0.target == target })?.raDeg == nil
    }

    private var filteredTargets: [TargetStats] {
        guard !searchText.isEmpty else { return appState.stats }
        return appState.stats.filter { stats in
            stats.target.localizedCaseInsensitiveContains(searchText)
                || stats.displayName.localizedCaseInsensitiveContains(searchText)
                || stats.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private var rows: [StatsRow] {
        filteredTargets.map { stats in
            // R9-T3: the discovered-stacks summary child row is gone --
            // "Stackek" now live on the target's own Célpont-részletek page
            // (Stackek szegmens), so duplicating a summary of them here (on
            // top of the tooltip's own `stacksSummaryLine`) would just be
            // noise.
            let childRows: [StatsRow] = (appState.sessionDetailsByTarget[stats.target] ?? []).map { detail in
                StatsRow(
                    id: "s:\(stats.target):\(detail.dateRaw)",
                    kind: .session(target: stats.target, detail: detail),
                    children: nil
                )
            }
            return StatsRow(
                id: "t:\(stats.target)",
                kind: .target(stats),
                children: childRows.isEmpty ? nil : childRows
            )
        }
    }

    private func row(withID id: StatsRow.ID) -> StatsRow? {
        for row in rows {
            if row.id == id { return row }
            if let child = row.children?.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    private var totalIntegrationSeconds: Double {
        appState.stats.reduce(0) { $0 + $1.totalIntegrationSeconds }
    }

    // MARK: - Tile row (R9-D8/a)

    private var sessionCount: Int {
        appState.stats.reduce(0) { $0 + $1.sessionDates.count }
    }

    private var doneCount: Int {
        appState.projectStates.count { $0.phase == .done }
    }

    private var inProgressCount: Int {
        appState.projectStates.count { $0.phase != .done }
    }

    private var tilesRow: some View {
        HStack(spacing: 12) {
            StatTile(title: "Célpontok", value: "\(appState.stats.count)", color: .blue)
            StatTile(title: "Sessionök", value: "\(sessionCount)", color: .blue)
            StatTile(title: "Összes integráció", value: formatDuration(totalIntegrationSeconds), color: .green)
            StatTile(title: "Kész / folyamatban", value: "\(doneCount) / \(inProgressCount)", color: .orange)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // N10 (R9 round 3): without the `isBusy` check, the launch-time
            // `loadDashboardData()` kicked off by `openRoot` left this page
            // flashing "Nincs célpont a könyvtárban" for however long that
            // load took, on a library that plainly has targets -- `stats`
            // just hadn't landed yet.
            if appState.isBusy && appState.stats.isEmpty {
                ProgressView("Célpontok betöltése…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.stats.isEmpty {
                noTargetsState
            } else {
                HStack {
                    TextField("Keresés célpont vagy címke szerint", text: $searchText)
                        .frame(width: 280)
                    // R10 review (item 9): "Frissítés" is this app's
                    // standard label for a re-run-the-load button
                    // (`NightsPage`/`DiscoveryPage` already use it) -- was
                    // one of two remaining "Újraszámolás" holdouts (the
                    // other: `CalibrationPage`).
                    Button("Frissítés") { appState.loadDashboardData() }
                        .disabled(appState.isBusy || appState.db == nil)
                    Spacer()
                    if appState.isBusy {
                        ProgressView().controlSize(.small)
                        Text(appState.progressText).foregroundStyle(.secondary)
                    }
                }

                if let lastError = appState.lastError {
                    Text(lastError).foregroundStyle(.red)
                }

                tilesRow

                if rows.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    statsTable
                }
            }
        }
        .padding()
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3, antialiased: true)
                    .padding(8)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFolderDrop(providers)
        }
        .confirmationDialog(
            "Almappa beolvasása",
            isPresented: Binding(
                get: { pendingScanSubpath != nil },
                set: { if !$0 { pendingScanSubpath = nil } }
            )
        ) {
            Button("Beolvasás") {
                if let subpath = pendingScanSubpath {
                    appState.runScan(subpath: subpath)
                }
                pendingScanSubpath = nil
            }
            Button("Mégse", role: .cancel) { pendingScanSubpath = nil }
        } message: {
            Text("Csak ezt az almappát olvassam be? \(pendingScanSubpath ?? "")")
        }
        .onAppear {
            // R9-D3: `loadStats()`/`loadPlan()` fired back-to-back here used
            // to race each other's `currentTask` (see `loadDashboardData`'s
            // doc comment) -- bundled into one background operation, which
            // also fills `plan` (needed by `targetLacksCoordinate` to gate
            // the "Plate-solve…" action).
            // N9 (R9 round 3): `!appState.isBusy` stops this from firing a
            // SECOND redundant `loadDashboardData()` right behind the one
            // `openRoot` already kicked off at launch.
            if !appState.isBusy && (appState.stats.isEmpty || appState.plan == nil) {
                appState.loadDashboardData()
            }
        }
        .sheet(item: $linkingSession) { session in
            CalibLinkSheet(target: session.target, date: session.date)
        }
        .sheet(item: $solvingTarget) { solving in
            PlateSolveSheet(target: solving.target)
        }
        .sheet(item: $stackListingSession) { session in
            StackListSheet(target: session.target, date: session.date)
        }
        .sheet(item: $noteEditingSession) { session in
            SessionNoteSheet(target: session.target, date: session.date)
        }
        .sheet(item: $goalEditingTarget) { editing in
            GoalEditSheet(target: editing.target, initialHours: editing.currentHours)
        }
        .sheet(item: $addingTag) { info in
            AddTagSheet(target: info.target, date: info.date)
        }
    }

    // MARK: - Empty states (R9-D8/g)

    private var noTargetsState: some View {
        ContentUnavailableView {
            Label("Nincs célpont a könyvtárban", systemImage: "moon.stars")
        } description: {
            Text("Válassz egy képkönyvtárat, vagy hozz létre egy új sessiont a kezdéshez.")
        } actions: {
            Button("Mappa választása…") { appState.chooseRoot() }
            Button("Új session…") { NotificationCenter.default.post(name: .newSession, object: nil) }
                .disabled(appState.db == nil)
            Button("Mappastruktúra súgó") {
                NotificationCenter.default.post(name: .showFolderStructureHelp, object: nil)
            }
        }
    }

    private var statsTable: some View {
        Table(rows, children: \.children, selection: $selection) {
            TableColumn("Célpont / Session") { row in
                nameCell(row)
            }
            .width(min: 220, ideal: 260)

            // R9-D8/b: target rows only -- mirrors the sidebar's own phase
            // dots/`TonightPage`'s "Állapot" column so a target's pipeline
            // state is visible without opening its Célpont-részletek page.
            TableColumn("Fázis") { row in phaseCell(row) }
                .width(min: 90, ideal: 110)

            TableColumn("Integráció") { row in
                Text(formatDuration(integrationSeconds(row)))
            }
            .width(min: 80, ideal: 90)

            // R9-T3/B11: goal-tag UI landed on the Célpont-részletek header
            // first -- this minimal read-only column (target rows only) is
            // what makes a goal set there immediately visible here too.
            TableColumn("Cél") { row in
                Text(goalText(row)).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 70)

            // R10-B7: grouped so the table stays AT (not over) `Table`'s
            // 10-top-level-column cap once the trailing "⋯" actions column
            // below needs its own slot -- same `Group { }` workaround
            // `QualitySegment.frameTable` already established.
            Group {
                // R9-D8/c: target rows only -- "N csoport" from
                // `AppState.stackGroupsByTarget` (R8-3's variant grouping),
                // `-` for a target with no discovered stacks at all.
                TableColumn("Stackek") { row in
                    Text(stacksText(row)).foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 90)

                TableColumn("Keretek") { row in
                    Text(framesText(row))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 120, ideal: 150)
            }

            TableColumn("Expozíciók / Utolsó dátum") { row in
                Text(exposureOrLastDateText(row))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 130, ideal: 180)

            TableColumn("Kamera") { row in
                Text(cameraText(row))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Részletek") { row in
                Text(detailsText(row))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 180)

            // R9-D8/d: read-only -- no +/× here anymore, a tag is added/
            // removed from the row's own context menu instead.
            TableColumn("Címkék") { row in
                tagsCell(row)
            }
            .width(min: 120, ideal: 180)

            // R10-B7: visible row-actions -- mirrors the exact same
            // `targetContextMenuItems`/`sessionActionMenu` switch the
            // row-scoped `.contextMenu(forSelectionType:)` below uses, so
            // the right-click menu and this borderless "⋯" button can never
            // drift apart.
            TableColumn("") { row in
                Menu {
                    switch row.kind {
                    case .target(let stats):
                        targetContextMenuItems(stats)
                    case .session(let target, let detail):
                        sessionActionMenu(target: target, detail: detail)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .width(actionColumnWidth)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        // R9-D8/h: row-scoped context menu + double-click-to-open, same
        // pattern `SessionsSegment.table` uses -- replaces the old per-cell
        // `.contextMenu`/`.onTapGesture` that only fired over the name
        // cell's own text.
        .contextMenu(forSelectionType: StatsRow.ID.self) { ids in
            if let id = ids.first, let row = row(withID: id) {
                switch row.kind {
                case .target(let stats):
                    targetContextMenuItems(stats)
                case .session(let target, let detail):
                    sessionActionMenu(target: target, detail: detail)
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = row(withID: id), case .target(let stats) = row.kind {
                appState.currentPage = .target(stats.target)
            }
        }
    }

    // MARK: - Column: Fázis

    @ViewBuilder
    private func phaseCell(_ row: StatsRow) -> some View {
        if case .target(let stats) = row.kind {
            PhaseChip(phase: appState.projectStates.first { $0.target == stats.target }?.phase)
        }
    }

    // MARK: - Column: Stackek

    private func stacksText(_ row: StatsRow) -> String {
        guard case .target(let stats) = row.kind else { return "" }
        guard let groups = appState.stackGroupsByTarget[stats.target], !groups.isEmpty else { return TDFormat.missingCell }
        return "\(groups.count) csoport"
    }

    // MARK: - Column 1: Célpont / Session

    @ViewBuilder
    private func nameCell(_ row: StatsRow) -> some View {
        switch row.kind {
        case .target(let stats):
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(stats.displayName).bold()
                    if stats.isWideField {
                        Text("wide-field")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                }
                .lineLimit(1)
                // Resolved catalog designation/common name (R7-B7) --
                // secondary caption with the raw folder name underneath,
                // only when it actually differs (an unresolved/junk folder
                // name already equals `displayName`, so showing it twice
                // would be noise).
                if stats.displayName != stats.target {
                    Text(stats.target)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .help(targetBreakdownTooltip(stats))
        case .session(_, let detail):
            HStack(spacing: 6) {
                Text(detail.dateRaw)
                if detail.hasReadme {
                    Text("README")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .help(readmeNotesTooltip(detail.notes))
                }
                if detail.isExcludedFromTotals {
                    Text("kizárva")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                        .foregroundStyle(.red)
                }
            }
            .lineLimit(1)
            .opacity(detail.isExcludedFromTotals ? 0.5 : 1.0)
        }
    }

    // MARK: - Context menus (R9-T3/A.2/B9/D8 -- replaces the old Műveletek column)

    /// Target row's right-click menu -- everything the removed "Műveletek"
    /// column used to offer for a target EXCEPT "Panelek…"/"Stackek…" table
    /// buttons (dropped outright, not moved: both now live on the target's
    /// own Célpont-részletek page). R9-D8/e adds "Cél beállítása…"/"Kész
    /// stackek…" (moved off the header/tooltip-only treatment they had
    /// before; a "Mozaik-panelek…" item that briefly lived alongside them
    /// was removed in N12/R9 round 3 -- it just duplicated "Célpont
    /// megnyitása"), and R9-D8/d moves tag add/remove here (the "Címkék"
    /// column itself is now read-only chips).
    @ViewBuilder
    private func targetContextMenuItems(_ stats: TargetStats) -> some View {
        // R10 review (item 8): "Célpont megnyitása" everywhere a row's
        // primary action navigates to the target page (`NightsPage`
        // already uses this exact wording) -- was a bare "Megnyitás", which
        // reads as "open the FILE" the way `QualitySegment`'s identically-
        // named (but genuinely file-opening) context-menu item does.
        Button("Célpont megnyitása") { appState.currentPage = .target(stats.target) }
        Button("Megnyitás Finderben") { revealInFinder(relativePath: "sessions/\(stats.target)") }
        Divider()
        Button("Cél beállítása…") {
            let current = appState.projectStates.first { $0.target == stats.target }?.goalSeconds
            goalEditingTarget = GoalEditingTarget(target: stats.target, currentHours: (current ?? 36000) / 3600.0)
        }
        if let report = appState.stackReportsByTarget[stats.target], !report.stacks.isEmpty {
            Button("Kész stackek…") {
                appState.pendingTargetSegment = .stacks
                appState.currentPage = .target(stats.target)
            }
        }
        // N12 (R9 round 3): "Mozaik-panelek…" used to do EXACTLY what
        // "Célpont megnyitása" already does (jump to the target's default
        // Áttekintés segment, which already has the inline mosaic table) --
        // dropped as a pure duplicate rather than given its own preselect.
        Divider()
        Menu("Exportálás") {
            Button("AstroBin CSV") { appState.exportAcquisition(target: stats.target, format: .astrobin) }
            Button("CSV") { appState.exportAcquisition(target: stats.target, format: .csv) }
            Button("Markdown") { appState.exportAcquisition(target: stats.target, format: .md) }
        }
        Button("Célpont-riport készítése") { appState.exportTargetReport(target: stats.target) }
        if targetLacksCoordinate(stats.target) {
            Divider()
            Button("Plate-solve…") { solvingTarget = SolvingTarget(target: stats.target) }
        }
        Divider()
        Button("Címke hozzáadása…") { addingTag = AddTagTarget(target: stats.target, date: nil) }
        if !stats.tags.isEmpty {
            Menu("Címke eltávolítása") {
                ForEach(stats.tags, id: \.self) { tag in
                    Button(tag) { appState.removeTag(target: stats.target, date: nil, tag: tag) }
                }
            }
        }
    }

    /// Session row's right-click menu / visible "⋯" menu -- R11-T2: now a
    /// thin wrapper around the shared `SessionActionMenu` (SharedComponents
    /// .swift), the same builder `NightsPage`/`SessionsSegment` route their
    /// own session rows through, so this page's action set can never drift
    /// from theirs again. `showOpenTarget` defaults to `true` (this page
    /// isn't the target's own detail page), adding "Célpont megnyitása"
    /// here for the first time.
    private func sessionActionMenu(target: String, detail: SessionDetail) -> some View {
        SessionActionMenu(
            target: target,
            date: detail.dateRaw,
            tags: detail.tags,
            linkingSession: $linkingSession,
            stackListingSession: $stackListingSession,
            noteEditingSession: $noteEditingSession,
            addingTag: $addingTag
        )
    }

    private func revealInFinder(relativePath: String) {
        let url = URL(fileURLWithPath: appState.config.rootPath, isDirectory: true).appendingPathComponent(relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Folder drop -> scoped scan (D23/B13)

    /// Same `NSItemProvider`/`.fileURL` drop-handling shape `WelcomeView` uses
    /// for "drop a folder to pick the root" -- here a dropped folder scopes a
    /// rescan instead of choosing a new root.
    private func handleFolderDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                handleDroppedFolder(url)
            }
        }
        return true
    }

    /// Maps a dropped folder to a root-relative subpath and opens the
    /// confirmation dialog -- rejects (via `appState.lastError`) anything
    /// that isn't actually under the configured root, since a scan can only
    /// ever touch the library, never some unrelated folder the user happened
    /// to drag in.
    private func handleDroppedFolder(_ url: URL) {
        let rootPath = URL(fileURLWithPath: appState.config.rootPath, isDirectory: true).standardizedFileURL.path
        let droppedPath = url.standardizedFileURL.path

        guard droppedPath != rootPath else {
            appState.lastError = "Ez a könyvtár gyökere -- ehhez a \u{201E}Beolvasás\u{201D} gomb való."
            return
        }
        guard droppedPath.hasPrefix(rootPath + "/") else {
            appState.lastError = "A mappa nincs a könyvtár gyökere alatt: \(droppedPath)"
            return
        }
        pendingScanSubpath = String(droppedPath.dropFirst(rootPath.count + 1))
    }

    /// Hover tooltip on a target row's name cell: the usable-vs-gross
    /// breakdown behind the headline integration number, so a user who sees
    /// "42.55h" shrink to "29.77h" after upgrading can see WHY without
    /// digging into individual sessions.
    private func targetBreakdownTooltip(_ stats: TargetStats) -> String {
        var lines = [
            "Valós (usable) integráció: \(formatDuration(stats.usableIntegrationSeconds))",
            "Bruttó (dedup nélkül): \(formatDuration(stats.grossIntegrationSeconds))",
            "Használható keret: \(stats.usableFrameCount)",
        ]
        if stats.duplicateLinkCount > 0 { lines.append("Duplikált link/másolat: \(stats.duplicateLinkCount)") }
        if stats.rejectedFrameCount > 0 { lines.append("Elvetett (Reject/): \(stats.rejectedFrameCount)") }
        if stats.nonFrameFileCount > 0 { lines.append("Nem-keret fájl a lights/ alatt: \(stats.nonFrameFileCount)") }
        if !stats.excludedSessionDates.isEmpty {
            lines.append("Kizárt session-ök: \(stats.excludedSessionDates.joined(separator: ", "))")
        }
        if let panels = appState.panelReportsByTarget[stats.target], panels.isMosaic {
            lines.append("Panelek: \(panelsSummaryLine(panels))")
        }
        if let report = appState.stackReportsByTarget[stats.target], !report.stacks.isEmpty {
            lines.append("Stackek: \(stacksSummaryLine(report))")
        }
        return lines.joined(separator: "\n")
    }

    /// "3 stack, legjobb: 106×120 s (3:32)" (R8-1) -- the compact one-line
    /// discovered-stacks summary in the target row's hover tooltip
    /// (`targetBreakdownTooltip`; R9-T3 removed the old "Stackek…" popover
    /// this used to feed -- "Kész stackek…" now just navigates straight to
    /// `TargetDetailPage`'s Stackek segment). The "best" stack is the first
    /// one in `report.stacks` that has a parsed `totalSecondsFromName` --
    /// the list is already sorted that way (`StackDiscovery.discover`'s own
    /// convention).
    private func stacksSummaryLine(_ report: TargetStacks) -> String {
        var line = "\(report.stacks.count) stack"
        if let best = report.stacks.first(where: { $0.totalSecondsFromName != nil }) {
            let frames = best.framesFromName.map(String.init) ?? "?"
            let sub = best.subSecondsFromName.map { String(format: "%.0f", $0) } ?? "?"
            line += ", legjobb: \(frames)×\(sub) s (\(formatDuration(best.totalSecondsFromName ?? 0)))"
        }
        return line
    }

    /// Hover tooltip on a session row's "README" badge (R6-4): every note
    /// `ReadmeNotesParser` pulled out of that session's `README.txt`, one
    /// `key: value` line each, sorted by key for a stable read. Falls back
    /// to a short placeholder for a README with no parseable lines at all
    /// (an edge case, but the badge itself only reflects the file's
    /// existence, not whether it has any content worth surfacing).
    private func readmeNotesTooltip(_ notes: [String: String]) -> String {
        guard !notes.isEmpty else { return "README.txt (nincs kiolvasható bejegyzés)" }
        return notes.keys.sorted().map { "\($0): \(notes[$0] ?? "")" }.joined(separator: "\n")
    }

    /// "3 panel: A 2:10 · B 1:50 · C 0:35 ⚠️ kiegyenlítetlen" -- the compact
    /// one-line mosaic summary in the target row's hover tooltip
    /// (`targetBreakdownTooltip`; same "old popover replaced by straight
    /// navigation" history as `stacksSummaryLine` above -- "Mozaik-panelek…"
    /// now just opens `TargetDetailPage`).
    private func panelsSummaryLine(_ report: PanelReport) -> String {
        let perPanel = report.panels.map { "\($0.label) \(formatDuration($0.integrationSeconds))" }.joined(separator: " · ")
        var line = "\(report.panels.count) panel: \(perPanel)"
        if report.isUnbalanced { line += " ⚠️ kiegyenlítetlen" }
        return line
    }

    // MARK: - Column: Integráció

    private func integrationSeconds(_ row: StatsRow) -> Double {
        switch row.kind {
        case .target(let stats): return stats.totalIntegrationSeconds
        case .session(_, let detail): return detail.integrationSeconds
        }
    }

    /// "6:00" for a target with a `goal:6h` tag, "-" otherwise -- `""` for
    /// session rows (a goal is target-scoped only). Reads
    /// `AppState.projectStates` (`ProjectState.goalSeconds`, already
    /// `GoalTag`-parsed) rather than re-parsing `TargetStats.tags` itself.
    private func goalText(_ row: StatsRow) -> String {
        guard case .target(let stats) = row.kind else { return "" }
        guard let goalSeconds = appState.projectStates.first(where: { $0.target == stats.target })?.goalSeconds else {
            return TDFormat.missingCell
        }
        return formatDuration(goalSeconds)
    }

    // MARK: - Column: Keretek

    private func framesText(_ row: StatsRow) -> String {
        switch row.kind {
        case .target(let stats):
            return "\(stats.sessionDates.count) session"
        case .session(_, let detail):
            var parts: [String] = []
            if detail.usableLightCount > 0 { parts.append("\(detail.usableLightCount) light") }
            if detail.flatCount > 0 { parts.append("\(detail.flatCount) flat") }
            if detail.darkCount > 0 { parts.append("\(detail.darkCount) dark") }
            if detail.biasCount > 0 { parts.append("\(detail.biasCount) bias") }
            var text = parts.isEmpty ? TDFormat.missingCell : parts.joined(separator: " · ")
            var extras: [String] = []
            if detail.rejectedCount > 0 { extras.append("\(detail.rejectedCount) elvetett") }
            if detail.duplicateLinkCount > 0 { extras.append("\(detail.duplicateLinkCount) link") }
            if !extras.isEmpty {
                text += "  (+\(extras.joined(separator: " · ")))"
            }
            if let accepted = detail.dssAcceptedCount, let rejected = detail.dssRejectedCount {
                text += " · DSS: \(accepted)✓/\(rejected)✗"
            }
            return text
        }
    }

    // MARK: - Column: Expozíciók / Utolsó dátum

    private func exposureOrLastDateText(_ row: StatsRow) -> String {
        switch row.kind {
        case .target(let stats):
            return TDFormat.cell(stats.lastSessionDate)
        case .session(_, let detail):
            return exposureSummary(detail.exposureBreakdown)
        }
    }

    private func exposureSummary(_ breakdown: [String: Int]) -> String {
        guard !breakdown.isEmpty else { return TDFormat.missingCell }
        return breakdown
            .sorted { $0.key < $1.key }
            .map { key, count in
                if key == "unknown" { return "?×\(count)" }
                let label = Double(key).map(Self.formatNumber) ?? key
                return "\(label)s×\(count)"
            }
            .joined(separator: ", ")
    }

    // MARK: - Column: Kamera

    private func cameraText(_ row: StatsRow) -> String {
        switch row.kind {
        case .target(let stats):
            return stats.cameras.isEmpty ? TDFormat.missingCell : stats.cameras.joined(separator: ", ")
        case .session(_, let detail):
            return detail.cameras.isEmpty ? TDFormat.missingCell : detail.cameras.joined(separator: ", ")
        }
    }

    // MARK: - Column: Részletek (sessions only)

    private func detailsText(_ row: StatsRow) -> String {
        guard case .session(_, let detail) = row.kind else { return "" }
        var parts: [String] = []
        if !detail.focalLengthsMM.isEmpty {
            parts.append(detail.focalLengthsMM.map { "\(Self.formatNumber($0)) mm" }.joined(separator: "/"))
        }
        if !detail.gains.isEmpty {
            parts.append("gain \(detail.gains.map(Self.formatNumber).joined(separator: "/"))")
        }
        if !detail.sensorTempsC.isEmpty {
            parts.append(detail.sensorTempsC.map { "\(Self.formatNumber($0)) °C" }.joined(separator: "/"))
        }
        if !detail.filters.isEmpty {
            parts.append(detail.filters.joined(separator: "/"))
        }
        return parts.isEmpty ? TDFormat.missingCell : parts.joined(separator: " · ")
    }

    // MARK: - Column: Címkék (read-only, R9-D8/d)

    @ViewBuilder
    private func tagsCell(_ row: StatsRow) -> some View {
        switch row.kind {
        case .target(let stats):
            ReadOnlyTagChipsRow(tags: stats.tags)
        case .session(_, let detail):
            ReadOnlyTagChipsRow(tags: detail.tags)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }

    private static func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

// MARK: - Tag add sheet (R9-D8/d)

/// One target, optionally scoped to one of its session dates -- `Identifiable`
/// so a `@State` of this type can drive `AddTagSheet`'s `.sheet(item:)`.
/// `date == nil` means a target-level tag, same convention
/// `Database.addTag`/`AppState.addTag` already use.
struct AddTagTarget: Identifiable {
    let target: String
    let date: String?
    var id: String { date.map { "\(target):\($0)" } ?? target }
}

/// Small prompt sheet for R9-D8/d's "Címke hozzáadása…" context-menu item --
/// replaces the old inline `AddTagChip` popover now that tag mutation lives
/// in the row context menu instead of the (now read-only) "Címkék" column.
struct AddTagSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: String
    let date: String?
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Címke hozzáadása").font(.headline)
            Text(date.map { "\(target) / \($0)" } ?? target).foregroundStyle(.secondary)
            TextField("Címke", text: $text).onSubmit(submit)
            HStack {
                Spacer()
                Button("Mégse") { dismiss() }
                Button("Hozzáadás", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appState.addTag(target: target, date: date, tag: trimmed)
        dismiss()
    }
}

// MARK: - Read-only tag chips (R9-D8/d)

/// A wrapping row of read-only tag capsules -- no add/remove affordance;
/// that moved into the row's context menu (`AddTagSheet`/"Címke
/// eltávolítása" submenu). Shared by target and session rows.
private struct ReadOnlyTagChipsRow: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.35)))
            }
        }
    }
}

/// Minimal wrapping horizontal-then-vertical layout for tag chips -- SwiftUI
/// has no built-in "flow" container. Lays subviews left-to-right, wrapping
/// to a new line once the proposed width would be exceeded.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 600
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > maxWidth {
                origin.x = 0
                origin.y += lineHeight + spacing
                lineHeight = 0
            }
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, origin.x)
        }

        return CGSize(width: totalWidth, height: origin.y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > bounds.minX, origin.x + size.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
