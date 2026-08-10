import AstroCore
import SwiftUI

/// A value snapshot suitable for bindings in capture editors. It can
/// represent an inventory profile, an older custom value which is no longer
/// in the inventory, or the explicit no-filter choice.
struct FilterProfileSelection: Equatable, Hashable, Sendable {
    var manufacturer: String?
    var model: String?
    var name: String?
    var signalMode: SignalMode

    init(
        manufacturer: String? = nil,
        model: String? = nil,
        name: String? = nil,
        signalMode: SignalMode = .unknown
    ) {
        self.manufacturer = manufacturer
        self.model = model
        self.name = name
        self.signalMode = signalMode
    }

    init(profile: FilterProfileRecord) {
        self.init(
            manufacturer: profile.manufacturer,
            model: profile.model,
            name: profile.name,
            signalMode: profile.signalMode
        )
    }

    static let none = FilterProfileSelection(signalMode: .unfiltered)

    var isNone: Bool {
        CaptureFilterLabel.make(manufacturer: manufacturer, model: model, name: name) == nil
            && signalMode == .unfiltered
    }

    var displayLabel: String {
        CaptureFilterLabel.make(manufacturer: manufacturer, model: model, name: name)
            ?? (isNone ? "Szűrő nélkül" : "Nincs szűrő kiválasztva")
    }
}

/// Shared menu used by capture-group, bulk-assignment and conversion
/// editors. The visible label always shows the exact snapshot that will be
/// saved; inventory selection merely copies values into that snapshot.
struct FilterProfilePicker: View {
    @Environment(AppState.self) private var appState

    @Binding var selection: FilterProfileSelection
    var title = "Szűrő"
    @State private var presentingNewFilter = false

    var body: some View {
        Menu {
            Button {
                selection = .none
            } label: {
                Label("Szűrő nélkül", systemImage: "circle.slash")
            }

            if !appState.filterProfiles.isEmpty {
                Divider()
                ForEach(appState.filterProfiles) { profile in
                    Button {
                        selection = FilterProfileSelection(profile: profile)
                    } label: {
                        Label(profile.displayLabel, systemImage: "camera.filters")
                    }
                }
            }

            Divider()
            Button {
                presentingNewFilter = true
            } label: {
                Label("Új szűrő…", systemImage: "plus.circle")
            }
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selection.isNone ? Color.secondary.opacity(0.12) : Color.purple.opacity(0.16))
                    Image(systemName: selection.isNone ? "circle.slash" : "camera.filters")
                        .foregroundStyle(selection.isNone ? Color.secondary : Color.purple)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(selection.displayLabel)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if selection.signalMode != .unknown {
                    Text(selection.signalMode.displayNameHU)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(selection.isNone ? Color.secondary : Color.purple)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(0.035))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.10)))
            )
        }
        .menuStyle(.borderlessButton)
        .onAppear { appState.loadFilterProfiles() }
        .sheet(isPresented: $presentingNewFilter) {
            FilterProfileEditorSheet(initialProfile: nil) { saved in
                selection = FilterProfileSelection(profile: saved)
            }
        }
    }
}

/// Focused add/edit sheet reused by the inventory page and inline pickers.
/// It waits for AppState's persisted record before dismissing, so an inline
/// add cannot leave the current capture draft pointing at an unsaved value.
struct FilterProfileEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let initialProfile: FilterProfileRecord?
    var onSaved: (FilterProfileRecord) -> Void

    @State private var manufacturer: String
    @State private var model: String
    @State private var name: String
    @State private var signalMode: SignalMode
    @State private var notes: String
    @State private var waitingIdentityKey: String?
    @State private var saveError: String?

    init(
        initialProfile: FilterProfileRecord?,
        onSaved: @escaping (FilterProfileRecord) -> Void = { _ in }
    ) {
        self.initialProfile = initialProfile
        self.onSaved = onSaved
        _manufacturer = State(initialValue: initialProfile?.manufacturer ?? "")
        _model = State(initialValue: initialProfile?.model ?? "")
        _name = State(initialValue: initialProfile?.name ?? "")
        _signalMode = State(initialValue: initialProfile?.signalMode ?? .unknown)
        _notes = State(initialValue: initialProfile?.notes ?? "")
    }

    private var draft: FilterProfileRecord {
        FilterProfileRecord(
            id: initialProfile?.id,
            manufacturer: manufacturer,
            model: model,
            name: name,
            signalMode: signalMode,
            notes: notes,
            createdAt: initialProfile?.createdAt ?? 0,
            updatedAt: initialProfile?.updatedAt ?? 0
        )
    }

    private var canSave: Bool {
        CaptureFilterLabel.make(manufacturer: manufacturer, model: model, name: name) != nil
            && waitingIdentityKey == nil
            && !appState.isBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(initialProfile == nil ? "Új szűrő hozzáadása" : "Szűrő szerkesztése")
                        .font(.title2.weight(.semibold))
                    Text("A mentett szűrő minden capture-felületen kiválasztható lesz.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "camera.filters")
                    .font(.title2)
                    .foregroundStyle(.purple)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.14)))
            }

            GroupBox("Azonosítás") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Gyártó").foregroundStyle(.secondary)
                        TextField("pl. SVBONY", text: $manufacturer)
                    }
                    GridRow {
                        Text("Modell").foregroundStyle(.secondary)
                        TextField("pl. SV220", text: $model)
                    }
                    GridRow {
                        Text("Saját név / sáv").foregroundStyle(.secondary)
                        TextField("pl. Hα + OIII", text: $name)
                    }
                }
                .padding(.top, 4)
            }

            GroupBox("Használat") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Fénysáv", selection: $signalMode) {
                        ForEach(SignalMode.allCases, id: \.self) { mode in
                            Text(mode.displayNameHU).tag(mode)
                        }
                    }
                    TextField("Megjegyzés, pl. 7 nm dual-band", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
                .padding(.top, 4)
            }

            if CaptureFilterLabel.make(manufacturer: manufacturer, model: model, name: name) == nil {
                Label("Adj meg legalább gyártót, modellt vagy saját nevet.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let error = saveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                if waitingIdentityKey != nil {
                    ProgressView().controlSize(.small)
                    Text("Mentés…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Mégse") { dismiss() }
                Button(initialProfile == nil ? "Hozzáadás és kiválasztás" : "Módosítások mentése") {
                    let record = draft
                    saveError = nil
                    waitingIdentityKey = record.identityKey
                    appState.saveFilterProfile(record)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onChange(of: appState.lastSavedFilterProfile) { _, saved in
            guard let saved,
                  let waitingIdentityKey,
                  saved.identityKey == waitingIdentityKey
            else { return }
            self.waitingIdentityKey = nil
            onSaved(saved)
            dismiss()
        }
        .onChange(of: appState.isBusy) { _, busy in
            guard !busy, waitingIdentityKey != nil, let error = appState.lastError else { return }
            saveError = error
            waitingIdentityKey = nil
        }
    }
}
