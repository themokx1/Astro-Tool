import AstroApplication
import AstroCore
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

public enum OnboardingPhase: Equatable, Sendable {
    case chooseLibrary
    case scanning(progress: LibraryScanProgress?)
    case summary(LibrarySnapshot)
    case accessProblem(LibraryAccessProblem)

    public var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }

    public var summary: LibrarySnapshot? {
        if case .summary(let snapshot) = self { return snapshot }
        return nil
    }

    /// Plain-string fallback, kept for callers that only want a message --
    /// today that is `V2RootView`'s `LibraryAccessProblemBanner` (main-shell
    /// restore failures), which is out of Task 14's file list and still
    /// renders this as an untranslated `Text(String)`. `LibraryWelcomeView`
    /// itself no longer reads this: it switches on the `.accessProblem`
    /// payload directly so it can render a translatable `Text` and derive
    /// its buttons from `recovery` (see `LibraryAccessProblem`).
    public var accessProblemMessage: String? {
        if case .accessProblem(let problem) = self { return problem.fallbackMessage }
        return nil
    }

    public var progress: Double? {
        if case .scanning(let progress) = self { return progress?.fraction }
        return nil
    }

    public var scanProgress: LibraryScanProgress? {
        if case .scanning(let progress) = self { return progress }
        return nil
    }
}

public enum OnboardingCompletionChoice: Equatable, Sendable {
    case library
    case preferences
}

public struct OnboardingSessionClient: Sendable {
    public let accessMode: LibraryAccessMode
    private let scanOperation: @Sendable (
        @escaping @Sendable (LibraryScanProgress) -> Void
    ) async throws -> LibrarySnapshot

    public init(
        accessMode: LibraryAccessMode,
        scan: @escaping @Sendable () async throws -> LibrarySnapshot
    ) {
        self.accessMode = accessMode
        scanOperation = { _ in try await scan() }
    }

    public init(
        accessMode: LibraryAccessMode,
        scan: @escaping @Sendable (
            @escaping @Sendable (LibraryScanProgress) -> Void
        ) async throws -> LibrarySnapshot
    ) {
        self.accessMode = accessMode
        scanOperation = scan
    }

    public func scan(
        progress: @escaping @Sendable (LibraryScanProgress) -> Void
    ) async throws -> LibrarySnapshot {
        try await scanOperation(progress)
    }
}

public struct OnboardingSessionFactory: Sendable {
    private let makeSession: @Sendable (URL, AppStoragePaths) async throws -> OnboardingSessionClient

    public init(
        _ makeSession: @escaping @Sendable (URL, AppStoragePaths) async throws
            -> OnboardingSessionClient
    ) {
        self.makeSession = makeSession
    }

    public func callAsFunction(
        root: URL,
        storage: AppStoragePaths
    ) async throws -> OnboardingSessionClient {
        try await makeSession(root, storage)
    }

    public static let production = OnboardingSessionFactory { root, storage in
        let session = try await LibrarySession.open(rootURL: root, storage: storage)
        return OnboardingSessionClient(
            accessMode: await session.accessMode,
            scan: { progress in
                try await session.scan { update in
                    progress(update)
                }
            }
        )
    }
}

public struct OnboardingStorageFactory: Sendable {
    private let makeStorage: @Sendable (URL) throws -> AppStoragePaths

    public init(_ makeStorage: @escaping @Sendable (URL) throws -> AppStoragePaths) {
        self.makeStorage = makeStorage
    }

    public func callAsFunction(root: URL) throws -> AppStoragePaths {
        try makeStorage(root)
    }

    public static let production = OnboardingStorageFactory { root in
        try AppStoragePaths.production(
            libraryID: LibraryIdentity(rootURL: root),
            libraryRoot: root
        )
    }
}

public struct SecurityScopedAccess: Sendable {
    private let startAccess: @Sendable (URL) -> Bool
    private let stopAccess: @Sendable (URL) -> Void

