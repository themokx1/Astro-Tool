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
        appState.plan?.count { $0.verdict == "ma jó" } ?? 0
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
                // correct highlight, and `MainShellView.page(for:)` is what
                // preselects the calendar segment on that route.
                navRow("Naptár", systemImage: "calendar", page: .calendar)
                // R10-B4: the catalog discovery sweep -- a night-planning
                // tool like "Ma este"/"Naptár" above it (suggests targets
                // for TONIGHT), not a library-browsing one, hence living
                // here rather than next to "Éjszakák" under KÖNYVTÁR below.
                navRow("Felfedezés", systemImage: "sparkles", page: .discover)
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
                // routing the Audit page's "Takarítható" segment;
                // `MainShellView.page(for:)` preselects it. The "Audit" row
                // above still highlights whenever `currentPage == .audit`
                // specifically, unaffected by this.
                navRow("Takarítás", systemImage: "trash", page: .cleanup, badgeText: cleanupBadgeText)
            }

            Section("ESZKÖZÖK") {
                navRow("Szenzor-profilok", systemImage: "gearshape", page: .sensor, badgeCount: appState.sensorProfiles.count)
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

    @ViewBuilder
    private func navRow(
        _ title: String, systemImage: String, page: Page,
        badgeCount: Int? = nil, badgeText: String? = nil, badgeRed: Bool = false
    ) -> some View {
        navRowLabel(title, systemImage: systemImage, badgeCount: badgeCount, badgeText: badgeText, badgeRed: badgeRed)
            .tag(page)
    }

    /// Just the label half of `navRow` -- factored out so the "Takarítás"
    /// row (a plain `Button`, not a `.tag`-selectable row, since it needs a
    /// tap side effect beyond routing) can reuse the exact same title/icon/
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
        .help(phaseLabel(row.phase))
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

    private func phaseLabel(_ phase: ProjectPhase?) -> String {
        switch phase {
        case .collecting: return "gyűjtés"
        case .readyToStack: return "stackelhető"
        case .stacked: return "feldolgozásra vár"
        case .done: return "kész"
        case nil: return "ismeretlen állapot"
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
