import Foundation
import Testing
@testable import AstroCore

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-sessioncreator-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func sessionCreatorBuildsFullTreeIncludingStacksProcessedCalibration() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try SessionCreator.create(
        root: root, catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-02"
    )

    #expect(result.targetFolder == "M1_Crab_Nebula")

    let fm = FileManager.default
    func expectDir(_ relativePath: String) {
        var isDir: ObjCBool = false
        let path = root.appendingPathComponent(relativePath).path
        #expect(fm.fileExists(atPath: path, isDirectory: &isDir), "expected directory at \(relativePath)")
        #expect(isDir.boolValue)
    }

    for sub in ["lights", "flats", "darks", "biases"] {
        expectDir("sessions/M1_Crab_Nebula/2026-08-02/\(sub)")
    }
    expectDir("stacks/M1_Crab_Nebula/2026-08-02")
    expectDir("processed/M1_Crab_Nebula/2026-08-02")
    expectDir("calibration_library/darks")
    expectDir("calibration_library/flats")
    expectDir("calibration_library/biases")

    #expect(fm.fileExists(atPath: root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-02/README.txt").path))
    #expect(!result.createdURLs.isEmpty)
    for url in result.createdURLs {
        #expect(fm.fileExists(atPath: url.path))
    }
}

@Test func sessionCreatorReadmeContainsExpectedSections() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try SessionCreator.create(
        root: root, catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-02"
    )

    let readmeURL = root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-02/README.txt")
    let contents = try String(contentsOf: readmeURL, encoding: .utf8)

    #expect(contents.contains("Astro Session Notes"))
    #expect(contents.contains("Target folder : M1_Crab_Nebula"))
    #expect(contents.contains("Target (raw)  : Crab Nebula"))
    #expect(contents.contains("Catalog prefix: M1"))
    #expect(contents.contains("Date          : 2026-08-02"))
    #expect(contents.contains("Created at    :"))

    #expect(contents.contains("Folder map"))
    #expect(contents.contains("sessions/M1_Crab_Nebula/2026-08-02/lights : RAW light frames"))
    #expect(contents.contains("sessions/M1_Crab_Nebula/2026-08-02/flats  : RAW flats"))
    #expect(contents.contains("sessions/M1_Crab_Nebula/2026-08-02/darks  : RAW darks"))
    #expect(contents.contains("sessions/M1_Crab_Nebula/2026-08-02/biases   : RAW biases (if used)"))
    #expect(contents.contains("stacks/M1_Crab_Nebula/2026-08-02"))
    #expect(contents.contains("processed/M1_Crab_Nebula/2026-08-02"))

    #expect(contents.contains("Fill in metadata (recommended)"))
    for field in ["Camera:", "Sensor temp:", "Gain/Offset:", "Exposure (lights):", "Filter:", "Optics:", "Mount:", "Guiding:", "Total integration:", "Location/Bortle:", "Notes/issues:"] {
        #expect(contents.contains(field), "missing metadata field \(field)")
    }

    #expect(contents.contains("Calibration reminder"))
    #expect(contents.contains("calibration_library/"))
}

@Test func sessionCreatorThrowsInvalidInputForEmptyAfterSanitizeCatalogAndName() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    do {
        _ = try SessionCreator.create(root: root, catalogRaw: "!!!", nameRaw: "///", date: "2026-08-02")
        Issue.record("expected AstroError.invalidInput for an empty-after-sanitize target")
    } catch let AstroError.invalidInput(reason) {
        #expect(!reason.isEmpty)
    } catch {
        Issue.record("expected AstroError.invalidInput, got \(error)")
    }
}

@Test func sessionCreatorThrowsInvalidInputForNonCanonicalDate() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    do {
        _ = try SessionCreator.create(root: root, catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-02-2")
        Issue.record("expected AstroError.invalidInput for a non-canonical date")
    } catch let AstroError.invalidInput(reason) {
        #expect(!reason.isEmpty)
    } catch {
        Issue.record("expected AstroError.invalidInput, got \(error)")
    }
}

@Test func sessionCreatorCanAddAndPersistAnOptionalInitialCapture() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(path: ":memory:")
    let draft = CaptureGroupDraft(
        slug: "sv220-nb",
        displayName: "SV220 dual-band",
        sensorMode: .osc,
        signalMode: .dualBand,
        filterManufacturer: "SVBONY",
        filterModel: "SV220"
    )

    let result = try SessionCreator.create(
        root: root,
        catalogRaw: "IC 1396",
        nameRaw: "Elephant's Trunk",
        date: "2026-08-08",
        initialCapture: draft,
        db: db
    )

    let group = try #require(result.captureGroup)
    #expect(group.id != nil)
    #expect(group.target == result.targetFolder)
    #expect(group.sessionDate == "2026-08-08")
    #expect(group.filterLabel == "SVBONY SV220")
    #expect(try db.captureGroups(target: result.targetFolder, date: "2026-08-08") == [group])
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(
        "sessions/\(result.targetFolder)/2026-08-08/captures/sv220-nb/lights"
    ).path))

    let readme = try String(
        contentsOf: root.appendingPathComponent("sessions/\(result.targetFolder)/2026-08-08/README.txt"),
        encoding: .utf8
    )
    #expect(readme.contains("Initial capture"))
    #expect(readme.contains("SV220 dual-band"))
    #expect(readme.contains("captures/sv220-nb"))
}
