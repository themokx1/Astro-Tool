import SwiftUI

/// R9-T6/B4's session note editor: `Kulcs: érték` rows written to
/// `.astro_tool/notes/<target>-<date>.txt` via `AppState.saveSessionNotes`
/// -- NEVER to that session's `README.txt` (the iron rule). Pre-fills a
/// fixed template of the observing-conditions fields the R9 review found
/// missing from every real session in the library this tool was built
/// against, plus whatever custom key a previous save already added. A
/// second block shows the session's README-sourced notes read-only (lock
/// icon) -- editing those means opening the README itself, which this tool
/// will never do on the user's behalf.
struct SessionNoteSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: String
    let date: String

    /// The fixed template rows every session gets pre-filled, per spec --
    /// order matters (shown in this exact sequence).
    private static let templateKeys = ["Bortle", "SQM", "Seeing", "Átlátszóság", "Szél", "Páralecsapódás", "Megjegyzés"]

    @State private var values: [String: String] = [:]
    /// Custom keys beyond the fixed template -- either loaded from a prior
    /// save, or added in this session via the "+ egyéni kulcs" row.
    @State private var customKeys: [String] = []
    @State private var newCustomKey: String = ""
    @State private var newCustomValue: String = ""
    @State private var readmeNotes: [String: String] = [:]
    @State private var loaded = false

    private var editableKeys: [String] { Self.templateKeys + customKeys }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !readmeNotes.isEmpty {
                        readmeSection
                    }
                    editableSection
                    addCustomKeySection
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 520)
        .onAppear(perform: load)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Éjszaka-jegyzet szerkesztése").font(.headline)
            Text("\(target) · \(date)").font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    // MARK: - README (read-only)

    private var readmeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("A README.txt-ből").font(.subheadline).bold()
            Text("Ezeket az értékeket a session README.txt-je tartalmazza — ott szerkeszd, ez az app soha nem írja azt a fájlt.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(readmeNotes.keys.sorted(), id: \.self) { key in
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        Text(key).frame(width: 130, alignment: .leading).foregroundStyle(.secondary)
                        Text(readmeNotes[key] ?? "").foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.callout)
                }
            }
        }
    }

    // MARK: - Editable rows

    private var editableSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Jegyzetek").font(.subheadline).bold()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(editableKeys, id: \.self) { key in
                    HStack(spacing: 6) {
                        Text(key).frame(width: 130, alignment: .leading)
                        TextField("", text: binding(for: key))
                    }
                }
            }
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 }
        )
    }

    // MARK: - Add a custom key

    private var addCustomKeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Egyéni kulcs hozzáadása").font(.subheadline).bold()
            HStack(spacing: 6) {
                TextField("Kulcs", text: $newCustomKey).frame(width: 130)
                TextField("Érték", text: $newCustomValue)
                Button("Hozzáadás", action: addCustomKey)
                    .disabled(
                        newCustomKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || editableKeys.contains(newCustomKey.trimmingCharacters(in: .whitespacesAndNewlines))
                    )
            }
        }
    }

    private func addCustomKey() {
        let key = newCustomKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !editableKeys.contains(key) else { return }
        customKeys.append(key)
        values[key] = newCustomValue
        newCustomKey = ""
        newCustomValue = ""
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Mégse") { dismiss() }
            Spacer()
            Button("Mentés") { save() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Load / save

    private func load() {
        guard !loaded else { return }
        loaded = true
        readmeNotes = appState.readmeNotes(target: target, date: date)
        let stored = appState.storeNotes(target: target, date: date)
        for key in Self.templateKeys { values[key] = stored[key] ?? "" }
        for (key, value) in stored where !Self.templateKeys.contains(key) {
            customKeys.append(key)
            values[key] = value
        }
    }

    private func save() {
        let notes = editableKeys.map { ($0, values[$0] ?? "") }
        appState.saveSessionNotes(target: target, date: date, notes: notes)
        dismiss()
    }
}
