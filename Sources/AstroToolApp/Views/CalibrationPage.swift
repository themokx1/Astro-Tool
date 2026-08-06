import AstroCore
import SwiftUI

/// R9-T5/A.4 -- rebuild of the old `CalibrationView`: `Lefedettség`/
/// `Egészség` `Picker(.segmented)`, 4 header tiles, Teendők promoted to
/// action cards ABOVE the coverage table (each with a "Linkelés…" button
/// where a session is resolvable), the table itself gaining the three
/// `CalibNeed` fields that existed but were never rendered (`Típus`/`Gain`/
/// `Kamera`), and a single `Újraszámolás` replacing the old three identical
/// "Frissítés" buttons. "Szenzor-profilok" moved off this page entirely in
/// R9-T1 (`SensorPage`).
struct CalibrationPage: View {
    enum Segment: String, CaseIterable, Hashable {
        case coverage = "Lefedettség"
        case health = "Egészség"
    }

    @Environment(AppState.self) private var appState
    @State private var segment: Segment = .coverage
    @State private var selectedNeedID: CoverageRow.ID?

    private var needs: [CalibNeed] { appState.calibNeeds }
    private var todos: [CalibNeed] { needs.filter { $0.todo != nil } }

    private var missingCount: Int { needs.filter { $0.matchedMasterPath == nil }.count }
    private var staleCount: Int { needs.filter { $0.isStale }.count }
    private var freshCount: Int { needs.filter { $0.matchedMasterPath != nil && !$0.isStale }.count }
    private var masterDarkCountText: String {
        appState.calibHealth.map { "\($0.darkMasters.count)" } ?? "-"
    }

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 16) {
            tiles

            Picker("Szegmens", selection: $segment) {
                ForEach(Segment.allCases, id: \.self) { seg in
                    Text(seg.rawValue).tag(seg)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }

            switch segment {
            case .coverage: coverageSegment
            case .health: healthSegment
            }
        }
        .padding()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if appState.isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(appState.progressText).foregroundStyle(.secondary)
                        Button("Mégse") { appState.cancelCurrentOperation() }
                    }
                } else {
                    Button("Újraszámolás") {
                        appState.loadCalib()
                        appState.loadCalibHealth()
                    }
                    .disabled(appState.db == nil)
                }
            }
        }
        .onAppear {
            if appState.calibNeeds.isEmpty { appState.loadCalib() }
            if appState.calibHealth == nil { appState.loadCalibHealth() }
        }
        .sheet(item: $appState.calibNeedLinkSession) { session in
            CalibLinkSheet(target: session.target, date: session.date)
        }
    }

    // MARK: - Header tiles

    private var tiles: some View {
        HStack(spacing: 12) {
            CalibStatTile(title: "Hiányzó", value: "\(missingCount)", color: .red)
            CalibStatTile(title: "Elavult", value: "\(staleCount)", color: .orange)
            CalibStatTile(title: "Friss", value: "\(freshCount)", color: .green)
            CalibStatTile(title: "Master darkok", value: masterDarkCountText, color: .gray)
        }
    }

    // MARK: - Lefedettség

    private var coverageSegment: some View {
        VStack(alignment: .leading, spacing: 16) {
            if needs.isEmpty {
                ContentUnavailableView {
                    Label("Nincs kalibrációs adat", systemImage: "thermometer")
                } description: {
                    Text("Futtass beolvasást és Újraszámolást a kalibráció-lefedettség számításához.")
                }
            } else {
                if !todos.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Teendők").font(.headline)
                        ForEach(Array(todos.enumerated()), id: \.offset) { _, need in
                            actionCard(need)
                        }
                    }
                }

                HStack {
                    Text("Lefedettség").font(.headline)
                    Spacer()
                    MetricInfoButton(metrics: Self.coverageMetricInfo)
                }
                coverageTable
            }
        }
    }

    /// D32: this table's computed-metric columns, explained -- same
    /// "one button per table" `MetricInfoButton` pattern the target-detail
    /// segments already established.
    private static let coverageMetricInfo: [MetricInfoButton.Metric] = [
        .init(
            title: "Kor (nap)",
            explanation: "A hozzárendelt master-kalibrációs fájl kora napokban, a light-keretek dátumához mérve. Mikor hazudik: hiányzó masternél „-”, és a kor önmagában nem jelent elavultságot -- azt a küszöb (napok) dönti el, ami a „Állapot” oszlopba fut bele."
        ),
        .init(
            title: "Állapot",
            explanation: "„friss” = van illő master és nem elavult; „⚠️ elavult” = a kora meghaladja a beállított küszöböt; „hiányzik” = nincs illő master-kalibráció. Mikor hazudik: a küszöb (Beállítások ▸ Kalibráció) évszaktól/szenzor öregedésétől függetlenül fix napszám -- egy technikailag még jó master is elavultnak jelölhető, ha a küszöb szigorúbb, mint amire tényleg szükség van."
        ),
    ]

    private func actionCard(_ need: CalibNeed) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(need.todo ?? "").font(.callout)
                if !need.targets.isEmpty {
                    Text(need.targets.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !need.targets.isEmpty {
                Button("Linkelés…") { appState.openCalibLinkSheet(forNeed: need) }
                    .buttonStyle(.link)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    }

    private var coverageRows: [CoverageRow] { needs.map(CoverageRow.init) }

    private var coverageTable: some View {
        Table(coverageRows, selection: $selectedNeedID) {
            TableColumn("Típus") { row in Text(row.need.kind.rawValue) }
                .width(60)
            TableColumn("Exp. (s)") { row in Text(formattedExposure(row.need.exposureSeconds)) }
                .width(60)
            TableColumn("Hőm. (°C)") { row in Text(row.need.tempC.map { String(format: "%.1f", $0) } ?? "-") }
                .width(70)
            TableColumn("Gain") { row in Text(row.need.requiredGain.map { String(format: "%g", $0) } ?? "-") }
                .width(60)
            TableColumn("Kamera") { row in
                Text(row.need.requiredCamera ?? "-")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 100, ideal: 140)
            TableColumn("Light-ok") { row in Text("\(row.need.lightCount)") }
                .width(60)
            TableColumn("Master") { row in
                Text(row.need.matchedMasterPath ?? "hiányzik")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.need.matchedMasterPath ?? "hiányzik")
            }
            .width(min: 160, ideal: 240)
            TableColumn("Kor (nap)") { row in Text(row.need.masterAgeDays.map(String.init) ?? "-") }
                .width(70)
            TableColumn("Állapot") { row in statusView(row.need) }
                .width(80)
            TableColumn("Megjegyzés") { row in
                if !row.need.mismatchReasons.isEmpty {
                    Text(row.need.mismatchReasons.joined(separator: ", "))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.need.mismatchReasons.joined(separator: ", "))
                }
            }
            .width(min: 140, ideal: 200)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: CoverageRow.ID.self) { ids in
            if let id = ids.first, let row = coverageRows.first(where: { $0.id == id }) {
                coverageContextMenuItems(row.need)
            }
        }
    }

    @ViewBuilder
    private func coverageContextMenuItems(_ need: CalibNeed) -> some View {
        Button("Kalibráció linkelése…") { appState.openCalibLinkSheet(forNeed: need) }
            .disabled(need.targets.isEmpty)
        Button("Master mappa megnyitása Finderben") {
            if let path = need.matchedMasterPath { appState.revealPathInFinder(path) }
        }
        .disabled(need.matchedMasterPath == nil)
        Button("Érintett sessionök megjelenítése") {
            if let target = need.targets.first { appState.currentPage = .target(target) }
        }
        .disabled(need.targets.isEmpty)
    }

    @ViewBuilder
    private func statusView(_ need: CalibNeed) -> some View {
        if need.isStale {
            Text("⚠️ elavult").foregroundStyle(.orange)
        } else if need.matchedMasterPath != nil {
            Text("friss").foregroundStyle(.green)
        } else {
            Text("hiányzik").foregroundStyle(.red)
        }
    }

    private func formattedExposure(_ value: Double) -> String {
        String(format: "%g", value)
    }

    // MARK: - Egészség

    private var healthSegment: some View {
        Group {
            if let health = appState.calibHealth {
                CalibHealthSections(health: health)
            } else {
                Text("Még nincs betöltve.").foregroundStyle(.secondary)
            }
        }
    }
}

