import AstroApplication
import AstroCore
import SwiftUI

/// The card-import wizard's own steps, in order. Modeled as a plain
/// `Int`-backed enum (not a state machine type with per-step payloads) the
/// same way `ConversionWorkspace`'s own step progression is -- every step's
/// actual data lives on `CaptureImportStore` itself, this only tracks which
/// one is showing.
public enum CaptureImportStep: Int, CaseIterable, Sendable {
    case source
    case classify
    case destination
    case preview
    case copy
    case receipt
}

/// A thread-safe progress box for the copy step's `CaptureImportCommand
/// .copy` call -- same shape `LibraryHealthStore`'s own
/// `HealthOperationProgressBox` uses to bridge a synchronous progress
/// callback (called from inside `OperationHost.run`'s detached task) to
/// `OperationHost.relayProgress`'s polling read.
private final class CaptureImportProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _completed: Int64 = 0
    private var _total: Int64 = 0
    func update(completed: Int, total: Int) {
        lock.lock(); _completed = Int64(completed); _total = Int64(total); lock.unlock()
    }
    var current: (completed: Int64, total: Int64) {
        lock.lock(); defer { lock.unlock() }
        return (_completed, _total)
    }
}

/// Backs `CaptureImportView`: the owner's own most-important workflow --
/// "plug in the ASI Air storage and the Canon R8, build the dedicated
/// capture folders in a few clicks, and copy the files in". Composes with
/// the SAME machinery the "New Session" sheet already ships
/// (`NewSessionStore`/`SessionCreationCommand` for the destination step,
/// via `destinationStore` below) rather than re-implementing any of it, and
/// adds exactly one new thing: the copy half, via
/// `CaptureImportCommand`/`WriteGuard.copyCaptureFile`.
///
/// The source card is NEVER touched -- every step here only ever reads from
/// `selectedSourceURL`'s subtree; nothing in this store deletes, moves, or
/// offers to clear anything on the card.
@MainActor
@Observable
public final class CaptureImportStore {
    public var step: CaptureImportStep = .source

    // MARK: Step 1 -- Source

    public private(set) var mountedVolumes: [ImportSourceVolume] = []
    public private(set) var selectedSourceURL: URL?
    public var isChoosingFolder = false
    public private(set) var isScanning = false
    public private(set) var scanErrorKey: LocalizedStringKey?

    // MARK: Step 2 -- Classify

    public private(set) var discovered: [DiscoveredCaptureFile] = []
    /// `discovered` split into shooting bursts by `CaptureBurstGrouper` --
    /// the Classify step's own unit of decision (owner feedback W4-1b: "azok
    /// egyértelműen majd egy kategóriába fognak tartozni", they'll clearly
    /// belong to one category). Recomputed once per scan; exclude/include
    /// and role overrides never reshuffle group membership, only which of a
    /// group's files count as "active" for it.
    public private(set) var groups: [CaptureFileGroup] = []
    public var roleOverrides: [String: FrameRole] = [:]
    public var excludedIDs: Set<String> = []
    /// Which groups the Classify list currently shows expanded to their
    /// individual files -- the brief's "individual files expandable for
    /// override/exclude".
    public var expandedGroupIDs: Set<String> = []
    /// Selected List rows, each either `"group:<groupID>"` or
    /// `"file:<fileID>"` -- a single selection set over BOTH row kinds
    /// (`ClassifyRow` in `CaptureImportView`) so one "Set Role"/"Exclude"/
    /// "Include" toolbar resolves either a whole group or one expanded
    /// file the same way, via `fileIDs(forSelectedRows:)` below.
    public var selectedIDs: Set<String> = []

    // MARK: Step 3 -- Destination (reuses `NewSessionStore` verbatim)

    public let destinationStore: NewSessionStore
    public let existingProjects: [ProjectRecord]

    // MARK: Step 4 -- Preview

    public private(set) var preview: CaptureImportPreview?
    public private(set) var previewErrorKey: LocalizedStringKey?

    // MARK: Step 5 -- Copy

    public private(set) var isCopying = false
    public private(set) var copyErrorKey: LocalizedStringKey?

    // MARK: Step 6 -- Receipt

    public private(set) var receipt: CaptureImportReceipt?

    public let rootURL: URL
    public let accessMode: LibraryAccessMode

    public init(
        rootURL: URL,
        accessMode: LibraryAccessMode,
        indexedFolders: [String],
        existingProjects: [ProjectRecord],
        mountedVolumes: [ImportSourceVolume]? = nil,
        // V3 pre-stack program, section 5.1 (Ingest-figyelő): `nil` for
        // every existing call site (zero behavior change) -- the Home
        // banner's pre-loaded entry point below is the only caller that
        // ever supplies one, via `IngestSuggestionEngine.matchProject`'s
        // unambiguous project match.
        sessionPrefill: SessionCreationPrefill? = nil
    ) {
        self.rootURL = rootURL
        self.accessMode = accessMode
        self.existingProjects = existingProjects
        self.destinationStore = NewSessionStore(
            rootURL: rootURL, accessMode: accessMode, indexedFolders: indexedFolders, prefill: sessionPrefill
        )
        // Every byte this wizard writes lands under a capture's own
        // lights/flats/darks/biases branch (`WriteGuard.copyCaptureFile`
        // refuses anywhere else) -- so unlike the plain "New Session" sheet,
        // a capture is never optional here, and the toggle for it is never
        // shown.
        destinationStore.createsCapture = true
        self.mountedVolumes = mountedVolumes ?? ImportSourceVolumeLister.listMountedVolumes(libraryRootURL: rootURL)
    }

