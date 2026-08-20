import AstroApplication
import AstroCore
import Foundation

/// One capture file `LiveNightFolderLister` found under the watched folder
/// -- deliberately a THIN, stat-only record (no header/Exif read yet): the
/// watcher only pays the cost of opening a file's metadata once that same
/// path has been seen with a STABLE size across two consecutive polls (see
/// `LiveNightWatcher.pollNow()`), so a frame the rig is still writing is
/// never read mid-write.
public struct LiveNightFolderListing: Equatable, Sendable {
    public let url: URL
    public let sizeBytes: Int64
    public let modificationDate: Date

    public init(url: URL, sizeBytes: Int64, modificationDate: Date) {
        self.url = url
        self.sizeBytes = sizeBytes
        self.modificationDate = modificationDate
    }
}

/// V3 pre-stack program, section 5.6 (Élő éjszaka-mód): hides the actual
/// directory walk behind a protocol so `LiveNightWatcherTests` can hand the
/// watcher a synthetic, in-memory file list per poll -- no real timer, no
/// real filesystem, deterministic. `nil` from `listCaptureFiles` means the
/// folder itself is unreachable right now (unmounted share, deleted
/// folder) -- distinct from an empty array, which means "reachable, just
/// nothing new."
public protocol LiveNightFolderLister: Sendable {
    func listCaptureFiles(in folder: URL) -> [LiveNightFolderListing]?
}

/// Production `LiveNightFolderLister`: a plain recursive `FileManager`
/// enumeration filtered to `LibraryScanner.fitsExtensions`/`.rawExtensions`
/// -- the SAME two extension sets `CaptureImportScanner`'s own card-import
/// walk uses, never a second hand-picked list (this codebase's own "same
/// engine, never a copied predicate" rule). Deliberately does NOT open any
/// file (no header parse, no Exif read) -- this is the CHEAP, poll-every-
/// 15-30s half of the pipeline; `LiveNightWatcher.processConfirmedFile`
/// does the expensive per-file read, and only once for genuinely new,
/// size-stable files.
public struct FileManagerLiveNightFolderLister: LiveNightFolderLister {
    public init() {}

    public func listCaptureFiles(in folder: URL) -> [LiveNightFolderListing]? {
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var results: [LiveNightFolderListing] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            ]) else { continue }
            guard values.isDirectory != true, values.isSymbolicLink != true else { continue }
            let ext = url.pathExtension.lowercased()
            guard LibraryScanner.fitsExtensions.contains(ext) || LibraryScanner.rawExtensions.contains(ext) else { continue }
            results.append(LiveNightFolderListing(
                url: url,
                sizeBytes: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            ))
        }
        return results
    }
}

/// V3 pre-stack program, section 5.6 (Élő éjszaka-mód): polls a watched
/// folder (the rig's own mounted share, or any folder the owner points
/// this at) for new capture frames, and folds each genuinely new,
/// no-longer-being-written one into a `LiveNightSessionModel` -- frame
/// count, a `QuickStarProxy` focus proxy for FITS frames only, and a
/// `LiveNightGoalEstimator` ETA once a project match supplies a goal.
///
/// Poll-only, per the spec's own risk section for this feature ("Javaslat:
/// az első verzió induljon poll-only móddal ... és az FSEvents-optimalizáció
/// csak validáció után kerüljön be"): this codebase has no FSEvents/
/// `DispatchSourceFileSystemObject` watcher anywhere yet, and SMB share
/// reliability for such a watcher cannot be validated against the owner's
/// actual rig share from here. A plain periodic directory listing is
/// simpler and more predictable over a network share, and is what this
/// type implements for V3.0; an FSEvents fast path remains a valid future
/// optimization once validated against the real share, never a
/// prerequisite for this feature to ship.
///
/// Owns none of the actual import/library mutation: everything here is
/// read-only inspection of the watched folder, mirroring `IngestWatcher`'s
/// own "owns none of the actual import" contract
/// (`Sources/AstroUI/Features/Library/IngestWatcher.swift`). Reggeli
/// lezáráskor (per spec) the session is simply abandoned here -- the
/// frames it already saw are picked up the ordinary way by the next
/// `LibraryScanner.scan`, never written anywhere by this type.
@MainActor
@Observable
public final class LiveNightWatcher: @unchecked Sendable {
    public struct ProjectGoalInfo: Equatable, Sendable {
        public let project: ProjectRecord
        /// `ProjectAnnotationRecord.integrationGoalHours` for this project --
        /// the SAME V2-native goal value `HomeStore`'s "Continue where it
        /// matters" card and `ProjectsStore.workspaceRows` already surface,
        /// deliberately reused here rather than V1's separate `GoalTag`
        /// string-tag convention (`Sources/AstroCore/Stats/GoalTag.swift`):
        /// `ProjectRecord` carries no tags of its own, and re-deriving a V1
        /// tag lookup for a V2-only card would be exactly the kind of
        /// second, parallel goal representation the V3 program's own
        /// non-negotiables warn against (see the Metaadat-javító section for
        /// the filter-precedence version of this same mistake).
        public let goalHours: Double?

