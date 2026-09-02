@testable import AstroUI
import AstroApplication
import AstroCore
import Foundation
import Testing

/// Pads a FITS card line to 80 characters and assembles a full 2880-byte
/// header block, plus a minimal signed-16-bit light frame -- duplicated
/// (not imported) from `Tests/AstroApplicationTests/FrameRatingCommandTests.
/// swift`'s own private helpers, the same cross-target duplication that
/// file's own doc comment already documents (`AstroUITests` cannot import
/// `AstroApplicationTests`' file-private target either).
private func ratingRunnerCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func ratingRunnerHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(ratingRunnerCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

private func buildRatingRunner16BitFITSFrame(width: Int, height: Int, pixels: [Int]) -> Data {
    precondition(pixels.count == width * height)
    let cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                 \(width)",
        "NAXIS2  =                 \(height)",
        "END",
    ]
    var data = ratingRunnerHeaderData(cards)
    for value in pixels {
        let unsigned = UInt16(bitPattern: Int16(value))
        data.append(UInt8(unsigned >> 8))
        data.append(UInt8(unsigned & 0xFF))
    }
    return data
}

/// A fresh fixture: a temp library directory with one real FITS light frame
/// on disk, a fresh sqlite index `Database` recording it, and a fresh
/// `MetadataStore` recording one project/night/series/frame-decision that
/// resolves to it -- exactly the two databases `ProjectRatingRunner.run`
/// reads from (`metadataFactory` for the project/series/frame-decision walk,
/// `commandFactory` for the actual `FrameRatingCommand.run` that touches
/// pixels). Both are constructed directly (`Database(path:)`,
/// `FrameRatingCommand(db:config:root:)`), never `.production(rootURL:)`,
/// so this test never touches the real `~/Library/Application Support/
/// AstroTool/...` tree.
private struct RunnerFixture {
    let libraryDir: URL
    let dbDir: URL
    let indexDB: Database
    let metadata: MetadataStore
    var config: AstroConfig
    let project: ProjectRecord
    let relativePath: String
    let fileID: Int64

    static func make() async throws -> RunnerFixture {
        let libraryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-rating-runner-tests-lib-\(UUID().uuidString)", isDirectory: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-rating-runner-tests-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let relativePath = "sessions/M31/2026-01-01/lights/a.fit"
        let frameURL = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: frameURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = buildRatingRunner16BitFITSFrame(width: 4, height: 4, pixels: Array(repeating: 200, count: 16))
        try data.write(to: frameURL)

        let indexDB = try Database(path: dbDir.appendingPathComponent("index.sqlite").path)
        let fileID = try indexDB.upsertFile(FileRecord(
            path: relativePath, size: Int64(data.count), mtime: 1_700_000_000, ext: "fit", kind: "fits",
            area: .sessions, target: "M31", sessionDate: "2026-01-01", role: .light,
            scannedAt: Date().timeIntervalSince1970
        ))

        var config = AstroConfig()
        config.rootPath = libraryDir.path
        // Deterministic "no real Siril" default -- same reasoning
        // `RatingCommandFixture.make()` documents.
        config.rating.sirilPath = "/definitely/not/a/real/binary/siril-cli"

        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "M 31", displayName: "Andromeda", phase: .collecting)
        let night = NightRecord(id: UUID(), localDate: "2026-01-01", timeZoneID: "Europe/Budapest")
        let series = SeriesRecord(
            id: UUID(), projectID: project.id, nightID: night.id, setupID: nil,
            setupDescriptor: "Test rig", sensorMode: .mono, passband: .broadband,
            exposureSeconds: 60, filterName: nil, filterID: nil, gain: nil, offset: nil, binning: "1x1"
        )
        let frameDecision = FrameDecisionRecord(
            id: UUID(), seriesID: series.id, relativePath: relativePath,
            verdict: .accepted, logicallyExcluded: false
        )
        try await metadata.save(MetadataWriteBatch(
            projects: [project], nights: [night], series: [series], frameDecisions: [frameDecision]
        ))

