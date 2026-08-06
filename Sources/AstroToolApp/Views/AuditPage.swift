import AppKit
import AstroCore
import SwiftUI

/// R9-T2/A.5 -- the Audit page's reframing of "the dreaded number": the old
/// flat `AuditView` bucketed every non-error finding as one scary "Gyanús"
/// count (3 545 on the real library, 88% of it cleanable `.DS_Store`/Siril
/// leftovers). This page instead splits into three `Picker(.segmented)`
/// segments -- `Hibák` (sure errors), `Gyanús` (suspicious MINUS residue
/// MINUS duplicate-content), `Takarítható` (residue + duplicate-content,
/// i.e. exactly what `CleanupSummary`/`AppState.cleanupSummary` already
/// tracks for the quarantine script) -- so residue leaves the "gyanús"
/// bucket and becomes "reclaimable disk space" instead.
struct AuditPage: View {
    @Environment(AppState.self) private var appState

    /// Which `FindingGrouper.Key`s are currently expanded in the Hibák/
    /// Gyanús list -- mirrors the old `AuditView`'s pattern of only building
    /// a group's per-finding detail rows once it's actually opened.
    @State private var expandedKeys: Set<FindingGrouper.Key> = []
    /// The multi-select category filter (A.5: "a szabadszöveges Kategória
    /// szűrő többválasztós Menu lesz"). Empty means "no filter" (show every
    /// category present in the current segment).
    @State private var selectedCategories: Set<String> = []

    // MARK: - Derived finding buckets (A.5's reframing)

    private var errorFindings: [Finding] {
        appState.findings.filter { $0.severity == .sureError }
    }

    /// Suspicious MINUS residue MINUS duplicate-content -- the whole point
    /// of this page. Residue and duplicate-content findings are always
    /// `.suspicious` (never `.sureError`), so this is the only bucket that
    /// needs the exclusion; `errorFindings`/`intentionalFindings` don't.
    private var suspiciousFindings: [Finding] {
        appState.findings.filter {
            $0.severity == .suspicious && $0.category != "residue" && $0.category != "duplicate-content"
        }
    }

    private var intentionalFindings: [Finding] {
        appState.findings.filter { $0.severity == .probablyIntentional }
    }

    private var cleanupFileCount: Int {
        appState.cleanupSummary?.groups.reduce(0) { $0 + $1.fileCount } ?? 0
    }

    private var cleanupBytesText: String {
        Self.formatBytes(appState.cleanupSummary?.grandTotalBytes ?? 0)
    }

    /// `true` once an audit has actually run (`noAuditYetState` handles the
    /// "never ran" case) and every bucket that matters came back empty --
    /// A.5's green "Minden rendben" empty state. `intentionalFindings` is
    /// deliberately excluded: those are expected, not something to clear.
    private var isEverythingClean: Bool {
        errorFindings.isEmpty && suspiciousFindings.isEmpty && cleanupFileCount == 0
    }

    private var currentSegmentFindings: [Finding] {
        switch appState.auditSegment {
        case .errors: return errorFindings
        case .suspicious: return suspiciousFindings
        case .cleanable: return []
        }
    }

