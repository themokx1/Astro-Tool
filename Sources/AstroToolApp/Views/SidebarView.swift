import AstroCore
import SwiftUI

/// `.searchFocused(_:)` needs macOS 15 -- this package targets macOS 14, so
/// the ⌘F-focuses-the-search-field behavior only kicks in on macOS 15+;
/// pre-15, the search field is still there (via `.searchable`), it just
/// isn't programmatically focusable.
private struct SearchFocusModifier: ViewModifier {
    var isFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.searchFocused(isFocused)
        } else {
            content
        }
    }
}

extension Notification.Name {
    /// Posted by the "Kereső" menu command (⌘F, `Views/Commands.swift`) --
    /// `SidebarView` is the only observer for now (T1 scope: sidebar-local
    /// target filtering only). T6 widens this into the real global search.
    static let focusSearchField = Notification.Name("AstroTool.focusSearchField")
}

/// The navigation shell's sidebar (R9-T1): fixed top-level pages plus one
/// row per target, replacing the old six-tab `TabView`. Selection drives
/// `AppState.currentPage` directly -- there is no separate "detail
/// navigation" state, the sidebar IS the router.
struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    @FocusState private var searchFieldFocused: Bool

    private struct TargetRow: Identifiable {
        let target: String
        let displayName: String
        let tags: [String]
        let phase: ProjectPhase?
        let lastSessionDate: String?
        var id: String { target }
    }

    /// `ProjectStatusQueries` phase order the spec itself lists in
    /// ("gyűjtés, stackelhető, feldolgozásra vár, kész") -- used both for
    /// the dot color and as the primary sort key, un-phased targets (no
    /// `ProjectState` entry yet, e.g. right after a fresh scan before
    /// "Frissítés" on a phase-computing page has run) sort last.
    private static func phaseRank(_ phase: ProjectPhase?) -> Int {
        switch phase {
        case .collecting: return 0
        case .readyToStack: return 1
        case .stacked: return 2
        case .done: return 3
        case nil: return 4
        }
    }

    private var targetRows: [TargetRow] {
        let phaseByTarget = Dictionary(uniqueKeysWithValues: appState.projectStates.map { ($0.target, $0.phase) })
        let rows = appState.stats.map { stat in
            TargetRow(
                target: stat.target,
                displayName: stat.displayName,
                tags: stat.tags,
                phase: phaseByTarget[stat.target],
                lastSessionDate: stat.lastSessionDate
            )
        }
        let filtered: [TargetRow]
        if searchText.isEmpty {
            filtered = rows
        } else {
            filtered = rows.filter { row in
                row.displayName.localizedCaseInsensitiveContains(searchText)
                    || row.target.localizedCaseInsensitiveContains(searchText)
                    || row.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }
        return filtered.sorted { lhs, rhs in
            let lhsRank = Self.phaseRank(lhs.phase)
            let rhsRank = Self.phaseRank(rhs.phase)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            // Descending by last session date; targets with no session date
            // sort after ones that have one.
            switch (lhs.lastSessionDate, rhs.lastSessionDate) {
            case let (l?, r?): return l > r
            case (nil, nil): return lhs.displayName < rhs.displayName
            case (nil, _): return false
            case (_, nil): return true
            }
        }
    }

    private var tonightBadgeCount: Int {
        // R11-T6/F3: `hasPrefix`, not `==` -- an NB-augmented verdict
        // ("ma jó — Ha-ra") is still a "shoot this tonight" recommendation.
        appState.plan?.count { $0.verdict.hasPrefix("ma jó") } ?? 0
    }

    private var missingCalibCount: Int {
        appState.calibNeeds.count { $0.matchedMasterPath == nil }
    }

    /// R10-B3: total session count across every target -- same sum
    /// `AllTargetsPage.sessionCount` computes over `appState.stats`
    /// (duplicated rather than shared, same per-file small-helper
    /// convention `formatDuration`/`formatNumber` already follow across
    /// this app target).
    private var nightsBadgeCount: Int {
        appState.stats.reduce(0) { $0 + $1.sessionDates.count }
    }

    /// R10-A5: `Page.searchResults` reachability -- total hit count for the
    /// "Keresés" row's badge, `0` (no badge, see `navRowLabel`) before a
    /// search's results have actually landed. Same four-bucket sum
    /// `AppState.runSearch`'s own `progressText`/`SearchResultsPage`'s
    /// header line use.
    private var searchResultBadgeCount: Int {
        guard let results = appState.searchResults else { return 0 }
        return results.targets.count + results.sessions.count + results.files.count + results.notes.count
    }

    var body: some View {
        @Bindable var appState = appState

        List(selection: $appState.currentPage) {
            Section {
                navRow("Ma este", systemImage: "moon.stars.fill", page: .tonight, badgeCount: tonightBadgeCount)
                // D25: a normal tag-selectable row again (was a plain
                // `Button` that set `tonightSegment` as a tap side effect
                // and navigated to `.tonight`, which meant this row never
                // highlighted as selected) -- `Page.calendar` is now its own
                // case, so `List(selection:)`'s tag-matching alone gives the
                // correct highlight. R11-T13/F13: indented under "Ma este"
                // (its real parent -- this row IS `TonightPage`'s "Következő
                // 30 éjszaka" segment, just its own `Page` case so the
                // sidebar highlight tracks it precisely) and, unlike before,
                // the highlight now ALSO stays correct switching back the
                // other way: `AppState.tonightSegment` derives itself from
                // `currentPage`, so `TonightPage` always shows the segment
                // matching whichever row is actually highlighted, no matter
                // how `currentPage` got there (see that property's own doc
                // comment for the bug this fixes).
                navRow("Naptár", systemImage: "calendar", page: .calendar, indent: true)
                // R10-B4: the catalog discovery sweep -- a night-planning
                // tool like "Ma este"/"Naptár" above it (suggests targets
                // for TONIGHT), not a library-browsing one, hence living
                // here rather than next to "Éjszakák" under KÖNYVTÁR below.
                navRow("Felfedezés", systemImage: "sparkles", page: .discover)
                // R11-T9/F5: only shown once the last scan actually left
                // something fresh -- `freshSessionKeys` is session-only
                // (never persisted), so this naturally disappears again on
                // relaunch until the next scan finds new light frames.
                if !appState.freshSessionKeys.isEmpty {
                    navRow(
                        "Előző éjszaka", systemImage: "sunrise", page: .previousNight,
                        badgeCount: appState.freshSessionKeys.count
                    )
                }
                // R10-A5: `Page.searchResults` had no sidebar row at all --
                // no highlight while it was on screen, no way back to it
                // once you navigated elsewhere. Only shown once a search has
                // actually run this session (`searchQuery` is set
                // synchronously at the very start of `runSearch`, before its
                // results even come back) -- never shown for a session that
                // never searched at all.
                if !appState.searchQuery.isEmpty {
                    navRow("Keresés", systemImage: "magnifyingglass", page: .searchResults, badgeCount: searchResultBadgeCount)
                }
            }

            Section("KÖNYVTÁR") {
                navRow("Minden célpont", systemImage: "square.grid.2x2", page: .allTargets, badgeCount: appState.stats.count)
                // R10-B3: the cross-target session browser -- badge mirrors
                // `AllTargetsPage`'s own `sessionCount` tile (sum over every
                // target's `sessionDates`, already loaded via `stats`/
                // `loadDashboardData()`) rather than `appState.nights?.count`,
                // so the badge shows a real number immediately without
                // forcing an eager `loadNights()` just to populate it.
                navRow("Éjszakák", systemImage: "moon.zzz", page: .nights, badgeCount: nightsBadgeCount)
                ForEach(targetRows) { row in
                    targetRow(row)
                }
                phaseLegendRow
            }

            Section("ÁLLAPOT") {
                navRow(
                    "Kalibráció", systemImage: "thermometer", page: .calibration,
                    badgeCount: missingCalibCount, badgeRed: missingCalibCount > 0
                )
                navRow(
                    "Audit", systemImage: "checkmark.shield", page: .audit,
                    badgeCount: appState.auditErrorBadgeCount, badgeRed: appState.auditErrorBadgeCount > 0
                )
                // D25: same fix as "Naptár" above -- `Page.cleanup` is its
                // own case now, so this is a normal tag-selectable row
                // (was a plain `Button` that never highlighted as selected)
                // routing the Audit page's "Takarítható" segment. R11-T13/
                // F13: indented under "Audit" (its real parent, same
                // reasoning "Naptár" above documents) -- `AppState
                // .auditSegment` derives itself from `currentPage`, so this
                // row's highlight and `AuditPage`'s own segmented picker can
                // never drift apart. The "Audit" row above still highlights
                // whenever `currentPage == .audit` specifically, unaffected
                // by this.
                navRow("Takarítás", systemImage: "trash", page: .cleanup, badgeText: cleanupBadgeText, indent: true)
                // R11-T10/F7: long-term time series across every target --
                // no `⌘`-shortcut (same stance "Előző éjszaka" above already
                // takes; the existing ⌘1-9 assignment doesn't change) and no
                // badge (there's no single "count" that reads naturally
                // here, unlike Kalibráció/Audit/Takarítás's missing/error/
                // size badges).
                navRow("Trendek", systemImage: "chart.xyaxis.line", page: .trends)
            }

            Section("ESZKÖZÖK") {
                navRow("Szenzor-profilok", systemImage: "gearshape", page: .sensor, badgeCount: appState.sensorProfiles.count)
                navRow("Szűrők", systemImage: "camera.filters", page: .filters, badgeCount: appState.filterProfiles.count)
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Célpont, session, fájl, jegyzet")
        .modifier(SearchFocusModifier(isFocused: $searchFieldFocused))
        // R9-T6/B3: Enter/submit on the sidebar search field runs the real
        // global search (targets/sessions/files/notes) and navigates to
        // `Page.searchResults` -- the live-as-you-type filtering above (via
        // `targetRows`) still narrows the sidebar's own target list, this
        // is purely additive.
        .onSubmit(of: .search) {
            guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            appState.runSearch(query: searchText)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
            searchFieldFocused = true
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    }

    private var cleanupBadgeText: String? {
        guard let summary = appState.cleanupSummary, summary.grandTotalBytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: summary.grandTotalBytes)
    }

    /// R11-T13/F13: `indent` visually nests a row under the sibling ABOVE it
    /// in the same `Section` ("Naptár" under "Ma este", "Takarítás" under
    /// "Audit") -- a plain leading padding on the whole label (icon + text
    /// shift right together), the simplest nesting cue that fits this
    /// sidebar's existing flat `List` (no `OutlineGroup`/disclosure
    /// triangles anywhere else in it worth matching).
    @ViewBuilder
    private func navRow(
        _ title: String, systemImage: String, page: Page,
        badgeCount: Int? = nil, badgeText: String? = nil, badgeRed: Bool = false, indent: Bool = false
    ) -> some View {
        navRowLabel(title, systemImage: systemImage, badgeCount: badgeCount, badgeText: badgeText, badgeRed: badgeRed)
            .padding(.leading, indent ? 20 : 0)
            .tag(page)
    }

    /// Just the label half of `navRow` -- factored out so `navRow` itself
    /// stays a thin `.tag`/`.padding` wrapper around one shared title/icon/
    /// badge layout.
    @ViewBuilder
    private func navRowLabel(
        _ title: String, systemImage: String,
        badgeCount: Int? = nil, badgeText: String? = nil, badgeRed: Bool = false
    ) -> some View {
        let resolvedBadgeText = badgeText ?? badgeCount.flatMap { $0 > 0 ? "\($0)" : nil }
        Label {
            HStack {
                Text(title)
                Spacer()
                if let resolvedBadgeText {
                    badge(resolvedBadgeText, red: badgeRed)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }

    private func targetRow(_ row: TargetRow) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(phaseColor(row.phase))
                .frame(width: 4, height: 4)
            Text(row.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .tag(Page.target(row.target))
        // The row's own dot is color-only -- `phaseLabel`'s fuller
        // "ismeretlen állapot" wording (rather than the compact "-" its
        // other callers use inside a table chip) reads better as a hover
        // tooltip sentence than the table-chip default does.
        .help(phaseLabel(row.phase, unknown: "ismeretlen állapot"))
    }

    /// R10-B7: the sidebar's 4pt phase dots are color-only, their meaning
    /// only discoverable via `targetRow`'s hover tooltip above -- this
    /// always-visible one-line legend at the bottom of KÖNYVTÁR spells out
    /// the same four colors/labels with no interaction of its own (a `?`
    /// button would just be one more thing to click for information this
    /// can show for free).
    private var phaseLegendRow: some View {
        HStack(spacing: 8) {
            legendDot(.blue, "gyűjtés")
            legendDot(.yellow, "stackelhető")
            legendDot(.orange, "feldolgozásra vár")
            legendDot(.green, "kész")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .allowsHitTesting(false)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(label)
        }
    }

    private func badge(_ text: String, red: Bool) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill((red ? Color.red : Color.secondary).opacity(0.15)))
            .foregroundStyle(red ? Color.red : Color.secondary)
    }
}
