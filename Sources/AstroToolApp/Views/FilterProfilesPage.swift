import AstroCore
import SwiftUI

/// The user's reusable, library-scoped filter inventory. It is deliberately
/// an equipment page rather than a session page: saved profiles can be
/// picked from any future capture, while historic sessions retain snapshots.
struct FilterProfilesPage: View {
    @Environment(AppState.self) private var appState

    @State private var presentingEditor = false
    @State private var editorProfile: FilterProfileRecord?
    @State private var pendingDelete: FilterProfileRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryHeader

                if appState.filterProfiles.isEmpty {
                    emptyState
                } else {
                    savedSection
                }

                if !appState.discoveredFilterProfiles.isEmpty {
                    discoveredSection
                }

                if let error = appState.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    editorProfile = nil
                    presentingEditor = true
                } label: {
                    Label("Szűrő hozzáadása", systemImage: "plus")
                }
            }
        }
        .onAppear { appState.loadFilterProfiles() }
        .sheet(isPresented: $presentingEditor) {
            FilterProfileEditorSheet(initialProfile: editorProfile)
        }
        .confirmationDialog(
            "Törlöd a szűrőt a saját listádból?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Törlés a saját listából", role: .destructive) {
                guard let profile = pendingDelete else { return }
                pendingDelete = nil
                appState.deleteFilterProfile(profile)
            }
            Button("Mégse", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("A korábbi sessionökben és gyűjtésekben rögzített szűrőadat megmarad; egyetlen fájl sem változik.")
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.24), Color.blue.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "camera.filters")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.purple)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text("Saját szűrők")
                    .font(.title2.weight(.semibold))
                Text("Egyszer rögzíted, utána gyűjtésnél, tömeges besorolásnál és session-konvertálásnál listából választod.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(appState.filterProfiles.count)")
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(.purple)
                Text("mentett szűrő")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.045)))
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Image(systemName: "camera.filters")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.purple)
            Text("Még nincs saját szűrőd elmentve")
                .font(.headline)
            Text("A saját szűrődet itt egyszer felveheted, majd minden új capture-ben kiválaszthatod.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button("Első szűrő hozzáadása") {
                editorProfile = nil
                presentingEditor = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.purple.opacity(0.045))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.purple.opacity(0.16)))
        )
    }

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saját lista")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                ForEach(appState.filterProfiles, id: \.identityKey) { profile in
                    savedCard(profile)
                }
            }
        }
    }

    private func savedCard(_ profile: FilterProfileRecord) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayLabel)
                        .font(.headline)
                    Text(profile.signalMode.displayNameHU)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CaptureVisuals.color(sensor: nil, signal: profile.signalMode))
                }
                Spacer()
                Menu {
                    Button("Szerkesztés…") {
                        editorProfile = profile
                        presentingEditor = true
                    }
                    Divider()
                    Button("Törlés…", role: .destructive) { pendingDelete = profile }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }

            if let notes = profile.notes, !notes.isEmpty {
                Text(notes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("Nincs megjegyzés")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                inventoryChip(profile.manufacturer ?? "gyártó nincs megadva", color: .secondary)
                if let model = profile.model { inventoryChip(model, color: .purple) }
                if let name = profile.name { inventoryChip(name, color: .blue) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.045))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        )
    }

    private var discoveredSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Már használt, még nincs a saját listában")
                    .font(.headline)
                Text("Capture-gyűjtésből vagy FITS-fejlécből talált értékek. Ellenőrzés után egy kattintással elmenthetők.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(appState.discoveredFilterProfiles, id: \.identityKey) { candidate in
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.displayLabel).font(.headline)
                        Text(candidate.signalMode.displayNameHU)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Szerkesztés…") {
                        editorProfile = candidate
                        presentingEditor = true
                    }
                    Button("Importálás") {
                        appState.saveFilterProfile(candidate)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.orange.opacity(0.055))
                        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.orange.opacity(0.18)))
                )
            }
        }
    }

    private func inventoryChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}
