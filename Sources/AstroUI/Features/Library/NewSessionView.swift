import AstroApplication
import AstroCore
import SwiftUI

/// A session-creation prefill for the sheet's two "already know the target"
/// entry points (`ProjectWorkspaceView`'s header action, `ProjectsView`'s row
/// action) -- the Nights page's own toolbar action passes `nil` and lets the
/// user pick a project or type a catalog/name instead, mirroring V1's
/// `NewSessionSheet`'s "from a catalog target" vs. "custom target" split.
public struct SessionCreationPrefill: Equatable, Sendable {
    public let catalogRaw: String
    public let nameRaw: String
    public let catalogTarget: CatalogTarget?
    public let displayName: String

    public init(catalogRaw: String, nameRaw: String, catalogTarget: CatalogTarget?, displayName: String) {
        self.catalogRaw = catalogRaw
        self.nameRaw = nameRaw
        self.catalogTarget = catalogTarget
        self.displayName = displayName
    }

    /// Builds a prefill from an already-open project -- resolves the
    /// project's own `catalogID` back to a `CatalogTarget` the exact same
    /// way `ProjectsQuery.canonicalFolderName(for:)` does, so the session
    /// folds into the SAME on-disk target folder that project's own pages
    /// already show, never a second, differently-spelled one. Falls back to
    /// the project's own `catalogID`/`displayName` as plain strings when the
    /// catalog no longer recognizes that designation (a project can outlive
    /// a renamed or removed catalog entry) -- `SessionCreationCommand`
    /// still resolves a target folder in that case via `Sanitizer.makeTarget`,
    /// it just cannot reuse `SessionCreator.targetFolder`'s catalog-aware
    /// disk lookup.
    public static func project(_ project: ProjectRecord) -> Self {
        let catalogTarget = TargetCatalog.search(project.catalogID, limit: 1)
            .first { $0.designation == project.catalogID }
        let nameRaw = catalogTarget.flatMap { TargetCatalog.englishName(for: $0) }
            ?? catalogTarget?.commonNameHU
            ?? project.displayName
        return Self(
            catalogRaw: project.catalogID,
            nameRaw: nameRaw,
            catalogTarget: catalogTarget,
            displayName: project.displayName
        )
    }
}

/// Backs `NewSessionView`: holds the sheet's own input fields (including the
/// capture fields -- W3-10 owner correction: a night can hold 2-3 captures
/// under different filters/setups, so a bare `sessions/<target>/<date>/` is
/// not the whole story), previews exactly what
/// `SessionCreationCommand.create(...)` will do via that same command's
/// `preview(...)`, and drives `create(...)`/`undo(...)` through
/// `OperationHost` -- the same shape `ConversionStore` uses for
/// `SessionConversionCommand.apply`/`.rollback`.
@MainActor
@Observable
public final class NewSessionStore {
    public typealias CommandFactory = @Sendable (URL, LibraryAccessMode, [String]) throws -> SessionCreationCommand

    public var catalogRaw: String
    public var nameRaw: String
    public var catalogTarget: CatalogTarget?
    public var dateText: String
    /// `true` while the "existing project" picker is showing (only
    /// meaningful when `isPrefilled == false`) -- `false` switches to the
    /// free-typed catalog/name fields, mirroring V1's `NewSessionSheet
    /// .usesCustomTarget` segmented control.
    public var usesExistingProject: Bool

    /// Mirrors V1's `NewSessionSheet.createsInitialCapture` -- user-toggleable
    /// while the session doesn't exist yet (a bare session with no capture
    /// is still valid, exactly like V1). Once `preview.sessionAlreadyExists`
    /// is `true`, `effectiveCreatesCapture` below forces this on: adding to
    /// an existing session can ONLY be "add a capture", the same way
    /// `SessionCreationCommand.create` itself requires one in that case.
    public var createsCapture = true
    public var captureDisplayName = "OSC · No Filter"
    public var captureSensorMode: SensorMode = .osc
    public var captureSignalMode: SignalMode = .unfiltered
    public var captureFilterManufacturer = ""
    public var captureFilterModel = ""

    public private(set) var preview: SessionCreationPreview?
    public private(set) var previewErrorKey: LocalizedStringKey?
    public private(set) var receipt: SessionCreationReceipt?
    public private(set) var isCreating = false
    public private(set) var isUndoing = false
    public private(set) var isUndone = false
    public private(set) var undoErrorKey: LocalizedStringKey?