    /// V3 pre-stack program, section 5.1 (Ingest-figyelő): the Home banner's
    /// pre-loaded entry point -- `IngestWatcher` already ran
    /// `CaptureImportScanner.scan`/`IngestSuggestionEngine.matchProject` for
    /// this exact volume, so this skips straight past the Source step by
    /// reusing `recordScan(_:)` VERBATIM (same burst grouping, same
    /// "unresolved role" gate, same jump to `.classify`) -- a pre-loaded run
    /// and a manually-scanned run can never disagree about what counts as
    /// ready to classify, because they share the one code path.
    public convenience init(
        prefilling rootURL: URL,
        accessMode: LibraryAccessMode,
        indexedFolders: [String],
        existingProjects: [ProjectRecord],
        sourceURL: URL,
        discovered: [DiscoveredCaptureFile],
        sessionPrefill: SessionCreationPrefill?
    ) {
        self.init(
            rootURL: rootURL, accessMode: accessMode, indexedFolders: indexedFolders,
            existingProjects: existingProjects, sessionPrefill: sessionPrefill
        )
        selectedSourceURL = sourceURL
        recordScan(discovered)
    }

    // MARK: - Step 1 actions

    public func chooseSource(_ url: URL) {
        selectedSourceURL = url
        scanErrorKey = nil
        isScanning = true
        // `.detached`: a card's own recursive directory walk (thousands of
        // files on a real SD card) is synchronous, blocking I/O --
        // `CaptureImportScanner.scan` must never run on the main actor, the
        // same reasoning every other filesystem-walking store in this app
        // (`OnboardingStore.openAndScan`, `LibraryScanner` callers generally)
        // already follows.
        Task.detached { [weak self] in
            do {
                let files = try CaptureImportScanner.scan(sourceRoot: url)
                await self?.recordScan(files)
            } catch {
                await self?.recordScanFailure()
            }
        }
    }

    private func recordScan(_ files: [DiscoveredCaptureFile]) {
        discovered = files
        groups = CaptureBurstGrouper.group(files)
        roleOverrides = [:]
        excludedIDs = []
        expandedGroupIDs = []
        selectedIDs = []
        isScanning = false
        if files.isEmpty {
            scanErrorKey = "No .fit/.fits/.cr3 capture files were found there."
            return
        }
        prefillDestinationDate()
        step = .classify
    }

    private func recordScanFailure() {
        isScanning = false
        scanErrorKey = "AstroTool could not read that location."
    }

    /// Prefills the destination date from the earliest capture date any
    /// scanned file reports -- the owner's brief: "date default from the
    /// files' own capture dates". `NewSessionStore.dateText` remains a
    /// perfectly normal, user-editable field afterward; this only supplies
    /// its starting value.
    private func prefillDestinationDate() {
        guard let earliest = discovered.compactMap(\.captureDate).min() else { return }
        destinationStore.dateText = earliest
        destinationStore.refreshPreview()
    }

    // MARK: - Step 2 (Classify) derived state

    public var activeFiles: [DiscoveredCaptureFile] {
        discovered.filter { !excludedIDs.contains($0.id) }
    }

    public func resolvedRole(for file: DiscoveredCaptureFile) -> FrameRole? {
        roleOverrides[file.id] ?? file.proposedRole
    }

    /// Files still needing a human decision -- neither proposed a role by
    /// the scanner's own content-based classifier nor resolved by hand yet.
    /// The Classify step cannot be left while this is non-empty: an
    /// unresolved file must be either assigned a role or excluded, never
    /// silently carried forward as a guess.
    public var unresolvedCount: Int {
        activeFiles.filter { resolvedRole(for: $0) == nil }.count
    }

    public var canProceedPastClassify: Bool {
        !activeFiles.isEmpty && unresolvedCount == 0
    }

    public func assignRole(_ role: FrameRole, to ids: Set<String>) {
        for id in ids { roleOverrides[id] = role }
    }

    public func exclude(_ ids: Set<String>) {
        excludedIDs.formUnion(ids)
        selectedIDs.subtract(ids)
    }

    public func include(_ ids: Set<String>) {
        excludedIDs.subtract(ids)
    }

    /// The exact items `CaptureImportCommand.preview`/`.copy` will use --
    /// every active file paired with its resolved role. Unaffected by
    /// grouping: `CaptureImportCommand` never sees a group, only the
    /// per-file `roleOverrides` groups expand into (see
    /// `fileIDs(forSelectedRows:)`/`assignRole(_:toGroups:)` below).
    public var resolvedItems: [CaptureImportItem] {
        CaptureImportItem.resolved(from: activeFiles, overrides: roleOverrides)
    }

    // MARK: - Step 2 (Classify) group-level derived state and actions

    /// Files in `group` not excluded -- the group's own `activeFiles`.
    public func activeFiles(in group: CaptureFileGroup) -> [DiscoveredCaptureFile] {
        group.files.filter { !excludedIDs.contains($0.id) }
    }

    /// The role every ACTIVE file in `group` currently resolves to (override
    /// or proposal), when they all agree -- `nil` when the group is fully
    /// excluded, has no active files, or its active files currently resolve
    /// to different roles ("mixed", shown as unresolved rather than picking
    /// one to hide the disagreement). A FITS group whose files all proposed
    /// the same `IMAGETYP` role resolves here automatically, with no
    /// override needed, via the same per-file `resolvedRole(for:)` fallback
    /// every file already uses -- grouping surfaces that agreement, it
    /// doesn't compute a new one.
    public func resolvedRole(for group: CaptureFileGroup) -> FrameRole? {
        let active = activeFiles(in: group)
        guard !active.isEmpty else { return nil }
        let roles = Set(active.map { resolvedRole(for: $0) })
        guard roles.count == 1, let only = roles.first else { return nil }
        return only
    }

