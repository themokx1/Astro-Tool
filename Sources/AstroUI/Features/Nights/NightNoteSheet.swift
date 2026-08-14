import AstroApplication
import AstroCore
import SwiftUI

/// V2's native equivalent of V1's `SessionNoteSheet`
/// (`Sources/AstroToolApp/Views/SessionNoteSheet.swift`): a structured
/// key-value editor for one session's "night notes" -- the fixed
/// observing-condition template plus any custom key a prior save added --
/// backed by the testable `NightNoteStore`. Shows the session's
/// README-sourced notes read-only above the editable section (lock icon,
/// exactly V1's own framing: "edit those in the README itself, this app
/// never will"), flags a field whose value disagrees with the README's own
/// (`NoteConflicts`), and posts a toast through `OperationHost` on save
/// rather than silently dismissing.
public struct NightNoteSheet: View {
    let rootURL: URL
    let target: String
    let date: String
    let accessMode: LibraryAccessMode
    let dismiss: () -> Void

    @State private var store: NightNoteStore
    @State private var newCustomKey = ""
    @State private var newCustomValue = ""
    @Environment(OperationHost.self) private var operationHost

    public init(
        rootURL: URL,
        target: String,
        date: String,
        accessMode: LibraryAccessMode,
        dismiss: @escaping () -> Void,
        store: NightNoteStore = NightNoteStore()
    ) {
        self.rootURL = rootURL
        self.target = target
        self.date = date
        self.accessMode = accessMode
        self.dismiss = dismiss
        _store = State(initialValue: store)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                    if !store.readmeNotes.isEmpty { readmeSection }
                    editableSection
                    addCustomKeySection
                    if accessMode != .mutationEnabled {
                        Label("Requires write access. Enable write operations in Settings to save night notes.", systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let errorMessage = store.errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(AstroTokens.Spacing.section)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 560)
        .accessibilityIdentifier("v2.nights.note-sheet")
        .task {
            await store.load(rootURL: rootURL, target: target, date: date, accessMode: accessMode)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Edit Night Notes").font(.headline)
            Text("\(target) · \(date)").font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(AstroTokens.Spacing.section)
    }

    // MARK: - README (read-only)

    private var readmeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("From README.txt").font(.subheadline).bold()
            Text("These values come from the session's README.txt — edit them there; this app never writes that file.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.readmeNotes.keys.sorted(), id: \.self) { key in
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        Text(key).frame(width: 130, alignment: .leading).foregroundStyle(.secondary)
                        Text(store.readmeNotes[key] ?? "").foregroundStyle(.secondary)
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
            Text("Notes").font(.subheadline).bold()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.editableKeys, id: \.self) { key in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            HStack(spacing: 3) {
                                Text(key)
                                if let info = Self.fieldInfo[key] { NightNoteFieldInfoButton(fieldKey: key, info: info) }
                            }
                            .frame(width: 130, alignment: .leading)
                            TextField(Self.examplePlaceholder(for: key), text: binding(for: key))
                                .textFieldStyle(.roundedBorder)
                        }
                        if let conflict = store.conflicts[key] {
                            conflictRow(key: key, conflict: conflict)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("v2.nights.note-fields")
    }

    private func conflictRow(key: String, conflict: NoteConflicts.Conflict) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("Differs from README: \(conflict.readmeValue)").foregroundStyle(.secondary)
            Button("Use README Value") { store.setValue(conflict.readmeValue, for: key) }
                .buttonStyle(.link)
        }
        .font(.caption)
        .padding(.leading, 136)
    }

    private static let fieldInfo: [String: (explanation: String, scale: String)] = [
        "Bortle": ("Sky-glow light pollution on a 1–9 scale.", "1 = dark rural sky … 9 = inner-city sky"),
        "SQM": ("Sky background brightness in mag/arcsec², measured with a handheld meter.", "≈17 = bright city sky … ≈22 = excellent dark-sky site"),
        "Seeing": ("Momentary atmospheric steadiness — how sharp a point a star can focus to.", "1 = turbulent/poor … 5 = pristine/excellent"),
        "Transparency": ("How much light the sky lets through — degraded by haze, smoke, or high cloud, independent of seeing.", "1 = hazy/poor … 5 = pristine/excellent"),
        "Wind": ("Measured or estimated wind speed during the session — strong wind can cause vibration or star trailing.", "e.g. km/h, m/s, or a simple \"calm / moderate / strong\""),
        "Dew": ("Dew or frost forming on the optics or sensor — causes gradually softening stars.", "e.g. \"none\" / \"light\" / \"heavy — needed a dew heater\""),
    ]

    private static func examplePlaceholder(for key: String) -> String {
        switch key {
        case "Bortle": return "e.g. 5"
        case "SQM": return "e.g. 20.8"
        case "Seeing": return "e.g. 3/5"
        case "Transparency": return "e.g. 4/5"
        case "Wind": return "e.g. 15 km/h"
        case "Dew": return "e.g. none"
        default: return ""
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(get: { store.value(for: key) }, set: { store.setValue($0, for: key) })
    }

    // MARK: - Add a custom key

    private var addCustomKeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add a Custom Key").font(.subheadline).bold()
            HStack(spacing: 6) {
                TextField("Key", text: $newCustomKey).frame(width: 130).textFieldStyle(.roundedBorder)
                TextField("Value", text: $newCustomValue).textFieldStyle(.roundedBorder)
                Button("Add", action: addCustomKey)
                    .disabled(newCustomKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message = store.customKeyErrorMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        .accessibilityIdentifier("v2.nights.note-add-custom-key")
    }

    private func addCustomKey() {
        guard store.addCustomKey(newCustomKey, value: newCustomValue) else { return }
        newCustomKey = ""
        newCustomValue = ""
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
            Spacer()
            Button("Save") { Task { await save() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(store.isSaving || accessMode != .mutationEnabled)
                .accessibilityIdentifier("v2.nights.note-save")
        }
        .padding(AstroTokens.Spacing.section)
    }

    private func save() async {
        let succeeded = await store.save()
        if succeeded {
            operationHost.notify(.success, message: "Night notes saved.")
            dismiss()
        } else {
            operationHost.notify(.failure, message: store.errorMessage ?? "Saving night notes failed.")
        }
    }
}

/// One template field's ⓘ popover -- same "borderless `info.circle` button
/// popover" shape V1's own `FieldInfoButton` (`SessionNoteSheet.swift`)
/// established, without that type's `GlossarySheet` deep link since V2's own
/// glossary (Wave 3 Task 7) doesn't exist yet.
private struct NightNoteFieldInfoButton: View {
    let fieldKey: String
    let info: (explanation: String, scale: String)
    @State private var showPopover = false

    var body: some View {
        Button { showPopover = true } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .popover(isPresented: $showPopover) {
            VStack(alignment: .leading, spacing: 8) {
                Text(fieldKey).font(.subheadline).bold()
                Text(info.explanation).font(.caption)
                Text(info.scale).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(AstroTokens.Spacing.standard)
            .frame(width: 260)
        }
    }
}