    public init(
        start: @escaping @Sendable (URL) -> Bool,
        stop: @escaping @Sendable (URL) -> Void
    ) {
        startAccess = start
        stopAccess = stop
    }

    func start(_ url: URL) -> Bool {
        startAccess(url)
    }

    func stop(_ url: URL) {
        stopAccess(url)
    }

    public static let production = SecurityScopedAccess(
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )

    public static let inactive = SecurityScopedAccess(
        start: { _ in false },
        stop: { _ in }
    )
}

public struct LibraryBookmarkStore: @unchecked Sendable {
    private let loadURL: () -> URL?
    private let saveURL: (URL) -> Void
    private let clearURL: () -> Void

    public init(
        load: @escaping () -> URL?,
        save: @escaping (URL) -> Void,
        clear: @escaping () -> Void
    ) {
        loadURL = load
        saveURL = save
        clearURL = clear
    }

    public func load() -> URL? { loadURL()?.standardizedFileURL }
    public func save(_ url: URL) { saveURL(url.standardizedFileURL) }
    public func clear() { clearURL() }

    public static func production(defaults: UserDefaults = .standard) -> Self {
        let key = "v2.library.securityScopedBookmark"
        let legacyKey = "rootBookmark"
        return Self(
            load: {
                let isLegacy = defaults.data(forKey: key) == nil
                guard let data = defaults.data(forKey: key)
                    ?? defaults.data(forKey: legacyKey)
                else { return nil }
                var isStale = false
                guard let url = try? URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) else {
                    defaults.removeObject(forKey: key)
                    if isLegacy { defaults.removeObject(forKey: legacyKey) }
                    return nil
                }
                if isLegacy { defaults.set(data, forKey: key) }
                if isStale,
                   let refreshed = try? url.bookmarkData(
                       options: .withSecurityScope,
                       includingResourceValuesForKeys: nil,
                       relativeTo: nil
                   ) {
                    defaults.set(refreshed, forKey: key)
                }
                return url
            },
            save: { url in
                guard let data = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) else { return }
                defaults.set(data, forKey: key)
            },
            clear: { defaults.removeObject(forKey: key) }
        )
    }

    public static let inactive = Self(load: { nil }, save: { _ in }, clear: {})
}

public enum OnboardingStoreError: Error, Equatable, Sendable {
    case mutationAccessUnsupported
    case notDirectory
}

/// What went wrong opening or scanning a library -- carries enough
/// structure that the sentence AND the buttons come from the same source
/// of truth (Task 14, 2026-08-16 owner screenshot). Before this, the dialog
/// derived its message from a raw `error.localizedDescription` (Swift's
/// default `"AstroCore.AstroError error 4"` for a non-`LocalizedError`
/// type) while its buttons were fixed regardless of what actually failed --
/// so a database error got told to re-pick a folder, a fix that could not
/// work. Now a wrong diagnosis becomes a wrong BUTTON, which people notice,
/// instead of only a wrong sentence, which people skim past.
public enum LibraryAccessProblem: Equatable, Sendable {
    /// The chosen path is not a directory (a single file was picked or
    /// dropped) -- not an `AstroError`, so it is modeled here directly
    /// instead of forcing an artificial `AstroError` case for it.
    case notDirectory
    case astro(AstroError)
    /// A failure that is neither of the above (should be rare to never in
    /// production -- every real open/scan failure throws `AstroError` or
    /// `OnboardingStoreError.notDirectory`). Carries no payload on purpose:
    /// there is nothing honest to say about an error this code does not
    /// model, so it gets a generic sentence rather than a raw Swift dump.
    case other

    init(catching error: any Error) {
        if error as? OnboardingStoreError == .notDirectory {
            self = .notDirectory
        } else if let astroError = error as? AstroError {
            self = .astro(astroError)
        } else {
            self = .other
        }
    }

    public var recovery: AstroErrorRecovery {
        switch self {
        case .notDirectory: .rechooseLibrary
        case .astro(let error): error.recovery
        case .other: .rechooseLibrary
        }
    }