    public let rootURL: URL
    public let accessMode: LibraryAccessMode
    /// `true` for the Project workspace/Projects-page entry points (the
    /// catalog target is already known and shown read-only); `false` for
    /// the Nights page's own unprefilled entry point.
    public let isPrefilled: Bool
    private let indexedFolders: [String]
    private let commandFactory: CommandFactory

    public init(
        rootURL: URL,
        accessMode: LibraryAccessMode,
        indexedFolders: [String],
        prefill: SessionCreationPrefill?,
        commandFactory: @escaping CommandFactory = { root, mode, folders in
            try .production(rootURL: root, accessMode: mode, indexedFolders: folders)
        }
    ) {
        self.rootURL = rootURL
        self.accessMode = accessMode
        self.indexedFolders = indexedFolders
        self.commandFactory = commandFactory
        catalogRaw = prefill?.catalogRaw ?? ""
        nameRaw = prefill?.nameRaw ?? ""
        catalogTarget = prefill?.catalogTarget
        isPrefilled = prefill != nil
        usesExistingProject = true
        dateText = NewSessionStore.today()
        refreshPreview()
    }

    private func makeCommand() throws -> SessionCreationCommand {
        try commandFactory(rootURL, accessMode, indexedFolders)
    }

    var dateIsValid: Bool {
        guard let parsed = SessionDateParser.parse(dateText) else { return false }
        return parsed.isCanonical
    }

    /// `catalogTarget` only when it should actually take effect: always for
    /// a prefilled sheet (no mode toggle at all), or for the unprefilled
    /// Nights entry point only while its "Existing Project" mode is
    /// selected. Switching to "Custom Target" does not clear the stored
    /// `catalogTarget` (V1's own `NewSessionSheet`/`AppState.createSession`
    /// never clears `selectedCatalogTarget` on that same toggle either --
    /// see `AppState.createSession`'s `catalogTarget: usesCustomTarget ?
    /// nil : selectedCatalogTarget`); instead every read goes through this
    /// property, so a typed custom catalog/name is never silently
    /// overridden by whichever project was picked before the mode switch.
    private var effectiveCatalogTarget: CatalogTarget? {
        (isPrefilled || usesExistingProject) ? catalogTarget : nil
    }

    /// `true` whenever a capture WILL be created by this exact `create(...)`
    /// call -- either because the user asked for one, or because the
    /// session already exists and adding a capture is the only thing this
    /// call can legitimately do (`SessionCreationCommand.create` itself
    /// throws `AstroError.invalidInput` for a capture-less call once the
    /// session date directory is already there).
    public var effectiveCreatesCapture: Bool {
        (preview?.sessionAlreadyExists ?? false) || createsCapture
    }

    var captureSlug: String {
        CaptureGroupDraft.suggestedSlug(for: captureDisplayName)
    }

    /// The exact draft `create(...)` would submit right now, or `nil` when
    /// no capture is being created at all (the bare-session path).
    var captureDraft: CaptureGroupDraft? {
        guard effectiveCreatesCapture else { return nil }
        return CaptureGroupDraft(
            slug: captureSlug,
            displayName: captureDisplayName,
            sensorMode: captureSensorMode,
            signalMode: captureSignalMode,
            filterManufacturer: captureFilterManufacturer.isEmpty ? nil : captureFilterManufacturer,
            filterModel: captureFilterModel.isEmpty ? nil : captureFilterModel
        )
    }

    /// The exact folder `create(...)` would use right now for the current
    /// fields -- computed via `SessionCreationCommand.resolvedTargetFolder`
    /// inside `refreshPreview()`'s own command call; exposed here as a pure
    /// string for the view's own empty-target check, using the same
    /// resolution `preview`/`create` themselves depend on. Reset to an
    /// empty string whenever `refreshPreview()` cannot even construct a
    /// command (e.g. the library's index database is unreachable), same as
    /// `preview`/`previewErrorKey` in that branch -- never left holding a
    /// stale value from a previous, since-invalidated set of fields.
    private(set) var targetFolderPreview: String = ""

