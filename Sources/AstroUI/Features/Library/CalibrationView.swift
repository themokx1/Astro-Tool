import AppKit
import AstroApplication
import AstroCore
import SwiftUI

/// One dark-coverage combo (`CalibNeed`), wrapped only to give the `Table`
/// an `Identifiable` row -- no field is recomputed, `need` is the engine's
/// own value untouched.
private struct CalibrationCoverageRow: Identifiable, Equatable {
    let id: String
    let need: CalibNeed

    init(_ need: CalibNeed) {
        self.need = need
        let tempLabel: String = need.tempC.map { String($0) } ?? "nil"
        self.id = "\(need.kind.rawValue)|\(need.exposureSeconds)|\(tempLabel)"
    }

    /// `KeyPathComparator` needs a non-optional `Comparable` value.
    var tempSortKey: Double { need.tempC ?? -.infinity }
    var masterSortKey: String { need.matchedMasterPath ?? "" }
}

public struct CalibrationView: View {
    /// The two tables this workspace hosts used to be stacked in one
    /// scrolling page. Per the freeze diagnosis (build 20017), a `Table`
    /// nested in a `ScrollView` gets an unbounded proposed height and
    /// cannot virtualize -- and stacking TWO such tables doubled the cost.
    /// This segmented control swaps between them instead, so exactly one
    /// `Table` is materialized at a time and it gets the whole table
    /// region's bounded height.
    private enum Section: String, CaseIterable, Identifiable {
        case coverage = "Session coverage"
        case masters = "Master darks"
        var id: String { rawValue }

        /// W3-9: the segmented picker below used to render `Text(section.rawValue)`
        /// -- a `String`, so it always chose `Text`'s verbatim overload even
        /// though both case labels already had `hu.lproj` entries.
        var displayLabel: LocalizedStringKey { LocalizedStringKey(rawValue) }
    }

    let rootURL: URL?
    let accessMode: LibraryAccessMode
    let chooseLibrary: () -> Void
    let onLibraryFindingsChanged: (() -> Void)?
    @Environment(OperationHost.self) private var operationHost
    @State private var store = CalibrationStore()
    @State private var selectedSection: Section = .coverage
    @State private var selectedCoverageID: String?
    @State private var selectedMasterID: String?
    @State private var showsLinkPreview = false
    /// Section 5.2 (Kalibrációs automata): "Build Master…" preview sheet.
    @State private var showsBuildSheet = false
    /// The exact `CalibNeed` the open build sheet is previewing -- kept here
    /// (not just inside `store.buildPreview`, which only carries the plain
    /// exposure/temp values a `CalibrationMasterBuildPreview` needs to
    /// render) so the sheet's own "Build" button can hand the same `CalibNeed`
    /// back to `store.buildMaster(need:)` without reconstructing one.
    @State private var buildTargetNeed: CalibNeed?
    /// V2 UI/UX audit (2026-08-14) systemic pattern S7: `store.coverage` is
    /// a small, already-in-memory local list (one library's own dark-need
    /// combos), not a store-cached collection in its own right, so the sort
    /// is cached in local `@State` rather than `CalibrationStore` (see
    /// `NightsStore.sortOrder`'s own doc comment for the convention this
    /// follows). Default is highest light-count first -- the combos
    /// needing the most attention.
    @State private var coverageSortOrder: [KeyPathComparator<CalibrationCoverageRow>] = [
        KeyPathComparator(\CalibrationCoverageRow.need.lightCount, order: .reverse)
    ]
    @State private var sortedCoverageRows: [CalibrationCoverageRow] = []

