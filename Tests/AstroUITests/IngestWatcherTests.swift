import AstroApplication
import AstroCore
@testable import AstroUI
import Foundation
import Testing

@MainActor
private final class FakeIngestVolumeMonitor: @MainActor IngestVolumeMonitor {
    private var mountHandler: ((URL) -> Void)?
    private var unmountHandler: ((URL) -> Void)?

    func startObservingMounts(_ handler: @escaping @MainActor (URL) -> Void) {
        mountHandler = handler
    }

    func startObservingUnmounts(_ handler: @escaping @MainActor (URL) -> Void) {
        unmountHandler = handler
    }

    func simulateMount(_ url: URL) {
        mountHandler?(url)
    }

    func simulateUnmount(_ url: URL) {
        unmountHandler?(url)
    }
}

private func project(catalogID: String, displayName: String) -> ProjectRecord {
    ProjectRecord(id: UUID(), catalogID: catalogID, displayName: displayName, phase: .collecting)
}

private func libraryRoot() -> URL {
    URL(fileURLWithPath: "/Volumes/AstroLibrary", isDirectory: true)
}

@MainActor
private func makeWatcher(
    monitor: FakeIngestVolumeMonitor,
    enabled: Bool = true,
    classify: @escaping @Sendable (URL) -> Bool = { _ in true },
    scan: @escaping @Sendable (URL) throws -> [DiscoveredCaptureFile] = { _ in
        [DiscoveredCaptureFile(
            sourceURL: URL(fileURLWithPath: "/Volumes/EOS_DIGITAL/IMG_0001.CR3"),
            relativeSourcePath: "IMG_0001.CR3",
            fileName: "IMG_0001.CR3",
            ext: "cr3",
            kind: "raw",
            sizeBytes: 1024,
            proposedRole: nil,
            captureDate: nil,
            captureDateSource: nil
        )]
    },
    matchProject: @escaping @Sendable (String, [ProjectRecord]) -> IngestSuggestionEngine.ProjectMatch? = { _, _ in nil }
) -> IngestWatcher {
    IngestWatcher(
        monitor: monitor,
        isEnabled: { enabled },
        classify: classify,
        scan: scan,
        matchProject: matchProject,
        // The default production resolver needs `rootURL` to be a REAL,
        // currently-mounted path (`URL.resourceValues(forKeys:
        // [.volumeURLKey])`) -- `libraryRoot()` below is a synthetic test
        // path that was never actually mounted, so this stands in with the
        // one fact the tests actually need: "the library's own volume path
        // IS `libraryRoot()`'s own path", matching what the real resolver
        // would report for a genuinely open library.
        libraryVolumePath: { _ in libraryRoot().standardizedFileURL.path }
    )
}

@MainActor
private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

@Suite("IngestWatcher mount handling")
@MainActor
struct IngestWatcherTests {
    @Test func disabledWatcherIgnoresAMount() async {
        let monitor = FakeIngestVolumeMonitor()
        let watcher = makeWatcher(monitor: monitor, enabled: false)
        watcher.updateLibraryContext(.init(
            rootURL: libraryRoot(), accessMode: .readOnly, indexedFolders: [], existingProjects: []
        ))
        watcher.start()

        monitor.simulateMount(URL(fileURLWithPath: "/Volumes/EOS_DIGITAL", isDirectory: true))
        await waitUntil { watcher.candidate != nil }

        #expect(watcher.candidate == nil)
    }

    @Test func withNoLibraryContextAMountIsIgnored() async {
        let monitor = FakeIngestVolumeMonitor()
        let watcher = makeWatcher(monitor: monitor)
        watcher.start()

        monitor.simulateMount(URL(fileURLWithPath: "/Volumes/EOS_DIGITAL", isDirectory: true))
        await waitUntil { watcher.candidate != nil }

        #expect(watcher.candidate == nil)
    }

    @Test func aNonVolumesPathIsNeverOffered() async {
        let monitor = FakeIngestVolumeMonitor()
        let watcher = makeWatcher(monitor: monitor)
        watcher.updateLibraryContext(.init(
            rootURL: libraryRoot(), accessMode: .readOnly, indexedFolders: [], existingProjects: []
        ))
        watcher.start()

        monitor.simulateMount(URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true))
        await waitUntil { watcher.candidate != nil }

