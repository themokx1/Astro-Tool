import AstroCore
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
///
/// R11-T12/F11(b): each of the six OBSERVING-CONDITION template fields
/// (everything but the free-text "Megjegyzés") now carries a small ⓘ button
/// -- a 1-2 sentence explanation plus a value scale, footer-linked to this
/// term's own `GlossarySheet` entry (`.showGlossary`'s anchor payload) --
/// and an example placeholder, since a first-time user staring at "Bortle"
/// or "SQM" with no hint of what a plausible value even looks like was
/// exactly the R11 persona review's own finding (spec F11 item 4).
///
/// R11-T13/F20: a field whose key also appears in the README section above
/// with a DIFFERENT value (`NoteConflicts.detect`) gets a yellow warning row
/// right under it -- "eltér a README-től: <readme-érték>" plus a
/// "README-érték átvétele" button that copies the README's value into this
/// (app-store) field. The README section itself stays exactly as read-only
/// as ever; this only ever writes to the note-editor's own store.
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

    /// R11-T13/F20: recomputed on every access (no caching, same "cheap
    /// derived read" stance the rest of this app takes for similar
    /// comparisons) straight off the LIVE `values` the user is currently
    /// editing -- so typing the README's own value into a conflicting field
    /// clears its warning immediately, and "README-érték átvétele" below
    /// resolves it the same way, with no extra state of its own to keep in
    /// sync.
    private var conflicts: [String: NoteConflicts.Conflict] {
        NoteConflicts.detect(appNotes: values, readmeNotes: readmeNotes)
    }

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
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            HStack(spacing: 3) {
                                Text(key)
                                if Self.fieldInfo[key] != nil {
                                    FieldInfoButton(fieldKey: key)
                                }
                            }
                            .frame(width: 130, alignment: .leading)
                            TextField(Self.examplePlaceholder(for: key), text: binding(for: key))
                        }
                        // R11-T13/F20: this key disagrees with the README's
                        // own value for it -- offered right here (rather than
                        // only in the read-only section above) since this is
                        // exactly where the user would fix it.
                        if let conflict = conflicts[key] {
                            conflictRow(key: key, conflict: conflict)
                        }
                    }
                }
            }
        }
    }

    /// One conflicting field's yellow warning row -- "README-érték átvétele"
    /// copies the README's value into THIS app-store field (never the other
    /// way around: the README stays permanently read-only, see this file's
    /// own header doc comment).
    private func conflictRow(key: String, conflict: NoteConflicts.Conflict) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("eltér a README-től: \(conflict.readmeValue)")
                .foregroundStyle(.secondary)
            Button("README-érték átvétele") {
                values[key] = conflict.readmeValue
            }
            .buttonStyle(.link)
        }
        .font(.caption)
        .padding(.leading, 136)
    }

    // MARK: - Field ⓘ (R11-T12/F11(b))

    /// One template field's ⓘ popover content: a 1-2 sentence explanation,
    /// a value scale, and a footer link to this field's own `GlossarySheet`
    /// entry -- keyed by the exact `templateKeys` text above. `fileprivate`
    /// (not `private`): `FieldInfoButton` below is a sibling top-level type
    /// in this same file, not an extension of `SessionNoteSheet`, so a
    /// plain `private` here wouldn't be visible to it.
    fileprivate struct FieldInfo {
        let explanation: String
        let scale: String
        /// The `GlossarySheet` term name to scroll to -- always a real
        /// entry in that sheet's own list (R11-T12/F11(a) added the missing
        /// ones specifically so every field here has a match).
        let glossaryAnchor: String
    }

    fileprivate static let fieldInfo: [String: FieldInfo] = [
        "Bortle": FieldInfo(
            explanation: "Az égi háttér fényszennyezettsége egy 1-9-es skálán.",
            scale: "1 = sötét vidéki ég … 9 = belvárosi ég",
            glossaryAnchor: "Bortle-skála"
        ),
        "SQM": FieldInfo(
            explanation: "Az égi háttér fényessége mag/ívmásodperc² egységben, kézi műszerrel mérve.",
            scale: "≈17 = városi, világos ég … ≈22 = kiváló, sötét vidéki ég",
            glossaryAnchor: "SQM"
        ),
        "Seeing": FieldInfo(
            explanation: "A légkör pillanatnyi nyugalma -- ez szabja meg, mennyire éles pontra tud fókuszálni a csillag.",
            scale: "1 = nyugtalan/rossz … 5 = kristálytiszta/kiváló",
            glossaryAnchor: "Seeing"
        ),
        "Átlátszóság": FieldInfo(
            explanation: "Az égbolt fényáteresztő képessége -- pára, füst vagy magas felhő rontja, a seeing-től függetlenül.",
            scale: "1 = párás/rossz … 5 = kristálytiszta/kiváló",
            glossaryAnchor: "Átlátszóság"
        ),
        "Szél": FieldInfo(
            explanation: "A session közben mért/becsült szélsebesség -- erős szél rezgést, csillag-nyúlást okozhat.",
            scale: "pl. km/h vagy m/s, vagy egyszerű \"nyugodt / közepes / erős\" jelölés",
            glossaryAnchor: "Szél"
        ),
        "Páralecsapódás": FieldInfo(
            explanation: "Harmat/dér lecsapódása az optikán vagy a szenzoron -- fokozatosan elmosódó csillagokat okoz.",
            scale: "pl. \"nem\" / \"enyhe\" / \"erős -- páramentesítő kellett volna\"",
            glossaryAnchor: "Páralecsapódás"
        ),
    ]

    private static func examplePlaceholder(for key: String) -> String {
        switch key {
        case "Bortle": return "pl. 5"
        case "SQM": return "pl. 20.8"
        case "Seeing": return "pl. 3/5"
        case "Átlátszóság": return "pl. 4/5"
        case "Szél": return "pl. 15 km/h"
        case "Páralecsapódás": return "pl. nem"
        default: return ""
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

/// One template field's ⓘ button -- same "borderless `info.circle` button
/// popover" shape `MetricInfoButton` already establishes, scoped to a single
/// field instead of a whole table's columns. `fieldKey` must have a
/// `SessionNoteSheet.fieldInfo` entry (the caller only ever constructs this
/// for keys it already checked).
private struct FieldInfoButton: View {
    let fieldKey: String

    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .popover(isPresented: $showPopover) {
            if let info = SessionNoteSheet.fieldInfo[fieldKey] {
                VStack(alignment: .leading, spacing: 8) {
                    Text(fieldKey).font(.subheadline).bold()
                    Text(info.explanation).font(.caption)
                    Text(info.scale).font(.caption2).foregroundStyle(.secondary)
                    Divider()
                    Button("Fogalomtár…") {
                        showPopover = false
                        NotificationCenter.default.post(name: .showGlossary, object: info.glossaryAnchor)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(width: 260)
            }
        }
    }
}