    /// Every category actually present in the current segment, with its
    /// finding count -- backs the multi-select category filter `Menu`.
    private var presentCategories: [(category: String, count: Int)] {
        var counts: [String: Int] = [:]
        for finding in currentSegmentFindings {
            counts[finding.category, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { (category: $0.key, count: $0.value) }
    }

    private var categoryFilteredFindings: [Finding] {
        guard !selectedCategories.isEmpty else { return currentSegmentFindings }
        return currentSegmentFindings.filter { selectedCategories.contains($0.category) }
    }

    /// Severity-first, group-size-descending -- same shared grouping the CLI
    /// uses, so the two never drift on what counts as "one root cause".
    private var groups: [FindingGrouper.Group] {
        FindingGrouper.group(categoryFilteredFindings, config: appState.config)
    }

    private func ackKey(_ group: FindingGrouper.Group) -> String {
        Database.ackKey(category: group.key.category, groupKey: group.key.groupKey)
    }

    private func isAcked(_ group: FindingGrouper.Group) -> Bool {
        appState.ackedKeys.contains(ackKey(group))
    }

    /// B5: acked groups are hidden entirely unless the toolbar toggle is on,
    /// in which case every group shows (acked ones dimmed, see `groupRow`).
    private var visibleGroups: [FindingGrouper.Group] {
        appState.showAckedFindings ? groups : groups.filter { !isAcked($0) }
    }

    /// N8 (R9 round 3): writes `currentPage` (`.cleanup`/`.audit`) alongside
    /// `auditSegment` -- without this, flipping the segmented picker by hand
    /// (rather than via the sidebar's "Takarítás" row) left `currentPage`
    /// pointing at whichever page got here first, so the sidebar's selection
    /// highlight drifted from what was actually on screen.
    private var segmentBinding: Binding<AppState.AuditSegment> {
        Binding(
            get: { appState.auditSegment },
            set: { newValue in
                appState.auditSegment = newValue
                appState.currentPage = newValue == .cleanable ? .cleanup : .audit
            }
        )
    }

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 12) {
            // `lastRunID` is only ever set by `runAudit` (same call site that
            // populates both `findings` and `cleanupSummary`), so it's the
            // one reliable "has an audit actually run this session" signal
            // -- checking `findings.isEmpty` alone would be wrong once a
            // real audit comes back all-clear (0 findings is a valid,
            // celebrated result, not "never ran").
            if appState.lastRunID == nil {
                noAuditYetState
            } else if isEverythingClean {
                allClearState
            } else {
                tiles

                Picker("Szegmens", selection: segmentBinding) {
                    Text("Hibák (\(errorFindings.count))").tag(AppState.AuditSegment.errors)
                    Text("Gyanús (\(suspiciousFindings.count))").tag(AppState.AuditSegment.suspicious)
                    Text("Takarítható (\(cleanupFileCount) fájl · \(cleanupBytesText))").tag(AppState.AuditSegment.cleanable)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 620)
                .onChange(of: appState.auditSegment) {
                    // Categories differ per segment -- a leftover selection
                    // from Hibák would silently empty out Gyanús.
                    selectedCategories = []
                }

                if let lastError = appState.lastError {
                    Text(lastError).foregroundStyle(.red)
                }

                switch appState.auditSegment {
                case .errors, .suspicious:
                    findingsSegment
                case .cleanable:
                    cleanableSegment
                }
            }
        }
        .padding()
        .onAppear {
            // R9-D2: `cleanupSummary` used to only ever get filled in as a
            // side effect of `runAudit()` -- a fresh launch (or a direct
            // sidebar jump to Audit, never having visited a page that
            // triggers `loadDashboardData()`) left the Takarítható segment
            // showing "Nincs takarítható tétel." even on a library that
            // genuinely has residue. Loading on-demand here restores it
            // without re-running the audit itself.
            if appState.cleanupSummary == nil {
                appState.loadCleanup()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if appState.isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(appState.progressText).foregroundStyle(.secondary)
                        Button("Mégse") { appState.cancelCurrentOperation() }
                    }
                } else {
                    Menu {
                        Button("Duplikátum-keresés nélkül (gyors)") {
                            appState.runAudit(includeSuspicious: appState.includeSuspiciousInScript, includeDuplicates: false)
                        }
                    } label: {
                        Text("Audit futtatása")
                    } primaryAction: {
                        appState.runAudit(includeSuspicious: appState.includeSuspiciousInScript)
                    }
                    .disabled(appState.db == nil)
                }
            }

            if appState.auditSegment != .cleanable {
                ToolbarItem {
                    Toggle("Rendben-jelöltek megjelenítése", isOn: $appState.showAckedFindings)
                }
            }

            if appState.auditSegment == .cleanable {
                ToolbarItem {
                    Stepper("Limit: \(appState.cleanupLimit)", value: $appState.cleanupLimit, in: 1...200, step: 5)
                }
            }