    /// `true` once EVERY file in `group` -- not just the active ones -- has
    /// been excluded by hand. Distinguished from "no active files" only in
    /// how the row reads to the user ("Excluded" vs "Unclassified"); both
    /// states leave the group's row with nothing left to resolve.
    public func isGroupFullyExcluded(_ group: CaptureFileGroup) -> Bool {
        !group.files.isEmpty && group.files.allSatisfy { excludedIDs.contains($0.id) }
    }

    /// Active files in `group` still needing a role -- mirrors
    /// `unresolvedCount`'s per-file definition, scoped to one group, so a
    /// row can show "3 unclassified" instead of forcing an expand to find
    /// out.
    public func unresolvedCount(in group: CaptureFileGroup) -> Int {
        activeFiles(in: group).filter { resolvedRole(for: $0) == nil }.count
    }

    /// A hint the Classify row may show next to "Unclassified" -- never
    /// applied on its own (the brief: "always displayed as a suggestion the
    /// user confirms, never silently applied"). `nil` once the group already
    /// has a resolved role (nothing left to suggest), otherwise the FITS
    /// agreement (`agreedProposedRole`, already surfaced by
    /// `resolvedRole(for:)` above and so `nil` here since a resolved role
    /// means this method is never asked for one) or the CR3 exposure-based
    /// hint from `CaptureExposureRoleHint`.
    public func suggestedRole(for group: CaptureFileGroup) -> FrameRole? {
        guard resolvedRole(for: group) == nil else { return nil }
        return CaptureExposureRoleHint.suggest(medianExposureSeconds: group.exposureSummary?.medianExposureSeconds)
    }

    /// Applies `role` to every file in every named group -- the "tap the
    /// suggested role" shortcut on a group row. Still an explicit user
    /// action (a tap), still routed through the same per-file
    /// `assignRole(_:to:)` every OTHER role assignment uses; never called
    /// automatically from `suggestedRole(for:)` itself.
    public func assignRole(_ role: FrameRole, toGroups groupIDs: Set<String>) {
        let ids = groups.filter { groupIDs.contains($0.id) }.reduce(into: Set<String>()) { $0.formUnion($1.fileIDs) }
        assignRole(role, to: ids)
    }

    public func toggleExpanded(_ groupID: String) {
        if expandedGroupIDs.contains(groupID) {
            expandedGroupIDs.remove(groupID)
        } else {
            expandedGroupIDs.insert(groupID)
        }
    }

    /// Resolves the Classify list's own row-selection ids
    /// (`"group:<id>"`/`"file:<id>"`, see `selectedIDs`'s own doc comment)
    /// into the underlying FILE ids the existing per-file
    /// `assignRole(_:to:)`/`exclude(_:)`/`include(_:)` already operate on --
    /// the one seam between "the UI selects rows" and "the engine only ever
    /// sees files", so a selected group expands to every one of its files
    /// and a selected individual (expanded) file contributes just itself.
    /// Pure and independently testable: this is what proves a group-level
    /// role assignment reaches `CaptureImportItem.resolved`'s per-file input
    /// correctly, without needing to drive the SwiftUI list at all.
    public func fileIDs(forSelectedRows rowIDs: Set<String>) -> Set<String> {
        var result: Set<String> = []
        for rowID in rowIDs {
            if let groupID = Self.groupID(fromRowID: rowID) {
                if let group = groups.first(where: { $0.id == groupID }) {
                    result.formUnion(group.fileIDs)
                }
            } else if let fileID = Self.fileID(fromRowID: rowID) {
                result.insert(fileID)
            }
        }
        return result
    }

    // `nonisolated`: pure string formatting/parsing with no actor state --
    // `ClassifyRow.id` (`CaptureImportView.swift`) calls these from a
    // non-`@MainActor` context (an `Identifiable` conformance on a plain
    // `enum`), which cannot synchronously call an isolated member of this
    // `@MainActor` class otherwise.
    public nonisolated static func groupRowID(_ groupID: String) -> String { "group:\(groupID)" }
    public nonisolated static func fileRowID(_ fileID: String) -> String { "file:\(fileID)" }
    private static func groupID(fromRowID rowID: String) -> String? {
        rowID.hasPrefix("group:") ? String(rowID.dropFirst("group:".count)) : nil
    }
    private static func fileID(fromRowID rowID: String) -> String? {
        rowID.hasPrefix("file:") ? String(rowID.dropFirst("file:".count)) : nil
    }

    // MARK: - Step 3 -> 4

    /// Runs the SAME `NewSessionStore.create` the "New Session" sheet's own
    /// button calls, then computes this wizard's own copy preview against
    /// whatever session/capture it just created (or added to). Never builds
    /// the session tree itself -- that entire step is `NewSessionStore`'s.
    public func createDestinationStructure(operationHost: OperationHost) async {
        await destinationStore.create(operationHost: operationHost)
        guard let receipt = destinationStore.receipt, let slug = receipt.captureSlug else { return }
        do {
            preview = try CaptureImportCommand.preview(
                items: resolvedItems, root: rootURL,
                target: receipt.targetFolder, date: receipt.date, slug: slug
            )
            previewErrorKey = nil
            step = .preview
        } catch {
            previewErrorKey = "AstroTool could not preview the copy."
        }
    }

    // MARK: - Step 5 (Copy)

