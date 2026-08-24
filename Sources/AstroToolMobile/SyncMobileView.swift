import SwiftUI
import Foundation
import AstroMobileDomain

struct SyncMobileView: View {
    let snapshot: MobileLibrarySnapshot
    let changes: [MobileChange]
    let queuedChangeCount: Int
    let stagedPackageURL: URL?
    let onScan: () -> Void
    let onImport: () -> Void
    let onDiscard: () -> Void

    private var checklistCount: Int { snapshot.briefings.flatMap(\.checklist).flatMap(\.items).count }

    var body: some View {
        List {
            Section("Plan freshness") {
                LabeledContent("Plan from Mac", value: snapshot.createdAt.formatted(.dateTime.year().month(.abbreviated).day().hour().minute()))
                HStack {
                    Text("Updated")
                    Spacer()
                    Text(snapshot.createdAt, style: .relative).monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                Label("Mac plan saved on this iPhone", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color(uiColor: .systemGreen))
                    .accessibilityIdentifier("mobile-mac-library-status")
            }

            Section("On this iPhone") {
                countRow("Projects", value: snapshot.projects.count)
                countRow("Nights", value: snapshot.nights.count)
                countRow("Image sets", value: snapshot.captures.count)
                countRow("Briefings", value: snapshot.briefings.count)
                countRow("Notes", value: snapshot.notes.count)
                countRow("Checklist items", value: checklistCount)
                countRow("Phone changes waiting", value: queuedChangeCount, identifier: "mobile-queued-count")
                if queuedChangeCount > 0 {
                    Text("Ready to send back in the next step.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("mobile-queued-explanation")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Original photos stay on your Mac or external drive.", systemImage: "lock.shield")
                        .font(.body.weight(.semibold))
                    Text("This iPhone can change only checklist progress and notes. Photos remain where you keep them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
            }
            .accessibilityIdentifier("v5.mobile.safety")

            Section("Bring in a newer plan") {
                if stagedPackageURL != nil {
                    Text("A newer plan from your Mac is waiting. Your current plan stays available until it is checked.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Scan one-time key") { onScan() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("mobile-sync-scan")
                    Button("Import newer plan") { onImport() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("mobile-sync-import")
                    Button("Keep current plan") { onDiscard() }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("mobile-sync-discard")
                } else {
                    Text("When your Mac has a newer plan, send it here with AirDrop. It will appear above your current plan for review.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("v5.mobile.import")

            Section("Safe handoff") {
                Text("Imports, scanner access, and storage recovery remain available here. Your Mac library stays unchanged.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sync")
        .accessibilityIdentifier("mobile-sync-surface")
    }

    private func countRow(_ title: LocalizedStringKey, value: Int, identifier: String? = nil) -> some View {
        LabeledContent(title) {
            if let identifier {
                Text("\(value)").font(.body.monospacedDigit()).accessibilityIdentifier(identifier)
            } else {
                Text("\(value)").font(.body.monospacedDigit())
            }
        }
    }
}