/// One coverage-table row -- view-layer wrapper giving each `CalibNeed` a
/// stable `Identifiable` id for `Table`'s selection/context-menu machinery
/// (the model type itself has no natural primary key). R9-D7: `id` used to
/// be a fresh `UUID()` minted every time `coverageRows` recomputed (it's a
/// plain `map` over `appState.calibNeeds`, re-evaluated on every render) --
/// a `Table`'s selection/context-menu tracks rows by `id`, so a row's
/// identity silently changed out from under any active selection or open
/// context menu. Deriving `id` from the need's own fields instead makes it
/// stable across re-renders of the SAME underlying combo.
struct CoverageRow: Identifiable {
    var id: String {
        let temp = need.tempC.map { "\($0)" } ?? "-"
        let gain = need.requiredGain.map { "\($0)" } ?? "-"
        let camera = need.requiredCamera ?? "-"
        return "\(need.kind.rawValue)|\(need.exposureSeconds)|\(temp)|\(gain)|\(camera)"
    }
    let need: CalibNeed
}

/// Small colored stat tile, same look as `AuditPage`'s private `StatTile` --
/// kept as its own (differently-named) private type per that file's own
/// convention of each page owning its tile view rather than sharing one
/// globally.
private struct CalibStatTile: View {
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

/// The "Kalibráció-egészség" section's three collapsible blocks (flat
/// discipline, bias inventory, dark master health). R9-T5/A.4 adds a
/// status breakdown to each header ("Flat-fegyelem — 2 hibás / 34 rendben")
/// and a "Megnyitás Finderben" context menu on every PROBLEM row (a
/// `BiasGroup`/its `missingBiasCombos` strings carry no single meaningful
/// path each, so those two rows stay without one).
private struct CalibHealthSections: View {
    @Environment(AppState.self) private var appState
    let health: CalibHealthReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(flatHeader) {
                if health.flats.isEmpty {
                    Text("Nincs session usable lighttal.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(sortedFlats().enumerated()), id: \.offset) { _, flat in
                            flatRow(flat)
                        }
                    }
                }
            }