        return RunnerFixture(
            libraryDir: libraryDir, dbDir: dbDir, indexDB: indexDB, metadata: metadata,
            config: config, project: project, relativePath: relativePath, fileID: fileID
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    /// Same fake "siril-cli" shell script `FrameRatingCommandTests.
    /// installFakeSirilCLI()` uses -- a fixed, parseable findstar result, so
    /// `.fullReMeasure` is testable end to end without a real Siril install.
    func installFakeSirilCLI() throws -> String {
        let scriptURL = dbDir.appendingPathComponent("fake-siril-cli.sh")
        let script = """
        #!/bin/sh
        echo "log: Found 42 Gaussian profile stars in image, channel #0 (FWHM 3.0, roundness 0.87)"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL.path
    }
}

/// OWNER BUG (2026-08-19 real-library audit): the owner pressed "Minden
/// projekt értékelése" (`ProjectRatingRunner.run(scope: .allProjects)`, the
/// Home dashboard's "Rate Everything" gate button) and reported the
/// Insights FWHM trend never changing. His real `ratings` table confirmed
/// it: the run that button started wrote 489 rows, every one with `fwhm
/// IS NULL` and `siril_version = ''` -- because `run(scope:...)` had NO
/// `mode` parameter at all and unconditionally rated with `.nativeOnly`
/// (`FrameRatingCommand.run`'s `provider = nil` for that mode, so a
/// `StarMetricsProvider`/Siril is never even attempted). No number of
/// re-presses could ever have filled that trend in.
@MainActor
@Suite("ProjectRatingRunner")
struct ProjectRatingRunnerTests {
    @Test("Rating all projects with the default mode never populates FWHM -- the exact bug the owner hit")
    func defaultModeNeverMeasuresStarMetrics() async throws {
        let fixture = try await RunnerFixture.make()
        defer { fixture.cleanup() }
        let host = OperationHost(center: OperationCenter())
        let command = FrameRatingCommand(db: fixture.indexDB, config: fixture.config, root: fixture.libraryDir)

        await ProjectRatingRunner.run(
            scope: .allProjects(libraryName: "TestLibrary"),
            rootURL: fixture.libraryDir,
            metadataFactory: { _ in fixture.metadata },
            sharedMetadata: nil,
            operationHost: host,
            commandFactory: { _ in command }
        )
        await host.settle()

        let stored = try #require(try fixture.indexDB.rating(fileID: fixture.fileID))
        #expect(stored.fwhm == nil, "default .nativeOnly mode must never populate star metrics -- reproduces the owner's bug")
        #expect(stored.background != nil)
        #expect(stored.score != nil)
    }

    @Test("Rating all projects with .fullReMeasure fills in FWHM -- the fix: a real measuring path through the same runner")
    func fullReMeasureModeMeasuresStarMetrics() async throws {
        var fixture = try await RunnerFixture.make()
        defer { fixture.cleanup() }
        fixture.config.rating.sirilPath = try fixture.installFakeSirilCLI()
        let host = OperationHost(center: OperationCenter())
        let command = FrameRatingCommand(db: fixture.indexDB, config: fixture.config, root: fixture.libraryDir)

        await ProjectRatingRunner.run(
            scope: .allProjects(libraryName: "TestLibrary"),
            rootURL: fixture.libraryDir,
            metadataFactory: { _ in fixture.metadata },
            sharedMetadata: nil,
            operationHost: host,
            mode: .fullReMeasure,
            commandFactory: { _ in command }
        )
        await host.settle()

        let stored = try #require(try fixture.indexDB.rating(fileID: fixture.fileID))
        #expect(stored.fwhm == 3.0)
        #expect(stored.starCount == 42)
        #expect(stored.sirilVersion != nil)
    }

    @Test("Rating a single project also honors an explicit mode, not just the .allProjects scope")
    func singleProjectScopeHonorsMode() async throws {
        var fixture = try await RunnerFixture.make()
        defer { fixture.cleanup() }
        fixture.config.rating.sirilPath = try fixture.installFakeSirilCLI()
        let host = OperationHost(center: OperationCenter())
        let command = FrameRatingCommand(db: fixture.indexDB, config: fixture.config, root: fixture.libraryDir)

        await ProjectRatingRunner.run(
            scope: .project(id: fixture.project.id, displayName: fixture.project.displayName),
            rootURL: fixture.libraryDir,
            metadataFactory: { _ in fixture.metadata },
            sharedMetadata: nil,
            operationHost: host,
            mode: .fullReMeasure,
            commandFactory: { _ in command }
        )
        await host.settle()

        let stored = try #require(try fixture.indexDB.rating(fileID: fixture.fileID))
        #expect(stored.fwhm == 3.0)
    }

    // MARK: - Rating is exclusive app-wide, not per-scope

    @Test("Rating all projects is refused while a single project's rating is still running")
    func allProjectsIsRefusedWhileAnotherScopeRates() async throws {
        // The scopes overlap -- every project's frames are also "all
        // projects" frames -- but each call site used to dedupe only on its
        // own `.rate` key, so both could run at once over the same frames.
        let fixture = try await RunnerFixture.make()
        defer { fixture.cleanup() }
        let host = OperationHost(center: OperationCenter())
        let command = FrameRatingCommand(db: fixture.indexDB, config: fixture.config, root: fixture.libraryDir)
        let busy = await host.run(
            kind: ProjectRatingRunner.kind(for: .project(id: fixture.project.id, displayName: "A")),
            title: "Rating Frames", cancellation: .cooperative
        ) {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }

        await ProjectRatingRunner.run(
            scope: .allProjects(libraryName: "TestLibrary"),
            rootURL: fixture.libraryDir,
            metadataFactory: { _ in fixture.metadata },
            sharedMetadata: nil,
            operationHost: host,
            commandFactory: { _ in command }
        )

        #expect(
            host.activeOperations.filter { $0.kind.isRating }.count == 1,
            "a second rating run must never measure the same frames concurrently"
        )
        #expect(host.toasts.contains { $0.level == .info })
        #expect(try fixture.indexDB.rating(fileID: fixture.fileID) == nil, "nothing was rated")
        _ = await host.cancel(id: busy)
    }

    // MARK: - v5 library-switch fixes, item 3: this runner used to open its
    // own confined `MetadataStore` connection through `metadataFactory` on
    // every run, competing with `ProjectsStore`'s already-open one for the
    // same database.

    @Test("An already-open metadata store is reused instead of opening a second connection")
    func sharedMetadataStoreIsUsedInsteadOfTheFactory() async throws {
        let fixture = try await RunnerFixture.make()
        defer { fixture.cleanup() }
        let host = OperationHost(center: OperationCenter())
        let command = FrameRatingCommand(db: fixture.indexDB, config: fixture.config, root: fixture.libraryDir)

        await ProjectRatingRunner.run(
            scope: .allProjects(libraryName: "TestLibrary"),
            rootURL: fixture.libraryDir,
            // Opening one here would be the bug -- the run must go through
            // `sharedMetadata` and never touch this.
            metadataFactory: { _ in throw ProjectRatingRunnerTestFailure.shouldNotOpenASecondConnection },
            sharedMetadata: fixture.metadata,
            operationHost: host,
            commandFactory: { _ in command }
        )
        await host.settle()

        #expect(try fixture.indexDB.rating(fileID: fixture.fileID) != nil)
        #expect(!host.toasts.contains { $0.level == .failure })
    }

    @Test("Every rating scope answers to the shared isRating predicate, and nothing else does")
    func isRatingCoversEveryScopeAndOnlyRating() {
        #expect(ProjectRatingRunner.kind(for: .allProjects(libraryName: "L")).isRating)
        #expect(ProjectRatingRunner.kind(for: .project(id: UUID(), displayName: "A")).isRating)
        #expect(OperationKind.rate(series: UUID().uuidString).isRating)
        #expect(OperationKind.rate(series: "night-\(UUID().uuidString)").isRating)
        #expect(!OperationKind.scan(library: "L").isRating)
        #expect(!OperationKind.sensorMeasurement(library: "L").isRating)
        #expect(!OperationKind.audit(library: "L").isRating)
    }
}

private enum ProjectRatingRunnerTestFailure: Error, Equatable {
    case shouldNotOpenASecondConnection
}
