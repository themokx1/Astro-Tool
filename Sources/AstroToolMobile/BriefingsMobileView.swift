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
                                    Text(briefingTitle(briefing)).font(.body.weight(.semibold))
                                    Spacer()
                                    Text("v\(briefing.revision)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text(briefing.nightDate.map { plannedDate($0) } ?? "Planned date not set")
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

    private func briefingTitle(_ briefing: MobileBriefing) -> String {
        briefing.nightDate.map { $0.formatted(.dateTime.month(.abbreviated).day().year()) } ?? "Saved briefing"
    }

    private func plannedDate(_ date: Date) -> String {
        "Planned · \(date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))"
    }

    private func readinessLabel(_ value: String) -> String {
        switch value.lowercased() {
        case "ready", "good": return String(localized: "Ready")
        case "warning", "needsattention", "needs_attention": return String(localized: "Needs attention")
        case "blocked": return String(localized: "Not ready")
        default: return String(localized: "Plan status available")
        }
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
                    LabeledContent("Planned", value: nightDate.formatted(.dateTime.month(.wide).day().year().hour().minute()))
                } else {
                    LabeledContent("Planned", value: "Date not set")
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
                                Text(targetRoleLabel(target.role)).foregroundStyle(.secondary)
                            }
                            Text("Planned · \(plannedTime(target.start))–\(plannedTime(target.end))")
                                .font(.footnote).foregroundStyle(.secondary)
                            ForEach(target.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
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
                            Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(section.items) { item in
                                let completed = MobileEffectiveState.checklistValue(briefingID: briefing.id, itemID: item.id, snapshotValue: item.isCompleted, changes: changes)
                                Button {
                                    toggle(item: item, completed: completed)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(completed ? Color(uiColor: .systemGreen) : .secondary)
                                        Text(item.title).strikethrough(completed)
                                        Spacer()
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .accessibilityValue(completed ? "Completed" : "Not completed")
                                .accessibilityIdentifier("mobile-briefing-checklist-\(item.id)")
                            }
                        }
                    }
                }
            }
            if let note {
                Section("Note") {
                    Text(MobileEffectiveState.noteText(noteID: note.id, snapshotText: note.text, changes: changes).isEmpty ? "No note yet" : MobileEffectiveState.noteText(noteID: note.id, snapshotText: note.text, changes: changes))
                        .foregroundStyle(note.text.isEmpty ? .secondary : .primary)
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
            } catch { message = "This checklist item could not be saved yet." }
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

    private func targetRoleLabel(_ value: String) -> String {
        switch value.lowercased() {
        case "target", "science": return String(localized: "Target")
        case "calibration", "calibrationtarget": return String(localized: "Calibration")
        case "focus": return String(localized: "Focus")
        default: return String(localized: "Target")
        }
    }

    private func plannedTime(_ date: Date) -> String {
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