        public init(project: ProjectRecord, goalHours: Double?) {
            self.project = project
            self.goalHours = goalHours
        }
    }

    public struct LibraryContext: Equatable, Sendable {
        public let projectGoals: [ProjectGoalInfo]

        public init(projectGoals: [ProjectGoalInfo]) {
            self.projectGoals = projectGoals
        }
    }

    /// `nil` means "not watching anything right now" -- the Home card
    /// provider's own "nothing real, nothing shown" contract.
    public private(set) var folderURL: URL?
    public private(set) var session = LiveNightSessionModel()
    /// The matched project's own display name, purely for the Home card's
    /// caption -- `nil` whenever `IngestSuggestionEngine.matchProject`
    /// found nothing unambiguous for the watched folder's own name.
    public private(set) var matchedProjectName: String?
    private var goalSeconds: Double?

    private var libraryContext: LibraryContext?
    private let lister: LiveNightFolderLister
    private let readFITSExposureSeconds: @Sendable (URL) -> Double?
    private let readRawMeta: @Sendable (URL) -> (exposureSeconds: Double?, captureDate: Date?)
    private let quickStarProxyRadius: @Sendable (URL) -> Double?
    private let matchProject: @Sendable (String, [ProjectRecord]) -> IngestSuggestionEngine.ProjectMatch?
    private let now: @Sendable () -> Date
    /// No new confirmed frame for longer than this is reported as
    /// `.idleTooLong` -- the spec's own "vége az éjszakának?" state. 20
    /// minutes comfortably exceeds any normal sub-exposure + dither/
    /// download cadence this app's own capture pipelines produce, while
    /// still catching a genuinely stalled/finished session well before
    /// sunrise.
    private let idleThreshold: TimeInterval
    /// Path -> last-seen size, for files not yet confirmed stable. A path
    /// only moves to `confirmedPaths` once the SAME size is observed on two
    /// consecutive polls -- the rig's own still-writing frame must never be
    /// read mid-write.
    private var pendingSizes: [String: Int64] = [:]
    private var confirmedPaths: Set<String> = []
    private var started = false
    private var boundOperationHost: OperationHost?
    private var activeOperationID: UUID?
    private var settingsObserver: NSObjectProtocol?
    private let pollIntervalSeconds: Double