    public func runCopy(operationHost: OperationHost, runScan: @escaping () -> Void) async {
        guard let preview, !isCopying else { return }
        isCopying = true
        copyErrorKey = nil
        step = .copy
        let items = resolvedItems
        let root = rootURL
        let accessMode = accessMode
        let box = CaptureImportProgressBox()
        let kind = OperationKind.importCapture(target: "\(preview.target)/\(preview.date)/\(preview.slug)")
        let title = "\(OperationHost.localized("Copying capture files")) \(preview.target)/\(preview.date)"

        let id = await operationHost.run(kind: kind, title: title, cancellation: .cooperative) { [weak self] in
            let result = try CaptureImportCommand.copy(
                items: items, root: root, accessMode: accessMode,
                target: preview.target, date: preview.date, slug: preview.slug,
                progress: { completed, total in box.update(completed: completed, total: total) },
                shouldCancel: { Task.isCancelled }
            )
            await self?.recordReceipt(result)
        }
        operationHost.relayProgress(id: id) {
            let progress = box.current
            return OperationProgress(completed: progress.completed, total: progress.total > 0 ? progress.total : nil)
        }
        _ = await operationHost.outcome(of: id)
        isCopying = false
        if receipt == nil {
            copyErrorKey = "AstroTool could not copy the files. The source card was not modified."
            step = .preview
        }
    }

    private func recordReceipt(_ receipt: CaptureImportReceipt) {
        self.receipt = receipt
        step = .receipt
    }
}

/// The card-import wizard's one sheet -- entry points: Home's toolbar action
/// and the Library section's own toolbar action both present this same
/// route (`AppRoute.PresentationRoute.importCapture`), exactly the way
/// `.newNight` already presents one `NewSessionView` for three separate
/// entry points.
public struct CaptureImportView: View {
    @State private var store: CaptureImportStore
    let dismiss: () -> Void
    let runScan: () -> Void
    let importCompleted: () -> Void
    /// W-fix (item 3): `store` is `@State`, so it dies the moment this view
    /// is unmounted (e.g. the guided first-success journey backing out to
    /// its own `.importOffer` step) -- a caller that needs to remember past
    /// this view's lifetime whether "Create Structure" actually wrote a
    /// session/capture tree has nowhere else to learn that. Defaults to a
    /// no-op for the other two call sites (`V2RootView`, `IngestHomeCard`),
    /// which have no such outer journey to keep honest.
    var structureCreated: (_ targetFolder: String, _ date: String, _ captureSlug: String?) -> Void = { _, _, _ in }
    /// Mirrors `structureCreated` for the wizard's own Undo, so a caller
    /// that recorded the structure's creation can also un-record it once
    /// the user removes it again before leaving.
    var structureUndone: () -> Void = {}
    @Environment(OperationHost.self) private var operationHost

    public init(
        rootURL: URL,
        accessMode: LibraryAccessMode,
        indexedFolders: [String],
        existingProjects: [ProjectRecord],
        dismiss: @escaping () -> Void,
        runScan: @escaping () -> Void,
        importCompleted: @escaping () -> Void = {},
        structureCreated: @escaping (_ targetFolder: String, _ date: String, _ captureSlug: String?) -> Void = { _, _, _ in },
        structureUndone: @escaping () -> Void = {}
    ) {
        _store = State(initialValue: CaptureImportStore(
            rootURL: rootURL, accessMode: accessMode,
            indexedFolders: indexedFolders, existingProjects: existingProjects
        ))
        self.dismiss = dismiss
        self.runScan = runScan
        self.importCompleted = importCompleted
        self.structureCreated = structureCreated
        self.structureUndone = structureUndone
    }

