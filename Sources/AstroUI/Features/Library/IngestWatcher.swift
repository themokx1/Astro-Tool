import AppKit
import AstroApplication
import AstroCore
import Foundation
import Observation

/// V3 pre-stack program, section 5.1 (Ingest-figyelő): hides `NSWorkspace`
/// behind a protocol so `IngestWatcherTests` can simulate a mount/unmount
/// synchronously, without a real volume -- the exact seam the spec's own
/// test plan calls for ("szintetikus kötet-mountolás szimulációja
/// (protokoll mögé rejtett `NSWorkspace`)"). The production implementation
/// below is the direct analogue of `AppState.startVolumeMountObserverIfNeeded`
/// (`Sources/AstroToolApp/AppState.swift`) -- same notification, same
/// "register once" shape -- just exposed as an injectable dependency instead
/// of a private method on a concrete class.
/// Deliberately NOT itself `@MainActor` -- only the two handler PARAMETERS
/// are, so a plain, non-isolated conformer (`NSWorkspaceIngestVolumeMonitor`
/// below) never has its own stored properties/`deinit` forced into actor
/// isolation just for holding two `NSObjectProtocol` observer tokens (which
/// are not `Sendable`, and don't need to be -- they're only ever touched
/// from the main thread in practice, `queue: .main` guarantees that, but the
/// type system has no way to know it without `MainActor.assumeIsolated`
/// below doing the asserting explicitly).
public protocol IngestVolumeMonitor: AnyObject {
    func startObservingMounts(_ handler: @escaping @MainActor (URL) -> Void)
    func startObservingUnmounts(_ handler: @escaping @MainActor (URL) -> Void)
}

/// Production `IngestVolumeMonitor`: `NSWorkspace.didMountNotification`/
/// `.didUnmountNotification`, delivered on the `.main` `OperationQueue` --
/// `MainActor.assumeIsolated` is sound here specifically because `queue:
/// .main` guarantees the block itself already runs on the main thread, the
/// same reasoning that lets this avoid a `Task { @MainActor in ... }` hop
/// (and the extra one-runloop-turn delay that would add) for every mount
/// event.
public final class NSWorkspaceIngestVolumeMonitor: IngestVolumeMonitor {
    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?

    public init() {}

    public func startObservingMounts(_ handler: @escaping @MainActor (URL) -> Void) {
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { handler(url) }
        }
    }

    public func startObservingUnmounts(_ handler: @escaping @MainActor (URL) -> Void) {
        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { handler(url) }
        }
    }

    deinit {
        if let mountObserver { NSWorkspace.shared.notificationCenter.removeObserver(mountObserver) }
        if let unmountObserver { NSWorkspace.shared.notificationCenter.removeObserver(unmountObserver) }
    }
}

/// V3 pre-stack program, section 5.1 (Ingest-figyelő): watches for a mounted
/// capture card/network share and, when one looks real (`IngestVolumeClassifier`)
/// and the toggle is on (`IngestWatcherSettings.enabledDefaultsKey`), runs the
/// SAME engines the manual wizard already uses (`CaptureImportScanner.scan`,
/// `CaptureBurstGrouper.group`, `IngestSuggestionEngine.matchProject`) to
/// build a `Candidate` a Home card can offer -- "burst-csoportok már megvannak,
/// session-javaslat és projekt-hozzárendelés már ki van töltve, csak jóvá
/// kell hagyni".
///
/// Owns none of the actual import: everything here is read-only inspection
/// of the SOURCE volume. Accepting the candidate hands its `discovered`
/// files/`sessionPrefill` straight to `CaptureImportStore`'s prefilled
/// initializer, which still runs the entire existing preview/confirm/copy
/// pipeline untouched.
///
/// State lives in memory only (`AstroConfig`/the index DB are never touched
/// here), per the spec's own "Adat/séma" note for this feature -- restarting
/// the app simply forgets which volumes were already offered.
@MainActor
@Observable
public final class IngestWatcher: @unchecked Sendable {
    /// Everything the watcher needs from the currently-open library to
    /// decide "is this volume the library's own" and to run
    /// `IngestSuggestionEngine.matchProject` -- refreshed by
    /// `updateLibraryContext(_:)` whenever the host screen's own library
    /// state changes (mirrors `HomeStore.configure`'s own refresh points).
    public struct LibraryContext: Equatable, Sendable {
        public let rootURL: URL
        public let accessMode: LibraryAccessMode
        public let indexedFolders: [String]
        public let existingProjects: [ProjectRecord]

