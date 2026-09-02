import AstroApplication
import AstroCore
@testable import AstroUI
import Foundation
import Testing

/// Hands `LiveNightWatcher.pollNow()` a scripted directory listing per poll
/// -- no real filesystem, no real timer, deterministic. `nil` simulates the
/// watched folder becoming unreachable; setting a fresh array simulates the
/// next poll's own snapshot. Lock-protected (mirrors `OperationHost.swift`'s
/// own `CancellableTaskBox`) since `pollNow()` reads this from inside a
/// `Task.detached`.
private final class FakeFolderLister: LiveNightFolderLister, @unchecked Sendable {
    private let lock = NSLock()
    private var response: [LiveNightFolderListing]?

    init(response: [LiveNightFolderListing]? = []) {
        self.response = response
    }

    func setResponse(_ response: [LiveNightFolderListing]?) {
        lock.withLock { self.response = response }
    }

    func listCaptureFiles(in folder: URL) -> [LiveNightFolderListing]? {
        lock.withLock { response }
    }
}

private func watchedFolder(_ name: String = "M31") -> URL {
    URL(fileURLWithPath: "/Volumes/RigShare/\(name)", isDirectory: true)
}

private func listing(_ name: String, sizeBytes: Int64, modificationDate: Date = Date()) -> LiveNightFolderListing {
    LiveNightFolderListing(
        url: watchedFolder().appendingPathComponent(name), sizeBytes: sizeBytes, modificationDate: modificationDate
    )
}

private func project(catalogID: String, displayName: String) -> ProjectRecord {
    ProjectRecord(id: UUID(), catalogID: catalogID, displayName: displayName, phase: .collecting)
}

/// A settable "now" for tests that need to advance the clock mid-test --
/// `LiveNightWatcher`'s own `now` parameter is `@escaping @Sendable () ->
/// Date`, and a plain captured `var` cannot cross that boundary (the
/// compiler correctly refuses it as a potential data race); lock-protected
/// storage mirrors `FakeFolderLister`'s own `NSLock` pattern above.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ initial: Date) {
        current = initial
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    func now() -> Date {
        lock.withLock { current }
    }
}

@MainActor
private func makeWatcher(
    lister: FakeFolderLister,
    fitsExposure: Double? = 300,
    rawMeta: (exposureSeconds: Double?, captureDate: Date?) = (60, nil),
    proxyRadius: Double? = 2.5,
    now: @escaping @Sendable () -> Date = Date.init,
    idleThreshold: TimeInterval = 1200,
    /// `.inactive` by default: these folders are synthetic, so a real
    /// `startAccessingSecurityScopedResource` would only ever return false.
    securityScopedAccess: SecurityScopedAccess = .inactive
) -> LiveNightWatcher {
    LiveNightWatcher(
        lister: lister,
        readFITSExposureSeconds: { _ in fitsExposure },
        readRawMeta: { _ in rawMeta },
        quickStarProxyRadius: { _ in proxyRadius },
        securityScopedAccess: securityScopedAccess,
        now: now,
        idleThreshold: idleThreshold,
        pollIntervalSeconds: 9999 // never actually fires in a test -- only pollNow() is called directly.
    )
}

@Suite("LiveNightWatcher polling")
@MainActor
struct LiveNightWatcherTests {
    @Test("Switching watched folders cancels the previous operation before starting the next one")
    func switchingFoldersKeepsExactlyOneWatchOperation() async throws {
        let watcher = makeWatcher(lister: FakeFolderLister())
        let host = OperationHost(center: OperationCenter())

        await watcher.startWatching(folder: watchedFolder("M31"), operationHost: host)
        #expect(host.activeOperations.filter { $0.kind == .liveNightWatch }.count == 1)

        await watcher.startWatching(folder: watchedFolder("M42"), operationHost: host)
        #expect(
            host.activeOperations.filter { $0.kind == .liveNightWatch }.count == 1,
            "changing folders must not leave the old polling loop alive"
        )

