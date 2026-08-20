@testable import AstroApplication
import AstroCore
import Foundation
import Testing

private func sessionConversionCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func sessionConversionHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(sessionConversionCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

/// File-local fixture -- mirrors `CalibrationLinkCommandTests`' own
/// `CalibLinkFixture` and `AstroCoreTests/SessionConversionExecutorTests`'
/// `ExecutorFixture`; kept as its own copy per this codebase's convention
/// that Swift Testing fixtures live next to the test file that uses them.
private struct SessionConversionFixture {
    let root: URL
    let db: Database
    var config: AstroConfig

    static func make(exposures: [Double] = [60]) throws -> SessionConversionFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-conversion-command-\(UUID().uuidString)", isDirectory: true)
        let lights = root.appendingPathComponent("sessions/M31/2026-01-01/lights", isDirectory: true)
        try FileManager.default.createDirectory(at: lights, withIntermediateDirectories: true)
        for (offset, exposure) in exposures.enumerated() {
            try sessionConversionHeaderData([
                "SIMPLE  =                    T",
                "BITPIX  =                   16",
                "NAXIS   =                    2",
                "EXPTIME = \(exposure)",
                "BAYERPAT= 'RGGB'",
                "END",
            ]).write(to: lights.appendingPathComponent("light\(offset + 1).fit"))
        }
        let db = try Database(path: root.appendingPathComponent("index.sqlite").path)
        var config = AstroConfig()
        config.rootPath = root.path
        _ = try LibraryScanner(config: config, db: db).scan()
        return SessionConversionFixture(root: root, db: db, config: config)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func writeFITSFlat(_ relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sessionConversionHeaderData([
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    2",
            "IMAGETYP= 'FLAT'",
            "END",
        ]).write(to: url)
    }

    func rescan() throws {
        _ = try LibraryScanner(config: config, db: db).scan()
    }

    func command(accessMode: LibraryAccessMode) -> SessionConversionCommand {
        SessionConversionCommand(db: db, config: config, root: root, accessMode: accessMode)
    }
}

@Suite("SessionConversionCommand")
struct SessionConversionCommandTests {
    // (a) Read-only mode throws before touching disk.
    @Test("Apply in read-only mode throws before any filesystem or database write")
    func applyReadOnlyThrowsBeforeTouchingDisk() throws {
        let fixture = try SessionConversionFixture.make()
        defer { fixture.cleanup() }
        let command = fixture.command(accessMode: .readOnly)
        let plan = try command.plan(target: "M31", date: "2026-01-01", mode: .physical)
        let source = fixture.root.appendingPathComponent("sessions/M31/2026-01-01/lights/light1.fit")

        #expect(throws: LibraryMutationError.readOnly) {
            _ = try command.apply(plan)
        }

        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try fixture.db.captureGroups(target: "M31", date: "2026-01-01").isEmpty)
    }

    // (b) Logical mode moves nothing.
    @Test("Apply in logical mode creates capture metadata but moves no files")
    func applyLogicalModeMovesNothing() throws {
        let fixture = try SessionConversionFixture.make()
        defer { fixture.cleanup() }
        let command = fixture.command(accessMode: .mutationEnabled)
        let plan = try command.plan(target: "M31", date: "2026-01-01", mode: .logicalOnly)
        let source = fixture.root.appendingPathComponent("sessions/M31/2026-01-01/lights/light1.fit")

        let receipt = try command.apply(plan)

        #expect(receipt.moves.isEmpty)
        #expect(receipt.mode == .logicalOnly)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try fixture.db.captureGroups(target: "M31", date: "2026-01-01").count == 1)
    }

    // (c) Physical apply moves per the engine's receipt, and the receipt is returned.
    @Test("Apply in physical mode moves exactly the receipt's own moves")
    func applyPhysicalModeMovesFilesAndReturnsReceipt() throws {
        let fixture = try SessionConversionFixture.make()
        defer { fixture.cleanup() }
        let command = fixture.command(accessMode: .mutationEnabled)
        let plan = try command.plan(target: "M31", date: "2026-01-01", mode: .physical)
        let move = try #require(plan.moves.first)
        let source = fixture.root.appendingPathComponent(move.sourceRelative)
        let destination = fixture.root.appendingPathComponent(move.destinationRelative)

        let receipt = try command.apply(plan)

        #expect(receipt.moves == plan.moves)
        #expect(receipt.status == .applied)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    // (d) Rollback restores everything byte-identical.
    @Test("Rollback restores the moved file byte-identical to its original content")
    func rollbackRestoresByteIdenticalContent() throws {
        let fixture = try SessionConversionFixture.make()
        defer { fixture.cleanup() }
        let command = fixture.command(accessMode: .mutationEnabled)
        let plan = try command.plan(target: "M31", date: "2026-01-01", mode: .physical)
        let move = try #require(plan.moves.first)
        let source = fixture.root.appendingPathComponent(move.sourceRelative)
        let originalBytes = try Data(contentsOf: source)

        let receipt = try command.apply(plan)
        let rolledBack = try command.rollback(receipt)

        #expect(rolledBack.status == .rolledBack)
        #expect(FileManager.default.fileExists(atPath: source.path))
        let restoredBytes = try Data(contentsOf: source)
        #expect(restoredBytes == originalBytes)
        #expect(try fixture.db.captureGroups(target: "M31", date: "2026-01-01").isEmpty)
    }

    // (e) Double-apply of the same plan is rejected.
    @Test("A second apply of the same plan is rejected by the engine's own guard")
    func secondApplyOfSamePlanIsRejected() throws {
        let fixture = try SessionConversionFixture.make()
        defer { fixture.cleanup() }
        let command = fixture.command(accessMode: .mutationEnabled)
        let plan = try command.plan(target: "M31", date: "2026-01-01", mode: .logicalOnly)
        _ = try command.apply(plan)

        // The database layer rejects re-creating a group whose slug already
        // exists (`Database.applySessionConversionMetadata`) -- the same
        // plan applied twice hits this guard since a logical apply never
        // moves files, so the source fingerprint stays unchanged and the
        // preflight staleness check alone would not catch it.
        #expect(throws: AstroError.self) {
            _ = try command.apply(plan)
        }
        #expect(try fixture.db.captureGroups(target: "M31", date: "2026-01-01").count == 1)
    }

    // (f) Group edits are reflected in the applied result.
    @Test("editingGroup's overwritten display name, sensor, signal, and filter reach the applied capture group")
    func groupEditsAreReflectedInAppliedResult() throws {
        let fixture = try SessionConversionFixture.make()
        defer { fixture.cleanup() }
        let command = fixture.command(accessMode: .mutationEnabled)
        let plan = try command.plan(target: "M31", date: "2026-01-01", mode: .logicalOnly)
        let proposed = try #require(plan.proposedGroups.first)

        let edited = try command.editingGroup(
            slug: proposed.draft.slug,
            displayName: "Ha OSC 60s",
            sensorMode: .mono,
            signalMode: .narrowband,
            filterManufacturer: "Antlia",
            filterModel: "3nm",
            filterName: "Ha",
            in: plan
        )
        let receipt = try command.apply(edited)

        #expect(receipt.status == .applied)
        let group = try #require(
            fixture.db.captureGroups(target: "M31", date: "2026-01-01").first { $0.slug == proposed.draft.slug }
        )
        #expect(group.displayName == "Ha OSC 60s")
        #expect(group.sensorMode == .mono)
        #expect(group.signalMode == .narrowband)
        #expect(group.filterManufacturer == "Antlia")
        #expect(group.filterModel == "3nm")
        #expect(group.filterName == "Ha")
    }

    @Test("editingGroup throws when the slug no longer names a proposed group")
    func editingGroupThrowsForUnknownSlug() throws {
        let fixture = try SessionConversionFixture.make()
        defer { fixture.cleanup() }
        let command = fixture.command(accessMode: .readOnly)
        let plan = try command.plan(target: "M31", date: "2026-01-01", mode: .logicalOnly)

        #expect(throws: AstroError.self) {
            _ = try command.editingGroup(
                slug: "does-not-exist",
                displayName: "x", sensorMode: .unknown, signalMode: .unknown,
                filterManufacturer: nil, filterModel: nil, filterName: nil,
                in: plan
            )
        }
    }

    @Test("resolvingAmbiguity assigns an unresolved calibration frame to the chosen group and clears the ambiguity")
    func resolvingAmbiguityAssignsChosenGroup() throws {
        let fixture = try SessionConversionFixture.make(exposures: [60, 120])
        defer { fixture.cleanup() }
        try fixture.writeFITSFlat("sessions/M31/2026-01-01/flats/flat1.fit")
        try fixture.rescan()
        let command = fixture.command(accessMode: .readOnly)
        let plan = try command.plan(target: "M31", date: "2026-01-01", mode: .logicalOnly)
        let ambiguity = try #require(plan.ambiguities.first)
        #expect(ambiguity.candidateGroupSlugs.count >= 2)
        let chosenSlug = try #require(ambiguity.candidateGroupSlugs.first)

        let resolved = try command.resolvingAmbiguity(id: ambiguity.id, withGroupSlug: chosenSlug, in: plan)

        #expect(!resolved.ambiguities.contains { $0.id == ambiguity.id })
        #expect(resolved.assignments.contains {
            $0.path == "sessions/M31/2026-01-01/flats/flat1.fit" && $0.groupSlug == chosenSlug
        })
    }
}
