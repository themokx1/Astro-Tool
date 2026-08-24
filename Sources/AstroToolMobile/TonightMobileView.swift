import SwiftUI
import Foundation
import AstroMobileDomain

struct TonightMobileView: View {
    let snapshot: MobileLibrarySnapshot
    let changes: [MobileChange]
    let store: MobileLibraryStore
    let onStoreChange: () async -> Void

    @State private var noteDraft = ""
    @State private var editingNote = false
    @State private var actionMessage: String?
    @State private var now = Date()

    private var selection: MobileBriefingSelection.Result? {
        MobileBriefingSelection.select(briefings: snapshot.briefings, now: now)
    }

    private var briefing: MobileBriefing? { selection?.briefing }

    private var briefingNote: MobileNote? {
        guard let briefing else { return nil }
        return snapshot.notes.first { $0.id == briefing.noteID }
    }

    private var freshness: MobileSnapshotFreshness {
        MobileSnapshotFreshness.classification(snapshotDate: snapshot.createdAt, now: now)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                horizonBand
                if let selection {
                    briefingContent(selection)
                } else {
                    ContentUnavailableView("No briefing saved yet", systemImage: "moon.stars", description: Text("Your Mac-prepared plans will appear here after the next import."))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Tonight")
        .navigationBarTitleDisplayMode(.large)
        .task { now = Date(); syncDraft() }
        .refreshable { now = Date(); await onStoreChange(); syncDraft() }
        .onChange(of: briefingNote?.id) { _, _ in syncDraft() }
        .alert("Phone change", isPresented: Binding(get: { actionMessage != nil }, set: { if !$0 { actionMessage = nil } })) {
            Button("OK", role: .cancel) { actionMessage = nil }
        } message: {
            Text(actionMessage ?? "")
        }
        .accessibilityIdentifier("mobile-tonight-surface")
    }

    private var horizonBand: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Plan from Mac", systemImage: freshness == .stale ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 5) {
                Text("Updated")
                Text(snapshot.createdAt, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                Text("(")
                Text(snapshot.createdAt, style: .relative)
                Text(")")
                Text("·")
                Text(freshness == .stale ? "Needs a newer plan" : "Ready for tonight")
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(freshness == .stale ? Color(red: 1, green: 0.77, blue: 0.25) : .white)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.043, green: 0.063, blue: 0.125), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(freshness == .stale ? Color(red: 1, green: 0.77, blue: 0.25) : .clear, lineWidth: 2)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Plan from Mac"))
        .accessibilityValue(horizonAccessibilityValue)
        .accessibilityIdentifier(freshness == .stale ? "v5.mobile.stale" : "v5.mobile.fresh")
    }