    /// Plain, untranslated fallback -- see `OnboardingPhase.accessProblemMessage`'s
    /// doc comment for who still reads this.
    public var fallbackMessage: String {
        switch self {
        case .notDirectory:
            "Choose a folder that contains your image library. Individual files cannot be scanned as a library."
        case .astro(let error):
            error.errorDescription ?? "AstroTool could not complete this action."
        case .other:
            "AstroTool could not complete this action. Try again, or choose a different library."
        }
    }
}

@MainActor
@Observable
public final class OnboardingStore {
    public private(set) var phase: OnboardingPhase
    public private(set) var selectedRoot: URL?
    public private(set) var indexDatabaseURL: URL?
    public private(set) var completionChoice: OnboardingCompletionChoice?

    public let accessMode: LibraryAccessMode = .readOnly
    public let personalizationIsOptional = true

    private let sessionFactory: OnboardingSessionFactory
    private let storageFactory: OnboardingStorageFactory
    private let securityScopedAccess: SecurityScopedAccess
    private let bookmarkStore: LibraryBookmarkStore
    private var activeOperationID: UUID?
    private var activeSecurityScopedURL: URL?

    public init(
        sessionFactory: OnboardingSessionFactory = .production,
        storageFactory: OnboardingStorageFactory = .production,
        securityScopedAccess: SecurityScopedAccess = .production,
        bookmarkStore: LibraryBookmarkStore = .production()
    ) {
        self.sessionFactory = sessionFactory
        self.storageFactory = storageFactory
        self.securityScopedAccess = securityScopedAccess
        self.bookmarkStore = bookmarkStore
        phase = .chooseLibrary
        selectedRoot = nil
        indexDatabaseURL = nil
        completionChoice = nil
        activeOperationID = nil
        activeSecurityScopedURL = nil
    }

    public func openAndScan(_ rootURL: URL) async throws {
        let operationID = UUID()
        let root = rootURL.standardizedFileURL
        releaseActiveSecurityScope()
        activeOperationID = operationID
        selectedRoot = root
        completionChoice = nil
        phase = .scanning(progress: nil)

        let didStartScopedAccess = securityScopedAccess.start(rootURL)
        var shouldStopScopedAccess = didStartScopedAccess
        defer {
            if shouldStopScopedAccess {
                securityScopedAccess.stop(rootURL)
            }
        }

        do {
            try Task.checkCancellation()
            guard Self.isDirectory(root) else {
                throw OnboardingStoreError.notDirectory
            }
            let storage = try storageFactory(root: root)
            guard isActive(operationID) else { return }
            indexDatabaseURL = storage.indexDatabase
            let session = try await sessionFactory(root: root, storage: storage)
            guard isActive(operationID) else { return }
            guard session.accessMode == .readOnly else {
                throw OnboardingStoreError.mutationAccessUnsupported
            }
            let progressBuffer = LatestOnboardingProgress()
            let progressPoller = ProgressRelay.run(
                while: { !Task.isCancelled },
                read: { progressBuffer.peek() },
                apply: { [weak self] progress in
                    guard let progress else { return }
                    self?.receiveProgress(progress, operationID: operationID)
                }
            )
            defer { progressPoller.cancel() }
            let snapshot = try await session.scan(progress: { progress in
                progressBuffer.store(progress)
            })
            try Task.checkCancellation()
            if let progress = progressBuffer.peek() {
                receiveProgress(progress, operationID: operationID)
            }
            guard isActive(operationID) else { return }
            phase = .summary(snapshot)
            bookmarkStore.save(root)
            if didStartScopedAccess {
                activeSecurityScopedURL = rootURL
                shouldStopScopedAccess = false
            }
        } catch is CancellationError {
            if isActive(operationID) {
                activeOperationID = nil
                resetToLibraryChoice()
            }
            throw CancellationError()
        } catch {
            if isActive(operationID) {
                phase = .accessProblem(LibraryAccessProblem(catching: error))
            }
            throw error
        }
    }