        #expect(watcher.candidate == nil)
    }

    @Test func theLibrarysOwnVolumeIsNeverOfferedAsASource() async {
        let monitor = FakeIngestVolumeMonitor()
        let watcher = makeWatcher(monitor: monitor)
        watcher.updateLibraryContext(.init(
            rootURL: libraryRoot(), accessMode: .readOnly, indexedFolders: [], existingProjects: []
        ))
        watcher.start()

        // `makeWatcher`'s injected `libraryVolumePath` reports
        // `libraryRoot()`'s own path as the library's volume -- mounting
        // that exact path must never be offered as an import SOURCE.
        monitor.simulateMount(libraryRoot())
        await waitUntil { watcher.candidate != nil }

        #expect(watcher.candidate == nil)
    }

    @Test func aClassifiedCaptureVolumeIsPublishedWithItsGroupsAndNoPrefillWhenNothingMatches() async {
        let monitor = FakeIngestVolumeMonitor()
        let watcher = makeWatcher(monitor: monitor)
        watcher.updateLibraryContext(.init(
            rootURL: libraryRoot(), accessMode: .readOnly, indexedFolders: [],
            existingProjects: [project(catalogID: "M42", displayName: "Orion Nebula")]
        ))
        watcher.start()

        monitor.simulateMount(URL(fileURLWithPath: "/Volumes/EOS_DIGITAL", isDirectory: true))
        await waitUntil { watcher.candidate != nil }

        let candidate = watcher.candidate
        #expect(candidate?.volume.path == "/Volumes/EOS_DIGITAL")
        #expect(candidate?.discovered.count == 1)
        #expect(candidate?.groups.count == 1)
        #expect(candidate?.sessionPrefill == nil)
    }

    @Test func aMatchedProjectNameProducesASessionPrefill() async {
        let monitor = FakeIngestVolumeMonitor()
        let target = project(catalogID: "M31", displayName: "Andromeda Galaxy")
        let watcher = makeWatcher(
            monitor: monitor,
            matchProject: { _, projects in
                projects.first.map { IngestSuggestionEngine.ProjectMatch(project: $0, confidence: .exact) }
            }
        )
        watcher.updateLibraryContext(.init(
            rootURL: libraryRoot(), accessMode: .readOnly, indexedFolders: [], existingProjects: [target]
        ))
        watcher.start()

        monitor.simulateMount(URL(fileURLWithPath: "/Volumes/M31", isDirectory: true))
        await waitUntil { watcher.candidate != nil }

        #expect(watcher.candidate?.sessionPrefill?.catalogRaw == "M31")
    }

    @Test func aVolumeThatFailsClassificationIsNeverOffered() async {
        let monitor = FakeIngestVolumeMonitor()
        let watcher = makeWatcher(monitor: monitor, classify: { _ in false })
        watcher.updateLibraryContext(.init(
            rootURL: libraryRoot(), accessMode: .readOnly, indexedFolders: [], existingProjects: []
        ))
        watcher.start()

        monitor.simulateMount(URL(fileURLWithPath: "/Volumes/RANDOM_USB", isDirectory: true))
        await waitUntil { watcher.candidate != nil }

        #expect(watcher.candidate == nil)
    }

    @Test func anEmptyScanIsNeverOfferedEvenIfClassificationPassed() async {
        let monitor = FakeIngestVolumeMonitor()
        let watcher = makeWatcher(monitor: monitor, classify: { _ in true }, scan: { _ in [] })
        watcher.updateLibraryContext(.init(
            rootURL: libraryRoot(), accessMode: .readOnly, indexedFolders: [], existingProjects: []
        ))
        watcher.start()

        monitor.simulateMount(URL(fileURLWithPath: "/Volumes/EOS_DIGITAL", isDirectory: true))
        await waitUntil { watcher.candidate != nil }

        #expect(watcher.candidate == nil)
    }

    @Test func theSameVolumeIsNeverOfferedTwiceWithoutAnUnmountInBetween() async {
        let monitor = FakeIngestVolumeMonitor()
        let watcher = makeWatcher(monitor: monitor)
        watcher.updateLibraryContext(.init(
            rootURL: libraryRoot(), accessMode: .readOnly, indexedFolders: [], existingProjects: []
        ))
        watcher.start()
        let url = URL(fileURLWithPath: "/Volumes/EOS_DIGITAL", isDirectory: true)

        monitor.simulateMount(url)
        await waitUntil { watcher.candidate != nil }
        #expect(watcher.candidate != nil)

        watcher.dismissCandidate()
        #expect(watcher.candidate == nil)

        monitor.simulateMount(url)
        // Give any (incorrect) re-publish a moment to land, then assert it
        // never did -- `dismissCandidate` must not reset the "already
        // offered" bookkeeping for a volume that never unmounted.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(watcher.candidate == nil)
    }

    @Test func unmountingTheOfferedVolumeClearsTheCandidateAndAllowsAFreshOffer() async {
        let monitor = FakeIngestVolumeMonitor()
        let watcher = makeWatcher(monitor: monitor)
        watcher.updateLibraryContext(.init(
            rootURL: libraryRoot(), accessMode: .readOnly, indexedFolders: [], existingProjects: []
        ))
        watcher.start()
        let url = URL(fileURLWithPath: "/Volumes/EOS_DIGITAL", isDirectory: true)

        monitor.simulateMount(url)
        await waitUntil { watcher.candidate != nil }
        #expect(watcher.candidate != nil)

        monitor.simulateUnmount(url)
        #expect(watcher.candidate == nil)

        monitor.simulateMount(url)
        await waitUntil { watcher.candidate != nil }
        #expect(watcher.candidate != nil)
    }
}
