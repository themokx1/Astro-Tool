@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// Fixture mirrors `NightNotesCommandTests`/`CalibrationLinkCommandTests`'
/// own shape: an isolated temp-dir index DB, kept as a file-local copy per
/// this codebase's convention.
private struct AssignmentFixture {
    let dbDir: URL
    let db: Database

    static func make() throws -> AssignmentFixture {
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-assignment-tests-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        return AssignmentFixture(dbDir: dbDir, db: db)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dbDir)
    }

    @discardableResult
    func insertLight(
        target: String = "IC_1396_Elephants_Trunk_Nebula",
        date: String = "2026-08-08",
        path suffix: String
    ) throws -> Int64 {
        try db.upsertFile(FileRecord(
            path: "sessions/\(target)/\(date)/lights/\(suffix)",
            size: 1024, mtime: 1, ext: "cr3", kind: "raw",
            area: .sessions, target: target, sessionDate: date, role: .light, scannedAt: 1
        ))
    }
}

@Suite("CaptureAssignmentCommand")
struct CaptureAssignmentCommandTests {
    @Test(".readOnly mode refuses to write, before touching the database")
    func readOnlyModeThrows() throws {
        let fixture = try AssignmentFixture.make()
        defer { fixture.cleanup() }
        let fileID = try fixture.insertLight(path: "IMG_0001.cr3")
        let groupID = try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-08",
            slug: "canon-night", displayName: "Canon night"
        ))
        let command = CaptureAssignmentCommand(db: fixture.db, config: AstroConfig(), accessMode: .readOnly)

        #expect(throws: LibraryMutationError.readOnly) {
            try command.assign(
                target: "IC_1396_Elephants_Trunk_Nebula", date: "2026-08-08",
                paths: ["sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/IMG_0001.cr3"],
                groupID: groupID, signalOverride: .dualBand
            )
        }
        #expect(try fixture.db.fileCaptureAssignment(fileID: fileID) == nil)
    }

    @Test("assign() writes exactly the same UPSERT row shape V1's AppState.assignCaptureMetadata writes")
    func assignWritesUpsertRow() throws {
        let fixture = try AssignmentFixture.make()
        defer { fixture.cleanup() }
        let path = "sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/IMG_0001.cr3"
        let fileID = try fixture.insertLight(path: "IMG_0001.cr3")
        let groupID = try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-08",
            slug: "canon-night", displayName: "Canon night"
        ))
        let command = CaptureAssignmentCommand(db: fixture.db, config: AstroConfig(), accessMode: .mutationEnabled)

        let receipt = try command.assign(
            target: "IC_1396_Elephants_Trunk_Nebula", date: "2026-08-08",
            paths: [path], groupID: groupID,
            signalOverride: .dualBand, filterManufacturerOverride: "Optolong", filterModelOverride: "L-eXtreme"
        )

        #expect(receipt.assignedPaths == [path])
        let stored = try #require(try fixture.db.fileCaptureAssignment(fileID: fileID))
        #expect(stored.captureGroupID == groupID)
        #expect(stored.signalModeOverride == .dualBand)
        #expect(stored.filterManufacturerOverride == "Optolong")
        #expect(stored.filterModelOverride == "L-eXtreme")
        #expect(stored.assignmentSource == "app")
    }

    @Test("A path outside the given target/date scope is rejected without throwing for the whole batch")
    func scopedPathsOutsideSessionAreSkipped() throws {
        let fixture = try AssignmentFixture.make()
        defer { fixture.cleanup() }
        let inScopePath = "sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/IMG_0001.cr3"
        try fixture.insertLight(path: "IMG_0001.cr3")
        try fixture.insertLight(target: "M31", date: "2026-08-09", path: "IMG_0002.cr3")
        let groupID = try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-08",
            slug: "canon-night", displayName: "Canon night"
        ))
        let command = CaptureAssignmentCommand(db: fixture.db, config: AstroConfig(), accessMode: .mutationEnabled)

        let receipt = try command.assign(
            target: "IC_1396_Elephants_Trunk_Nebula", date: "2026-08-08",
            paths: [inScopePath, "sessions/M31/2026-08-09/lights/IMG_0002.cr3"],
            groupID: groupID, signalOverride: .dualBand
        )

        #expect(receipt.assignedPaths == [inScopePath])
    }

    @Test("A group belonging to a different session is rejected outright")
    func groupScopeMismatchThrows() throws {
        let fixture = try AssignmentFixture.make()
        defer { fixture.cleanup() }
        try fixture.insertLight(path: "IMG_0001.cr3")
        let groupID = try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "M31", sessionDate: "2026-08-09",
            slug: "other-night", displayName: "Other night"
        ))
        let command = CaptureAssignmentCommand(db: fixture.db, config: AstroConfig(), accessMode: .mutationEnabled)

        #expect(throws: CaptureAssignmentCommandError.groupScopeMismatch(groupID: groupID)) {
            try command.assign(
                target: "IC_1396_Elephants_Trunk_Nebula", date: "2026-08-08",
                paths: ["sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/IMG_0001.cr3"],
                groupID: groupID
            )
        }
    }

    @Test("clear() deletes the assignment row, restoring the resolver's non-override verdict")
    func clearRevokesTheOverride() throws {
        let fixture = try AssignmentFixture.make()
        defer { fixture.cleanup() }
        let path = "sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/IMG_0001.cr3"
        let fileID = try fixture.insertLight(path: "IMG_0001.cr3")
        let groupID = try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-08",
            slug: "canon-night", displayName: "Canon night"
        ))
        let command = CaptureAssignmentCommand(db: fixture.db, config: AstroConfig(), accessMode: .mutationEnabled)
        try command.assign(
            target: "IC_1396_Elephants_Trunk_Nebula", date: "2026-08-08",
            paths: [path], groupID: groupID, signalOverride: .dualBand
        )
        #expect(try fixture.db.fileCaptureAssignment(fileID: fileID) != nil)

        try command.clear(paths: [path])

        #expect(try fixture.db.fileCaptureAssignment(fileID: fileID) == nil)
    }

    @Test("clear() in .readOnly mode throws before deleting anything")
    func clearReadOnlyThrows() throws {
        let fixture = try AssignmentFixture.make()
        defer { fixture.cleanup() }
        let path = "sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/IMG_0001.cr3"
        let fileID = try fixture.insertLight(path: "IMG_0001.cr3")
        let groupID = try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-08",
            slug: "canon-night", displayName: "Canon night"
        ))
        let mutableCommand = CaptureAssignmentCommand(db: fixture.db, config: AstroConfig(), accessMode: .mutationEnabled)
        try mutableCommand.assign(
            target: "IC_1396_Elephants_Trunk_Nebula", date: "2026-08-08",
            paths: [path], groupID: groupID, signalOverride: .dualBand
        )
        let readOnlyCommand = CaptureAssignmentCommand(db: fixture.db, config: AstroConfig(), accessMode: .readOnly)

        #expect(throws: LibraryMutationError.readOnly) {
            try readOnlyCommand.clear(paths: [path])
        }
        #expect(try fixture.db.fileCaptureAssignment(fileID: fileID) != nil)
    }

    @Test("An explicit .unfiltered override with no filter fields is honored as 'no filter', not 'no override'")
    func explicitUnfilteredOverrideClearsFilter() throws {
        let fixture = try AssignmentFixture.make()
        defer { fixture.cleanup() }
        let path = "sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/IMG_0001.cr3"
        try fixture.insertLight(path: "IMG_0001.cr3")
        let groupID = try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-08",
            slug: "canon-night", displayName: "Canon night", signalMode: .dualBand, filterName: "SV220"
        ))
        let command = CaptureAssignmentCommand(db: fixture.db, config: AstroConfig(), accessMode: .mutationEnabled)

        try command.assign(
            target: "IC_1396_Elephants_Trunk_Nebula", date: "2026-08-08",
            paths: [path], groupID: groupID, signalOverride: .unfiltered
        )

        let resolver = try CaptureResolver.load(db: fixture.db)
        let file = try #require(try fixture.db.file(path: path))
        let resolved = resolver.resolve(file: file, meta: nil)
        #expect(resolved.signalMode == .unfiltered)
        #expect(resolved.filterLabel == nil)
    }

    // MARK: - filterGaps()

    @Test("filterGaps() groups frames with no resolved filter by target/date/label")
    func filterGapsGroupsByScope() throws {
        let fixture = try AssignmentFixture.make()
        defer { fixture.cleanup() }
        try fixture.insertLight(path: "IMG_0001.cr3")
        try fixture.insertLight(path: "IMG_0002.cr3")
        let command = CaptureAssignmentCommand(db: fixture.db, config: AstroConfig(), accessMode: .readOnly)

        let gaps = try command.filterGaps()

        #expect(gaps.count == 1)
        #expect(gaps.first?.paths.count == 2)
        #expect(gaps.first?.target == "IC_1396_Elephants_Trunk_Nebula")
        #expect(gaps.first?.date == "2026-08-08")
    }

    @Test("filterGaps() excludes frames that already resolve a filter")
    func filterGapsExcludesResolvedFrames() throws {
        let fixture = try AssignmentFixture.make()
        defer { fixture.cleanup() }
        let path = "sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/IMG_0001.cr3"
        try fixture.insertLight(path: "IMG_0001.cr3")
        let groupID = try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-08",
            slug: "canon-night", displayName: "Canon night", signalMode: .dualBand, filterName: "SV220"
        ))
        let command = CaptureAssignmentCommand(db: fixture.db, config: AstroConfig(), accessMode: .mutationEnabled)
        try command.assign(
            target: "IC_1396_Elephants_Trunk_Nebula", date: "2026-08-08",
            paths: [path], groupID: groupID
        )

        #expect(try command.filterGaps().isEmpty)
    }

    // MARK: - suggestRule()

    @Test("suggestRule() infers dual-band directly from the group's own slug text")
    func suggestRuleFromSlugText() throws {
        let fixture = try AssignmentFixture.make()
        defer { fixture.cleanup() }
        let groupID = try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-08",
            slug: "sv220_dual-band", displayName: "SV220 dual-band"
        ))
        let command = CaptureAssignmentCommand(db: fixture.db, config: AstroConfig(), accessMode: .readOnly)

        let suggestion = try #require(try command.suggestRule(groupID: groupID))
        #expect(suggestion.signalMode == .dualBand)
        #expect(suggestion.basis == .slugNameText)
    }

    @Test("suggestRule() proposes a sibling night's declared filter when every same-slug sibling agrees")
    func suggestRuleFromAgreeingSiblingNight() throws {
        let fixture = try AssignmentFixture.make()
        defer { fixture.cleanup() }
        try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-01",
            slug: "canon-night", displayName: "Canon night",
            signalMode: .narrowband, filterName: "Ha"
        ))
        let groupID = try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-08",
            slug: "canon-night", displayName: "Canon night"
        ))
        let command = CaptureAssignmentCommand(db: fixture.db, config: AstroConfig(), accessMode: .readOnly)

        let suggestion = try #require(try command.suggestRule(groupID: groupID))
        #expect(suggestion.signalMode == .narrowband)
        #expect(suggestion.filterName == "Ha")
    }

    @Test("suggestRule() stays empty when sibling nights disagree -- no guess from mixed evidence")
    func suggestRuleEmptyWhenSiblingsDisagree() throws {
        let fixture = try AssignmentFixture.make()
        defer { fixture.cleanup() }
        try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-01",
            slug: "canon-night", displayName: "Canon night",
            signalMode: .narrowband, filterName: "Ha"
        ))
        try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-02",
            slug: "canon-night", displayName: "Canon night",
            signalMode: .broadband, filterName: "CLS"
        ))
        let groupID = try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-08",
            slug: "canon-night", displayName: "Canon night"
        ))
        let command = CaptureAssignmentCommand(db: fixture.db, config: AstroConfig(), accessMode: .readOnly)

        #expect(try command.suggestRule(groupID: groupID) == nil)
    }

    @Test("suggestRule() stays empty for an unknown group id")
    func suggestRuleEmptyForUnknownGroup() throws {
        let fixture = try AssignmentFixture.make()
        defer { fixture.cleanup() }
        let command = CaptureAssignmentCommand(db: fixture.db, config: AstroConfig(), accessMode: .readOnly)

        #expect(try command.suggestRule(groupID: 9999) == nil)
    }
}