    /// Applies a picked existing project's identity to the fields --
    /// `usesExistingProject`'s picker calls this on selection.
    public func selectExistingProject(_ project: ProjectRecord) {
        let resolved = SessionCreationPrefill.project(project)
        catalogRaw = resolved.catalogRaw
        nameRaw = resolved.nameRaw
        catalogTarget = resolved.catalogTarget
        refreshPreview()
    }

    /// Recomputes `preview`/`previewErrorKey` from the current fields.
    /// Called after every field edit; never touches the filesystem beyond
    /// the read-only checks `SessionCreationCommand.preview` itself
    /// performs.
    public func refreshPreview() {
        guard receipt == nil else { return }
        do {
            let command = try makeCommand()
            targetFolderPreview = command.resolvedTargetFolder(
                catalogRaw: catalogRaw, nameRaw: nameRaw, catalogTarget: effectiveCatalogTarget
            )
            guard !targetFolderPreview.isEmpty else {
                preview = nil
                previewErrorKey = "The catalog number and target name resolve to an empty folder name."
                return
            }
            guard dateIsValid else {
                preview = nil
                previewErrorKey = "Invalid date — the YYYY-MM-DD format is required."
                return
            }
            preview = try command.preview(
                catalogRaw: catalogRaw, nameRaw: nameRaw, date: dateText,
                catalogTarget: effectiveCatalogTarget, capture: captureDraft
            )
            previewErrorKey = nil
        } catch AstroError.invalidInput {
            targetFolderPreview = ""
            preview = nil
            previewErrorKey = "AstroTool could not preview this session."
        } catch {
            targetFolderPreview = ""
            preview = nil
            previewErrorKey = "AstroTool could not preview this session."
        }
    }

    public var canCreate: Bool {
        accessMode == .mutationEnabled
            && receipt == nil
            && !isCreating
            && preview != nil
            && previewErrorKey == nil
    }

    /// The one reason (if any) `canCreate` is currently `false`, for the
    /// sheet's own disabled-button tooltip -- surfaces
    /// `AstroError.invalidInput`'s own reason (via `previewErrorKey`, one of
    /// this store's own fixed, already-localized fragments) rather than a
    /// generic "can't create" with no explanation.
    public var disabledReasonKey: LocalizedStringKey? {
        if receipt != nil { return nil }
        if accessMode != .mutationEnabled {
            return "Requires write access. Enable write operations in Settings to create this session."
        }
        return previewErrorKey
    }

    public func create(operationHost: OperationHost) async {
        guard canCreate, let preview else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let command = try makeCommand()
            let catalogRaw = catalogRaw
            let nameRaw = nameRaw
            let catalogTarget = effectiveCatalogTarget
            let dateText = dateText
            let capture = captureDraft
            let kind = OperationKind.createSession(target: "\(preview.targetFolder)/\(preview.date)")
            let title = "\(OperationHost.localized("Creating session")) \(preview.targetFolder)/\(preview.date)"
            _ = await operationHost.run(kind: kind, title: title, cancellation: .unavailable) { [weak self] in
                let result = try command.create(
                    catalogRaw: catalogRaw, nameRaw: nameRaw, date: dateText,
                    catalogTarget: catalogTarget, capture: capture
                )
                await self?.recordReceipt(result)
            }
        } catch {
            previewErrorKey = "AstroTool could not preview this session."
        }
    }

    public func undo(operationHost: OperationHost) async {
        guard let receipt, !isUndoing, !isUndone else { return }
        isUndoing = true
        undoErrorKey = nil
        defer { isUndoing = false }
        do {
            let command = try makeCommand()
            let kind = OperationKind.createSession(target: "\(receipt.targetFolder)/\(receipt.date)")
            let title = OperationHost.localized("Undoing session creation")
            _ = await operationHost.run(kind: kind, title: title, cancellation: .unavailable) { [weak self] in
                do {
                    try command.undo(receipt)
                    await self?.recordUndone()
                } catch {
                    await self?.recordUndoFailure(error)
                }
            }
        } catch {
            undoErrorKey = "AstroTool could not undo this session."
        }
    }

    private func recordReceipt(_ receipt: SessionCreationReceipt) {
        self.receipt = receipt
    }

    private func recordUndone() {
        isUndone = true
    }

    private func recordUndoFailure(_ error: Error) {
        switch error {
        case SessionCreationUndoError.notEmpty:
            undoErrorKey = "The folder is no longer empty — it was not removed."
        case LibraryMutationError.readOnly:
            undoErrorKey = "Requires write access. Enable write operations in Settings to undo this."
        default:
            undoErrorKey = "AstroTool could not undo this session."
        }
    }

    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