        public init(
            rootURL: URL,
            accessMode: LibraryAccessMode,
            indexedFolders: [String],
            existingProjects: [ProjectRecord]
        ) {
            self.rootURL = rootURL
            self.accessMode = accessMode
            self.indexedFolders = indexedFolders
            self.existingProjects = existingProjects
        }
    }

    /// One mounted, classified-as-real capture source, ready for the Home
    /// card to offer. `sessionPrefill` is `nil` whenever
    /// `IngestSuggestionEngine.matchProject` found nothing unambiguous --
    /// the wizard then opens with its Destination step exactly as empty as
    /// it is today, never a guessed project.
    public struct Candidate: Identifiable, Equatable, Sendable {
        public var id: String { volume.path }
        public let volume: ImportSourceVolume
        public let discovered: [DiscoveredCaptureFile]
        public let groups: [CaptureFileGroup]
        public let sessionPrefill: SessionCreationPrefill?

        public init(
            volume: ImportSourceVolume,
            discovered: [DiscoveredCaptureFile],
            groups: [CaptureFileGroup],
            sessionPrefill: SessionCreationPrefill?
        ) {
            self.volume = volume
            self.discovered = discovered
            self.groups = groups
            self.sessionPrefill = sessionPrefill
        }
    }

    /// `nil` means "nothing to offer right now" -- the Home card provider's
    /// own "nothing real, nothing shown" contract.
    public private(set) var candidate: Candidate?

    private let monitor: IngestVolumeMonitor
    private let isEnabled: @Sendable () -> Bool
    private let classify: @Sendable (URL) -> Bool
    private let scan: @Sendable (URL) throws -> [DiscoveredCaptureFile]
    private let matchProject: @Sendable (String, [ProjectRecord]) -> IngestSuggestionEngine.ProjectMatch?
    /// Resolves a library root's own containing volume path -- injectable
    /// (like `classify`/`scan`/`matchProject` above) because the production
    /// implementation depends on `URL.resourceValues(forKeys:)` actually
    /// resolving against a REAL, currently-mounted path; a test's synthetic
    /// `rootURL` (never an actual directory on disk) can't exercise that
    /// resolution honestly, so `IngestWatcherTests` supplies its own.
    private let libraryVolumePath: @Sendable (URL) -> String

    /// Public so the Home card (`IngestHomeCardProvider`) can read the same
    /// rootURL/accessMode/indexedFolders/existingProjects it needs to build
    /// the pre-loaded `CaptureImportView` sheet, without a second, parallel
    /// place that stores the same four values.
    public private(set) var libraryContext: LibraryContext?
    /// Volumes a candidate was already published for, THIS launch -- cleared
    /// on unmount, so a genuine unplug/replug can re-offer, but a single
    /// still-mounted volume is never offered twice in a row (the spec's own
    /// "ne ajánlja fel ugyanazt kétszer").
    private var offeredVolumePaths: Set<String> = []
    /// A scan runs detached and can finish after its volume was unmounted or
    /// the open-library context changed. The per-path token lets the main
    /// actor discard that stale result instead of resurrecting a candidate
    /// for a source that is no longer valid.
    private var pendingVolumeScans: [String: UUID] = [:]
    private var started = false