            DisclosureGroup(biasHeader) {
                VStack(alignment: .leading, spacing: 6) {
                    if health.biasGroups.isEmpty {
                        Text("Nincs bias frame.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(health.biasGroups.enumerated()), id: \.offset) { _, group in
                        HStack(alignment: .top, spacing: 6) {
                            statusDot(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(biasLabel(group))
                                Text("\(group.frameCount) frame — \(group.locations.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !health.missingBiasCombos.isEmpty {
                        Divider()
                        ForEach(health.missingBiasCombos, id: \.self) { combo in
                            HStack(alignment: .top, spacing: 6) {
                                statusDot(.red)
                                Text(combo)
                            }
                        }
                    }
                }
            }

            DisclosureGroup(darkHeader) {
                VStack(alignment: .leading, spacing: 6) {
                    if health.darkMasters.isEmpty {
                        Text("Nincs master dark.").foregroundStyle(.secondary)
                    }
                    ForEach(sortedDarkMasters(), id: \.path) { master in
                        darkRow(master)
                    }
                }
            }
        }
    }

    // MARK: Headers

    private var flatHeader: String {
        let problem = health.flats.filter { $0.status != "rendben" }.count
        let ok = health.flats.count - problem
        return "Flat-fegyelem — \(problem) hibás / \(ok) rendben"
    }

    private var biasHeader: String {
        "Bias-készlet — \(health.missingBiasCombos.count) hiányzó / \(health.biasGroups.count) csoport rendben"
    }

    private var darkHeader: String {
        let problem = health.darkMasters.filter { $0.isStale || $0.isUnused || !$0.warnings.isEmpty }.count
        let ok = health.darkMasters.count - problem
        return "Dark-készlet egészség — \(problem) hibás / \(ok) rendben"
    }

    // MARK: Rows

    @ViewBuilder
    private func flatRow(_ flat: FlatDiscipline) -> some View {
        let row = HStack(alignment: .top, spacing: 6) {
            statusDot(flatColor(flat.status))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(flat.target) / \(flat.date) — \(flat.status)")
                if !flat.reasons.isEmpty {
                    Text(flat.reasons.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())

        // Only PROBLEM rows get a context menu (spec: "minden problémás
        // sorra Megnyitás Finderben") -- an empty `.contextMenu` would still
        // pop up a blank menu on right-click for a healthy "rendben" row.
        if flat.status != "rendben" {
            row.contextMenu {
                Button("Megnyitás Finderben") {
                    appState.revealPathInFinder("sessions/\(flat.target)/\(flat.date)")
                }
            }
        } else {
            row
        }
    }

    @ViewBuilder
    private func darkRow(_ master: DarkMasterHealth) -> some View {
        let row = HStack(alignment: .top, spacing: 6) {
            statusDot(darkColor(master))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(master.path) — \(master.frameCount) frame, \(master.ageDays.map(String.init) ?? "-") napos")
                if !master.warnings.isEmpty {
                    Text(master.warnings.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())

        let isProblem = master.isStale || master.isUnused || !master.warnings.isEmpty
        if isProblem {
            row.contextMenu {
                Button("Megnyitás Finderben") { appState.revealPathInFinder(master.path) }
            }
        } else {
            row
        }
    }

    private func sortedFlats() -> [FlatDiscipline] {
        health.flats.sorted { lhs, rhs in
            if lhs.status != rhs.status {
                // Problems ("nincs flat"/"flat nem illik") first, "rendben" last.
                return (lhs.status == "rendben" ? 1 : 0) < (rhs.status == "rendben" ? 1 : 0)
            }
            if lhs.target != rhs.target { return lhs.target < rhs.target }
            return lhs.date < rhs.date
        }
    }

    private func sortedDarkMasters() -> [DarkMasterHealth] {
        health.darkMasters.sorted { lhs, rhs in
            let lhsProblem = lhs.isStale || lhs.isUnused || !lhs.warnings.isEmpty
            let rhsProblem = rhs.isStale || rhs.isUnused || !rhs.warnings.isEmpty
            if lhsProblem != rhsProblem { return lhsProblem && !rhsProblem }
            return lhs.path < rhs.path
        }
    }

    private func flatColor(_ status: String) -> Color {
        switch status {
        case "rendben": return .green
        case "nincs flat": return .red
        default: return .orange
        }
    }

    private func darkColor(_ master: DarkMasterHealth) -> Color {
        if master.isUnused || !master.warnings.isEmpty { return .orange }
        if master.isStale { return .orange }
        return .green
    }

    private func biasLabel(_ group: BiasGroup) -> String {
        var parts: [String] = []
        if let gain = group.gain { parts.append("gain\(String(format: "%g", gain))") }
        if let offset = group.offset { parts.append("offset\(String(format: "%g", offset))") }
        if let camera = group.camera { parts.append(camera) }
        return parts.isEmpty ? "(ismeretlen kombó)" : parts.joined(separator: "/")
    }

    private func statusDot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 8, height: 8).padding(.top, 5)
    }
}
