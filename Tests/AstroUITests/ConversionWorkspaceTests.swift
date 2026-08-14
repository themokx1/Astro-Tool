@testable import AstroApplication
@testable import AstroUI
import AstroCore
import Foundation
import Testing

private func conversionStoreCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func conversionStoreHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(conversionStoreCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

/// A minimal on-disk library + scanned `Database`, mirroring
/// `SessionConversionCommandTests`' own fixture -- kept as its own file-local
/// copy per this codebase's convention. `useCase` points `ConversionUseCase`
/// at the exact same production-schema index database the real
/// `SessionConversionCommand` reads, so `ConversionStore.load` discovers the
/// same target/date scope both layers agree on.
@MainActor
private struct ConversionStoreFixture {
    let root: URL
    let db: Database
    var config: AstroConfig
    let useCase: ConversionUseCase

    static func make(exposures: [Double] = [60]) throws -> ConversionStoreFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversion-store-tests-\(UUID().uuidString)", isDirectory: true)
        let lights = root.appendingPathComponent("sessions/M31/2026-01-01/lights", isDirectory: true)
        try FileManager.default.createDirectory(at: lights, withIntermediateDirectories: true)
        for (offset, exposure) in exposures.enumerated() {
            try conversionStoreHeaderData([
                "SIMPLE  =                    T",
                "BITPIX  =                   16",
                "NAXIS   =                    2",
                "EXPTIME = \(exposure)",
                "BAYERPAT= 'RGGB'",
                "END",
            ]).write(to: lights.appendingPathComponent("light\(offset + 1).fit"))
        }
        let indexPath = root.appendingPathComponent("index.sqlite")
        let db = try Database(path: indexPath.path)
        var config = AstroConfig()
        config.rootPath = root.path
        _ = try LibraryScanner(config: config, db: db).scan()
        return ConversionStoreFixture(
            root: root, db: db, config: config,
            useCase: ConversionUseCase(indexDatabaseForTesting: indexPath)
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func writeFITSFlat(_ relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try conversionStoreHeaderData([
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    2",
            "IMAGETYP= 'FLAT'",
            "END",
        ]).write(to: url)
    }

    func rescan() throws { _ = try LibraryScanner(config: config, db: db).scan() }

    func makeStore() -> ConversionStore {
        ConversionStore(
            useCase: useCase,
            commandFactory: { _, accessMode in
                SessionConversionCommand(db: db, config: config, root: root, accessMode: accessMode)
            }
        )
    }
}

@MainActor
@Suite("V2 Conversion store")
struct ConversionWorkspaceTests {
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("Condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test("Loading discovers the session and builds an initial logical plan")
    func loadingBuildsInitialPlan() async throws {
        let fixture = try ConversionStoreFixture.make()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()

        await store.load(rootURL: fixture.root)

        #expect(store.sessions.contains(ConversionSessionID(target: "M31", date: "2026-01-01")))
        #expect(store.plan?.scope.target == "M31")
        #expect(store.plan?.mode == .logicalOnly)
        #expect(store.plan?.moves.isEmpty == true)
    }

    @Test("editGroup overwrites the proposed group's display name, sensor, signal, and filter")
    func editGroupOverwritesDraftFields() async throws {
        let fixture = try ConversionStoreFixture.make()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.load(rootURL: fixture.root)
        let slug = try #require(store.plan?.proposedGroups.first?.draft.slug)

        store.editGroup(
            slug: slug, displayName: "Edited Name", sensorMode: .mono, signalMode: .narrowband,
            filterManufacturer: "Antlia", filterModel: "3nm", filterName: "Ha"
        )

        let draft = try #require(store.plan?.proposedGroups.first { $0.draft.slug == slug }?.draft)
        #expect(draft.displayName == "Edited Name")
        #expect(draft.sensorMode == .mono)
        #expect(draft.signalMode == .narrowband)
        #expect(draft.filterName == "Ha")
    }

    @Test("canApply is false while a blocking ambiguity remains, true once resolved")
    func resolveAmbiguityClearsBlockAndAssignsFile() async throws {
        let fixture = try ConversionStoreFixture.make(exposures: [60, 120])
        defer { fixture.cleanup() }
        try fixture.writeFITSFlat("sessions/M31/2026-01-01/flats/flat1.fit")
        try fixture.rescan()
        let store = fixture.makeStore()
        await store.load(rootURL: fixture.root)
        let ambiguity = try #require(store.plan?.ambiguities.first)
        #expect(!store.canApply)

        let slug = try #require(ambiguity.candidateGroupSlugs.first)
        store.ambiguityChoices[ambiguity.id] = slug
        store.resolveAmbiguity(ambiguity)

        #expect(store.plan?.ambiguities.isEmpty == true)
        #expect(store.canApply)
        #expect(store.plan?.assignments.contains {
            $0.path == "sessions/M31/2026-01-01/flats/flat1.fit" && $0.groupSlug == slug
        } == true)
    }

    @Test("Applying in read-only mode is rejected with an explanatory message and touches no file")
    func applyReadOnlyIsRejected() async throws {
        let fixture = try ConversionStoreFixture.make()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.load(rootURL: fixture.root, accessMode: .readOnly)
        let host = OperationHost(center: OperationCenter())
        let source = fixture.root.appendingPathComponent("sessions/M31/2026-01-01/lights/light1.fit")

        await store.applyPlan(operationHost: host)

        #expect(store.lastReceipt == nil)
        #expect(store.planErrorMessage != nil)
        #expect(host.activeOperations.isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("Applying a physical plan in mutation-enabled mode moves the file and records the receipt")
    func applyPhysicalMutationEnabledMovesFilesAndRecordsReceipt() async throws {
        let fixture = try ConversionStoreFixture.make()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.load(rootURL: fixture.root, accessMode: .mutationEnabled)
        store.mode = .physical
        try await store.refreshPlan()
        let move = try #require(store.plan?.moves.first)
        let source = fixture.root.appendingPathComponent(move.sourceRelative)
        let destination = fixture.root.appendingPathComponent(move.destinationRelative)
        let host = OperationHost(center: OperationCenter())

        await store.applyPlan(operationHost: host)
        try await waitUntil { host.activeOperations.isEmpty }

        #expect(store.lastReceipt?.status == .applied)
        #expect(store.plan == nil)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(host.toasts.contains { $0.level == .success })
    }

    @Test("Undoing a receipt restores the moved file and flips the receipt's status")
    func undoReceiptRestoresFileAndFlipsStatus() async throws {
        let fixture = try ConversionStoreFixture.make()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.load(rootURL: fixture.root, accessMode: .mutationEnabled)
        store.mode = .physical
        try await store.refreshPlan()
        let move = try #require(store.plan?.moves.first)
        let source = fixture.root.appendingPathComponent(move.sourceRelative)
        let host = OperationHost(center: OperationCenter())
        await store.applyPlan(operationHost: host)
        try await waitUntil { host.activeOperations.isEmpty }

        await store.undoReceipt(operationHost: host)
        try await waitUntil { host.activeOperations.isEmpty }

        #expect(store.lastReceipt?.status == .rolledBack)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}