        await watcher.stopWatching(operationHost: host)
        #expect(host.activeOperations.filter { $0.kind == .liveNightWatch }.isEmpty)
    }

    @Test("pollNow does nothing when no folder is configured")
    func pollNowDoesNothingWithoutAFolder() async {
        let watcher = makeWatcher(lister: FakeFolderLister())
        let didWork = await watcher.pollNow()
        #expect(didWork == false)
        #expect(watcher.session.totalFrameCount == 0)
    }

    @Test("configureFolder resets every per-session accumulator")
    func configureFolderResetsSessionState() {
        let watcher = makeWatcher(lister: FakeFolderLister())
        watcher.configureFolder(watchedFolder())
        #expect(watcher.folderURL?.path == watchedFolder().path)
    }

    @Test("configureFolder with the SAME folder is a no-op, never resets an in-progress session")
    func configureFolderSameFolderIsANoOp() async {
        let lister = FakeFolderLister()
        let watcher = makeWatcher(lister: lister)
        watcher.configureFolder(watchedFolder())

        lister.setResponse([listing("frame1.fits", sizeBytes: 1000)])
        await watcher.pollNow() // pending (first sighting)
        lister.setResponse([listing("frame1.fits", sizeBytes: 1000)])
        await watcher.pollNow() // stable -> confirmed
        #expect(watcher.session.totalFrameCount == 1)

        watcher.configureFolder(watchedFolder()) // same folder again
        #expect(watcher.session.totalFrameCount == 1, "re-configuring the SAME folder must not wipe the running session")
    }

    @Test("configureFolder with a DIFFERENT folder starts a fresh session")
    func configureFolderDifferentFolderStartsFresh() async {
        let lister = FakeFolderLister()
        let watcher = makeWatcher(lister: lister)
        watcher.configureFolder(watchedFolder("M31"))
        lister.setResponse([listing("frame1.fits", sizeBytes: 1000)])
        await watcher.pollNow()
        lister.setResponse([listing("frame1.fits", sizeBytes: 1000)])
        await watcher.pollNow()
        #expect(watcher.session.totalFrameCount == 1)

        watcher.configureFolder(watchedFolder("M42"))
        #expect(watcher.session.totalFrameCount == 0)
    }

    @Test("A file must show a STABLE size across two consecutive polls before it counts as a frame")
    func fileMustBeSizeStableAcrossTwoPolls() async {
        let lister = FakeFolderLister()
        let watcher = makeWatcher(lister: lister)
        watcher.configureFolder(watchedFolder())

        lister.setResponse([listing("frame1.fits", sizeBytes: 1000)])
        await watcher.pollNow()
        #expect(watcher.session.totalFrameCount == 0, "a file seen only once must never be treated as complete")

        // Still growing -- still not stable.
        lister.setResponse([listing("frame1.fits", sizeBytes: 4000)])
        await watcher.pollNow()
        #expect(watcher.session.totalFrameCount == 0)

        // Same size as the previous poll -- now stable, gets processed.
        lister.setResponse([listing("frame1.fits", sizeBytes: 4000)])
        await watcher.pollNow()
        #expect(watcher.session.totalFrameCount == 1)

        // A confirmed file is never re-processed even if it keeps appearing.
        lister.setResponse([listing("frame1.fits", sizeBytes: 4000)])
        await watcher.pollNow()
        #expect(watcher.session.totalFrameCount == 1)
    }

    @Test("A FITS frame routes through the FITS exposure/quick-proxy readers, never the raw-meta reader")
    func fitsFrameRoutesThroughFITSReaders() async {
        let lister = FakeFolderLister()
        let watcher = makeWatcher(lister: lister, fitsExposure: 300, proxyRadius: 3.1)
        watcher.configureFolder(watchedFolder())

        lister.setResponse([listing("light_0001.fits", sizeBytes: 5000)])
        await watcher.pollNow()
        lister.setResponse([listing("light_0001.fits", sizeBytes: 5000)])
        await watcher.pollNow()

        #expect(watcher.session.fitsFrameCount == 1)
        #expect(watcher.session.cr3FrameCount == 0)
        #expect(watcher.session.medianQuickProxyRadiusPixels == 3.1)
        #expect(watcher.session.exposureSeconds == [300])
    }

    @Test("A CR3 frame routes through the raw-meta reader and never gets a quick-proxy radius")
    func cr3FrameRoutesThroughRawMetaReader() async {
        let lister = FakeFolderLister()
        let watcher = makeWatcher(lister: lister, rawMeta: (45, nil))
        watcher.configureFolder(watchedFolder())

        lister.setResponse([listing("IMG_0001.CR3", sizeBytes: 20_000_000)])
        await watcher.pollNow()
        lister.setResponse([listing("IMG_0001.CR3", sizeBytes: 20_000_000)])
        await watcher.pollNow()

        #expect(watcher.session.cr3FrameCount == 1)
        #expect(watcher.session.fitsFrameCount == 0)
        #expect(watcher.session.medianQuickProxyRadiusPixels == nil)
        #expect(watcher.session.exposureSeconds == [45])
    }

    @Test("A nil listing (unreachable folder) marks the session disconnected")
    func nilListingMarksDisconnected() async {
        let lister = FakeFolderLister(response: [])
        let watcher = makeWatcher(lister: lister)
        watcher.configureFolder(watchedFolder())

        lister.setResponse(nil)
        let didWork = await watcher.pollNow()
        #expect(didWork == false)
        #expect(watcher.session.connectionState == .disconnected)
    }

    @Test("A reachable listing after a disconnect reconnects the session, even with nothing new")
    func reachableListingAfterDisconnectReconnects() async {
        let lister = FakeFolderLister()
        let watcher = makeWatcher(lister: lister)
        watcher.configureFolder(watchedFolder())

        lister.setResponse(nil)
        await watcher.pollNow()
        #expect(watcher.session.connectionState == .disconnected)

        lister.setResponse([])
        await watcher.pollNow()
        #expect(watcher.session.connectionState == .watching)
    }

    @Test("No new frames for longer than the idle threshold marks the session idle")
    func idleThresholdMarksSessionIdle() async {
        let lister = FakeFolderLister()
        let clock = MutableClock(Date(timeIntervalSince1970: 500_000))
        let watcher = makeWatcher(lister: lister, now: { clock.now() }, idleThreshold: 600)
        watcher.configureFolder(watchedFolder())

        lister.setResponse([listing("frame1.fits", sizeBytes: 1000, modificationDate: clock.now())])
        await watcher.pollNow()
        lister.setResponse([listing("frame1.fits", sizeBytes: 1000, modificationDate: clock.now())])
        await watcher.pollNow()
        #expect(watcher.session.connectionState == .watching)

        // Advance well past the idle threshold with no new frames arriving.
        clock.advance(by: 900)
        lister.setResponse([])
        await watcher.pollNow()
        #expect(watcher.session.connectionState == .idleTooLong)
    }

    @Test("A matched project's goal seconds feed into currentGoalEstimate")
    func matchedProjectGoalFeedsGoalEstimate() async throws {
        let lister = FakeFolderLister()
        let currentTime = Date(timeIntervalSince1970: 800_000)
        let watcher = makeWatcher(lister: lister, fitsExposure: 300, now: { currentTime })
        let target = project(catalogID: "M31", displayName: "Andromeda Galaxy")
        watcher.updateLibraryContext(.init(projectGoals: [.init(project: target, goalHours: 2)]))
        watcher.configureFolder(watchedFolder("M31"))

        #expect(watcher.matchedProjectName == "Andromeda Galaxy")
        #expect(watcher.currentGoalEstimate() == nil, "no frames recorded yet -- nothing honest to project")

        lister.setResponse([listing("light_0001.fits", sizeBytes: 1000, modificationDate: currentTime)])
        await watcher.pollNow()
        lister.setResponse([listing("light_0001.fits", sizeBytes: 1000, modificationDate: currentTime)])
        await watcher.pollNow()

        let estimate = try #require(watcher.currentGoalEstimate())
        #expect(estimate.goalSeconds == 7200)
        #expect(estimate.integratedSeconds == 300)
    }

    @Test("No project match leaves matchedProjectName and the goal estimate both nil")
    func noProjectMatchLeavesGoalNil() {
        let lister = FakeFolderLister()
        let watcher = makeWatcher(lister: lister)
        watcher.updateLibraryContext(.init(projectGoals: [.init(project: project(catalogID: "M42", displayName: "Orion Nebula"), goalHours: 5)]))
        watcher.configureFolder(watchedFolder("CompletelyUnrelatedFolderName"))

        #expect(watcher.matchedProjectName == nil)
        #expect(watcher.currentGoalEstimate() == nil)
    }
}

