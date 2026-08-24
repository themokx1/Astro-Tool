import SwiftUI
import Foundation
import AstroMobileDomain

struct ProjectsMobileView: View {
    let snapshot: MobileLibrarySnapshot
    let changes: [MobileChange]
    let store: MobileLibraryStore
    let onStoreChange: () async -> Void
    @State private var sortMode: SortMode = .name

    enum SortMode: String, CaseIterable {
        case name, progress, phase
        var title: String {
            switch self {
            case .name: return String(localized: "Name")
            case .progress: return String(localized: "Progress")
            case .phase: return String(localized: "Phase")
            }
        }
    }

    private var projects: [MobileProject] {
        snapshot.projects.sorted { lhs, rhs in
            switch sortMode {
            case .name:
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                return comparison == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : comparison == .orderedAscending
            case .phase:
                let leftPhase = phaseRank(lhs.phase)
                let rightPhase = phaseRank(rhs.phase)
                if leftPhase != rightPhase { return leftPhase < rightPhase }
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                return comparison == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : comparison == .orderedAscending
            case .progress:
                let left = MobileProjectProgress.fraction(integrationSeconds: lhs.integrationSeconds, goalHours: lhs.goalHours) ?? -1
                let right = MobileProjectProgress.fraction(integrationSeconds: rhs.integrationSeconds, goalHours: rhs.goalHours) ?? -1
                if left != right { return left > right }
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                return comparison == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : comparison == .orderedAscending
            }
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Sort projects", selection: $sortMode) {
                    ForEach(SortMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("mobile-project-sort")
            }
            Section("Projects") {
                if projects.isEmpty {
                    ContentUnavailableView("No projects yet", systemImage: "square.stack.3d.up", description: Text("Projects prepared on your Mac will appear after import."))
                } else {
                    ForEach(projects) { project in
                        NavigationLink {
                            ProjectMobileDetailView(project: project, snapshot: snapshot, changes: changes, store: store, onStoreChange: onStoreChange)
                        } label: {
                            ProjectRow(project: project)
                        }
                        .accessibilityIdentifier("mobile-project-\(project.id.uuidString)")
                    }
                }
            }
        }
        .navigationTitle("Projects")
        .accessibilityIdentifier("mobile-projects-surface")
    }

    private func phaseLabel(_ value: String) -> String {
        MobileProjectPhaseLabel.label(for: value)
    }

    private func phaseRank(_ value: String) -> Int {
        switch value.lowercased() {
        case "planned": return 0
        case "collecting": return 1
        case "processing": return 2
        case "complete": return 3
        case "archived": return 4
        default: return 5
        }
    }
}

private struct ProjectRow: View {
    let project: MobileProject

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(project.displayName).font(.body.weight(.semibold))
                Spacer()
                Text(project.catalogID)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(phaseLabel(project.phase)).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text(collectedIntegration(project.integrationSeconds))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if let fraction = MobileProjectProgress.fraction(integrationSeconds: project.integrationSeconds, goalHours: project.goalHours) {
                    Text("\(Int(fraction * 100))%")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("No goal").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let fraction = MobileProjectProgress.fraction(integrationSeconds: project.integrationSeconds, goalHours: project.goalHours) {
                ProgressView(value: fraction)
                    .tint(Color(red: 0.373, green: 0.906, blue: 0.949))
                    .accessibilityValue(String.localizedStringWithFormat(NSLocalizedString("%d percent", comment: "Progress accessibility"), Int(fraction * 100)))
            }
        }
        .padding(.vertical, 5)
    }

    private func phaseLabel(_ value: String) -> String {
        MobileProjectPhaseLabel.label(for: value)
    }

    private func collectedIntegration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return String(localized: "Integration unavailable") }
        let minutes = Int(seconds / 60)
        if minutes >= 60 {
            return String.localizedStringWithFormat(NSLocalizedString("%d h %d min collected", comment: "Collected integration"), minutes / 60, minutes % 60)
        }
        return String.localizedStringWithFormat(NSLocalizedString("%d min collected", comment: "Collected integration"), minutes)
    }
}

private struct ProjectMobileDetailView: View {
    let project: MobileProject
    let snapshot: MobileLibrarySnapshot
    let changes: [MobileChange]
    let store: MobileLibraryStore
    let onStoreChange: () async -> Void
    @State private var editingNote = false
    @State private var noteDraft = ""
    @State private var message: String?

    private var captures: [MobileCapture] { snapshot.captures.filter { $0.projectID == project.id } }
    private var note: MobileNote? { snapshot.notes.first { $0.scope == .project && $0.ownerID == project.id.uuidString } }
    private var noteText: String { guard let note else { return "" }; return MobileEffectiveState.noteText(noteID: note.id, snapshotText: note.text, changes: changes) }

    var body: some View {
        List {
            Section("Project") {
                LabeledContent("Catalog", value: project.catalogID)
                LabeledContent("Phase", value: phaseLabel(project.phase))
                LabeledContent("Integration", value: duration(project.integrationSeconds))
                if let goal = project.goalHours, goal.isFinite, goal > 0 {
                    LabeledContent("Goal", value: String.localizedStringWithFormat(NSLocalizedString("%.1f hours", comment: "Integration goal"), goal))
                }
            }
            Section("Image sets") {
                if captures.isEmpty {
                    Text("No image sets in this plan").foregroundStyle(.secondary)
                } else {
                    ForEach(captures) { capture in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(capture.displayName).font(.body.weight(.medium))
                            HStack {
                                Text(capture.filterName ?? String(localized: "Unfiltered"))
                                Spacer()
                                Text(captureSummary(capture))
                            }
                            .font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            if let note, note.isEditableOnPhone {
                Section("Project note") {
                    if editingNote {
                        TextEditor(text: $noteDraft).frame(minHeight: 110).accessibilityIdentifier("mobile-project-note-editor")
                        HStack {
                            Button("Cancel") { editingNote = false; noteDraft = noteText }
                            Button("Save note") { save(note: note) }.buttonStyle(.borderedProminent).accessibilityIdentifier("mobile-project-note-save")
                        }
                        Text("A blank note is kept as a blank revision.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text(noteText.isEmpty ? String(localized: "No note yet") : noteText).foregroundStyle(noteText.isEmpty ? .secondary : .primary)
                            Spacer()
                            Button("Edit") { noteDraft = noteText; editingNote = true }.accessibilityIdentifier("mobile-project-note-edit")
                        }
                    }
                }
            }
        }
        .navigationTitle(project.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { noteDraft = noteText }
        .alert("Phone change", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    private func save(note: MobileNote) {
        Task {
            do {
                try await store.editNote(id: note.id, text: noteDraft)
                editingNote = false
                await onStoreChange()
            } catch MobileLibraryStoreError.noOpChange {
                editingNote = false
            } catch { message = String(localized: "This note could not be saved yet.") }
        }
    }

    private func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return String(localized: "Not available") }
        let minutes = Int(seconds / 60)
        if minutes >= 60 {
            return String.localizedStringWithFormat(NSLocalizedString("%d h %d min", comment: "Duration"), minutes / 60, minutes % 60)
        }
        return String.localizedStringWithFormat(NSLocalizedString("%d min", comment: "Duration"), minutes)
    }

    private func phaseLabel(_ value: String) -> String {
        MobileProjectPhaseLabel.label(for: value)
    }

    private func captureSummary(_ capture: MobileCapture) -> String {
        let exposure = String.localizedStringWithFormat(NSLocalizedString("%.1f s exposures", comment: "Exposure summary"), capture.exposureSeconds)
        return "\(duration(capture.integrationSeconds)) · \(exposure)"
    }
}
