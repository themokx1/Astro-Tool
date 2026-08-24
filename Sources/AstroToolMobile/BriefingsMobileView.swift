import SwiftUI
import Foundation
import AstroMobileDomain

struct BriefingsMobileView: View {
    let snapshot: MobileLibrarySnapshot
    let changes: [MobileChange]
    let store: MobileLibraryStore
    let onStoreChange: () async -> Void

    private var briefings: [MobileBriefing] {
        snapshot.briefings.sorted { lhs, rhs in
            lhs.savedAt == rhs.savedAt ? (lhs.revision == rhs.revision ? lhs.id.uuidString < rhs.id.uuidString : lhs.revision > rhs.revision) : lhs.savedAt > rhs.savedAt
        }
    }

    var body: some View {
        List {
            Section("Saved plans") {
                if briefings.isEmpty {
                    ContentUnavailableView("No briefings yet", systemImage: "doc.text", description: Text("Plans prepared on your Mac will appear after import."))
                } else {
                    ForEach(briefings) { briefing in
                        NavigationLink {
                            BriefingMobileDetailView(briefing: briefing, snapshot: snapshot, changes: changes, store: store, onStoreChange: onStoreChange)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(savedDate(briefing.savedAt)).font(.body.weight(.semibold))
                                    Spacer()
                                    Text(String.localizedStringWithFormat(NSLocalizedString("Revision %@", comment: "Briefing revision"), "\(briefing.revision)"))
                                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text(briefing.nightDate.map { plannedDate($0) } ?? String(localized: "Planned date not set"))
                                    Spacer()
                                    Text(readinessLabel(briefing.readiness))
                                }
                                .font(.footnote).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        }
                        .accessibilityIdentifier("mobile-briefing-\(briefing.id.uuidString)")
                    }
                }
            }
        }
        .navigationTitle("Briefings")
        .accessibilityIdentifier("mobile-briefings-surface")
    }

    private func savedDate(_ date: Date) -> String {
        String.localizedStringWithFormat(NSLocalizedString("Saved %@", comment: "Saved briefing date"), date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))
    }

    private func plannedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = MobileBriefingSelection.timeZone(for: date, nights: snapshot.nights) ?? .current
        return String.localizedStringWithFormat(NSLocalizedString("Planned · %@", comment: "Planned briefing date"), formatter.string(from: date))
    }

    private func readinessLabel(_ value: String) -> String {
        MobileBriefingReadinessLabel.label(for: value)
    }
}

private struct BriefingMobileDetailView: View {
    let briefing: MobileBriefing
    let snapshot: MobileLibrarySnapshot
    let changes: [MobileChange]
    let store: MobileLibraryStore
    let onStoreChange: () async -> Void
    @State private var message: String?

    private var note: MobileNote? { snapshot.notes.first { $0.id == briefing.noteID } }

    var body: some View {
        List {
            Section("Plan") {
                if let nightDate = briefing.nightDate {
                    LabeledContent("Planned", value: plannedDateTime(nightDate))
                } else {
                    LabeledContent("Planned", value: String(localized: "Date not set"))
                }
                LabeledContent("Readiness", value: readinessLabel(briefing.readiness))
                LabeledContent("Saved", value: briefing.savedAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))
            }
            if !briefing.targets.isEmpty {
                Section("Targets") {
                    ForEach(briefing.targets) { target in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(target.name).font(.body.weight(.medium))
                                Spacer()
                                Text(MobileBriefingTargetRoleLabel.label(for: target.role)).foregroundStyle(.secondary)
                            }
                            Text(plannedWindow(start: plannedTime(target.start), end: plannedTime(target.end)))
                                .font(.footnote).foregroundStyle(.secondary)
                            ForEach(target.warnings, id: \.self) { warning in
                                Label(warning == "Planned time only" ? String(localized: "Planned time only") : warning, systemImage: "exclamationmark.triangle")
                                    .font(.footnote).foregroundStyle(Color(uiColor: .systemOrange))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            if !briefing.checklist.isEmpty {
                Section("Checklist") {
                    ForEach(briefing.checklist) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title == "Before capture" ? String(localized: "Before capture") : section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(section.items) { item in
                                let completed = MobileEffectiveState.checklistValue(briefingID: briefing.id, itemID: item.id, snapshotValue: item.isCompleted, changes: changes)
                                Button {
                                    toggle(item: item, completed: completed)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(completed ? Color(uiColor: .systemGreen) : .secondary)
                                        Text(item.title == "Check focus" ? String(localized: "Check focus") : item.title).strikethrough(completed)
                                        Spacer()
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .accessibilityValue(String(localized: completed ? "Completed" : "Not completed"))
                                .accessibilityHint(String(localized: completed ? "Double-tap to mark this checklist item not completed" : "Double-tap to mark this checklist item completed"))
                                .accessibilityIdentifier("mobile-briefing-checklist-\(item.id)")
                            }
                        }
                    }
                }
            }
            if let note {
                Section("Note") {
                    let effectiveText = MobileEffectiveState.noteText(noteID: note.id, snapshotText: note.text, changes: changes)
                    Text(effectiveText.isEmpty ? String(localized: "No note yet") : effectiveText)
                        .foregroundStyle(effectiveText.isEmpty ? .secondary : .primary)
                }
            }
        }
        .navigationTitle("Briefing")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Phone change", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    private func toggle(item: MobileChecklistItem, completed: Bool) {
        Task {
            do {
                try await store.toggleChecklistItem(briefingID: briefing.id, itemID: item.id, isCompleted: !completed)
                await onStoreChange()
            } catch { message = String(localized: "This checklist item could not be saved yet.") }
        }
    }

    private func readinessLabel(_ value: String) -> String {
        MobileBriefingReadinessLabel.label(for: value)
    }

    private func plannedTime(_ date: Date) -> String {
        let timeZone = MobileBriefingSelection.timeZone(for: briefing.nightDate ?? date, nights: snapshot.nights) ?? .current
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    private func plannedDateTime(_ date: Date) -> String {
        let timeZone = MobileBriefingSelection.timeZone(for: briefing.nightDate ?? date, nights: snapshot.nights) ?? .current
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    private func plannedWindow(start: String, end: String) -> String {
        String.localizedStringWithFormat(NSLocalizedString("Planned %@–%@", comment: "Planned time window"), start, end)
    }
}