    public init(
        rootURL: URL?,
        accessMode: LibraryAccessMode = .readOnly,
        chooseLibrary: @escaping () -> Void,
        onLibraryFindingsChanged: (() -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.accessMode = accessMode
        self.chooseLibrary = chooseLibrary
        self.onLibraryFindingsChanged = onLibraryFindingsChanged
    }

    public var body: some View {
        WorkspaceTablePage(
            // W6-D fix: this used to name the internal `WriteGuard` codename
            // in user-facing prose -- in BOTH languages, since the old
            // Hungarian entry was itself a direct transliteration
            // ("...kizárólag a WriteGuardon keresztül alkalmazva.") rather
            // than a real translation. Reworded to describe what the guard
            // actually does instead of what it's called internally.
            subtitle: "Master-dark inventory and per-session linking, applied only through protected, verified writes."
        ) {
            toolbarContent
        } table: {
            tableContent
        }
        .task(id: rootURL) {
            if let rootURL { await store.load(rootURL: rootURL, accessMode: accessMode) }
        }
        .onChange(of: coverageSortOrder) { _, _ in recomputeSortedCoverageRows() }
        .task(id: store.coverage) { recomputeSortedCoverageRows() }
        .onAppear {
            store.onLibraryFindingsChanged = onLibraryFindingsChanged
        }
        .navigationTitle("Calibration")
        .astroSectionMarker("v2.detail.library.calibration", label: "Calibration")
        .sheet(isPresented: $showsLinkPreview) {
            linkPreviewSheet
        }
        .sheet(isPresented: $showsBuildSheet) {
            buildMasterSheet
        }
    }

    @ViewBuilder
    private var toolbarContent: some View {
        if rootURL != nil, !store.isLoading {
            HStack(spacing: AstroTokens.Spacing.standard) {
                MetricCard(
                    title: "Coverage gaps", value: "\(store.coverage.filter { $0.matchedMasterPath == nil }.count)",
                    detail: "Combos without a master", systemImage: "exclamationmark.triangle"
                )
                MetricCard(
                    title: "Master darks", value: "\(store.masters.count)",
                    detail: "Inventoried directories", systemImage: "archivebox"
                )
                MetricCard(
                    title: "Access",
                    // W6-D fix: `MetricCard.value` is deliberately plain
                    // `String` (it is almost always a formatted number, see
                    // that struct's own doc comment), which routes `Text`
                    // through its verbatim overload -- a bare ternary of two
                    // literals here silently stayed English forever no
                    // matter what `hu.lproj` said. Same "resolve the phrase
                    // eagerly" shape as `NightRow.TriageState.localizedText`.
                    value: NSLocalizedString(
                        store.accessMode == .mutationEnabled ? "Writable" : "Read only",
                        bundle: .main,
                        comment: ""
                    ),
                    detail: "Images protected", systemImage: "lock.shield"
                )
            }
            Picker("Section", selection: $selectedSection) {
                ForEach(Section.allCases) { section in
                    Text(section.displayLabel).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("v2.calibration.section")
        }
    }

    @ViewBuilder
    private var tableContent: some View {
        if let rootURL {
            if store.isLoading {
                ProgressView("Reading calibration coverage…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch selectedSection {
                case .coverage: coverageTable
                case .masters: mastersTable(rootURL: rootURL)
                }
            }
        } else {
            ContentUnavailableView {
                Label("No library open", systemImage: "externaldrive.badge.questionmark")
            } description: {
                Text(store.errorMessage ?? "Choose an image library to review calibration coverage.")
            } actions: {
                Button("Choose Image Library…", action: chooseLibrary).buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var coverageTable: some View {
        // Task 7 (2026-08-17, GroupBox removal): heading + Divider + Table,
        // `ReviewWorkspace.frameReview`'s own shape -- `WorkspaceTablePage`
        // already gives this whole `table:` slot one solid
        // `AstroTokens.Color.surface` background.
        VStack(alignment: .leading, spacing: 0) {
            Text("Session coverage").font(.headline)
                .padding(.horizontal, AstroTokens.Spacing.standard)
                .padding(.vertical, AstroTokens.Spacing.compact)
            Divider()
            Table(sortedCoverageRows, selection: $selectedCoverageID, sortOrder: $coverageSortOrder) {
                TableColumn("Combo", value: \CalibrationCoverageRow.tempSortKey) { row in
                    Text("\(AstroFormat.coefficient(row.need.exposureSeconds)) s / \(row.need.tempC.map { AstroFormat.coefficient($0) + " °C" } ?? "—")")
                        .font(.callout.monospaced())
                }
                TableColumn("Lights", value: \CalibrationCoverageRow.need.lightCount) { row in Text("\(row.need.lightCount)") }
                    .width(min: 60, ideal: 70)
                TableColumn("Master", value: \CalibrationCoverageRow.masterSortKey) { row in
                    // W6-D fix: `matchedMasterPath ?? "Missing"` is a
                    // `String ?? String literal` -- infers as plain `String`,
                    // so `Text(_:)` picked its verbatim overload and
                    // "Missing" stayed English even with a "Missing" ->
                    // "Hiányzik" entry already sitting unused in hu.lproj.
                    // Branching into two real `Text` values keeps the actual
                    // path verbatim (it's a filesystem path, never
                    // translated) while letting the literal "Missing" reach
                    // `Text`'s `LocalizedStringKey` overload.
                    (row.need.matchedMasterPath.map { Text(verbatim: $0) } ?? Text("Missing"))
                        .foregroundStyle(row.need.matchedMasterPath == nil ? AstroTokens.Color.accent : .primary)
                }
                TableColumn("Sessions") { row in
                    Text(row.need.sessions.map { "\($0.target) · \($0.date)" }.joined(separator: ", "))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu(forSelectionType: String.self) { ids in
                if let row = sortedCoverageRows.first(where: { ids.contains($0.id) }) {
                    coverageActionMenu(row)
                }
            }
            .accessibilityIdentifier("v2.calibration.coverage-table")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func recomputeSortedCoverageRows() {
        var rows = store.coverage.map(CalibrationCoverageRow.init)
        if !coverageSortOrder.isEmpty { rows.sort(using: coverageSortOrder) }
        sortedCoverageRows = rows
    }

    private func mastersTable(rootURL: URL) -> some View {
        // Task 7 (2026-08-17, GroupBox removal): same fix as `coverageTable`
        // above -- see its own comment.
        VStack(alignment: .leading, spacing: 0) {
            Text("Master darks").font(.headline)
                .padding(.horizontal, AstroTokens.Spacing.standard)
                .padding(.vertical, AstroTokens.Spacing.compact)
            Divider()
            Table(
                store.masters, selection: $selectedMasterID,
                sortOrder: Binding(get: { store.mastersSortOrder }, set: { store.setMastersSortOrder($0) })
            ) {
                TableColumn("Path", value: \CalibrationMasterInfo.path) { master in
                    Text(master.path).font(.callout.monospaced()).lineLimit(1)
                }
                TableColumn("Temp °C", value: \CalibrationMasterInfo.temperatureSortKey) { master in
                    Text(master.temperatureCelsius.map { AstroFormat.coefficient($0) } ?? "—")
                }
                .width(min: 70, ideal: 90)
                TableColumn("Age (days)", value: \CalibrationMasterInfo.ageDaysSortKey) { master in
                    Text(master.ageDays.map(String.init) ?? "—")
                }
                .width(min: 90, ideal: 110)
                TableColumn("Status", value: \CalibrationMasterInfo.statusSortKey) { master in masterStatus(master) }
                    .width(min: 140, ideal: 180)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu(forSelectionType: CalibrationMasterInfo.ID.self) { ids in
                if let master = store.masters.first(where: { ids.contains($0.id) }) {
                    masterActionMenu(master, rootURL: rootURL)
                }
            }
            .accessibilityIdentifier("v2.calibration.masters-table")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func coverageActionMenu(_ row: CalibrationCoverageRow) -> some View {
        Button("Preview Link…") { preparePreview(for: row) }
            .disabled(row.need.sessions.isEmpty)
            .help("Preview which sessions would link to a matching master dark")
        // Section 5.2 (Kalibrációs automata): only dark rows carry a
        // (exposure, temp) combo `CalibrationMasterBuildCommand.preview`
        // can act on -- `row.need.kind` is always `.dark` in THIS table
        // today (`CalibrationQuery.coverage()`'s own v1 dark-only scope), so
        // this never actually filters anything out yet, but stays explicit
        // rather than assuming a future flat/bias row silently gets a
        // "Build Master…" action that was only ever validated for darks.
        if row.need.kind == .dark {
            Button("Build Master…") { prepareBuildPreview(for: row) }
                .help("Build a master dark from already-scanned session dark subs, via Siril")
        }
    }

    @ViewBuilder
    private func masterActionMenu(_ master: CalibrationMasterInfo, rootURL: URL) -> some View {
        Button("Show in Finder") { revealMaster(master, rootURL: rootURL) }
            .disabled(masterURL(for: master, rootURL: rootURL) == nil)
    }

    private func masterStatus(_ master: CalibrationMasterInfo) -> some View {
        HStack(spacing: AstroTokens.Spacing.compact) {
            if master.isStale {
                Label("Stale", systemImage: "clock.badge.exclamationmark").foregroundStyle(AstroTokens.Color.attention)
            }
            if master.isUnused {
                Label("Unused", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            }
            if !master.isStale, !master.isUnused {
                Label("OK", systemImage: "checkmark.circle").foregroundStyle(AstroTokens.Color.ok)
            }
        }
        .font(.caption)
    }

    private func preparePreview(for row: CalibrationCoverageRow) {
        guard let session = row.need.sessions.first else { return }
        Task {
            await store.preparePlan(target: session.target, date: session.date)
            showsLinkPreview = true
        }
    }

    // MARK: - Section 5.2 (Kalibrációs automata): master-build sheet

    private func prepareBuildPreview(for row: CalibrationCoverageRow) {
        buildTargetNeed = row.need
        Task {
            await store.prepareBuildPreview(need: row.need)
            showsBuildSheet = true
        }
    }

    @ViewBuilder
    private var buildMasterSheet: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            HStack {
                Text("Build Master").font(.title3.bold())
                Spacer()
                Button("Close") {
                    showsBuildSheet = false
                    store.clearBuildPreview()
                    buildTargetNeed = nil
                }.keyboardShortcut(.cancelAction)
            }
            if store.isPreviewingBuild {
                ProgressView("Building plan…")
            } else if let preview = store.buildPreview {
                Text("\(AstroFormat.coefficient(preview.exposureSeconds)) s / \(preview.tempC.map { AstroFormat.coefficient($0) + " °C" } ?? "—")")
                    .font(.headline)
                Text("\(preview.sourceFrameCount) source dark(s) found, \(preview.minimumFrameCount) needed")
                    .foregroundStyle(preview.sourceFrameCount >= preview.minimumFrameCount ? AstroTokens.Color.ok : AstroTokens.Color.attention)

                if !preview.mismatchReasons.isEmpty {
                    Text(preview.mismatchReasons.joined(separator: "; "))
                        .font(.caption).foregroundStyle(AstroTokens.Color.attention)
                }
                if !preview.sirilAvailable {
                    Label("Siril was not found -- build this master manually.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(AstroTokens.Color.attention)
                }

                Toggle(
                    "Enable automatic master build",
                    isOn: Binding(
                        get: { preview.autoBuildEnabled },
                        set: { newValue in Task { await store.setAutoMasterBuildEnabled(newValue) } }
                    )
                )
                .help("Lets Build Master actually run Siril. Off by default until explicitly enabled here.")

                if store.accessMode != .mutationEnabled {
                    Label("Requires write access. Enable write operations in Settings to build this master.", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let buildErrorMessage = store.buildErrorMessage {
                    Text(buildErrorMessage).foregroundStyle(AstroTokens.Color.attention)
                }
                if let receipt = store.lastBuildReceipt {
                    Label("Built \(receipt.masterPath) from \(receipt.sourceFrameCount) frame(s)", systemImage: "checkmark.seal")
                        .foregroundStyle(AstroTokens.Color.ok)
                }

                HStack {
                    Spacer()
                    Button("Build") {
                        guard let buildTargetNeed else { return }
                        Task { await store.buildMaster(need: buildTargetNeed, operationHost: operationHost) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.accessMode != .mutationEnabled || !preview.canBuild || store.isBuilding || buildTargetNeed == nil)
                    .help("Stack the source dark frames into a new master via Siril")
                }
            } else if let buildErrorMessage = store.buildErrorMessage {
                Text(buildErrorMessage).foregroundStyle(AstroTokens.Color.attention)
            }
        }
        .padding(AstroTokens.Spacing.section)
        .frame(minWidth: 480, minHeight: 360)
        .accessibilityIdentifier("v2.calibration.build-preview")
    }

    @ViewBuilder
    private var linkPreviewSheet: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            HStack {
                Text("Link Preview").font(.title3.bold())
                Spacer()
                Button("Close") {
                    showsLinkPreview = false
                    store.clearPlan()
                }.keyboardShortcut(.cancelAction)
            }
            if store.isPlanning {
                ProgressView("Building plan…")
            } else if let plan = store.linkPlan {
                Text("\(plan.target) · \(plan.date)").font(.headline)
                if plan.items.isEmpty {
                    Text(plan.mismatchReasons.isEmpty
                        ? "Nothing to link -- this session already has what it needs."
                        : plan.mismatchReasons.joined(separator: "; "))
                        .foregroundStyle(.secondary)
                } else {
                    List(plan.items, id: \.destDir) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.sourcePath).font(.callout.monospaced())
                            Text("→ \(item.destDir) · \(item.reason)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 160)
                }
                if let receipt = store.lastReceipt {
                    Label("Linked \(receipt.linked.count) file(s), skipped \(receipt.skipped.count)", systemImage: "checkmark.seal")
                        .foregroundStyle(AstroTokens.Color.ok)
                }
                if let planErrorMessage = store.planErrorMessage {
                    Text(planErrorMessage).foregroundStyle(AstroTokens.Color.attention)
                }
                if store.accessMode != .mutationEnabled {
                    Label("Requires write access. Enable write operations in Settings to apply this link.", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Apply Link") { Task { await store.applyPlan() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.accessMode != .mutationEnabled || plan.items.isEmpty)
                        .help("Link the matched master calibration files into this session")
                }
            } else if let planErrorMessage = store.planErrorMessage {
                Text(planErrorMessage).foregroundStyle(AstroTokens.Color.attention)
            }
        }
        .padding(AstroTokens.Spacing.section)
        .frame(minWidth: 480, minHeight: 360)
        .accessibilityIdentifier("v2.calibration.link-preview")
    }

    private func masterURL(for master: CalibrationMasterInfo, rootURL: URL) -> URL? {
        let canonicalRoot = rootURL.standardizedFileURL
        let candidate = canonicalRoot.appendingPathComponent(master.path).standardizedFileURL
        let allowedPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard candidate.path.hasPrefix(allowedPrefix),
              FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private func revealMaster(_ master: CalibrationMasterInfo, rootURL: URL) {
        guard let url = masterURL(for: master, rootURL: rootURL) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