    public init(
        lister: LiveNightFolderLister = FileManagerLiveNightFolderLister(),
        readFITSExposureSeconds: @escaping @Sendable (URL) -> Double? = { url in
            (try? FITSReader.readHeader(url: url)).flatMap { $0.double("EXPTIME") }
        },
        readRawMeta: @escaping @Sendable (URL) -> (exposureSeconds: Double?, captureDate: Date?) = { url in
            let meta = ImageMetaReader.read(url: url)
            let date = meta?.dateTaken.flatMap { SessionTimeline.parseDateObs($0) }
            return (meta?.exposureSeconds, date)
        },
        quickStarProxyRadius: @escaping @Sendable (URL) -> Double? = { url in
            (try? QuickStarProxy.estimate(url: url))?.medianRadiusPixels
        },
        matchProject: @escaping @Sendable (String, [ProjectRecord]) -> IngestSuggestionEngine.ProjectMatch? =
            IngestSuggestionEngine.matchProject,
        now: @escaping @Sendable () -> Date = Date.init,
        idleThreshold: TimeInterval = 20 * 60,
        pollIntervalSeconds: Double = 20
    ) {
        self.lister = lister
        self.readFITSExposureSeconds = readFITSExposureSeconds
        self.readRawMeta = readRawMeta
        self.quickStarProxyRadius = quickStarProxyRadius
        self.matchProject = matchProject
        self.now = now
        self.idleThreshold = idleThreshold
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    public func updateLibraryContext(_ context: LibraryContext?) {
        libraryContext = context
        refreshGoal()
    }

    /// Sets (or clears, with `nil`) the watched folder and resets every
    /// per-session accumulator -- pure state assignment, no `OperationHost`
    /// involved, so tests can drive a session with just this plus
    /// `pollNow()`, never a real timer or a real registered operation.
    public func configureFolder(_ url: URL?) {
        let standardized = url?.standardizedFileURL
        guard folderURL != standardized else { return }
        folderURL = standardized
        session = LiveNightSessionModel()
        pendingSizes = [:]
        confirmedPaths = []
        refreshGoal()
    }

    /// Registers the watch loop with `OperationHost` under `.liveNightWatch`
    /// -- same "every long-running V2 job runs through
    /// `OperationHost.run`" convention `ProjectRatingRunner`/`SirilCLI`-backed
    /// jobs already follow, so the toolbar's Activity popover and its
    /// cancel button work for this exactly like they do for a scan or a
    /// rating pass. The loop itself (`watchLoop`) exits via
    /// `Task.checkCancellation`/`Task.sleep` throwing `CancellationError`,
    /// which `OperationHost.run` already treats as a clean, silent
    /// cancellation rather than a failure.
    public func startWatching(folder: URL, operationHost: OperationHost) async {
        configureFolder(folder)
        let title = OperationHost.localized("Live night watch")
        activeOperationID = await operationHost.run(kind: .liveNightWatch, title: title, cancellation: .cooperative) { [weak self] in
            try await self?.watchLoop()
        }
    }

    public func stopWatching(operationHost: OperationHost) async {
        if let activeOperationID {
            await operationHost.cancel(id: activeOperationID)
        }
        activeOperationID = nil
        configureFolder(nil)
    }

    /// Idempotent, same "guard against a second registration" shape
    /// `IngestWatcher.start()`/`AppState.startVolumeMountObserverIfNeeded`
    /// use: reads the Settings toggle/folder once immediately, then again
    /// on every `UserDefaults` change (the toggle and the folder picker
    /// both live in a DIFFERENT window, Settings ▸ Könyvtár, so this is how
    /// the main window notices either one changing without polling).
    public func start(operationHost: OperationHost) {
        guard !started else { return }
        started = true
        boundOperationHost = operationHost
        Task { @MainActor [weak self] in
            await self?.refreshFromSettings()
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refreshFromSettings() }
        }
    }

    /// Reads `LiveNightWatcherSettings`'s two keys and starts/stops the
    /// watch to match -- called once by `start(operationHost:)` and again
    /// on every subsequent `UserDefaults` change.
    private func refreshFromSettings(defaults: UserDefaults = .standard) async {
        guard let operationHost = boundOperationHost else { return }
        let enabled = defaults.bool(forKey: LiveNightWatcherSettings.enabledDefaultsKey)
        guard enabled, let folder = Self.resolveConfiguredFolder(defaults: defaults) else {
            if folderURL != nil { await stopWatching(operationHost: operationHost) }
            return
        }
        guard folder != folderURL else { return }
        await startWatching(folder: folder, operationHost: operationHost)
    }

    /// Resolves `LiveNightWatcherSettings.folderBookmarkDefaultsKey`'s
    /// security-scoped bookmark (written by `AppState.chooseLiveNightFolder()`)
    /// back into an accessible `URL` -- the same
    /// `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)`
    /// call `AppState`'s own root-folder bookmark resolution uses.
    public static func resolveConfiguredFolder(defaults: UserDefaults = .standard) -> URL? {
        guard let data = defaults.data(forKey: LiveNightWatcherSettings.folderBookmarkDefaultsKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale
        ) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url.standardizedFileURL
    }

    private func refreshGoal() {
        guard let folderURL, let libraryContext else {
            goalSeconds = nil
            matchedProjectName = nil
            return
        }
        let projects = libraryContext.projectGoals.map(\.project)
        guard let match = matchProject(folderURL.lastPathComponent, projects) else {
            goalSeconds = nil
            matchedProjectName = nil
            return
        }
        matchedProjectName = match.project.displayName
        let hours = libraryContext.projectGoals.first { $0.project.id == match.project.id }?.goalHours
        goalSeconds = hours.map { $0 * 3600 }
    }