    public func returnToLibraryChoice() {
        activeOperationID = nil
        releaseActiveSecurityScope()
        resetToLibraryChoice()
    }

    @discardableResult
    public func restoreSavedLibrary() async throws -> Bool {
        guard phase == .chooseLibrary, let root = bookmarkStore.load() else { return false }
        do {
            try await openAndScan(root)
            return true
        } catch {
            bookmarkStore.clear()
            throw error
        }
    }

    /// Runs `openAndScan(_:)` registered with `operationHost` -- so the very
    /// first (launch-time) scan of a library shows up in `activeOperations`
    /// (toolbar progress + Cancel), exactly like `rescan(operationHost:)`
    /// already does for a manual re-scan. Production launch/library-pick call
    /// sites should prefer this over the raw `openAndScan(_:)`, which today is
    /// only ever observed by the onboarding sheet (`LibraryWelcomeView`) --
    /// not presented at all outside UI tests, so its progress/failure was
    /// otherwise invisible (V2 UI/UX audit section 2.2). Fire-and-forget, same
    /// contract as `run(kind:title:work:)` itself: returns once the operation
    /// is registered, not once the scan finishes -- `phase`/`selectedRoot`
    /// still report the eventual outcome, same as calling `openAndScan`
    /// directly.
    public func openAndScan(_ rootURL: URL, through operationHost: OperationHost) async {
        await runScan(rootURL, through: operationHost, clearBookmarkOnFailure: false)
    }

    /// The `operationHost`-routed counterpart to `restoreSavedLibrary()` --
    /// same "no saved bookmark, or already past `.chooseLibrary`" no-op
    /// contract, and the same "clear the bookmark so a permanently broken
    /// path doesn't keep silently failing at every future launch" behavior,
    /// just surfaced through the toolbar instead of invisibly.
    @discardableResult
    public func restoreSavedLibrary(through operationHost: OperationHost) async -> Bool {
        guard phase == .chooseLibrary, let root = bookmarkStore.load() else { return false }
        await runScan(root, through: operationHost, clearBookmarkOnFailure: true)
        return true
    }

    private func runScan(_ rootURL: URL, through operationHost: OperationHost, clearBookmarkOnFailure: Bool) async {
        let kind = OperationKind.scan(library: rootURL.lastPathComponent)
        guard !operationHost.activeOperations.contains(where: { $0.kind == kind }) else { return }
        let id = await operationHost.run(
            kind: kind,
            title: "Scanning \(rootURL.lastPathComponent)",
            cancellation: .cooperative
        ) { [weak self] in
            do {
                try await self?.openAndScan(rootURL)
            } catch {
                if clearBookmarkOnFailure { self?.bookmarkStore.clear() }
                throw error
            }
        }
        // `ProgressRelay.run`/`relayProgress`'s own `read` closure is plain
        // `@Sendable`, not `@MainActor` -- it cannot touch `phase` (MainActor-
        // isolated) directly, only a thread-safe box like the scan's own
        // internal `LatestOnboardingProgress` (not reachable from out here,
        // since `openAndScan(_:)` owns it privately). A small `@MainActor`
        // poll loop reads `phase.scanProgress` directly instead -- same
        // throttle cadence as `ProgressRelay.defaultInterval`, stops on its
        // own once `id` leaves `activeOperations` (operation finished or was
        // cancelled), so there is nothing to store/cancel explicitly here.
        Task { @MainActor [weak self, weak operationHost] in
            while let operationHost, operationHost.activeOperations.contains(where: { $0.id == id }) {
                if let self, let progress = self.phase.scanProgress {
                    _ = await operationHost.reportProgress(
                        id: id,
                        completed: Int64(progress.scanned),
                        total: progress.total.map(Int64.init)
                    )
                }
                try? await Task.sleep(for: ProgressRelay.defaultInterval)
            }
        }
    }

    public func cancelActiveScan() {
        guard phase.isScanning else { return }
        activeOperationID = nil
        resetToLibraryChoice()
    }