    /// V3 pre-stack program, section 5.1 (Ingest-figyelő): the Home banner's
    /// entry point -- opens straight into `.classify` with `ingestCandidate`
    /// already scanned/grouped/matched by `IngestWatcher`, instead of the
    /// Source step every other entry point starts from.
    public init(
        rootURL: URL,
        accessMode: LibraryAccessMode,
        indexedFolders: [String],
        existingProjects: [ProjectRecord],
        ingestCandidate: IngestWatcher.Candidate,
        dismiss: @escaping () -> Void,
        runScan: @escaping () -> Void,
        importCompleted: @escaping () -> Void = {}
    ) {
        _store = State(initialValue: CaptureImportStore(
            prefilling: rootURL, accessMode: accessMode, indexedFolders: indexedFolders,
            existingProjects: existingProjects, sourceURL: ingestCandidate.volume.url,
            discovered: ingestCandidate.discovered, sessionPrefill: ingestCandidate.sessionPrefill
        ))
        self.dismiss = dismiss
        self.runScan = runScan
        self.importCompleted = importCompleted
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            header
            Divider()
            switch store.step {
            case .source: sourceStep
            case .classify: classifyStep
            case .destination: destinationStep
            case .preview: previewStep
            case .copy: copyStep
            case .receipt: receiptStep
            }
        }
        .padding(AstroTokens.Spacing.standard)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 680)
        .accessibilityIdentifier("v2.capture-import")
    }

    private var header: some View {
        HStack {
            Image(systemName: "sdcard").font(.title).foregroundStyle(AstroTokens.Color.accent)
            VStack(alignment: .leading) {
                Text("Import from Card").font(.title2.weight(.semibold))
                Text(stepSubtitle).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
        }
    }

    private var stepSubtitle: LocalizedStringKey {
        switch store.step {
        case .source: "Source"
        case .classify: "Classify"
        case .destination: "Destination"
        case .preview: "Preview"
        case .copy: "Copying"
        case .receipt: "Receipt"
        }
    }

    // MARK: - Step 1: Source

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            Text("Choose the ASI Air storage, the camera's SD card, or any folder.")
                .font(.subheadline)
            if store.mountedVolumes.isEmpty {
                Text("No external volumes are mounted right now.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                List(store.mountedVolumes) { volume in
                    Button {
                        store.chooseSource(volume.url)
                    } label: {
                        Label(volume.name, systemImage: "externaldrive")
                    }
                    .buttonStyle(.plain)
                }
                .accessibilityIdentifier("v2.capture-import.volumes")
            }
            Button("Choose a Folder…") { store.isChoosingFolder = true }
                .accessibilityIdentifier("v2.capture-import.choose-folder")
                .fileImporter(
                    isPresented: Binding(
                        get: { store.isChoosingFolder },
                        set: { store.isChoosingFolder = $0 }
                    ),
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    guard case .success(let urls) = result, let url = urls.first else { return }
                    store.chooseSource(url)
                }
            if store.isScanning {
                HStack { ProgressView().controlSize(.small); Text("Scanning…") }
            }
            if let scanErrorKey = store.scanErrorKey {
                Label(scanErrorKey, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AstroTokens.Color.attention)
            }
        }
    }

    // MARK: - Step 2: Classify

    /// One row the Classify `List` renders -- either a group header or,
    /// when that group is expanded (`store.expandedGroupIDs`), one of its
    /// individual files indented underneath it. A flat list of these (built
    /// by `classifyRows` below) rather than a nested `List`/`DisclosureGroup`
    /// tree keeps this a single, flat `List` -- the shape the rest of this
    /// app's own outline-style lists already use, and the one this file's
    /// own design gates assume (no `List` nested inside another `List`).
    private enum ClassifyRow: Identifiable {
        case group(CaptureFileGroup)
        case file(DiscoveredCaptureFile)

        var id: String {
            switch self {
            case .group(let group): CaptureImportStore.groupRowID(group.id)
            case .file(let file): CaptureImportStore.fileRowID(file.id)
            }
        }
    }

    /// `store.groups`, each followed by its own files when expanded --
    /// recomputed on every body evaluation from already-in-memory arrays
    /// (no sort, no I/O), so this never re-sorts a `List`/`Table` from
    /// inside `body` in the way the design gates forbid.
    private var classifyRows: [ClassifyRow] {
        store.groups.flatMap { group -> [ClassifyRow] in
            var rows: [ClassifyRow] = [.group(group)]
            if store.expandedGroupIDs.contains(group.id) {
                rows += group.files.map { .file($0) }
            }
            return rows
        }
    }

    private var classifyStep: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            HStack {
                Text("\(store.activeFiles.count) files · \(AstroFormat.bytes(store.activeFiles.reduce(0) { $0 + $1.sizeBytes }))")
                    .font(.subheadline.weight(.semibold))
                Text("\(store.groups.count) groups")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if store.unresolvedCount > 0 {
                    Label("\(store.unresolvedCount) unclassified", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(AstroTokens.Color.dataUnclassified)
                }
            }
            List(classifyRows, selection: Binding(
                get: { store.selectedIDs },
                set: { store.selectedIDs = $0 }
            )) { row in
                switch row {
                case .group(let group): groupRow(group)
                case .file(let file): classifyRow(file, indented: true)
                }
            }
            .accessibilityIdentifier("v2.capture-import.groups")

            HStack {
                Menu("Set Role") {
                    Button("Light") { store.assignRole(.light, to: store.fileIDs(forSelectedRows: store.selectedIDs)) }
                    Button("Flat") { store.assignRole(.flat, to: store.fileIDs(forSelectedRows: store.selectedIDs)) }
                    Button("Dark") { store.assignRole(.dark, to: store.fileIDs(forSelectedRows: store.selectedIDs)) }
                    Button("Bias") { store.assignRole(.bias, to: store.fileIDs(forSelectedRows: store.selectedIDs)) }
                }
                .disabled(store.selectedIDs.isEmpty)
                .accessibilityIdentifier("v2.capture-import.set-role")

                Button("Exclude") { store.exclude(store.fileIDs(forSelectedRows: store.selectedIDs)) }
                    .disabled(store.selectedIDs.isEmpty)
                Button("Include") { store.include(store.fileIDs(forSelectedRows: store.selectedIDs)) }
                    .disabled(store.selectedIDs.isEmpty)
                Spacer()
                Button("Continue") { store.step = .destination }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canProceedPastClassify)
                    .accessibilityIdentifier("v2.capture-import.classify-continue")
            }
        }
    }

    /// One group's own row: a representative thumbnail, its file
    /// count/time span/total size, its CR3 Exif summary (or FITS role
    /// agreement) when it has one, and a disclosure control to expand it
    /// into individual files. This is the row the owner's screenshot
    /// couldn't show him at all -- "honnan kéne nekem tudni, hogy valami
    /// light vagy dark vagy flat?" answered by a thumbnail plus exposure/
    /// ISO instead of a bare filename.
    private func groupRow(_ group: CaptureFileGroup) -> some View {
        let role = store.resolvedRole(for: group)
        let suggestion = store.suggestedRole(for: group)
        let isExcluded = store.isGroupFullyExcluded(group)
        let isExpanded = store.expandedGroupIDs.contains(group.id)
        let unresolvedFileCount = store.unresolvedCount(in: group)

        return HStack(alignment: .center, spacing: AstroTokens.Spacing.compact) {
            if let representative = group.representativeFile {
                CaptureImportGroupThumbnail(sourceURL: representative.sourceURL)
            }

            VStack(alignment: .leading, spacing: 2) {
                Self.timeSpanText(group)
                    .font(.callout)
                    .strikethrough(isExcluded)
                Text(verbatim: "\(AstroFormat.bytes(group.totalBytes)) · \(group.commonExtension?.uppercased() ?? "?")")
                    .font(.caption).foregroundStyle(.secondary)
                if let summary = group.exposureSummary {
                    HStack(spacing: 8) {
                        if let median = summary.medianExposureSeconds {
                            labeledValue("Exposure", AstroFormat.exposureSeconds(median))
                        }
                        if let iso = summary.mostCommonISO {
                            labeledValue("ISO", "\(iso)")
                        }
                        if let aperture = summary.mostCommonApertureFNumber {
                            Text(verbatim: "f/\(aperture.formatted(.number.precision(.fractionLength(1))))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if unresolvedFileCount > 0, !isExcluded {
                    Text("\(unresolvedFileCount) unclassified")
                        .font(.caption2).foregroundStyle(AstroTokens.Color.dataUnclassified)
                }
            }

            Spacer()

            if isExcluded {
                Text("Excluded").font(.caption).foregroundStyle(.secondary)
            } else if let role {
                Text(Self.roleLabel(role))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(role == .light ? AstroTokens.Color.dataLight : AstroTokens.Color.dataCalibration)
            } else if let suggestion {
                Button {
                    store.assignRole(suggestion, toGroups: [group.id])
                } label: {
                    Text("suggested: \(Self.roleEnglishName(suggestion))")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AstroTokens.Color.dataUnclassified)
            } else {
                Text("Unclassified")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AstroTokens.Color.dataUnclassified)
            }

            Button {
                store.toggleExpanded(group.id)
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
            // W6-D fix: this chevron only calls `toggleExpanded(_:)` --
            // it expands the group to list its individual files, it never
            // splits anything. "Split Group" was simply the wrong label,
            // in either language.
            .help(isExpanded ? "Collapse Group" : "Expand Group")
            .accessibilityIdentifier("v2.capture-import.group.expand.\(group.id)")
        }
    }

    private func labeledValue(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(verbatim: value).font(.caption2.monospacedDigit())
        }
    }

    /// `"N files · HH:mm–HH:mm"`, as a real `Text` (not a verbatim string)
    /// so "files" itself translates via the `"%lld files · %@–%@"` hu.lproj
    /// entry -- the group's own file count and capture span, in the
    /// camera's own clock (see `timeOfDayFormatter`'s own doc comment for
    /// why this is UTC-labeled rather than the device's local timezone).
    private static func timeSpanText(_ group: CaptureFileGroup) -> Text {
        guard let first = group.firstCaptureInstant, let last = group.lastCaptureInstant else {
            return Text("\(group.fileCount) files")
        }
        let start = timeOfDayFormatter.string(from: first)
        if first == last {
            return Text("\(group.fileCount) files · \(start)")
        }
        let end = timeOfDayFormatter.string(from: last)
        return Text("\(group.fileCount) files · \(start)–\(end)")
    }

    /// `DATE-OBS`/Exif `DateTimeOriginal` carry no timezone at all -- every
    /// other consumer in this codebase (`CaptureImportScanner`,
    /// `SessionTimeline.parseDateObs`) already treats that raw clock
    /// reading as if it were UTC purely to get consistent `Date` arithmetic,
    /// never converting it to the device's own timezone. Formatting with
    /// `timeZone = UTC` here undoes that label and shows the exact clock
    /// reading the camera/mount wrote, rather than shifting it to wherever
    /// this Mac happens to be configured -- the number a photographer
    /// checking their own capture log actually expects to see.
    private static let timeOfDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func classifyRow(_ file: DiscoveredCaptureFile, indented: Bool = false) -> some View {
        let role = store.resolvedRole(for: file)
        let isExcluded = store.excludedIDs.contains(file.id)
        return HStack {
            if indented {
                Spacer().frame(width: AstroTokens.Spacing.section)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.relativeSourcePath).font(.callout)
                    .strikethrough(isExcluded)
                Text(verbatim: "\(AstroFormat.bytes(file.sizeBytes)) · \(file.captureDate ?? "?")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isExcluded {
                Text("Excluded").font(.caption).foregroundStyle(.secondary)
            } else if let role {
                Text(Self.roleLabel(role))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(role == .light ? AstroTokens.Color.dataLight : AstroTokens.Color.dataCalibration)
            } else {
                Text("Unclassified")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AstroTokens.Color.dataUnclassified)
            }
        }
    }

    private static func roleLabel(_ role: FrameRole) -> LocalizedStringKey {
        switch role {
        case .light: "Light"
        case .flat: "Flat"
        case .dark: "Dark"
        case .bias: "Bias"
        default: "Unclassified"
        }
    }

    /// Same four names as `roleLabel` above, as plain `String` -- for
    /// interpolating into a `LocalizedStringKey` format string (`"suggested:
    /// %@"`) as its `%@` argument. Role names stay English by this file's
    /// own established convention (`LocalizationCoverageTests.allowlist`'s
    /// own doc comment); this is a SECOND spelling of that same convention
    /// only because a `LocalizedStringKey` cannot itself be interpolated
    /// into another `LocalizedStringKey` the way a `String` can.
    private static func roleEnglishName(_ role: FrameRole) -> String {
        switch role {
        case .light: "Light"
        case .flat: "Flat"
        case .dark: "Dark"
        case .bias: "Bias"
        default: "Unclassified"
        }
    }

    // MARK: - Step 3: Destination

    /// A thin form bound directly to `NewSessionStore`'s own public fields
    /// -- composes with the exact store/command the "New Session" sheet
    /// uses (never re-implements any of its target/date/capture
    /// validation), while staying this wizard's own layout: a capture is
    /// always being created here, so (unlike `NewSessionView`) the "Create a
    /// capture" toggle is never shown at all.
    private var destinationStep: some View {
        let destination = store.destinationStore
        return VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            Picker("Target", selection: Binding(
                get: { destination.usesExistingProject },
                set: { destination.usesExistingProject = $0; destination.refreshPreview() }
            )) {
                Text("Existing Project").tag(true)
                Text("Custom Target").tag(false)
            }
            .pickerStyle(.segmented)

            if destination.usesExistingProject {
                if store.existingProjects.isEmpty {
                    Text("No projects yet — type a catalog number and target name instead.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Project", selection: Binding(
                        get: { store.existingProjects.first { $0.catalogID == destination.catalogRaw }?.id },
                        set: { id in
                            guard let id, let project = store.existingProjects.first(where: { $0.id == id }) else { return }
                            destination.selectExistingProject(project)
                        }
                    )) {
                        Text("Choose a project").tag(Optional<UUID>.none)
                        ForEach(store.existingProjects, id: \.id) { project in
                            Text(project.displayName).tag(Optional(project.id))
                        }
                    }
                }
            } else {
                TextField("Catalog number (optional, e.g. C 14)", text: Binding(
                    get: { destination.catalogRaw },
                    set: { destination.catalogRaw = $0; destination.refreshPreview() }
                )).textFieldStyle(.roundedBorder)
                TextField("Target name", text: Binding(
                    get: { destination.nameRaw },
                    set: { destination.nameRaw = $0; destination.refreshPreview() }
                )).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Date (YYYY-MM-DD)", text: Binding(
                    get: { destination.dateText },
                    set: { destination.dateText = $0; destination.refreshPreview() }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                if let source = store.discovered.first?.captureDateSource {
                    Text(dateSourceLabel(source))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            TextField("Capture name", text: Binding(
                get: { destination.captureDisplayName },
                set: { destination.captureDisplayName = $0; destination.refreshPreview() }
            )).textFieldStyle(.roundedBorder)

            if let preview = destination.preview, preview.sessionAlreadyExists {
                Label("This session already exists — adding another capture.", systemImage: "moon.stars.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let reason = destination.disabledReasonKey {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(AstroTokens.Color.attention)
            }
            if let previewErrorKey = store.previewErrorKey {
                Label(previewErrorKey, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(AstroTokens.Color.attention)
            }
            // W-fix (item 2): "Create Structure" used to be able to fail
            // with zero visible feedback -- `command.create(...)`'s failure
            // was only ever announced by a toast on `OperationHost`'s
            // overlay, which is mounted on the window BEHIND this modal
            // wizard's sheet. `NewSessionStore.create` now surfaces the same
            // failure inline via `createErrorMessage`.
            if let createErrorMessage = destination.createErrorMessage {
                Label("AstroTool could not create the structure: \(createErrorMessage)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(AstroTokens.Color.critical)
                    .accessibilityIdentifier("v2.capture-import.create-structure-error")
            }

            HStack {
                Button("Back") { store.step = .classify }
                Spacer()
                if destination.isCreating { ProgressView().controlSize(.small) }
                Button("Create Structure") {
                    Task {
                        await store.createDestinationStructure(operationHost: operationHost)
                        // W-fix (item 3): tell a caller that outlives this
                        // view (the guided first-success journey's own
                        // coordinator) that real folders now exist, before
                        // this view's `@State` store has any chance to die.
                        if let receipt = destination.receipt, let slug = receipt.captureSlug {
                            structureCreated(receipt.targetFolder, receipt.date, slug)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!destination.canCreate)
                .accessibilityIdentifier("v2.capture-import.create-structure")
            }
        }
    }

    private func dateSourceLabel(_ source: CaptureDateSource) -> LocalizedStringKey {
        switch source {
        case .fitsDateObs: "Date suggested from the FITS DATE-OBS header."
        case .exifDateTaken: "Date suggested from the photo's Exif date."
        case .fileModificationDate: "Date suggested from the file's own modification date."
        }
    }

    // MARK: - Step 4: Preview

    private var previewStep: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            if let preview = store.preview {
                HStack {
                    Text("\(preview.entries.count) files · \(AstroFormat.bytes(preview.totalBytesToCopy))")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if preview.collisionCount > 0 {
                        Label("\(preview.collisionCount) already at destination", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(AstroTokens.Color.attention)
                    }
                }
                List(preview.entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: entry.relativeSourcePath).font(.caption)
                            Text(verbatim: entry.destinationRelativePath)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.collides {
                            Text("Skip").font(.caption).foregroundStyle(AstroTokens.Color.attention)
                        } else {
                            Text(verbatim: AstroFormat.bytes(entry.sizeBytes))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("v2.capture-import.preview-list")
            }
            Text("The source card is left untouched — this only copies.")
                .font(.caption).foregroundStyle(.secondary)
            if let copyErrorKey = store.copyErrorKey {
                Label(copyErrorKey, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AstroTokens.Color.attention)
            }
            // W-fix (item 3): "Create Structure" already wrote a real
            // session/capture folder tree by the time this step shows --
            // this is the user's one chance to remove it again, from
            // INSIDE this view, before backing out destroys `store` (its
            // `@State`) and the receipt this undo needs along with it.
            // Reuses `NewSessionStore.undo` verbatim, the same call
            // `NewSessionView`'s own Undo button makes.
            if store.destinationStore.isUndone {
                Label("Undone — the empty folders were removed.", systemImage: "arrow.uturn.backward.circle")
                    .font(.caption).foregroundStyle(AstroTokens.Color.attention)
            } else if store.destinationStore.receipt != nil {
                HStack {
                    if store.destinationStore.isUndoing { ProgressView().controlSize(.small) }
                    Button("Undo") {
                        Task {
                            await store.destinationStore.undo(operationHost: operationHost)
                            if store.destinationStore.isUndone { structureUndone() }
                        }
                    }
                    .disabled(store.destinationStore.isUndoing)
                    .accessibilityIdentifier("v2.capture-import.undo-structure")
                }
            }
            if let undoErrorKey = store.destinationStore.undoErrorKey {
                Text(undoErrorKey).font(.caption).foregroundStyle(AstroTokens.Color.attention)
            }
            HStack {
                Button("Back") { store.step = .destination }
                Spacer()
                Button("Start Copy") {
                    Task { await store.runCopy(operationHost: operationHost, runScan: runScan) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.preview == nil || store.destinationStore.isUndone)
                .accessibilityIdentifier("v2.capture-import.start-copy")
            }
        }
    }

    // MARK: - Step 5: Copy

    private var copyStep: some View {
        VStack(alignment: .center, spacing: AstroTokens.Spacing.standard) {
            Spacer()
            ProgressView()
            Text("Copying files — the source card is not modified.")
                .font(.subheadline)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step 6: Receipt

    private var receiptStep: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            if let receipt = store.receipt {
                // W-fix (item 1): a copy stopped mid-way through (the
                // toolbar's Activity popover can cancel this operation like
                // any other) still produced real, checksum-verified copies
                // -- `receipt.wasCancelled` says so honestly instead of the
                // ordinary "files copied" success banner, which would bury
                // the fact that some files were never attempted at all.
                if receipt.wasCancelled {
                    Label(
                        "Copy stopped — \(receipt.copied.count) files already copied and verified, \(notCopiedCount(receipt)) not copied.",
                        systemImage: "stop.circle"
                    )
                    .font(.headline).foregroundStyle(AstroTokens.Color.attention)
                } else {
                    Label("\(receipt.copied.count) files copied · \(AstroFormat.bytes(receipt.totalBytesCopied))", systemImage: "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(AstroTokens.Color.ok)
                }
                Text(verbatim: "sessions/\(receipt.target)/\(receipt.date)/captures/\(receipt.slug)")
                    .font(.callout.monospaced()).textSelection(.enabled)

                if !receipt.skippedCollisions.isEmpty {
                    Text("\(receipt.skippedCollisions.count) files already existed at the destination and were skipped.")
                        .font(.caption).foregroundStyle(AstroTokens.Color.attention)
                }
                if !receipt.failed.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(receipt.failed.count) files failed to copy:")
                            .font(.caption.weight(.semibold)).foregroundStyle(AstroTokens.Color.critical)
                        ForEach(receipt.failed, id: \.sourceURL) { failure in
                            HStack(spacing: 0) {
                                Text(verbatim: "\(failure.sourceURL.lastPathComponent): ")
                                failureReasonText(failure)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Label(
                    "Every copy was verified with a checksum against the source.",
                    systemImage: "checkmark.seal"
                )
                .font(.caption).foregroundStyle(.secondary)
                Label("The source card is untouched.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Label(
                    "This copy cannot be undone from here — the source is untouched on the card.",
                    systemImage: "arrow.uturn.backward.circle"
                )
                .font(.caption).foregroundStyle(.secondary)

                Label(
                    "The session will appear once the next library scan runs.",
                    systemImage: "info.circle"
                )
                .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button("Run Scan Now") {
                        runScan()
                        importCompleted()
                        dismiss()
                    }
                    .accessibilityIdentifier("v2.capture-import.run-scan")
                    Spacer()
                    Button("Done") {
                        importCompleted()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .accessibilityIdentifier("v2.capture-import.receipt")
    }

    /// W-fix (item 6): a failed copy's reason used to always render
    /// `failure.reason` verbatim -- for an `AstroError`-caused failure,
    /// that is `error.localizedDescription`, a real English sentence but
    /// still English no matter the app's own language, since `AstroError
    /// .errorDescription` deliberately never translates (see its own doc
    /// comment). When `failure.astroError` is set, this renders the SAME
    /// translated sentence `LibraryWelcomeView`'s own access-problem screen
    /// shows for that error, via its `accessProblemText(for:)`; otherwise
    /// it falls back to the plain English `reason` (already a fixed,
    /// localized sentence for the one non-`AstroError` failure this engine
    /// produces -- the checksum mismatch).
    private func failureReasonText(_ failure: CaptureImportReceipt.FailedFile) -> Text {
        if let astroError = failure.astroError {
            return LibraryWelcomeView.accessProblemText(for: astroError)
        }
        return Text(verbatim: failure.reason)
    }

    /// How many of the items submitted to `CaptureImportCommand.copy` never
    /// got a resolved outcome at all -- the ones a cancellation stopped the
    /// loop before reaching, distinct from `skippedCollisions`/`failed`
    /// (both of which DID get processed, just not copied). `store.preview`
    /// still holds the exact item count `copy` was given, since it is never
    /// cleared once the copy step starts.
    private func notCopiedCount(_ receipt: CaptureImportReceipt) -> Int {
        let total = store.preview?.entries.count ?? receipt.copied.count
        let accounted = receipt.copied.count + receipt.skippedCollisions.count + receipt.failed.count
        return max(total - accounted, 0)
    }
}