    private func watchLoop() async throws {
        while true {
            await pollNow()
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
        }
    }

    /// One poll cycle: lists the watched folder, advances every not-yet-
    /// confirmed path's size-stability check, and folds every FRESHLY
    /// confirmed (size-stable across two consecutive polls) file into
    /// `session`. Public and directly callable (never only reachable
    /// through the timer in `watchLoop`) so tests can drive deterministic,
    /// synthetic poll sequences.
    @discardableResult
    public func pollNow() async -> Bool {
        guard let folderURL else { return false }
        let listerRef = lister
        let listed = await Task.detached { listerRef.listCaptureFiles(in: folderURL) }.value

        guard let listed else {
            session.markDisconnected()
            return false
        }
        if session.connectionState == .disconnected {
            session.markReconnected()
        }

        var newlyConfirmed: [LiveNightFolderListing] = []
        var stillPending: [String: Int64] = [:]

        for file in listed {
            let path = file.url.path
            guard !confirmedPaths.contains(path) else { continue }
            if let lastSize = pendingSizes[path], lastSize == file.sizeBytes {
                newlyConfirmed.append(file)
                confirmedPaths.insert(path)
            } else {
                stillPending[path] = file.sizeBytes
            }
        }
        pendingSizes = stillPending

        guard !newlyConfirmed.isEmpty else {
            checkIdle()
            return true
        }

        for file in newlyConfirmed.sorted(by: { $0.modificationDate < $1.modificationDate }) {
            await processConfirmedFile(file)
        }
        return true
    }

    private func processConfirmedFile(_ file: LiveNightFolderListing) async {
        let ext = file.url.pathExtension.lowercased()
        let isFITS = LibraryScanner.fitsExtensions.contains(ext)
        let url = file.url

        if isFITS {
            let readExposure = readFITSExposureSeconds
            let readRadius = quickStarProxyRadius
            let (exposure, radius) = await Task.detached { () -> (Double?, Double?) in
                (readExposure(url), readRadius(url))
            }.value
            session.recordFrame(.init(
                kind: .fits, exposureSeconds: exposure, capturedAt: file.modificationDate, quickProxyRadiusPixels: radius
            ))
        } else {
            let readRaw = readRawMeta
            let meta = await Task.detached { readRaw(url) }.value
            session.recordFrame(.init(
                kind: .cr3, exposureSeconds: meta.exposureSeconds, capturedAt: meta.captureDate ?? file.modificationDate
            ))
        }
    }

    private func checkIdle() {
        guard let lastFrameAt = session.lastFrameAt else { return }
        guard now().timeIntervalSince(lastFrameAt) > idleThreshold else { return }
        session.markIdleTooLong()
    }

    /// The Home card's own ETA/progress read -- delegates to
    /// `session.goalEstimate`, `nil` whenever there is nothing honest to
    /// project (see that method's own doc comment).
    public func currentGoalEstimate() -> LiveNightGoalEstimator.Estimate? {
        session.goalEstimate(goalSeconds: goalSeconds, now: now())
    }
}

/// V3 pre-stack program, section 5.6 (Élő éjszaka-mód): "which night is
/// this instant part of" -- what `NightWorkspaceView`'s own "ÉLŐ" badge
/// compares against `NightRow.date` (`NightRecord.localDate`, canonical
/// `"yyyy-MM-dd"`, see `AnniversaryQuery`'s own doc comment for that
/// format). Uses the same local-noon-to-noon convention this codebase's own
/// `SkyTrack.noonToNoonWindow`/`SunMoon`'s "nightOf" helpers already use for
/// a night's own boundary (a capture after local midnight still belongs to
/// the PREVIOUS calendar date's night) -- deliberately the same
/// well-established astronomical-night convention every other "which
/// night" computation in this app already agrees on, not a second,
/// independently-invented one, and NOT an attempt to replicate whatever
/// exact per-frame grouping the index DB's own scan pipeline computes
/// internally (that lives several layers deeper than this in-process live
/// watcher ever reaches).
public enum LiveNightNightKey {
    public static func forNow(_ now: Date = Date(), timeZone: TimeZone = .current) -> String {
        key(for: now, timeZone: timeZone)
    }

    public static func key(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: date)
        let nightStart = hour < 12 ? (calendar.date(byAdding: .day, value: -1, to: date) ?? date) : date
        return formatter(timeZone: timeZone).string(from: nightStart)
    }

    private static func formatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