    /// Re-runs the same read-only scan pipeline `openAndScan` uses, against
    /// the *already open* `selectedRoot`, through `operationHost.run` -- so
    /// it shows up in `activeOperations`, supports cancel, and reports
    /// progress the same way any other V2 background job does. Unlike
    /// `openAndScan` (which owns picking a fresh library, and so resets to
    /// `.chooseLibrary` if that pick is cancelled or fails), a rescan that
    /// is cancelled or fails leaves `selectedRoot` and the last known-good
    /// `phase.summary` completely untouched -- there is no "choice" to roll
    /// back to, only a refresh that did not complete. `operationHost.run`'s
    /// own failure toast already surfaces a scan error; only the "nothing to
    /// rescan" case posts its own (`.info`) notification here.
    ///
    /// Matches `run(kind:title:work:)`'s own contract: this returns as soon
    /// as the operation is registered, without waiting for the scan itself
    /// to finish -- the progress relay below runs as its own unstructured
    /// task so a slow or gated scan can never block the caller.
    public func rescan(operationHost: OperationHost) async {
        guard let root = selectedRoot else {
            operationHost.notify(.info, message: "Choose a library before rescanning.")
            return
        }

        let kind = OperationKind.scan(library: root.lastPathComponent)
        guard !operationHost.activeOperations.contains(where: { $0.kind == kind }) else {
            operationHost.notify(.info, message: "A rescan of this library is already running.")
            return
        }

        let progressBuffer = LatestOnboardingProgress()
        let id = await operationHost.run(
            kind: kind,
            title: "Rescanning \(root.lastPathComponent)",
            cancellation: .cooperative
        ) { [weak self] in
            guard let self else { return }
            try Task.checkCancellation()
            let storage = try self.storageFactory(root: root)
            let session = try await self.sessionFactory(root: root, storage: storage)
            let snapshot = try await session.scan(progress: { progress in
                progressBuffer.store(progress)
            })
            try Task.checkCancellation()
            await self.applyRescanSnapshot(snapshot, root: root)
        }

        operationHost.relayProgress(id: id) {
            let progress = progressBuffer.peek()
            return OperationProgress(
                completed: Int64(progress?.scanned ?? 0),
                total: progress?.total.map(Int64.init)
            )
        }
    }

    /// Applies a rescan's result -- but only if the library it was scanning
    /// is still the one currently open (a `returnToLibraryChoice()` or a new
    /// `openAndScan` could have superseded it while the rescan was running).
    private func applyRescanSnapshot(_ snapshot: LibrarySnapshot, root: URL) {
        guard selectedRoot == root else { return }
        phase = .summary(snapshot)
    }

    public func continueWithoutPersonalizing() {
        completionChoice = .library
    }

    public func setUpPreferences() {
        completionChoice = .preferences
    }

    private func resetToLibraryChoice() {
        phase = .chooseLibrary
        selectedRoot = nil
        indexDatabaseURL = nil
        completionChoice = nil
    }

    private func releaseActiveSecurityScope() {
        guard let url = activeSecurityScopedURL else { return }
        activeSecurityScopedURL = nil
        securityScopedAccess.stop(url)
    }

    private func isActive(_ operationID: UUID) -> Bool {
        activeOperationID == operationID
    }

    private func receiveProgress(
        _ progress: LibraryScanProgress,
        operationID: UUID
    ) {
        guard isActive(operationID), case .scanning(let current) = phase else { return }
        if let current {
            guard progress.scanned >= current.scanned else { return }
            if current.total != nil, progress.total == nil { return }
            if let currentFraction = current.fraction,
               let nextFraction = progress.fraction,
               nextFraction < currentFraction {
                return
            }
        }
        phase = .scanning(progress: progress)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

}

@MainActor
public struct LibraryWelcomeView: View {
    @Bindable private var store: OnboardingStore
    private let onContinue: () -> Void
    private let onPersonalize: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isChoosingLibrary = false
    @State private var scanTask: Task<Void, Never>?
    @State private var scanOperationID: UUID?
    @State private var isDropTargeted = false