    @ViewBuilder
    private func briefingContent(_ selection: MobileBriefingSelection.Result) -> some View {
        let briefing = selection.briefing
        VStack(alignment: .leading, spacing: 6) {
            Text(selectionTitle(selection.kind))
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(readinessLabel(briefing.readiness))
                .font(.headline)
                .foregroundStyle(.secondary)
        }

        if !briefing.targets.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Planned targets")
                    .font(.headline)
                ForEach(briefing.targets) { target in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(target.name).font(.body.weight(.medium))
                            Spacer()
                            Text(plannedTime(target.start, for: briefing))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(plannedWindow(start: plannedTime(target.start, for: briefing), end: plannedTime(target.end, for: briefing)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(target.warnings, id: \.self) { warning in
                            Label(warningLabel(warning), systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(Color(uiColor: .systemOrange))
                        }
                    }
                    .padding(14)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .accessibilityIdentifier("mobile-tonight-targets")
        }

        checklist(briefing)
        noteSection
    }

    @ViewBuilder
    private func checklist(_ briefing: MobileBriefing) -> some View {
        if !briefing.checklist.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Checklist").font(.headline)
                ForEach(briefing.checklist) { section in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sectionTitle(section.title)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(section.items) { item in
                            let completed = MobileEffectiveState.checklistValue(briefingID: briefing.id, itemID: item.id, snapshotValue: item.isCompleted, changes: changes)
                            Button {
                                toggle(item: item, briefingID: briefing.id, completed: completed)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(completed ? Color(uiColor: .systemGreen) : .secondary)
                                        .font(.title3)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(itemTitle(item.title))
                                            .strikethrough(completed)
                                            .foregroundStyle(.primary)
                                        if let explanation = item.explanation {
                                            Text(explanation).font(.footnote).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(String(localized: completed ? "Completed" : "Not completed"))
                            .accessibilityHint(String(localized: completed ? "Double-tap to mark this checklist item not completed" : "Double-tap to mark this checklist item completed"))
                            .accessibilityIdentifier("mobile-checklist-\(item.id)")
                        }
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private var noteSection: some View {
        Group {
            if let note = briefingNote, note.isEditableOnPhone {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Your note").font(.headline)
                        Spacer()
                        if !editingNote {
                            Button(String(localized: "Update note")) { editingNote = true; syncDraft() }
                                .accessibilityIdentifier("mobile-note-edit")
                        }
                    }
                    if editingNote {
                        TextEditor(text: $noteDraft)
                            .frame(minHeight: 100)
                            .padding(8)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("v5.mobile.note.editor")
                        HStack {
                            Button("Cancel") { editingNote = false; syncDraft() }
                                .buttonStyle(.bordered)
                            Button("Save note") { save(note: note) }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("v5.mobile.note.save")
                        }
                        Text("A blank note is kept as a blank revision.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if noteText.isEmpty {
                        Text(String(localized: "No note yet")).foregroundStyle(.secondary)
                    } else {
                        Text(noteText).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var noteText: String {
        guard let note = briefingNote else { return "" }
        return MobileEffectiveState.noteText(noteID: note.id, snapshotText: note.text, changes: changes)
    }

    private func syncDraft() {
        guard !editingNote else { return }
        noteDraft = noteText
    }

    private func toggle(item: MobileChecklistItem, briefingID: UUID, completed: Bool) {
        Task {
            do {
                try await store.toggleChecklistItem(briefingID: briefingID, itemID: item.id, isCompleted: !completed)
                await onStoreChange()
            } catch {
                actionMessage = String(localized: "This checklist item could not be saved yet.")
            }
        }
    }

    private func save(note: MobileNote) {
        Task {
            do {
                try await store.editNote(id: note.id, text: noteDraft)
                editingNote = false
                await onStoreChange()
            } catch MobileLibraryStoreError.noOpChange {
                editingNote = false
            } catch {
                actionMessage = String(localized: "This note could not be saved yet.")
            }
        }
    }

    private func readinessLabel(_ value: String) -> String {
        MobileBriefingReadinessLabel.label(for: value)
    }

    private func selectionTitle(_ kind: MobileBriefingSelection.Kind) -> String {
        switch kind {
        case .tonight: return String(localized: "Tonight's plan")
        case .upcoming: return String(localized: "Upcoming plan")
        case .past: return String(localized: "Saved plan from the past")
        case .saved: return String(localized: "Saved plan")
        }
    }

    private func plannedWindow(start: String, end: String) -> String {
        String.localizedStringWithFormat(NSLocalizedString("Planned %@–%@", comment: "Planned time window"), start, end)
    }

    private func warningLabel(_ value: String) -> String {
        value == "Planned time only" ? String(localized: "Planned time only") : value
    }

    private var horizonAccessibilityValue: String {
        let absolute = snapshot.createdAt.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
        let relative = snapshot.createdAt.formatted(.relative(presentation: .named))
        let status = freshness == .stale ? String(localized: "Needs a newer plan") : String(localized: "Ready for tonight")
        return String.localizedStringWithFormat(NSLocalizedString("Updated %@ (%@). %@", comment: "Plan freshness accessibility"), absolute, relative, status)
    }

    private func sectionTitle(_ value: String) -> String {
        value == "Before capture" ? String(localized: "Before capture") : value
    }

    private func itemTitle(_ value: String) -> String {
        value == "Check focus" ? String(localized: "Check focus") : value
    }

    private func plannedTime(_ date: Date, for briefing: MobileBriefing) -> String {
        let timeZone = MobileBriefingSelection.timeZone(for: briefing.nightDate ?? date, nights: snapshot.nights) ?? .current
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}
