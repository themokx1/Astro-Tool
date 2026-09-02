import AstroApplication
import AstroCore
import AppKit
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

    /// Plain-string fallback -- Task 5b (2026-08-17) removed this property's
    /// last reader (`V2RootView`'s `LibraryAccessProblemBanner`, which used
    /// to render this as an untranslated `Text(String)`; it now reads
    /// `accessProblem` below instead and builds a translatable `Text` via
    /// `LibraryWelcomeView.accessProblemText(for:)`, the same helper this
    /// view's own body uses). Kept for any future caller that genuinely only
    /// wants a plain, non-translating string (a log line, a diagnostics
    /// dump); `LibraryWelcomeView` itself never reads this.
    public var accessProblemMessage: String? {
        if case .accessProblem(let problem) = self { return problem.fallbackMessage }
        return nil
    }

    /// The raw `.accessProblem` payload, for a caller that wants to render
    /// its own translatable copy (see `accessProblemMessage`'s doc comment
    /// for why the plain-string version is no longer enough).
    public var accessProblem: LibraryAccessProblem? {
        if case .accessProblem(let problem) = self { return problem }
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

    /// 2026-09-02 first-run audit, fix G: the plain path is now persisted
    /// alongside the bookmark, and `load` falls back to it. AstroTool is
    /// unsandboxed (there is no entitlements file), so a security-scoped
    /// bookmark is a convenience here, not a requirement -- but
    /// `bookmarkData(options: .withSecurityScope)` can still fail, and when
    /// it did the old `guard ... else { return }` swallowed the failure
    /// entirely: the user re-picked their library at every single launch,
    /// with nothing on screen ever explaining why.
    public static func production(defaults: UserDefaults = .standard) -> Self {
        let key = "v2.library.securityScopedBookmark"
        let legacyKey = "rootBookmark"
        let pathKey = "v2.library.rootPath"
        return Self(
            load: {
                let isLegacy = defaults.data(forKey: key) == nil
                if let data = defaults.data(forKey: key) ?? defaults.data(forKey: legacyKey) {
                    var isStale = false
                    if let url = try? URL(
                        resolvingBookmarkData: data,
                        options: .withSecurityScope,
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    ) {
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
                    }
                    // An unresolvable bookmark is worthless; the plain path
                    // below may still be right (a moved home directory, an
                    // unmounted volume that is back).
                    defaults.removeObject(forKey: key)
                    if isLegacy { defaults.removeObject(forKey: legacyKey) }
                }
                guard let path = defaults.string(forKey: pathKey), !path.isEmpty else { return nil }
                // Returned even when the directory is currently absent: the
                // onboarding store then diagnoses it properly ("the volume
                // holding X is not mounted", with Retry) instead of silently
                // starting up as if no library had ever been chosen. It also
                // only forgets the path when that diagnosis says the path
                // itself is wrong -- see `forgetBookmarkIfPermanentlyWrong`.
                return URL(fileURLWithPath: path, isDirectory: true)
            },
            save: { url in
                defaults.set(url.path, forKey: pathKey)
                let data = (try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )) ?? (try? url.bookmarkData())
                guard let data else { return }
                defaults.set(data, forKey: key)
            },
            clear: {
                defaults.removeObject(forKey: key)
                defaults.removeObject(forKey: legacyKey)
                defaults.removeObject(forKey: pathKey)
            }
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
    /// The chosen folder would contain AstroTool's own private data area
    /// (`AppStoragePaths`/`LibrarySession` refuse to put the index inside
    /// the library it indexes) -- what picking the home folder, `/`, or
    /// `~/Library` produces. 2026-09-02: these used to fall through to
    /// `.other`'s "AstroTool could not complete this action", which named
    /// neither the cause nor a fix.
    case storageInsideLibrary
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
        } else if Self.isStorageInsideLibrary(error) {
            self = .storageInsideLibrary
        } else if let astroError = error as? AstroError {
            self = .astro(astroError)
        } else {
            self = .other
        }
    }

    /// Every shape the "AstroTool's own storage would land inside the
    /// library" refusal can arrive in -- two from `AppStoragePaths.init`
    /// (the storage ROOTS, and the individual destinations under them) and
    /// one from `LibrarySession`, which re-checks the same invariant when it
    /// opens the index.
    private static func isStorageInsideLibrary(_ error: any Error) -> Bool {
        if let storageError = error as? AppStoragePathsError {
            return storageError == .storageRootInsideLibrary
                || storageError == .storageDestinationInsideLibrary
        }
        return error as? LibrarySessionError == .indexDestinationInsideLibrary
    }

    public var recovery: AstroErrorRecovery {
        switch self {
        case .notDirectory: .rechooseLibrary
        case .storageInsideLibrary: .rechooseLibrary
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
        case .storageInsideLibrary:
            "This folder contains AstroTool’s own data folder. Choose a folder that only holds your photos, for example inside Pictures."
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
            if let rootFailure = Self.rootFailure(root) {
                throw rootFailure
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
            forgetBookmarkIfPermanentlyWrong(error)
            throw error
        }
    }

    /// Clears the remembered library ONLY when the failure means the
    /// remembered path itself is the problem (`.rechooseLibrary`). An
    /// unplugged drive or a locked index is `.retry`-class: the path is
    /// still right, it is just unavailable right now, and forgetting it
    /// meant replugging the drive never helped -- the user had to re-pick
    /// the library at every launch.
    /// `nonisolated` because `runScan`'s `operationHost.run` work closure is
    /// not main-actor isolated; everything this touches is `Sendable`.
    private nonisolated func forgetBookmarkIfPermanentlyWrong(_ error: any Error) {
        guard !(error is CancellationError) else { return }
        guard LibraryAccessProblem(catching: error).recovery == .rechooseLibrary else { return }
        bookmarkStore.clear()
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
    /// contract, and the same "clear the bookmark so a permanently WRONG
    /// path doesn't keep silently failing at every future launch" behavior
    /// (see `forgetBookmarkIfPermanentlyWrong`, which keeps the bookmark for
    /// a merely unavailable one), just surfaced through the toolbar instead
    /// of invisibly.
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
            title: "\(OperationHost.localized("Scanning")) \(rootURL.lastPathComponent)",
            cancellation: .cooperative
        ) { [weak self] in
            do {
                try await self?.openAndScan(rootURL)
            } catch {
                if clearBookmarkOnFailure {
                    self?.forgetBookmarkIfPermanentlyWrong(error)
                }
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
            operationHost.notify(.info, message: OperationHost.localized("Choose a library before rescanning."))
            return
        }

        let kind = OperationKind.scan(library: root.lastPathComponent)
        guard !operationHost.activeOperations.contains(where: { $0.kind == kind }) else {
            operationHost.notify(.info, message: OperationHost.localized("A rescan of this library is already running."))
            return
        }

        let progressBuffer = LatestOnboardingProgress()
        let id = await operationHost.run(
            kind: kind,
            title: "\(OperationHost.localized("Rescanning")) \(root.lastPathComponent)",
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

    /// Why the root cannot be opened at all, or `nil` when it is a readable
    /// directory. This used to be a single `isDirectory` check built on
    /// `attributesOfItem`, which fails identically for "a file was picked"
    /// and "there is nothing at this path" -- so an external drive that was
    /// unplugged since the last launch was reported as "individual files
    /// cannot be scanned as a library" and the user was pushed to re-pick a
    /// folder that was never wrong. A missing path now goes through
    /// `AstroCore`'s own `RootErrorClassifier`, the same diagnosis the
    /// scanner already made, so an unmounted volume becomes the `.retry`-class
    /// `volumeNotMounted` ("reconnect the drive") instead.
    static func rootFailure(_ url: URL, fileManager: FileManager = .default) -> (any Error)? {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? nil : OnboardingStoreError.notDirectory
        }
        return RootErrorClassifier.classify(
            rootPath: url.path,
            subpath: nil,
            volumeExists: { fileManager.fileExists(atPath: $0) }
        )
    }

}

@MainActor
public struct LibraryWelcomeView: View {
    @Bindable private var store: OnboardingStore
    private let onContinue: () -> Void
    private let onPersonalize: () -> Void
    private let requestLibraryPicker: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var scanTask: Task<Void, Never>?
    @State private var scanOperationID: UUID?
    @State private var isDropTargeted = false

    public init(
        store: OnboardingStore,
        onContinue: @escaping () -> Void,
        onPersonalize: @escaping () -> Void,
        requestLibraryPicker: (() -> Void)? = nil
    ) {
        _store = Bindable(store)
        self.onContinue = onContinue
        self.onPersonalize = onPersonalize
        self.requestLibraryPicker = requestLibraryPicker
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
                    libraryName: store.selectedRoot?.lastPathComponent ?? "Image Library",
                    continueToLibrary: {
                        store.continueWithoutPersonalizing()
                        onContinue()
                    },
                    personalize: {
                        store.setUpPreferences()
                        onPersonalize()
                    },
                    chooseAnotherFolder: chooseAnotherLibrary
                )
            case .accessProblem(let problem):
                accessProblem(problem)
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 440)
        // Task 7b (2026-08-17): opaque, not the former 32% tint. This is the
        // one page root left that `V2RootView`'s detail column does NOT
        // cover -- it is the onboarding SHEET (presented from `V2RootView`
        // line ~492), a window of its own, so it owns its own backdrop
        // under the same rule: a page root paints `ground` at full opacity,
        // never a partial tint over whatever happens to be behind it.
        .background(AstroTokens.Color.ground)
        .onDisappear {
            cancelScan()
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.spacious) {
            Label("READ-ONLY FIRST SCAN", systemImage: "lock.shield")
                .font(.caption.weight(.semibold))
                .tracking(1.3)
                .foregroundStyle(AstroTokens.Color.accent)

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
            // W2-10 (2026-08-17): was a hand-rolled `.regularMaterial` +
            // `AstroTokens.CornerRadius.panel` + its own edge stroke -- the
            // exact shape `astroRaisedSurface` exists to replace elsewhere.
            // Kept RAISED rather than glass: unlike the marketing tiles in
            // `FirstScanSummaryView`, this well is a functional drop target
            // that needs a legible accent highlight while dragging, and a
            // solid surface reads that state change more clearly than glass
            // would. The highlight itself is now a second overlay on top of
            // the shared treatment's own hairline rather than a replacement
            // for it, using `ConcentricRectangle` (no explicit radius) so it
            // matches the shape `astroRaisedSurface` already published via
            // `.containerShape` instead of repeating the token.
            .astroRaisedSurface()
            .overlay {
                if isDropTargeted {
                    ConcentricRectangle().stroke(AstroTokens.Color.accent, lineWidth: 2)
                }
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
                    chooseLibrary()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("v3.onboarding.choose-library")
            }
        }
        .padding(AstroTokens.Spacing.spacious)
    }

    // W2-10 (2026-08-17): `title`/`detail` used to be plain `String`
    // parameters -- every call site below passes a literal, but the literal
    // is bound to a `String`-typed parameter, so `Text(title)`/`Text(detail)`
    // inside this function still resolve to the verbatim overload and never
    // translate. Same defect class as `MetricCard.title` and
    // `FirstScanSummaryView.countTile`'s own `label`, just one more
    // undetected shape of it (a function parameter, not a stored property,
    // so `V2PolishSurfaceTests.uiTextIsNeverAPlainString` -- which only scans
    // `let`/`var` declarations and enum case associated values -- cannot see
    // it).
    private func safetyRow(_ title: LocalizedStringKey, detail: LocalizedStringKey, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: AstroTokens.Spacing.standard) {
            Image(systemName: systemImage)
                .foregroundStyle(AstroTokens.Color.accent)
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
            recoveryButtons(for: problem)
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
    ///
    /// 2026-09-02: `.storageInsideLibrary` gets its own single action --
    /// `.rechooseLibrary`'s usual pair ("Choose Library Again…" plus
    /// "Choose a Different Library…") both mean the same thing here, and
    /// the honest instruction is narrower: pick a folder that only holds
    /// photos.
    @ViewBuilder
    private func recoveryButtons(for problem: LibraryAccessProblem) -> some View {
        if problem == .storageInsideLibrary {
            Button("Choose Another Folder…") { chooseAnotherLibrary() }
                .buttonStyle(.borderedProminent)
        } else {
            recoveryButtons(for: problem.recovery)
        }
    }

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
        chooseLibrary()
    }

    private func chooseLibrary() {
        if let requestLibraryPicker {
            requestLibraryPicker()
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let root = panel.url else { return }
            Task { @MainActor in beginScan(root) }
        }
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
    ///
    /// Internal rather than `private` as of Task 5b (2026-08-17):
    /// `V2RootView`'s `LibraryAccessProblemBanner` (main-shell restore
    /// failures) now reuses this instead of carrying its own second,
    /// untranslated copy of the same mapping.
    static func accessProblemText(for problem: LibraryAccessProblem) -> Text {
        switch problem {
        case .notDirectory:
            Text("Choose a folder that contains your image library. Individual files cannot be scanned as a library.")
        case .storageInsideLibrary:
            Text("This folder contains AstroTool’s own data folder. Choose a folder that only holds your photos, for example inside Pictures.")
        case .astro(let error):
            accessProblemText(for: error)
        case .other:
            Text("AstroTool could not complete this action. Try again, or choose a different library.")
        }
    }

    static func accessProblemText(for error: AstroError) -> Text {
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