@Suite("CaptureRuleSuggestionEngine")
struct CaptureRuleSuggestionEngineTests {
    @Test("Returns nil for a group that already has both signal mode and filter")
    func nilWhenAlreadyComplete() {
        let group = CaptureGroupRecord(
            target: "M31", sessionDate: "2026-08-08", slug: "canon-night", displayName: "Canon night",
            signalMode: .broadband, filterName: "CLS"
        )
        #expect(CaptureRuleSuggestionEngine.suggest(for: group, allGroups: []) == nil)
    }

    @Test("Falls back to the default imaging setup for an OSC group with no other evidence")
    func fallsBackToDefaultImagingSetup() {
        let group = CaptureGroupRecord(
            target: "M31", sessionDate: "2026-08-08", slug: "unlabeled", displayName: "Unlabeled",
            sensorMode: .osc
        )
        let setup = ImagingSetupProfile(
            id: "asi2600mc", name: "ASI2600MC", cameraName: "ZWO ASI2600MC Pro", cameraKind: .dedicatedAstro,
            sensorWidthMM: 23.5, sensorHeightMM: 15.7, focalLengthMinMM: 261, focalLengthMaxMM: 261,
            defaultFocalLengthMM: 261, isDefault: true, defaultFilterSignalMode: .dualBand, defaultFilterName: "SV220"
        )

        let suggestion = CaptureRuleSuggestionEngine.suggest(for: group, allGroups: [], imagingSetups: [setup])

        #expect(suggestion?.signalMode == .dualBand)
        #expect(suggestion?.filterName == "SV220")
        #expect(suggestion?.basis == .defaultImagingSetup)
    }

    @Test("Never applies the default imaging setup fallback to a mono group")
    func neverAppliesDefaultToMono() {
        let group = CaptureGroupRecord(
            target: "M31", sessionDate: "2026-08-08", slug: "unlabeled", displayName: "Unlabeled",
            sensorMode: .mono
        )
        let setup = ImagingSetupProfile(
            id: "asi2600mm", name: "ASI2600MM", cameraName: "ZWO ASI2600MM Pro", cameraKind: .monochrome,
            sensorWidthMM: 23.5, sensorHeightMM: 15.7, focalLengthMinMM: 261, focalLengthMaxMM: 261,
            defaultFocalLengthMM: 261, isDefault: true, defaultFilterSignalMode: .dualBand
        )

        #expect(CaptureRuleSuggestionEngine.suggest(for: group, allGroups: [], imagingSetups: [setup]) == nil)
    }
}