/// The watcher's `UserDefaults.didChangeNotification` observer fires on
/// EVERY defaults write anywhere in the app, and it used to resolve the
/// configured bookmark -- starting a security-scoped access -- before it
/// checked whether the folder had even changed, with no matching stop
/// anywhere in the type. One leaked kernel scope per keystroke in Settings,
/// plus a `NotificationCenter` block that outlived the watcher because
/// nothing removed it. These pin the balance.
@Suite("LiveNightWatcher security scope and observer lifetime")
@MainActor
struct LiveNightWatcherScopeTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source() throws -> String {
        try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/AstroUI/Features/LiveNight/LiveNightWatcher.swift"),
            encoding: .utf8
        )
    }

    @Test("Access starts once per watched folder and stops when the folder changes or the watch ends")
    func scopedAccessIsBalanced() {
        let probe = ScopedAccessProbe()
        let watcher = makeWatcher(lister: FakeFolderLister(), securityScopedAccess: probe.client)

        watcher.configureFolder(watchedFolder("M31"))
        #expect(probe.startedURLs == [watchedFolder("M31")])
        #expect(probe.stoppedURLs.isEmpty)

        // Re-configuring the same folder must not stack a second scope.
        watcher.configureFolder(watchedFolder("M31"))
        #expect(probe.startedURLs == [watchedFolder("M31")])

        watcher.configureFolder(watchedFolder("M42"))
        #expect(probe.stoppedURLs == [watchedFolder("M31")], "the previous folder's scope is released before the next starts")
        #expect(probe.startedURLs == [watchedFolder("M31"), watchedFolder("M42")])

        watcher.configureFolder(nil)
        #expect(probe.stoppedURLs == [watchedFolder("M31"), watchedFolder("M42")])
        #expect(probe.startedURLs.count == 2, "clearing the folder starts nothing")
    }

    @Test("stopWatching releases the security scope it started")
    func stopWatchingReleasesScope() async {
        let probe = ScopedAccessProbe()
        let watcher = makeWatcher(lister: FakeFolderLister(), securityScopedAccess: probe.client)
        let host = OperationHost(center: OperationCenter())

        await watcher.startWatching(folder: watchedFolder("M31"), operationHost: host)
        #expect(probe.startedURLs == [watchedFolder("M31")])

        await watcher.stopWatching(operationHost: host)
        #expect(probe.stoppedURLs == [watchedFolder("M31")])
    }

    @Test("resolveConfiguredFolder is a pure resolve -- it never starts an access nobody can stop")
    func resolveConfiguredFolderStartsNoAccess() throws {
        let source = try source()
        let body = try #require(
            source.components(separatedBy: "public static func resolveConfiguredFolder").dropFirst().first
        )
        #expect(
            !body.contains("startAccessingSecurityScopedResource"),
            "a static resolver has nowhere to store the accessed URL, so its scope can never be balanced"
        )
    }

    @Test("refreshFromSettings compares the stored bookmark before it resolves anything")
    func refreshComparesBookmarkBeforeResolving() throws {
        let source = try source()
        let body = try #require(
            source.components(separatedBy: "private func refreshFromSettings").dropFirst().first?
                .components(separatedBy: "\n    }").first
        )
        let comparison = try #require(body.range(of: "configuredFolderBookmark"))
        let resolve = try #require(body.range(of: "resolveConfiguredFolder"))
        #expect(
            comparison.lowerBound < resolve.lowerBound,
            "every UserDefaults write reaches here, so the cheap blob comparison must gate the resolve"
        )
    }

    @Test("deinit removes the settings observer and releases any held scope")
    func deinitCleansUp() throws {
        let source = try source()
        let body = try #require(
            source.components(separatedBy: "\n    deinit {").dropFirst().first?
                .components(separatedBy: "\n    }").first
        )
        #expect(body.contains("removeObserver"))
        #expect(body.contains("securityScopedAccess.stop"))
    }
}

