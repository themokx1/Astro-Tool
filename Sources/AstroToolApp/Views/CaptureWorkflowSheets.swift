import AstroCore
import SwiftUI

// MARK: - Shared capture visual language

enum CaptureVisuals {
    static func color(sensor: SensorMode?, signal: SignalMode?) -> Color {
        switch signal {
        case .dualBand, .narrowband: return .purple
        case .broadband, .unfiltered: return .cyan
        case .lrgb, .luminance: return .blue
        case .other: return .orange
        case .unknown, .none:
            return sensor == .osc ? .cyan : .secondary
        }
    }

    static func filterLabel(_ metadata: ResolvedCaptureMetadata?) -> String? {
        metadata?.filterLabel
    }
}

struct CaptureBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
}

// MARK: - Capture group creation

struct CaptureGroupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: String
    let date: String

    @State private var displayName = ""
    @State private var slug = ""
    @State private var sensorMode: SensorMode = .osc
    @State private var signalMode: SignalMode = .broadband
    @State private var filterSelection = FilterProfileSelection()
    @State private var notes = ""
    @State private var editingGroupID: Int64?
    @State private var savedSnapshot: [CaptureGroupRecord]?
    @State private var pendingDeleteID: Int64?

    private var draft: CaptureGroupDraft {
        CaptureGroupDraft(
            slug: slug,
            displayName: displayName,
            sensorMode: sensorMode,
            signalMode: signalMode,
            filterManufacturer: filterSelection.manufacturer,
            filterModel: filterSelection.model,
            filterName: filterSelection.name,
            notes: notes
        )
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !slug.isEmpty
            && CaptureGroupDraft.suggestedSlug(for: slug) == slug
            && !appState.isBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(editingGroupID == nil ? "Új gyűjtés" : "Gyűjtés szerkesztése")
                    .font(.title2.weight(.semibold))
                Text("\(target) · \(date)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                presetButton("OSC · szűrő nélkül", sensor: .osc, signal: .unfiltered)
                presetButton("OSC · dual-band", sensor: .osc, signal: .dualBand)
                presetButton("Monó · keskenysáv", sensor: .mono, signal: .narrowband)
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Beszédes név, pl. dual-band · 300 s", text: $displayName)
                    TextField("Mappanév (slug)", text: $slug)
                        .font(.body.monospaced())
                        .disabled(editingGroupID != nil)

                    Picker("Szenzor", selection: $sensorMode) {
                        ForEach(SensorMode.allCases, id: \.self) { mode in
                            Text(mode.displayNameHU).tag(mode)
                        }
                    }
                    Picker("Fénysáv", selection: $signalMode) {
                        ForEach(SignalMode.allCases, id: \.self) { mode in
                            Text(mode.displayNameHU).tag(mode)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    FilterProfilePicker(selection: groupFilterBinding)
                    TextField("Megjegyzés", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }

            if !appState.editableCaptureGroups.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ebben a sessionben már létezik").font(.caption.weight(.semibold))
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(appState.editableCaptureGroups, id: \.slug) { group in
                            HStack {
                                CaptureBadge(
                                    text: "\(group.displayName) · \(group.quickLabel)",
                                    color: CaptureVisuals.color(sensor: group.sensorMode, signal: group.signalMode)
                                )
                                Spacer()
                                Button("Szerkesztés") { beginEditing(group) }
                                    .buttonStyle(.borderless)
                                Button(role: .destructive) {
                                    pendingDeleteID = group.id
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Csak a gyűjtés metadata és hozzárendelései törlődnek; fájl nem")
                            }
                        }
                    }
                }
            }

            if let error = appState.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
            }

            HStack {
                Text("Létrejön: captures/\(slug.isEmpty ? "…" : slug)/{lights, flats, darks, biases}")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Mégse") { dismiss() }
                if editingGroupID != nil {
                    Button("Új gyűjtés") { resetEditor() }
                }
                Button(editingGroupID == nil ? "Gyűjtés létrehozása" : "Módosítások mentése") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(minWidth: 720)
        .onAppear { appState.loadEditableCaptureGroups(target: target, date: date) }
        .onChange(of: displayName) { oldName, name in
            let oldSuggestion = CaptureGroupDraft.suggestedSlug(for: oldName)
            if slug.isEmpty || slug == oldSuggestion {
                slug = CaptureGroupDraft.suggestedSlug(for: name)
            }
        }
        .onChange(of: appState.editableCaptureGroups) { _, groups in
            if let snapshot = savedSnapshot, snapshot != groups { dismiss() }
        }
        .confirmationDialog(
            "Törlöd a gyűjtés besorolási adatait?",
            isPresented: Binding(
                get: { pendingDeleteID != nil },
                set: { if !$0 { pendingDeleteID = nil } }
            )
        ) {
            Button("Metadata és hozzárendelések törlése", role: .destructive) {
                guard let id = pendingDeleteID,
                      let group = appState.editableCaptureGroups.first(where: { $0.id == id })
                else { return }
                pendingDeleteID = nil
                appState.deleteCaptureGroup(group)
                if editingGroupID == id { resetEditor() }
            }
            Button("Mégse", role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text("A nyers képek, stackek, feldolgozott fájlok és mappák nem törlődnek.")
        }
    }

    private func presetButton(
        _ title: String,
        sensor: SensorMode,
        signal: SignalMode,
        manufacturer: String = "",
        model: String = ""
    ) -> some View {
        Button(title) {
            sensorMode = sensor
            signalMode = signal
            filterSelection = FilterProfileSelection(
                manufacturer: optionalText(manufacturer),
                model: optionalText(model),
                signalMode: signal
            )
            if displayName.isEmpty { displayName = title }
        }
        .buttonStyle(.bordered)
        .tint(CaptureVisuals.color(sensor: sensor, signal: signal))
    }

    private func beginEditing(_ group: CaptureGroupRecord) {
        editingGroupID = group.id
        displayName = group.displayName
        slug = group.slug
        sensorMode = group.sensorMode
        signalMode = group.signalMode
        filterSelection = FilterProfileSelection(
            manufacturer: group.filterManufacturer,
            model: group.filterModel,
            name: group.filterName,
            signalMode: group.signalMode
        )
        notes = group.notes ?? ""
    }

    private func resetEditor() {
        editingGroupID = nil
        displayName = ""
        slug = ""
        sensorMode = .osc
        signalMode = .broadband
        filterSelection = FilterProfileSelection()
        notes = ""
    }

    private func save() {
        savedSnapshot = appState.editableCaptureGroups
        if let editingGroupID,
           var group = appState.editableCaptureGroups.first(where: { $0.id == editingGroupID }) {
            group.displayName = displayName
            group.sensorMode = sensorMode
            group.signalMode = signalMode
            group.filterManufacturer = filterSelection.manufacturer
            group.filterModel = filterSelection.model
            group.filterName = filterSelection.name
            group.notes = optionalText(notes)
            appState.updateCaptureGroup(group)
        } else {
            appState.createCaptureGroup(target: target, date: date, draft: draft)
        }
    }

    private func optionalText(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var groupFilterBinding: Binding<FilterProfileSelection> {
        Binding(
            get: { filterSelection },
            set: { selection in
                filterSelection = selection
                if selection.signalMode != .unknown { signalMode = selection.signalMode }
            }
        )
    }
}

// MARK: - Per-file and bulk assignment

struct CaptureAssignmentSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: String
    let date: String
    let frames: [FrameScore]
    let anchorPath: String
    let selectedPaths: [String]

    @State private var scope: CaptureAssignmentScope = .selectedFiles
    @State private var groupID: Int64?
    @State private var useExactOverride = false
    @State private var sensorOverride: SensorMode = .osc
    @State private var signalOverride: SignalMode = .dualBand
    @State private var filterSelection = FilterProfileSelection(signalMode: .dualBand)

    private var candidates: [CaptureAssignmentCandidate] {
        frames.compactMap { frame in
            guard sessionDate(frame.path) == date else { return nil }
            return CaptureAssignmentCandidate(path: frame.path, exposureSeconds: frame.exptime)
        }
    }

    private var anchor: CaptureAssignmentCandidate {
        candidates.first(where: { $0.path == anchorPath })
            ?? CaptureAssignmentCandidate(path: anchorPath, exposureSeconds: nil)
    }

    private var affectedPaths: [String] {
        CaptureBulkSelector.paths(
            scope: scope,
            anchor: anchor,
            selectedPaths: selectedPaths,
            candidates: candidates
        )
    }

    private var selectedGroup: CaptureGroupRecord? {
        appState.editableCaptureGroups.first { $0.id == groupID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Capture-besorolás").font(.title2.weight(.semibold))
                Text("\(target) · \(date) · csak ez a session")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 18) {
                GroupBox("1 · Hatókör") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $scope) {
                            ForEach(CaptureAssignmentScope.allCases, id: \.self) { item in
                                Text(item.displayNameHU).tag(item)
                            }
                        }
                        .labelsHidden()
                        Text("\(affectedPaths.count) fájl érintett")
                            .font(.headline.monospacedDigit())
                        Text(scopeExplanation)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("2 · Célgyűjtés") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Gyűjtés", selection: $groupID) {
                            Text("Válassz…").tag(Int64?.none)
                            ForEach(appState.editableCaptureGroups, id: \.slug) { group in
                                Text(group.displayName).tag(group.id)
                            }
                        }
                        if let group = selectedGroup {
                            HStack {
                                CaptureBadge(text: group.sensorMode.displayNameHU, color: CaptureVisuals.color(sensor: group.sensorMode, signal: group.signalMode))
                                CaptureBadge(text: group.signalMode.displayNameHU, color: CaptureVisuals.color(sensor: group.sensorMode, signal: group.signalMode))
                                if let filter = group.filterLabel { CaptureBadge(text: filter, color: .purple) }
                            }
                        }
                        Toggle("Pontos fájlszintű felülírás", isOn: $useExactOverride)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if useExactOverride {
                GroupBox("Fájlszintű OSC/NB és szűrőadat") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                        Picker("Szenzor", selection: $sensorOverride) {
                            ForEach(SensorMode.allCases, id: \.self) { Text($0.displayNameHU).tag($0) }
                        }
                        Picker("Fénysáv", selection: $signalOverride) {
                            ForEach(SignalMode.allCases, id: \.self) { Text($0.displayNameHU).tag($0) }
                        }
                        }
                        FilterProfilePicker(selection: assignmentFilterBinding, title: "Pontos szűrő-felülírás")
                    }
                }
            }

            GroupBox("3 · Mentés előtti előnézet") {
                HStack(alignment: .top, spacing: 16) {
                    previewColumn(title: "Jelenleg", after: false)
                    Image(systemName: "arrow.right").font(.title3).foregroundStyle(.secondary).padding(.top, 26)
                    previewColumn(title: "Mentés után", after: true)
                }
            }

            HStack {
                Button("Kézi besorolás törlése") {
                    appState.clearCaptureMetadata(target: target, date: date, paths: affectedPaths)
                    dismiss()
                }
                .disabled(affectedPaths.isEmpty || appState.isBusy)
                Spacer()
                Button("Mégse") { dismiss() }
                Button("Besorolás mentése") {
                    guard let groupID else { return }
                    appState.assignCaptureMetadata(
                        target: target,
                        date: date,
                        paths: affectedPaths,
                        groupID: groupID,
                        sensorOverride: useExactOverride ? sensorOverride : nil,
                        signalOverride: useExactOverride ? signalOverride : nil,
                        filterManufacturerOverride: useExactOverride ? filterSelection.manufacturer : nil,
                        filterModelOverride: useExactOverride ? filterSelection.model : nil,
                        filterNameOverride: useExactOverride ? filterSelection.name : nil
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(groupID == nil || affectedPaths.isEmpty || appState.isBusy)
            }
        }
        .padding(22)
        .frame(minWidth: 860, minHeight: 590)
        .onAppear {
            appState.loadEditableCaptureGroups(target: target, date: date)
            if selectedPaths.count <= 1 { scope = .currentFile }
        }
        .onChange(of: appState.editableCaptureGroups) { _, groups in
            if groupID == nil { groupID = groups.first?.id }
        }
    }

    private var scopeExplanation: String {
        switch scope {
        case .currentFile: return "Pontosan az aktív sor, más fájl nem változik."
        case .selectedFiles: return "A táblában kijelölt sorok, az aktuális sorrendtől függetlenül."
        case .sameFolder: return "Az aktív fájllal közös közvetlen mappában lévő pontozott frame-ek."
        case .sameExposure: return "Azonos session és névleges expozíció (például minden 300 s-os frame)."
        case .wholeSession: return "A kiválasztott dátum összes pontozott light frame-je."
        }
    }

    private func previewColumn(title: String, after: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(affectedPaths.prefix(18), id: \.self) { path in
                        let metadata = appState.frameCaptureMetadata[path]
                        VStack(alignment: .leading, spacing: 1) {
                            Text((path as NSString).lastPathComponent)
                                .font(.caption.monospaced()).lineLimit(1)
                            Text(after ? afterLabel : beforeLabel(metadata))
                                .font(.caption2)
                                .foregroundStyle(after ? Color.accentColor : Color.secondary)
                        }
                    }
                    if affectedPaths.count > 18 {
                        Text("+ \(affectedPaths.count - 18) további fájl")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 190)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func beforeLabel(_ metadata: ResolvedCaptureMetadata?) -> String {
        guard let metadata else { return "Nincs feloldott capture-adat" }
        let filter = CaptureVisuals.filterLabel(metadata) ?? "szűrő ismeretlen"
        return "\(metadata.displayName ?? "nincs gyűjtés") · \(metadata.sensorMode.displayNameHU) · \(metadata.signalMode.displayNameHU) · \(filter) · \(metadata.filterOrigin.displayNameHU)"
    }

    private var afterLabel: String {
        guard let group = selectedGroup else { return "Válassz célgyűjtést" }
        if useExactOverride {
            return "\(group.displayName) · \(sensorOverride.displayNameHU) · \(signalOverride.displayNameHU) · \(filterSelection.displayLabel) · Kézi felülírás"
        }
        return "\(group.displayName) · \(group.quickLabel) · Gyűjtésből"
    }

    private func sessionDate(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        return parts.count > 2 ? String(parts[2]) : nil
    }

    private var assignmentFilterBinding: Binding<FilterProfileSelection> {
        Binding(
            get: { filterSelection },
            set: { selection in
                filterSelection = selection
                if selection.signalMode != .unknown { signalOverride = selection.signalMode }
            }
        )
    }
}