    public init(
        store: OnboardingStore,
        onContinue: @escaping () -> Void,
        onPersonalize: @escaping () -> Void
    ) {
        _store = Bindable(store)
        self.onContinue = onContinue
        self.onPersonalize = onPersonalize
    }

    public var body: some View {
        Group {
            switch store.phase {
            case .chooseLibrary:
                welcome
            case .scanning(let progress):
                FirstScanView(
                    libraryName: store.selectedRoot?.lastPathComponent ?? "Image Library",
                    progress: progress,
                    cancel: cancelScan
                )
            case .summary(let snapshot):
                FirstScanSummaryView(
                    snapshot: snapshot,
                    continueToLibrary: {
                        store.continueWithoutPersonalizing()
                        onContinue()
                    },
                    personalize: {
                        store.setUpPreferences()
                        onPersonalize()
                    }
                )
            case .accessProblem(let problem):
                accessProblem(problem)
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 440)
        .background(AstroTokens.Color.graphite.opacity(0.32))
        .fileImporter(
            isPresented: $isChoosingLibrary,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let root = urls.first else { return }
            beginScan(root)
        }
        .onDisappear {
            cancelScan()
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.spacious) {
            Label("READ-ONLY FIRST SCAN", systemImage: "lock.shield")
                .font(.caption.weight(.semibold))
                .tracking(1.3)
                .foregroundStyle(AstroTokens.Color.spectralBlue)

            VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                Text("Bring your night sky library into focus")
                    .font(.largeTitle.weight(.semibold))
                Text("Choose the folder that contains your astrophotography images. AstroTool reads it locally and builds a separate index for fast browsing.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                safetyRow(
                    "Files stay where they are",
                    detail: "The first scan does not move, rename, or delete images.",
                    systemImage: "photo.on.rectangle.angled"
                )
                safetyRow(
                    "Your library remains read-only",
                    detail: "Only the folder you choose is inspected.",
                    systemImage: "eye"
                )
                safetyRow(
                    "The index stays outside your library",
                    detail: "Derived data is stored in AstroTool’s Application Support and cache folders.",
                    systemImage: "externaldrive.badge.checkmark"
                )
            }
            .padding(AstroTokens.Spacing.standard)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel))
            .overlay {
                RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel)
                    .stroke(isDropTargeted ? AstroTokens.Color.spectralBlue : AstroTokens.Color.hairline, lineWidth: isDropTargeted ? 2 : 1)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let root = urls.first else { return false }
                beginScan(root)
                return true
            } isTargeted: { isDropTargeted = $0 }

            HStack {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("You can also drop a folder above")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Choose Image Library…") {
                    isChoosingLibrary = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(AstroTokens.Spacing.spacious)
    }