/// Records the start/stop calls `LiveNightWatcher` makes through its
/// injected `SecurityScopedAccess` seam -- same probe shape
/// `V2OnboardingTests` already uses for `OnboardingStore`.
private final class ScopedAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [URL] = []
    private var stopped: [URL] = []

    var client: SecurityScopedAccess {
        SecurityScopedAccess(
            start: { [weak self] url in
                self?.lock.withLock { self?.started.append(url) }
                return true
            },
            stop: { [weak self] url in
                self?.lock.withLock { self?.stopped.append(url) }
            }
        )
    }

    var startedURLs: [URL] { lock.withLock { started } }
    var stoppedURLs: [URL] { lock.withLock { stopped } }
}

@Suite("LiveNightNightKey")
struct LiveNightNightKeyTests {
    @Test("An instant before local noon belongs to the PREVIOUS calendar date's night")
    func beforeNoonBelongsToPreviousDate() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let earlyMorning = utc.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 2))!
        #expect(LiveNightNightKey.key(for: earlyMorning, timeZone: TimeZone(identifier: "UTC")!) == "2026-08-19")
    }

    @Test("An instant after local noon belongs to that SAME calendar date's night")
    func afterNoonBelongsToSameDate() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let evening = utc.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 22))!
        #expect(LiveNightNightKey.key(for: evening, timeZone: TimeZone(identifier: "UTC")!) == "2026-08-20")
    }
}