// MARK: - Exact single-session converter

struct SessionConversionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: String
    let date: String

    @State private var mode: SessionConversionMode = .logicalOnly
    @State private var stage = 0
    @State private var ambiguityChoices: [String: String] = [:]
    @State private var confirmingApply = false

    var body: some View {
        VStack(spacing: 0) {
            scopeHeader
            Divider()
            if let receipt = appState.sessionConversionReceipt {
                receiptView(receipt)
            } else if let plan = appState.sessionConversionPlan {
                planView(plan)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("A session struktúrájának és FITS-adataiknak elemzése…")
                    Text("Sem fájlmozgatás, sem adatbázis-módosítás nem történik az Alkalmazás gombig.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1040, minHeight: 720)
        .onAppear {
            appState.resetSessionConversion()
            appState.planSessionConversion(target: target, date: date, mode: mode)
        }
        .confirmationDialog(
            mode == .physical ? "Végrehajtod a felsorolt fájlmozgatásokat?" : "Mented a logikai capture-besorolást?",
            isPresented: $confirmingApply
        ) {
            Button(mode == .physical ? "Konvertálás és fájlmozgatás" : "Logikai besorolás mentése") {
                if let plan = appState.sessionConversionPlan { appState.applySessionConversion(plan) }
            }
            Button("Mégse", role: .cancel) {}
        } message: {
            if let summary = appState.sessionConversionPlan?.summary {
                Text("\(summary.fileAssignmentCount) hozzárendelés · \(summary.moveCount) mozgatás · visszavonási bizonylat készül.")
            }
        }
    }

    private var scopeHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.15))
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.purple)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("Egyetlen session átalakítása").font(.title2.weight(.semibold))
                Text("RÖGZÍTETT HATÓKÖR · \(target) / \(date)")
                    .font(.caption.monospaced().weight(.bold)).foregroundStyle(.purple)
            }
            Spacer()
            Picker("Mód", selection: $mode) {
                Text("Logikai · nincs mozgatás").tag(SessionConversionMode.logicalOnly)
                Text("Fizikai · fájlok rendezése").tag(SessionConversionMode.physical)
            }
            .pickerStyle(.segmented)
            .frame(width: 360)
            .onChange(of: mode) { _, newMode in
                stage = 0
                ambiguityChoices = [:]
                appState.planSessionConversion(target: target, date: date, mode: newMode)
            }
            Button("Bezárás") { dismiss() }
        }
        .padding(18)
    }

    private func planView(_ plan: SessionConversionPlan) -> some View {
        VStack(spacing: 0) {
            Picker("Lépés", selection: $stage) {
                Text("1 · Felismerés").tag(0)
                Text("2 · Döntések és cél").tag(1)
                Text("3 · Pontos műveletek").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(16)

            ScrollView {
                Group {
                    if stage == 0 { recognitionStage(plan) }
                    else if stage == 1 { decisionStage(plan) }
                    else { exactOperationsStage(plan) }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }

            Divider()
            footer(plan)
        }
    }

    private func recognitionStage(_ plan: SessionConversionPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            summaryStrip(plan)
            Text(plan.humanSummaryHU).font(.callout)
            HStack(alignment: .top, spacing: 14) {
                conversionColumn("Jelenlegi források", color: .secondary) {
                    ForEach(plan.detectedClusters) { cluster in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(cluster.sourcePrefixes.joined(separator: ", ")).font(.caption.monospaced()).bold()
                            Text("\(cluster.rawFramePaths.count) nyers frame · \(TDFormat.hm(cluster.integrationSeconds))")
                            Text(exposureText(cluster.exposureBreakdown)).font(.caption).foregroundStyle(.secondary)
                            ForEach(cluster.evidence, id: \.self) { Text("• \($0)").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
                    }
                }
                Image(systemName: "arrow.right").font(.title2).foregroundStyle(.secondary).padding(.top, 42)
                conversionColumn("Javasolt gyűjtések", color: .purple) {
                    ForEach(plan.proposedGroups) { proposed in
                        proposedGroupCard(proposed)
                    }
                }
            }
        }
    }

    private func decisionStage(_ plan: SessionConversionPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if plan.proposedGroups.isEmpty {
                Label("Minden gyűjtés már létezik; nincs új név vagy filteradat.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Az új és meglévő gyűjtések adatai a mentés előtt javíthatók. A slug rögzített, mert erre hivatkozik minden előnézeti művelet.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(plan.proposedGroups.indices, id: \.self) { index in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                TextField("Gyűjtés neve", text: proposedNameBinding(index))
                                Text(plan.proposedGroups[index].draft.slug).font(.body.monospaced()).foregroundStyle(.secondary)
                                Picker("Szenzor", selection: proposedSensorBinding(index)) {
                                    ForEach(SensorMode.allCases, id: \.self) { Text($0.displayNameHU).tag($0) }
                                }
                                Picker("Fénysáv", selection: proposedSignalBinding(index)) {
                                    ForEach(SignalMode.allCases, id: \.self) { Text($0.displayNameHU).tag($0) }
                                }
                            }
                            FilterProfilePicker(
                                selection: proposedFilterSelectionBinding(index),
                                title: "Ehhez a gyűjtéshez rögzített szűrő"
                            )
                        }
                    } label: {
                        Label(
                            plan.proposedGroups[index].existingGroupID == nil
                                ? "Új gyűjtés"
                                : "Meglévő gyűjtés frissítése",
                            systemImage: plan.proposedGroups[index].existingGroupID == nil
                                ? "plus.circle"
                                : "arrow.triangle.2.circlepath.circle"
                        )
                    }
                }
            }

            if plan.ambiguities.isEmpty {
                Label("Minden fájl besorolása egyértelmű.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Kézi döntést kér").font(.headline)
                ForEach(plan.ambiguities) { ambiguity in
                    ambiguityCard(ambiguity)
                }
            }

            ForEach(plan.conflicts) { conflict in
                Label("\(conflict.path): \(conflict.message)", systemImage: "xmark.octagon.fill")
                    .font(.callout).foregroundStyle(.red)
            }
        }
    }

    private func exactOperationsStage(_ plan: SessionConversionPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryStrip(plan)
            DisclosureGroup("Adatbázis-hozzárendelések (\(plan.assignments.count))", isExpanded: .constant(true)) {
                operationRows(plan.assignments.map { "\($0.path)  →  \($0.groupSlug) [\($0.role.rawValue)]" })
            }
            if let removals = plan.sourceRemovals, !removals.isEmpty {
                DisclosureGroup("Túl tág mappaforrások leválasztása (\(removals.count))", isExpanded: .constant(true)) {
                    operationRows(removals.map { "\($0.relativePath) — \($0.reason)" })
                }
            }
            if plan.mode == .physical {
                DisclosureGroup("Létrehozandó mappák (\(plan.directoryCreations.count))") {
                    operationRows(plan.directoryCreations.map(\.relativePath))
                }
                DisclosureGroup("Fájlmozgatások (\(plan.moves.count))", isExpanded: .constant(true)) {
                    operationRows(plan.moves.map { "\($0.sourceRelative)  →  \($0.destinationRelative)" })
                }
            } else {
                Label("Logikai mód: egyetlen fájl útvonala sem változik.", systemImage: "lock.shield.fill")
                    .foregroundStyle(.green)
            }
            DisclosureGroup("Változatlan elemek (\(plan.unchangedItems.count))") {
                operationRows(plan.unchangedItems.map { "\($0.path) — \($0.reason)" })
            }
        }
    }

    private func footer(_ plan: SessionConversionPlan) -> some View {
        HStack {
            if !plan.canApply {
                Label("Előbb oldd fel a piros/sárga döntési pontokat.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            } else {
                Label("A terv alkalmazható és teljesen visszavonható.", systemImage: "checkmark.shield.fill")
                    .font(.callout).foregroundStyle(.green)
            }
            Spacer()
            Button("Előző") { stage = max(0, stage - 1) }.disabled(stage == 0)
            Button("Következő") { stage = min(2, stage + 1) }.disabled(stage == 2)
            Button(mode == .physical ? "Konvertálás…" : "Besorolás alkalmazása…") {
                confirmingApply = true
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!plan.canApply || appState.isBusy)
        }
        .padding(16)
    }

    private func receiptView(_ receipt: SessionConversionReceipt) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: receipt.status == .applied ? "checkmark.circle.fill" : "arrow.uturn.backward.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(receipt.status == .applied ? Color.green : Color.blue)
            Text(receipt.status == .applied ? "A session átalakítása elkészült" : "A session visszaállt az eredeti állapotba")
                .font(.title2.weight(.semibold))
            Text("Bizonylat: \(receipt.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("\(receipt.moves.count) fájlmozgatás · a korábbi metadata pontos mentése rendelkezésre áll")
                .foregroundStyle(.secondary)
            HStack {
                Button("Bizonylat megmutatása Finderben") {
                    appState.revealPathInFinder(receipt.receiptRelativePath)
                }
                if receipt.status == .applied {
                    Button("Konverzió visszavonása…", role: .destructive) {
                        appState.rollbackSessionConversion(receipt)
                    }
                }
                Button("Kész") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summaryStrip(_ plan: SessionConversionPlan) -> some View {
        HStack(spacing: 10) {
            metric("Nyers frame", "\(plan.summary.rawFrameCount)")
            metric("Integráció", TDFormat.hm(plan.summary.integrationSeconds))
            metric("Gyűjtés", "\(plan.detectedClusters.count)")
            metric("Besorolás", "\(plan.summary.fileAssignmentCount)")
            metric("Mozgatás", "\(plan.summary.moveCount)")
            metric("Adat", ByteCountFormatter.string(fromByteCount: plan.summary.bytesToMove, countStyle: .file))
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }

    private func conversionColumn<Content: View>(
        _ title: String, color: Color, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(color)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.045)))
    }

    private func proposedGroupCard(_ proposed: ProposedCaptureGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(proposed.existingGroupID == nil ? "Új gyűjtés" : "Meglévő gyűjtés frissítése")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack {
                Text(proposed.draft.displayName).font(.subheadline.weight(.semibold))
                Spacer()
                Text(proposed.draft.slug).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack {
                CaptureBadge(text: proposed.draft.sensorMode.displayNameHU, color: CaptureVisuals.color(sensor: proposed.draft.sensorMode, signal: proposed.draft.signalMode))
                CaptureBadge(text: proposed.draft.signalMode.displayNameHU, color: CaptureVisuals.color(sensor: proposed.draft.sensorMode, signal: proposed.draft.signalMode))
                if let filter = proposed.draft.filterModel ?? proposed.draft.filterName { CaptureBadge(text: filter, color: .purple) }
            }
            ForEach(proposed.sourceMappings, id: \.relativePath) { mapping in
                Text("\(mapping.relativePath) → \(mapping.role.rawValue)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(CaptureVisuals.color(sensor: proposed.draft.sensorMode, signal: proposed.draft.signalMode).opacity(0.09)))
    }

    private func ambiguityCard(_ ambiguity: ConversionAmbiguity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(ambiguity.title, systemImage: "questionmark.diamond.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            Text(ambiguity.explanation).font(.caption).foregroundStyle(.secondary)
            Text("\(ambiguity.affectedPaths.count) fájl: \(ambiguity.affectedPaths.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
                .font(.caption.monospaced()).lineLimit(2)
            HStack {
                Picker("Hová tartozik?", selection: Binding(
                    get: { ambiguityChoices[ambiguity.id] ?? ambiguity.candidateGroupSlugs.first ?? "" },
                    set: { ambiguityChoices[ambiguity.id] = $0 }
                )) {
                    ForEach(ambiguity.candidateGroupSlugs, id: \.self) { Text($0).tag($0) }
                }
                Button("Döntés rögzítése") {
                    let slug = ambiguityChoices[ambiguity.id] ?? ambiguity.candidateGroupSlugs.first ?? ""
                    appState.resolveSessionConversionAmbiguity(id: ambiguity.id, groupSlug: slug)
                }
                .disabled(ambiguity.candidateGroupSlugs.isEmpty)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.orange.opacity(0.25)))
    }

    private func operationRows(_ rows: [String]) -> some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.self) { row in
                Text(row).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .padding(.top, 6)
    }

    private func exposureText(_ breakdown: [String: Int]) -> String {
        breakdown.sorted { $0.key < $1.key }
            .map { "\($0.key)s × \($0.value)" }.joined(separator: " · ")
    }

    private func proposedNameBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { appState.sessionConversionPlan?.proposedGroups[index].draft.displayName ?? "" },
            set: { value in updateProposed(index) { $0.displayName = value } }
        )
    }

    private func proposedSensorBinding(_ index: Int) -> Binding<SensorMode> {
        Binding(
            get: { appState.sessionConversionPlan?.proposedGroups[index].draft.sensorMode ?? .unknown },
            set: { value in updateProposed(index) { $0.sensorMode = value } }
        )
    }

    private func proposedSignalBinding(_ index: Int) -> Binding<SignalMode> {
        Binding(
            get: { appState.sessionConversionPlan?.proposedGroups[index].draft.signalMode ?? .unknown },
            set: { value in updateProposed(index) { $0.signalMode = value } }
        )
    }

    private func proposedFilterSelectionBinding(_ index: Int) -> Binding<FilterProfileSelection> {
        Binding(
            get: {
                guard let draft = appState.sessionConversionPlan?.proposedGroups[index].draft else {
                    return FilterProfileSelection()
                }
                return FilterProfileSelection(
                    manufacturer: draft.filterManufacturer,
                    model: draft.filterModel,
                    name: draft.filterName,
                    signalMode: draft.signalMode
                )
            },
            set: { selection in
                updateProposed(index) {
                    $0.filterManufacturer = selection.manufacturer
                    $0.filterModel = selection.model
                    $0.filterName = selection.name
                    if selection.signalMode != .unknown { $0.signalMode = selection.signalMode }
                }
            }
        )
    }

    private func updateProposed(_ index: Int, mutation: (inout CaptureGroupDraft) -> Void) {
        guard var plan = appState.sessionConversionPlan,
              plan.proposedGroups.indices.contains(index)
        else { return }
        mutation(&plan.proposedGroups[index].draft)
        appState.replaceSessionConversionPlan(plan)
    }
}
