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

    private var briefing: MobileBriefing? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return snapshot.briefings
            .sorted { $0.savedAt == $1.savedAt ? $0.id.uuidString < $1.id.uuidString : $0.savedAt > $1.savedAt }
            .first(where: { briefing in
                guard let date = briefing.nightDate else { return false }
                return calendar.isDate(date, inSameDayAs: today)
            }) ?? snapshot.briefings.first
    }

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
                if let briefing {
                    briefingContent(briefing)
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
                Text(snapshot.createdAt, style: .relative)
                Text("·")
                Text(freshness == .stale ? "Needs a newer plan" : "Ready for tonight")
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(freshness == .stale ? Color(uiColor: .systemOrange) : .secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(freshness == .stale ? Color(uiColor: .systemOrange).opacity(0.16) : Color(red: 0.043, green: 0.063, blue: 0.125).opacity(0.96), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .foregroundStyle(freshness == .stale ? .primary : Color(uiColor: .systemBackground))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(freshness == .stale ? "Plan from Mac, needs a newer plan" : "Plan from Mac, ready for tonight")
        .accessibilityIdentifier(freshness == .stale ? "v5.mobile.stale" : "v5.mobile.fresh")
    }

    @ViewBuilder
    private func briefingContent(_ briefing: MobileBriefing) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tonight's plan")
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
                        Text("Planned · \(plannedTime(target.start, for: briefing))–\(plannedTime(target.end, for: briefing))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ForEach(target.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
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
                        Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
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
                                        Text(item.title)
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
                            .accessibilityValue(completed ? "Completed" : "Not completed")
                            .accessibilityHint("Double-tap to mark this checklist item \(completed ? "not completed" : "completed")")
                            .accessibilityIdentifier("mobile-checklist-\(item.id)")
                        }
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .accessibilityIdentifier("v5.mobile.checklist")
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
                            Button("Edit") { editingNote = true; syncDraft() }
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
                        Text("No note yet").foregroundStyle(.secondary)
                    } else {
                        Text(noteText).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityIdentifier("v5.mobile.note")
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
                actionMessage = "This checklist item could not be saved yet."
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
                actionMessage = "This note could not be saved yet."
            }
        }
    }

    private func readinessLabel(_ value: String) -> String {
        switch value.lowercased() {
        case "ready", "good": return String(localized: "Ready")
        case "warning", "needsattention", "needs_attention": return String(localized: "Needs attention")
        case "blocked": return String(localized: "Not ready")
        default: return String(localized: "Plan status available")
        }
    }

    private func plannedTime(_ date: Date, for briefing: MobileBriefing) -> String {
        let timeZone = snapshot.nights.first(where: { night in
            guard let zone = TimeZone(identifier: night.timeZoneID) else { return false }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.dateComponents([.year, .month, .day], from: date) == calendar.dateComponents([.year, .month, .day], from: briefing.nightDate ?? date)
        }).flatMap { TimeZone(identifier: $0.timeZoneID) } ?? .current
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}