            ToolbarItem {
                Menu("Script…") {
                    Toggle("Gyanúsak is a javító scriptbe", isOn: $appState.includeSuspiciousInScript)
                    Divider()
                    Button("Javító script (hibák)…") { appState.generateSuggestions() }
                        .disabled(appState.isBusy || errorFindings.isEmpty)
                    Button("Karantén-script (takarítható)…") { appState.generateCleanupScript() }
                        .disabled(appState.isBusy || (appState.cleanupSummary?.groups.isEmpty ?? true))
                }
            }
        }
    }

    // MARK: - Empty states (A.5)

    private var noAuditYetState: some View {
        ContentUnavailableView {
            Label("Nincs audit-eredmény", systemImage: "checkmark.shield")
        } description: {
            Text("Futtass auditot az elrontott mappanevek, félrekerült kalibráció és duplikátumok megtalálásához.")
        } actions: {
            Button("Audit futtatása") {
                appState.runAudit(includeSuspicious: appState.includeSuspiciousInScript)
            }
            .disabled(appState.isBusy || appState.db == nil)
        }
    }

    private var allClearState: some View {
        ContentUnavailableView {
            Label {
                Text("Minden rendben")
            } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
        }
    }

    // MARK: - Header tiles

    private var tiles: some View {
        HStack(spacing: 12) {
            StatTile(title: "Biztos hiba", value: "\(errorFindings.count)", color: .red)
            StatTile(title: "Gyanús", value: "\(suspiciousFindings.count)", color: .yellow)
            StatTile(title: "Takarítható", value: cleanupBytesText, color: .blue)
            StatTile(title: "Szándékos", value: "\(intentionalFindings.count)", color: .gray)
        }
    }

    // MARK: - Hibák / Gyanús segment

    private var findingsSegment: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                categoryFilterMenu
                Spacer()
            }

            if groups.isEmpty {
                Text(currentSegmentFindings.isEmpty ? "Nincs találat ebben a szegmensben." : "Nincs találat a szűrőkre.")
                    .foregroundStyle(.secondary)
            } else if visibleGroups.isEmpty {
                Text("Minden csoport rendben jelölve -- kapcsold be a \"Rendben-jelöltek megjelenítése\" váltót a megtekintésükhöz.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(visibleGroups, id: \.key) { group in
                            groupRow(group)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var categoryFilterMenu: some View {
        Menu {
            Button("Mind") { selectedCategories = [] }
            Divider()
            ForEach(presentCategories, id: \.category) { entry in
                Button {
                    if selectedCategories.contains(entry.category) {
                        selectedCategories.remove(entry.category)
                    } else {
                        selectedCategories.insert(entry.category)
                    }
                } label: {
                    HStack {
                        if selectedCategories.contains(entry.category) {
                            Image(systemName: "checkmark")
                        }
                        Text("\(entry.category) (\(entry.count))")
                    }
                }
            }
        } label: {
            Label(categoryFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
        }
        .frame(width: 240, alignment: .leading)
    }

    private var categoryFilterLabel: String {
        selectedCategories.isEmpty ? "Kategória szűrő" : "Kategória szűrő (\(selectedCategories.count))"
    }

    @ViewBuilder
    private func groupRow(_ group: FindingGrouper.Group) -> some View {
        let acked = isAcked(group)
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedKeys.contains(group.key) },
                set: { isExpanded in
                    if isExpanded {
                        expandedKeys.insert(group.key)
                    } else {
                        expandedKeys.remove(group.key)
                    }
                }
            )
        ) {
            if expandedKeys.contains(group.key) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.findings, id: \.path) { finding in
                        findingRow(finding)
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 12)
            }
        } label: {
            groupHeader(group, acked: acked)
        }
        .opacity(acked ? 0.5 : 1.0)
    }

    private func groupHeader(_ group: FindingGrouper.Group, acked: Bool) -> some View {
        HStack(spacing: 10) {
            severityIcon(group.key.severity)

            Text(group.key.category)
                .frame(minWidth: 160, alignment: .leading)

            Text(group.key.groupKey)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(group.key.groupKey)
                .frame(minWidth: 200, maxWidth: 320, alignment: .leading)

            Text("\(group.count) fájl")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))

            Text(group.firstMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(group.firstMessage)

            if acked {
                Text("rendben jelölve")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            groupMenu(group, acked: acked)
        }
    }

    private func groupMenu(_ group: FindingGrouper.Group, acked: Bool) -> some View {
        Menu {
            if acked {
                Button("Rendben-jelölés visszavonása") {
                    appState.unackFindingGroup(category: group.key.category, groupKey: group.key.groupKey)
                }
            } else {
                Button("Csoport megjelölése rendben lévőként") {
                    appState.ackFindingGroup(category: group.key.category, groupKey: group.key.groupKey)
                }
            }
            Button("Első fájl megnyitása Finderben") {
                if let first = group.findings.first {
                    appState.revealPathInFinder(first.path)
                }
            }
            Button("Összes útvonal másolása") {
                appState.copyPathsToPasteboard(group.findings.map(\.path))
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24)
    }

    private func findingRow(_ finding: Finding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(finding.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(finding.path)
                .frame(minWidth: 200, maxWidth: 360, alignment: .leading)
            Text(finding.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func severityIcon(_ severity: Severity) -> some View {
        switch severity {
        case .sureError:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .suspicious:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .probablyIntentional:
            Image(systemName: "checkmark.circle").foregroundStyle(.gray)
        }
    }

    // MARK: - Takarítható segment

    /// One row of the hierarchical cleanup `Table`: a category roll-up (with
    /// its listed paths, plus a trailing "…további N" row when
    /// `AppState.cleanupLimit` or `CleanupGroup`'s own 50-path cap truncates
    /// the list) as children -- same `Table(rows, children:)` pattern
    /// `AllTargetsPage`/`StackGroupSheet` already use.
    private struct CleanupRow: Identifiable {
        enum Kind {
            case category(CleanupGroup)
            case path(String)
            case more(Int)
        }
        let id: String
        let kind: Kind
        var children: [CleanupRow]?
    }

    private var cleanupRows: [CleanupRow] {
        guard let summary = appState.cleanupSummary else { return [] }
        return summary.groups.map { group in
            let shown = Array(group.paths.prefix(appState.cleanupLimit))
            var children: [CleanupRow] = shown.map { path in
                CleanupRow(id: "p:\(group.category):\(path)", kind: .path(path), children: nil)
            }
            let remaining = group.fileCount - shown.count
            if remaining > 0 {
                children.append(CleanupRow(id: "m:\(group.category)", kind: .more(remaining), children: nil))
            }
            return CleanupRow(id: "c:\(group.category)", kind: .category(group), children: children.isEmpty ? nil : children)
        }
    }

    /// D32: this table's one computed-metric column, explained -- same
    /// "one button per table" `MetricInfoButton` pattern the target-detail
    /// segments already established.
    private static let cleanableMetricInfo: [MetricInfoButton.Metric] = [
        .init(
            title: "Méret",
            explanation: "A kategória alá eső fájlok összesített, karanténba mozgatással felszabadítható helye. Mikor hazudik: a limit (Limit lépegető) csak a MEGJELENÍTETT útvonalak számát korlátozza, a méret mindig a teljes kategóriáé -- ez sosem alábecsült."
        ),
    ]

    private var cleanableSegment: some View {
        VStack(alignment: .leading, spacing: 8) {
            quarantineBanner

            if cleanupRows.isEmpty {
                Text("Nincs takarítható tétel.").foregroundStyle(.secondary)
            } else {
                HStack {
                    Spacer()
                    MetricInfoButton(metrics: Self.cleanableMetricInfo)
                }
                Table(cleanupRows, children: \.children) {
                    TableColumn("Kategória") { row in cleanupCategoryCell(row) }
                        .width(min: 220, ideal: 300)
                    TableColumn("Fájlok") { row in Text(cleanupFilesText(row)) }
                        .width(min: 60, ideal: 80)
                    TableColumn("Méret") { row in Text(cleanupSizeText(row)) }
                        .width(min: 80, ideal: 100)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    /// The Vasszabály, spelled out where a user actually looks before
    /// running the script -- not buried in the README (A.5's explicit ask).
    private var quarantineBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "shield.lefthalf.filled").foregroundStyle(.blue)
            Text("A script `mv`-vel karanténba mozgat, soha nem töröl. A karantént te üríted ki kézzel.")
                .font(.callout)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.1)))
    }

    @ViewBuilder
    private func cleanupCategoryCell(_ row: CleanupRow) -> some View {
        switch row.kind {
        case .category(let group):
            Text(Self.categoryLabel(group.category)).bold()
        case .path(let path):
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        case .more(let count):
            Text("…további \(count)")
                .foregroundStyle(.secondary)
                .italic()
        }
    }

    private func cleanupFilesText(_ row: CleanupRow) -> String {
        guard case .category(let group) = row.kind else { return "" }
        return "\(group.fileCount)"
    }

    private func cleanupSizeText(_ row: CleanupRow) -> String {
        guard case .category(let group) = row.kind else { return "" }
        return Self.formatBytes(group.totalBytes)
    }

    /// Hungarian display label for a `CleanupReport`/audit finding category
    /// -- falls back to the raw category string for anything not covered
    /// (defensive: `CleanupReport.build` is the only producer of the
    /// residue-* variants right now, but a future category shouldn't render
    /// as blank).
    private static func categoryLabel(_ category: String) -> String {
        switch category {
        case "residue-process-dir": return "Feldolgozási maradék mappa"
        case "residue-seq": return "Siril .seq maradék"
        case "residue-lst": return "Siril .lst maradék"
        case "residue-other": return "Egyéb maradék fájl"
        case "duplicate-content": return "Duplikált tartalom"
        default: return category
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// A small headline stat tile -- `title` caption + bold colored `value`,
/// shared by all four of this page's header tiles (A.5's "4 tile" row).
/// Kept local to this file since no other page has adopted the "4 tile"
/// convention yet (R9-T3..T5 will, per the review doc -- if/when they do,
/// this is the natural thing to promote to a shared file).
private struct StatTile: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold()).foregroundStyle(color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
    }
}