    public init(
        monitor: IngestVolumeMonitor = NSWorkspaceIngestVolumeMonitor(),
        isEnabled: @escaping @Sendable () -> Bool = {
            UserDefaults.standard.bool(forKey: IngestWatcherSettings.enabledDefaultsKey)
        },
        classify: @escaping @Sendable (URL) -> Bool = { IngestVolumeClassifier.isLikelyCaptureVolume(at: $0) },
        scan: @escaping @Sendable (URL) throws -> [DiscoveredCaptureFile] = { try CaptureImportScanner.scan(sourceRoot: $0) },
        matchProject: @escaping @Sendable (String, [ProjectRecord]) -> IngestSuggestionEngine.ProjectMatch? =
            IngestSuggestionEngine.matchProject,
        libraryVolumePath: @escaping @Sendable (URL) -> String = { rootURL in
            (try? rootURL.resourceValues(forKeys: [.volumeURLKey]))?.volume?.standardizedFileURL.path ?? "/"
        }
    ) {
        self.monitor = monitor
        self.isEnabled = isEnabled
        self.classify = classify
        self.scan = scan
        self.matchProject = matchProject
        self.libraryVolumePath = libraryVolumePath
    }

    /// Registers the mount/unmount observers -- idempotent, same "guard
    /// against a second registration" shape
    /// `AppState.startVolumeMountObserverIfNeeded` uses, since a host view's
    /// `body`/`onAppear` can legitimately call this more than once across
    /// the app's lifetime.
    public func start() {
        guard !started else { return }
        started = true
        monitor.startObservingMounts { [weak self] url in
            self?.handleMount(url)
        }
        monitor.startObservingUnmounts { [weak self] url in
            self?.handleUnmount(url)
        }
    }

    public func updateLibraryContext(_ context: LibraryContext?) {
        if libraryContext != context {
            pendingVolumeScans.removeAll()
            offeredVolumePaths.removeAll()
            candidate = nil
        }
        libraryContext = context
    }

    /// The banner's "Not now" action -- clears the candidate WITHOUT adding
    /// it back to `offeredVolumePaths` removal, so it stays gone until that
    /// volume is unmounted and mounted again.
    public func dismissCandidate() {
        candidate = nil
    }

    /// Called once the owner opens the pre-filled wizard for this candidate
    /// (whether or not they finish importing) -- same "don't re-offer what
    /// was already acted on" reasoning as `dismissCandidate()`.
    public func markCandidateHandled() {
        candidate = nil
    }

    private func handleMount(_ url: URL) {
        guard isEnabled() else { return }
        let standardizedPath = url.standardizedFileURL.path
        guard standardizedPath.hasPrefix("/Volumes/") else { return }
        guard let context = libraryContext else { return }
        guard standardizedPath != libraryVolumePath(context.rootURL) else { return }
        guard !offeredVolumePaths.contains(standardizedPath) else { return }
        guard pendingVolumeScans[standardizedPath] == nil else { return }
        let scanToken = UUID()
        pendingVolumeScans[standardizedPath] = scanToken

        let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
        let volume = ImportSourceVolume(name: name, path: standardizedPath)
        let projects = context.existingProjects
        let classifyFn = classify
        let scanFn = scan
        let matchFn = matchProject

        // `.detached`: classification/scanning walk a real filesystem
        // (potentially a slow network share or a large card) -- must never
        // block the main actor, same reasoning `CaptureImportStore
        // .chooseSource`'s own `Task.detached` comment documents for the
        // manual wizard's identical scan call.
        Task.detached { [weak self] in
            let candidate: Candidate?
            if classifyFn(volume.url), let discovered = try? scanFn(volume.url), !discovered.isEmpty {
                let groups = CaptureBurstGrouper.group(discovered)
                let match = matchFn(volume.name, projects)
                let prefill = match.map { SessionCreationPrefill.project($0.project) }
                candidate = Candidate(
                    volume: volume, discovered: discovered, groups: groups, sessionPrefill: prefill
                )
            } else {
                candidate = nil
            }
            await self?.finishScan(path: standardizedPath, token: scanToken, candidate: candidate)
        }
    }

    private func finishScan(path: String, token: UUID, candidate: Candidate?) {
        guard pendingVolumeScans[path] == token else { return }
        pendingVolumeScans.removeValue(forKey: path)
        guard let candidate else { return }
        offeredVolumePaths.insert(candidate.volume.path)
        self.candidate = candidate
    }

    private func handleUnmount(_ url: URL) {
        let standardizedPath = url.standardizedFileURL.path
        pendingVolumeScans.removeValue(forKey: standardizedPath)
        offeredVolumePaths.remove(standardizedPath)
        if candidate?.volume.path == standardizedPath {
            candidate = nil
        }
    }
}