    private func safetyRow(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: AstroTokens.Spacing.standard) {
            Image(systemName: systemImage)
                .foregroundStyle(AstroTokens.Color.spectralBlue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func accessProblem(_ problem: LibraryAccessProblem) -> some View {
        ContentUnavailableView {
            Label("Library access needs attention", systemImage: "folder.badge.questionmark")
        } description: {
            Self.accessProblemText(for: problem)
        } actions: {
            recoveryButtons(for: problem.recovery)
            // Task 14: the old "Back" button led to the same place as
            // "Close" for this sheet -- two buttons that dismiss to the
            // same outcome give the user two ways to guess wrong. "Back" is
            // deleted; "Close" stays as the one way out that offers no
            // recovery.
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    /// The dialog's action(s), derived from the error's own `recovery`
    /// instead of being fixed regardless of what failed (Task 14). Each
    /// case's primary action is `.buttonStyle(.borderedProminent)`.
    @ViewBuilder
    private func recoveryButtons(for recovery: AstroErrorRecovery) -> some View {
        switch recovery {
        case .rechooseLibrary:
            Button("Choose Library Again…") { chooseAnotherLibrary() }
                .buttonStyle(.borderedProminent)
            Button("Choose a Different Library…") { chooseAnotherLibrary() }
        case .retry:
            Button("Try Again") { retryAccessProblem() }
                .buttonStyle(.borderedProminent)
            Button("Choose a Different Library…") { chooseAnotherLibrary() }
        case .none:
            Button("Choose a Different Library…") { chooseAnotherLibrary() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func chooseAnotherLibrary() {
        store.returnToLibraryChoice()
        isChoosingLibrary = true
    }

    /// Re-runs the scan against the SAME root that just failed -- the point
    /// of `.retry` (a stale volume mount, a locked database) is that
    /// nothing about the folder choice was wrong, so re-picking it would
    /// not help. Falls back to the folder picker if, somehow, there is no
    /// remembered root to retry.
    private func retryAccessProblem() {
        guard let root = store.selectedRoot else {
            chooseAnotherLibrary()
            return
        }
        beginScan(root)
    }

    /// Maps a failure to translatable, honest copy -- `AstroCore`'s own
    /// `errorDescription` (see `Types.swift`) is a plain, non-translating
    /// `String`, so this switches on the case itself and builds a `Text`
    /// with a `LocalizedStringKey` instead. Unlike some other switch-derived
    /// `Text` in this codebase, these literal `Text("...")` call sites ARE
    /// picked up by `scripts/extract-localizable-strings.swift` (it matches
    /// any literal-first-argument call, even inside a `switch`) -- their
    /// `hu.lproj` entries were added because the extraction script's
    /// `--missing` reported them, not because they were invisible to it.
    private static func accessProblemText(for problem: LibraryAccessProblem) -> Text {
        switch problem {
        case .notDirectory:
            Text("Choose a folder that contains your image library. Individual files cannot be scanned as a library.")
        case .astro(let error):
            accessProblemText(for: error)
        case .other:
            Text("AstroTool could not complete this action. Try again, or choose a different library.")
        }
    }

    private static func accessProblemText(for error: AstroError) -> Text {
        switch error {
        case .accessDenied(let path):
            Text("AstroTool is not allowed to read \(path).")
        case .volumeNotMounted(let path):
            Text("The volume holding \(path) is not mounted.")
        case .pathNotFound(let path):
            Text("\(path) no longer exists.")
        case .corruptFITS(let path, let reason):
            Text("\(path) could not be read as a FITS file: \(reason)")
        case .databaseError(let detail):
            Text("AstroTool's own index could not be read: \(detail)")
        case .writeForbidden(let path):
            Text("Writing to \(path) is not permitted.")
        case .sirilNotFound(let path):
            Text("Siril was not found at \(path).")
        case .invalidInput(let detail):
            Text(detail)
        }
    }

    private func beginScan(_ root: URL) {
        cancelScan()
        let operationID = UUID()
        scanOperationID = operationID
        scanTask = Task {
            defer { finishScanTask(operationID) }
            do {
                try await store.openAndScan(root)
            } catch is CancellationError {
                // Cancellation is an explicit navigation action, not an error state.
            } catch {
                // The store exposes an actionable access state for the view.
            }
        }
    }

    private func cancelScan() {
        scanOperationID = nil
        store.cancelActiveScan()
        let task = scanTask
        scanTask = nil
        task?.cancel()
    }

    private func finishScanTask(_ operationID: UUID) {
        guard scanOperationID == operationID else { return }
        scanOperationID = nil
        scanTask = nil
    }
}

private final class LatestOnboardingProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: LibraryScanProgress?

    func store(_ progress: LibraryScanProgress) {
        lock.withLock { latest = progress }
    }

    /// Non-destructive read of the latest stored value -- unlike a
    /// consuming `take()`, this can be polled repeatedly by `ProgressRelay`
    /// without losing the last known value between ticks that see no new
    /// `store(_:)` call.
    func peek() -> LibraryScanProgress? {
        lock.withLock { latest }
    }
}
