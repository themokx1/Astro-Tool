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

@Test func sessionCreatorUsesValidatedCatalogCanonicalFolderOverride() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try SessionCreator.create(
        root: root,
        catalogRaw: "IC 1396",
        nameRaw: "Elephant's Trunk Nebula",
        date: "2026-08-10",
        targetFolderOverride: "IC_1396_Elephants_Trunk_Nebula"
    )

    #expect(result.targetFolder == "IC_1396_Elephants_Trunk_Nebula")
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(
        "sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-10/lights"
    ).path))
}

@Test func catalogTargetFolderResolutionReusesAnEmptyUnscannedExistingDirectory() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = "IC_1396_Elephant_Trunk_Nebula"
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("sessions/\(existing)"),
        withIntermediateDirectories: true
    )
    let target = try #require(TargetCatalog.all.first { $0.designation == "IC 1396" })

    let resolved = SessionCreator.targetFolder(
        for: target, root: root, indexedFolders: []
    )

    #expect(resolved == existing)
    #expect(resolved != TargetCatalog.canonicalFolderName(for: target))
}

@Test func sessionCreatorRejectsUnsafeFolderOverride() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: AstroError.self) {
        _ = try SessionCreator.create(
            root: root, catalogRaw: "IC 1396", nameRaw: "Elephant",
            date: "2026-08-10", targetFolderOverride: "../outside"
        )
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

/// W3-10: V2's "New Session" sheet previews the exact paths a create will
/// produce via `WriteGuard.sessionTreeRelativePaths` BEFORE the user
/// confirms -- this pins that, for tricky catalog/name inputs (a dash-form
/// designation, an apostrophe in the name, a custom non-catalog name), that
/// preview list is exactly the set of `sessions`/`stacks`/`processed`
/// directories and the README file `SessionCreator.create` actually
/// produces, so the two can never silently drift apart. Deliberately checks
/// as SETS (`Set(... ) == Set(...)`), not ordered arrays, since ordering is
/// an implementation detail neither side promises to match the other on.
@Test(arguments: [
    ("IC 1396", "Elephant's Trunk Nebula", "2026-08-11"),
    ("Sh2", "101", "2026-08-12"),
    ("", "My Custom Target!!", "2026-08-13"),
])
func previewedRelativePathsMatchWhatSessionCreatorActuallyCreates(
    catalogRaw: String, nameRaw: String, date: String
) throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try SessionCreator.create(root: root, catalogRaw: catalogRaw, nameRaw: nameRaw, date: date)

    let previewedRelativePaths = try WriteGuard.sessionTreeRelativePaths(target: result.targetFolder, dateDir: date)
    let previewedURLs = Set(previewedRelativePaths.map { root.appendingPathComponent($0).standardizedFileURL })

    let calibBase = root.appendingPathComponent("calibration_library", isDirectory: true).standardizedFileURL.path
    let actualSessionScopedURLs = Set(result.createdURLs.map(\.standardizedFileURL).filter {
        !$0.path.hasPrefix(calibBase + "/")
    })

    #expect(previewedURLs == actualSessionScopedURLs)
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

/// W3-10: previews the exact capture-tree paths `CaptureManager.create`
/// will produce -- pins `WriteGuard.captureTreeRelativePaths` against what
/// `CaptureManager.create` (called directly, the "add a second/third
/// capture to an already-existing session" path) actually creates, so the
/// two can never silently drift.
@Test func previewedCaptureRelativePathsMatchWhatCaptureManagerActuallyCreates() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(path: ":memory:")
    _ = try SessionCreator.create(root: root, catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11")

    let draft = CaptureGroupDraft(
        slug: "sv220-nb", displayName: "SV220 dual-band", sensorMode: .osc, signalMode: .dualBand,
        filterManufacturer: "SVBONY", filterModel: "SV220"
    )
    let result = try CaptureManager.create(root: root, db: db, target: "M1_Crab_Nebula", date: "2026-08-11", draft: draft)

    let previewedRelativePaths = try WriteGuard.captureTreeRelativePaths(
        target: "M1_Crab_Nebula", dateDir: "2026-08-11", slug: "sv220-nb"
    )
    let previewedURLs = Set(previewedRelativePaths.map { root.appendingPathComponent($0).standardizedFileURL })
    let actualURLs = Set(result.createdURLs.map(\.standardizedFileURL))
    #expect(previewedURLs == actualURLs)
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

/// W3-10 owner correction (2026-08-17, screenshot of the shipped preview):
/// "ezeket feleslegesen csinálja meg, a captures-be kellenek csak" (these
/// are made unnecessarily; they only belong under captures/) -- when a
/// session is created WITH an initial capture, the classic date-level
/// lights/flats/darks/biases quartet must NOT be created at all (it only
/// misleads the card-copy workflow once the capture owns its own per-filter
/// quartet); only the session root, the README, and
/// captures/<slug>/{lights,flats,darks,biases} come into being. The
/// capture-LESS overload (tested elsewhere) is unaffected -- a session with
/// no capture at all still needs the classic quartet as ITS raw-frame
/// destination.
@Test func sessionCreatorWithInitialCaptureOmitsClassicDateLevelQuartet() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try Database(path: ":memory:")
    let draft = CaptureGroupDraft(
        slug: "sv220-nb", displayName: "SV220 dual-band", sensorMode: .osc, signalMode: .dualBand,
        filterManufacturer: "SVBONY", filterModel: "SV220"
    )

    let result = try SessionCreator.create(
        root: root, catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-17",
        initialCapture: draft, db: db
    )

    let fm = FileManager.default
    let sessionDir = "sessions/\(result.targetFolder)/2026-08-17"
    for sub in ["lights", "flats", "darks", "biases"] {
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("\(sessionDir)/\(sub)").path), "\(sub) must not exist at the date level")
    }
    #expect(fm.fileExists(atPath: root.appendingPathComponent("\(sessionDir)/README.txt").path))
    for sub in ["lights", "flats", "darks", "biases"] {
        #expect(fm.fileExists(atPath: root.appendingPathComponent("\(sessionDir)/captures/sv220-nb/\(sub)").path))
    }
    // None of `result.createdURLs` may be one of the classic date-level
    // quartet paths.
    let forbidden = Set(["lights", "flats", "darks", "biases"].map {
        root.appendingPathComponent("\(sessionDir)/\($0)").standardizedFileURL
    })
    #expect(Set(result.createdURLs.map(\.standardizedFileURL)).isDisjoint(with: forbidden))

    let readme = try String(
        contentsOf: root.appendingPathComponent("\(sessionDir)/README.txt"), encoding: .utf8
    )
    #expect(!readme.contains("lights : RAW light frames"))
    #expect(!readme.contains("flats  : RAW flats"))
    #expect(!readme.contains("darks  : RAW darks"))
    #expect(!readme.contains("biases   : RAW biases"))
    #expect(readme.contains("captures/sv220-nb"))
}