/// The one "New Session"/"Add Capture" sheet every entry point presents
/// (Project workspace's header action, Projects page's row action, Nights
/// page's toolbar action) -- prefilled and read-only about the target for
/// the first two, a picker/free-typed pair of fields for the third. Every
/// one of them calls the exact same `NewSessionStore`/`SessionCreationCommand`
/// pair, so there is exactly one session/capture-creation implementation,
/// not three.
public struct NewSessionView: View {
    @State private var store: NewSessionStore
    let existingProjects: [ProjectRecord]
    let dismiss: () -> Void
    let didCreate: (SessionCreationReceipt) -> Void
    @Environment(OperationHost.self) private var operationHost

    public init(
        rootURL: URL,
        accessMode: LibraryAccessMode,
        indexedFolders: [String],
        prefill: SessionCreationPrefill?,
        existingProjects: [ProjectRecord] = [],
        dismiss: @escaping () -> Void,
        didCreate: @escaping (SessionCreationReceipt) -> Void = { _ in }
    ) {
        _store = State(initialValue: NewSessionStore(
            rootURL: rootURL, accessMode: accessMode, indexedFolders: indexedFolders, prefill: prefill
        ))
        self.existingProjects = existingProjects
        self.dismiss = dismiss
        self.didCreate = didCreate
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
                header
                if store.receipt == nil {
                    targetSection
                    dateSection
                    existingCapturesSection
                    captureSection
                    previewSection
                    if let disabledReasonKey = store.disabledReasonKey {
                        Label(disabledReasonKey, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(AstroTokens.Color.attention)
                            .accessibilityIdentifier("v2.new-session.disabled-reason")
                    }
                    footer
                } else {
                    receiptSection
                }
            }
            .padding(AstroTokens.Spacing.spacious)
        }
        .frame(minWidth: 580, minHeight: 520, idealHeight: 640)
        .accessibilityIdentifier("v2.new-session")
    }

    private var header: some View {
        HStack {
            Image(systemName: "moon.stars.circle").font(.title).foregroundStyle(AstroTokens.Color.accent)
            VStack(alignment: .leading) {
                Text("New Session").font(.title2.weight(.semibold))
                Text("Choose the night; AstroTool builds the whole folder skeleton.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private var targetSection: some View {
        if store.isPrefilled {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(AstroTokens.Color.ok)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(store.catalogTarget?.designation ?? store.catalogRaw))
                        .font(.headline)
                    Text(LocalizedStringKey(store.nameRaw)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .astroRecessedSurface()
        } else {
            Picker("Target", selection: $store.usesExistingProject) {
                Text("Existing Project").tag(true)
                Text("Custom Target").tag(false)
            }
            .pickerStyle(.segmented)
            .onChange(of: store.usesExistingProject) { _, _ in store.refreshPreview() }
            .accessibilityIdentifier("v2.new-session.target-mode")
            if store.usesExistingProject {
                if existingProjects.isEmpty {
                    Text("No projects yet — type a catalog number and target name instead.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Project", selection: existingProjectSelection) {
                        Text("Choose a project").tag(Optional<UUID>.none)
                        ForEach(existingProjects, id: \.id) { project in
                            Text(project.displayName).tag(Optional(project.id))
                        }
                    }
                    .accessibilityIdentifier("v2.new-session.project-picker")
                }
            } else {
                TextField("Catalog number (optional, e.g. C 14)", text: $store.catalogRaw)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: store.catalogRaw) { _, _ in store.refreshPreview() }
                    .accessibilityIdentifier("v2.new-session.catalog-field")
                TextField("Target name", text: $store.nameRaw)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: store.nameRaw) { _, _ in store.refreshPreview() }
                    .accessibilityIdentifier("v2.new-session.name-field")
            }
        }
    }

    private var existingProjectSelection: Binding<UUID?> {
        Binding(
            get: { existingProjects.first { $0.catalogID == store.catalogRaw }?.id },
            set: { id in
                guard let id, let project = existingProjects.first(where: { $0.id == id }) else { return }
                store.selectExistingProject(project)
            }
        )
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Date (YYYY-MM-DD)", text: $store.dateText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .onChange(of: store.dateText) { _, _ in store.refreshPreview() }
                .accessibilityIdentifier("v2.new-session.date-field")
            if !store.dateIsValid {
                Text("Invalid date — the YYYY-MM-DD format is required.")
                    .font(.caption).foregroundStyle(AstroTokens.Color.attention)
            }
        }
    }

    /// W3-10 (owner correction): "if the date already has captures, show
    /// them so the user sees what exists before adding another" -- a night
    /// can hold 2-3 captures under different filters/setups, so this list
    /// is what lets the user avoid re-adding the same one by mistake.
    @ViewBuilder
    private var existingCapturesSection: some View {
        if let preview = store.preview, preview.sessionAlreadyExists {
            VStack(alignment: .leading, spacing: 6) {
                Label("This session already exists.", systemImage: "moon.stars.fill")
                    .font(.subheadline.weight(.semibold))
                if preview.existingCaptures.isEmpty {
                    Text("No captures recorded for this night yet.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Captures already in this session:")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(preview.existingCaptures, id: \.slug) { group in
                        Label(group.quickLabel, systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                }
                Text("Add another capture below for a different filter, exposure series, or setup.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .astroRecessedSurface()
            .accessibilityIdentifier("v2.new-session.existing-captures")
        }
    }

    /// The capture fields -- V1's own `NewSessionSheet` "Első
    /// capture-gyűjtés" section, carried over field-for-field
    /// (`CaptureGroupDraft`'s actual model: display name, sensor mode,
    /// signal mode, filter manufacturer/model -- the engine has no
    /// focal-length/optics field at capture-creation time; that comes from
    /// scanned FITS headers later, never from this sheet). The toggle is
    /// disabled (forced on) once the session already exists, since adding a
    /// capture is the only thing `create(...)` can do at that point.
    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("Create a capture", isOn: Binding(
                get: { store.effectiveCreatesCapture },
                set: { store.createsCapture = $0 }
            ))
            .disabled(store.preview?.sessionAlreadyExists == true)
            .onChange(of: store.createsCapture) { _, _ in store.refreshPreview() }
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier("v2.new-session.capture-toggle")

            if store.effectiveCreatesCapture {
                HStack {
                    Button("OSC · No Filter") {
                        store.captureDisplayName = "OSC · No Filter"
                        store.captureSensorMode = .osc
                        store.captureSignalMode = .unfiltered
                        store.captureFilterManufacturer = ""
                        store.captureFilterModel = ""
                        store.refreshPreview()
                    }
                    Button("OSC · Dual-Band") {
                        store.captureDisplayName = "OSC · Dual-Band"
                        store.captureSensorMode = .osc
                        store.captureSignalMode = .dualBand
                        store.captureFilterManufacturer = ""
                        store.captureFilterModel = ""
                        store.refreshPreview()
                    }
                }
                TextField("Capture name", text: $store.captureDisplayName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: store.captureDisplayName) { _, _ in store.refreshPreview() }
                    .accessibilityIdentifier("v2.new-session.capture-name")
                HStack {
                    Picker("Sensor", selection: $store.captureSensorMode) {
                        ForEach(SensorMode.allCases, id: \.self) { Text($0.localizedDisplayName).tag($0) }
                    }
                    .onChange(of: store.captureSensorMode) { _, _ in store.refreshPreview() }
                    Picker("Signal", selection: $store.captureSignalMode) {
                        ForEach(SignalMode.allCases, id: \.self) { Text($0.localizedDisplayName).tag($0) }
                    }
                    .onChange(of: store.captureSignalMode) { _, _ in store.refreshPreview() }
                }
                if store.captureSignalMode == .dualBand || store.captureSignalMode == .narrowband {
                    HStack {
                        TextField("Filter maker", text: $store.captureFilterManufacturer)
                            .onChange(of: store.captureFilterManufacturer) { _, _ in store.refreshPreview() }
                        TextField("Filter model", text: $store.captureFilterModel)
                            .onChange(of: store.captureFilterModel) { _, _ in store.refreshPreview() }
                    }
                }
                Text("Creates its own lights/flats/darks/biases branch and stack/process location below this session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        if let preview = store.preview {
            VStack(alignment: .leading, spacing: 6) {
                Text("Will create: \(preview.targetFolder)/\(preview.date)")
                    .font(.subheadline.weight(.semibold))
                if preview.relativePaths.isEmpty {
                    Text("Nothing will be created — enable “Create a capture” above.")
                        .font(.caption).foregroundStyle(AstroTokens.Color.attention)
                } else {
                    ForEach(preview.relativePaths, id: \.self) { path in
                        Text(verbatim: path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .astroRecessedSurface()
            .accessibilityIdentifier("v2.new-session.preview")
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if store.isCreating { ProgressView().controlSize(.small) }
            Button(store.preview?.sessionAlreadyExists == true ? "Add Capture" : "Create Session") {
                Task { await store.create(operationHost: operationHost) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.canCreate)
            .help(store.disabledReasonKey ?? "Create the session folders")
            .accessibilityIdentifier("v2.new-session.create")
        }
        .onChange(of: store.receipt) { _, receipt in
            if let receipt { didCreate(receipt) }
        }
    }

    @ViewBuilder
    private var receiptSection: some View {
        if let receipt = store.receipt {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    receipt.sessionWasCreated ? "The folder was created." : "The capture was added.",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.headline).foregroundStyle(AstroTokens.Color.ok)
                // `Text(verbatim:)`, not a `LocalizedStringKey` literal --
                // this is a real on-disk relative path (`sessions/` is a
                // literal directory name), never something to translate.
                Text(verbatim: receipt.captureSlug.map { "sessions/\(receipt.targetFolder)/\(receipt.date)/captures/\($0)" }
                    ?? "sessions/\(receipt.targetFolder)/\(receipt.date)")
                    .font(.callout.monospaced()).textSelection(.enabled)
                // W3-10: an empty session/capture produces no scanned
                // frames, so it will not appear in Projects/Nights until
                // real light frames land in it and a rescan runs -- see
                // `ScanWorkflowMaterializer`'s own frame-driven project/
                // night construction. Telling the truth here beats
                // promising a row that will not show up.
                Label(
                    "The session will appear once the first light frames are scanned into it.",
                    systemImage: "info.circle"
                )
                .font(.caption).foregroundStyle(.secondary)

                if store.isUndone {
                    Label("Undone — the empty folders were removed.", systemImage: "arrow.uturn.backward.circle")
                        .foregroundStyle(AstroTokens.Color.attention)
                } else {
                    HStack {
                        if store.isUndoing { ProgressView().controlSize(.small) }
                        Button("Undo") {
                            Task { await store.undo(operationHost: operationHost) }
                        }
                        .disabled(store.isUndoing)
                        .accessibilityIdentifier("v2.new-session.undo")
                    }
                }
                if let undoErrorKey = store.undoErrorKey {
                    Text(undoErrorKey).font(.caption).foregroundStyle(AstroTokens.Color.attention)
                }
                HStack {
                    Spacer()
                    Button("Done", action: dismiss).buttonStyle(.borderedProminent)
                }
            }
            .accessibilityIdentifier("v2.new-session.receipt")
        }
    }
}

// W6-D fix: this sheet's own "Sensor"/"Signal" pickers used to render
// `SensorMode`/`SignalMode`'s `.displayName` directly -- the deliberately
// ENGLISH-only sibling built for `ConversionWorkspace`'s own picker (see
// that property's own doc comment, `CaptureModels.swift`: "V2's... otherwise
// -English UI must never show..."). Reusing it here made this
// session-creation sheet show "Jel: No filter" even in Hungarian ("Signal"
// itself already translates to "Jel"; the selected value did not) -- unlike
// `ConversionWorkspace`, this sheet is meant to follow the app's own
// language. `fileprivate` rather than changing `.displayName` itself, so
// `ConversionWorkspace`'s intentionally-English picker stays untouched.
// `captureDisplayName`/`captureSensorMode`/`captureSignalMode` themselves
// (the STORED values `CaptureGroupDraft` actually persists) are unaffected
// -- only this picker's rendered text changes. Same "resolve the phrase
// eagerly through NSLocalizedString" shape as
// `SeriesSensorMode.localizedText`/`SeriesPassband.localizedText`
// (`InspectorView.swift`).
fileprivate extension SensorMode {
    var localizedDisplayName: String {
        NSLocalizedString(displayName, bundle: .main, comment: "")
    }
}

fileprivate extension SignalMode {
    var localizedDisplayName: String {
        NSLocalizedString(displayName, bundle: .main, comment: "")
    }
}
