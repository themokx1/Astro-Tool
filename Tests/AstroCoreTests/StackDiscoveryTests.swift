import Foundation
import Testing
@testable import AstroCore

private func makeMemoryDB() throws -> Database {
    try Database(path: ":memory:")
}

/// Inserts one `files` row (no `fits_meta`) with a fresh, unique inode --
/// same "fake inode so dedup logic never accidentally collapses rows"
/// convention `FieldGeometryTests`/`NightHealthTests` use.
@discardableResult
private func insertFile(
    db: Database,
    path: String,
    size: Int64 = 50_000_000,
    ext: String,
    area: LibraryArea,
    target: String? = nil,
    sessionDate: String? = nil,
    role: FrameRole = .other,
    inode: Int64? = nil
) throws -> Int64 {
    let fileID = try db.upsertFile(
        FileRecord(
            path: path, size: size, mtime: 1_700_000_000, ext: ext, kind: "fits",
            area: area, target: target, sessionDate: sessionDate, role: role,
            scannedAt: 1_700_000_100
        )
    )
    try db.backfillInode(id: fileID, inode: inode ?? fileID, nlink: 1)
    return fileID
}

// MARK: - parseStackName

@Test func parseStackNameParsesRealASIAirAutosaveNaming() throws {
    let parsed = StackDiscovery.parseStackName("NGC_7000_106x120sec_12720s_drizzle-1-0x_2026-06-06_1627_og.fit")
    #expect(parsed?.frames == 106)
    #expect(parsed?.subSeconds == 120.0)
    #expect(parsed?.totalSeconds == 12720.0)
}

@Test func parseStackNameParsesSecondRealExample() throws {
    // Real on-disk name, IC1805-1848_Heart-and-Soul_Nebula/2025-12-27.
    let parsed = StackDiscovery.parseStackName("Sadr_____056x120sec_6720s_2025-12-28_1837_og.fit")
    #expect(parsed?.frames == 56)
    #expect(parsed?.subSeconds == 120.0)
    #expect(parsed?.totalSeconds == 6720.0)
}

@Test func parseStackNameToleratesZeroSecZeroSPlaceholder() throws {
    // Real on-disk name, a mosaic panel-prep light with no baked-in
    // exposure info -- the regex still matches, raw zeros and all; it's
    // `looksLikeStackOutput`'s/`StackFile`'s job to treat those as "unknown".
    let parsed = StackDiscovery.parseStackName("Unknown_344x0sec_0s_2026-06-20_1640_paneled_mosaic_final.fit")
    #expect(parsed?.frames == 344)
    #expect(parsed?.subSeconds == 0)
    #expect(parsed?.totalSeconds == 0)
}

@Test func parseStackNameReturnsNilWhenPatternAbsent() throws {
    #expect(StackDiscovery.parseStackName("Ha.fit") == nil)
    #expect(StackDiscovery.parseStackName("light_0001.fit") == nil)
}

// MARK: - looksLikeStackOutput

@Test func looksLikeStackOutputAcceptsASIAirAutosaveNaming() throws {
    #expect(StackDiscovery.looksLikeStackOutput(
        fileName: "NGC_7000_106x120sec_12720s_drizzle-1-0x_2026-06-06_1627_og.fit", ext: "fit", sizeBytes: 308_154_240
    ))
}

@Test func looksLikeStackOutputRejectsResidueEvenWhenItContainsStacked() throws {
    // Real on-disk name, IC1805-1848_Heart-and-Soul_Nebula/2025-12-30 --
    // starts with the Siril "registered" `r_` prefix (a `config.residuePatterns`
    // default, "r_*") despite also containing "_stacked".
    #expect(!StackDiscovery.looksLikeStackOutput(fileName: "r_merged_two_nights_stacked.fit", ext: "fit", sizeBytes: 200_000_000))
}

@Test func looksLikeStackOutputAcceptsButFlagsCalibrationMasterNaming() throws {
    // Real on-disk name, M42_Orion/2026-01-17/masters/.
    #expect(StackDiscovery.looksLikeStackOutput(fileName: "session1_6s_2026-01-17_-9.6C_flats_stacked.fit", ext: "fit", sizeBytes: 20_000_000))
}

@Test func looksLikeStackOutputAcceptsDSSAutosaveTIF() throws {
    #expect(StackDiscovery.looksLikeStackOutput(fileName: "Autosave001.tif", ext: "tif", sizeBytes: 40_000_000))
}

@Test func looksLikeStackOutputAcceptsASIAirNumberedLiveStackCapture() throws {
    // Real on-disk name, NGC_7000_North_American_Nebula/2026-05-23/Asi Air/.
    #expect(StackDiscovery.looksLikeStackOutput(
        fileName: "Stacked112_NGC 7000_120.0s_Bin1_2600MC_gain100_20260523-024212_-10.0C.fit", ext: "fit", sizeBytes: 90_000_000
    ))
}

@Test func looksLikeStackOutputAcceptsMosaicFinalNaming() throws {
    #expect(StackDiscovery.looksLikeStackOutput(fileName: "paneled_mosaic_stacked.fit", ext: "fit", sizeBytes: 90_000_000))
}

@Test func looksLikeStackOutputRejectsZeroByteFile() throws {
    #expect(!StackDiscovery.looksLikeStackOutput(fileName: "result.fit", ext: "fit", sizeBytes: 0))
}

@Test func looksLikeStackOutputRejectsPlainLightFrameName() throws {
    #expect(!StackDiscovery.looksLikeStackOutput(fileName: "light_0001.fit", ext: "fit", sizeBytes: 20_000_000))
}

@Test func looksLikeStackOutputRejectsBareChannelNameWithNoStackSignal() throws {
    // Real on-disk name, IC1805-1848_Heart-and-Soul_Nebula/2025-12-27 --
    // an OSC-split channel frame, not a finished stack by itself.
    #expect(!StackDiscovery.looksLikeStackOutput(fileName: "Ha.fit", ext: "fit", sizeBytes: 90_000_000))
}

@Test func looksLikeStackOutputRejectsZeroSecZeroSNameWithoutMosaicMarker() throws {
    // Real on-disk name, a raw mosaic panel-prep light sitting under
    // stacks/<T>/<date>/paneled_mosaic_process/lights/ -- ASIAIR's own
    // "no exposure info baked into this name" placeholder, not a stack.
    #expect(!StackDiscovery.looksLikeStackOutput(fileName: "Unknown_038x0sec_0s_2026-04-25_1737_session1.fit", ext: "fit", sizeBytes: 20_000_000))
}

// MARK: - discover: location signal (target/date from path)

@Test func discoverFindsStackUnderCanonicalStacksLocation() throws {
    let db = try makeMemoryDB()
    try insertFile(
        db: db, path: "stacks/NGC_7000_North_American_Nebula/2026-06-06/NGC_7000_106x120sec_12720s_drizzle-1-0x_2026-06-06_1627_og.fit",
        ext: "fit", area: .stacks, target: "NGC_7000_North_American_Nebula", sessionDate: "2026-06-06", role: .stack
    )

    let reports = try StackDiscovery.discover(db: db, config: AstroConfig())
    let target = try #require(reports.first { $0.target == "NGC_7000_North_American_Nebula" })
    let stack = try #require(target.stacks.first)
    #expect(stack.sessionDate == "2026-06-06")
    #expect(stack.framesFromName == 106)
    #expect(stack.subSecondsFromName == 120.0)
    #expect(stack.totalSecondsFromName == 12720.0)
    // Filename also literally mentions the target -> both signals agree.
    #expect(stack.matchSource == "mappa+fájlnév")
    #expect(stack.kind == "stack")
}

@Test func discoverMarksPathOnlyMatchWhenFilenameDoesNotMentionTarget() throws {
    // Real on-disk shape: IC1805-1848_Heart-and-Soul_Nebula's ASIAIR stack
    // is named after the guide star ("Sadr"), not the target itself.
    let db = try makeMemoryDB()
    try insertFile(
        db: db, path: "stacks/IC1805-1848_Heart-and-Soul_Nebula/2025-12-27/Sadr_____056x120sec_6720s_2025-12-28_1837_og.fit",
        ext: "fit", area: .stacks, target: "IC1805-1848_Heart-and-Soul_Nebula", sessionDate: "2025-12-27", role: .stack
    )

    let stacks = try StackDiscovery.stacks(target: "IC1805-1848_Heart-and-Soul_Nebula", db: db, config: AstroConfig())
    let stack = try #require(stacks.first)
    #expect(stack.matchSource == "mappa")
}

@Test func discoverFindsStackSittingAtTargetsStacksRootWithNoDateSubfolder() throws {
    // Real on-disk shape: stacks/M_Milky_Way/Autosave.tif -- no date
    // subfolder at all, so `PathClassifier` gives a target but no date.
    let db = try makeMemoryDB()
    try insertFile(
        db: db, path: "stacks/M_Milky_Way/Autosave.tif",
        ext: "tif", area: .stacks, target: "M_Milky_Way", sessionDate: nil, role: .stack
    )

    let stacks = try StackDiscovery.stacks(target: "M_Milky_Way", db: db, config: AstroConfig())
    let stack = try #require(stacks.first)
    #expect(stack.sessionDate == nil)
    #expect(stack.matchSource == "mappa")
}

// MARK: - discover: kind flagging

@Test func discoverFlagsCalibrationMasterAsMasterCandidateButStillListsIt() throws {
    let db = try makeMemoryDB()
    try insertFile(
        db: db, path: "sessions/M42_Orion/2026-01-17/masters/session1_6s_2026-01-17_-9.6C_flats_stacked.fit",
        ext: "fit", area: .sessions, target: "M42_Orion", sessionDate: "2026-01-17", role: .other
    )

    let stacks = try StackDiscovery.stacks(target: "M42_Orion", db: db, config: AstroConfig())
    let stack = try #require(stacks.first)
    #expect(stack.kind == "master-jelölt")
}

@Test func discoverFlagsBigTIFUnderProcessedAsFeldolgozott() throws {
    let db = try makeMemoryDB()
    try insertFile(
        db: db, path: "processed/M42_Orion/2026-01-17/result_final.tif",
        size: 200_000_000, ext: "tif", area: .processed, target: "M42_Orion", sessionDate: "2026-01-17", role: .processed
    )

    let stacks = try StackDiscovery.stacks(target: "M42_Orion", db: db, config: AstroConfig())
    let stack = try #require(stacks.first)
    #expect(stack.kind == "feldolgozott")
}

// MARK: - discover: filename signal (target/date resolved outside stacks/processed)

@Test func discoverMatchesRootLevelFileToKnownTargetByFilenameTokens() throws {
    let db = try makeMemoryDB()
    // Establishes NGC_7000_North_American_Nebula as a "known target".
    try insertFile(
        db: db, path: "sessions/NGC_7000_North_American_Nebula/2026-06-06/lights/l1.fit",
        ext: "fit", area: .sessions, target: "NGC_7000_North_American_Nebula", sessionDate: "2026-06-06", role: .light
    )
    // A stack-looking file sitting loose at the library root, no target in
    // its own path at all (area == .other).
    try insertFile(
        db: db, path: "NGC_7000_106x120sec_12720s_2026-06-06_stray_result_stacked.fit",
        ext: "fit", area: .other, target: nil, sessionDate: nil
    )

    let stacks = try StackDiscovery.stacks(target: "NGC_7000_North_American_Nebula", db: db, config: AstroConfig())
    let rootMatch = try #require(stacks.first { $0.path == "NGC_7000_106x120sec_12720s_2026-06-06_stray_result_stacked.fit" })
    #expect(rootMatch.matchSource == "fájlnév")
    #expect(rootMatch.sessionDate == "2026-06-06")
}

@Test func discoverGroupsUnmatchedStackLookingFileAsBesorolatlan() throws {
    let db = try makeMemoryDB()
    try insertFile(
        db: db, path: "sessions/M42_Orion/2026-01-17/lights/l1.fit",
        ext: "fit", area: .sessions, target: "M42_Orion", sessionDate: "2026-01-17", role: .light
    )
    // Stack-looking (Autosave*.tif), but mentions no known target at all.
    try insertFile(db: db, path: "Autosave002.tif", ext: "tif", area: .other, target: nil, sessionDate: nil)

    let reports = try StackDiscovery.discover(db: db, config: AstroConfig())
    let unclassified = try #require(reports.first { $0.target == "" })
    #expect(unclassified.displayName == "Besorolatlan")
    #expect(unclassified.stacks.contains { $0.path == "Autosave002.tif" })
    // "Besorolatlan" sorts last.
    #expect(reports.last?.target == "")
}

// MARK: - discover: dedup

@Test func discoverDedupsHardlinkedFilePreferringStacksLocatedCopy() throws {
    let db = try makeMemoryDB()
    let sharedInode: Int64 = 999_001
    try insertFile(
        db: db, path: "processed/M42_Orion/2026-01-17/result.fit",
        ext: "fit", area: .processed, target: "M42_Orion", sessionDate: "2026-01-17", role: .processed, inode: sharedInode
    )
    try insertFile(
        db: db, path: "stacks/M42_Orion/2026-01-17/result.fit",
        ext: "fit", area: .stacks, target: "M42_Orion", sessionDate: "2026-01-17", role: .stack, inode: sharedInode
    )

    let stacks = try StackDiscovery.stacks(target: "M42_Orion", db: db, config: AstroConfig())
    #expect(stacks.count == 1)
    #expect(stacks.first?.path == "stacks/M42_Orion/2026-01-17/result.fit")
}

// MARK: - discover: dimensions

@Test func discoverFillsDimensionsFromFITSMeta() throws {
    let db = try makeMemoryDB()
    let fileID = try insertFile(
        db: db, path: "stacks/M42_Orion/2026-01-17/result.fit",
        ext: "fit", area: .stacks, target: "M42_Orion", sessionDate: "2026-01-17", role: .stack
    )
    try db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, naxis1: 6248, naxis2: 4176))

    let stacks = try StackDiscovery.stacks(target: "M42_Orion", db: db, config: AstroConfig())
    #expect(stacks.first?.dimensions == "6248×4176")
}

// MARK: - discover: sort order

@Test func discoverSortsByTotalSecondsDescendingThenSizeDescending() throws {
    let db = try makeMemoryDB()
    try insertFile(
        db: db, path: "stacks/M42_Orion/2026-01-17/M42_Orion_050x60sec_3000s_a.fit",
        size: 10_000_000, ext: "fit", area: .stacks, target: "M42_Orion", sessionDate: "2026-01-17", role: .stack
    )
    try insertFile(
        db: db, path: "stacks/M42_Orion/2026-01-18/M42_Orion_200x60sec_12000s_b.fit",
        size: 5_000_000, ext: "fit", area: .stacks, target: "M42_Orion", sessionDate: "2026-01-18", role: .stack
    )
    // No parsed total at all -- sorts after every dated one, by size among ties.
    try insertFile(
        db: db, path: "stacks/M42_Orion/Autosave.tif",
        size: 20_000_000, ext: "tif", area: .stacks, target: "M42_Orion", sessionDate: nil, role: .stack
    )

    let stacks = try StackDiscovery.stacks(target: "M42_Orion", db: db, config: AstroConfig())
    #expect(stacks.map(\.path) == [
        "stacks/M42_Orion/2026-01-18/M42_Orion_200x60sec_12000s_b.fit",
        "stacks/M42_Orion/2026-01-17/M42_Orion_050x60sec_3000s_a.fit",
        "stacks/M42_Orion/Autosave.tif",
    ])
}

// MARK: - discover: no stacks at all

@Test func stacksReturnsEmptyForTargetWithNoDiscoveredStacks() throws {
    let db = try makeMemoryDB()
    try insertFile(
        db: db, path: "sessions/M42_Orion/2026-01-17/lights/l1.fit",
        ext: "fit", area: .sessions, target: "M42_Orion", sessionDate: "2026-01-17", role: .light
    )

    let stacks = try StackDiscovery.stacks(target: "M42_Orion", db: db, config: AstroConfig())
    #expect(stacks.isEmpty)
}

// MARK: - variantKind (R8-3)

@Test func variantKindClassifiesBareOgNameAsOriginal() throws {
    // Real on-disk name, NGC2237_Rosette_Nebula/stacks/2026-04-04.
    #expect(StackDiscovery.variantKind(
        fileName: "NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og.fit"
    ) == .original)
}

@Test func variantKindClassifiesGraxpertWorkChainAsEdited() throws {
    // Real on-disk name, NGC2237_Rosette_Nebula/sessions/2026-02-25_2026-03-15.
    #expect(StackDiscovery.variantKind(
        fileName: "NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_result_HOO_Improved.fit"
    ) == .edited)
}

@Test func variantKindRecognizesEveryChannelCompositeResultToken() throws {
    for token in ["HOO", "HSO", "SHO", "OSH"] {
        #expect(StackDiscovery.variantKind(fileName: "stack_og_work_graxpert_result_\(token)_Improved.fit") == .edited)
    }
}

@Test func variantKindClassifiesStarlessPrefixEvenOverEditMarkers() throws {
    // Real on-disk name, NGC2237_Rosette_Nebula/sessions -- starless wins even
    // though "_seti"/"_strech" are also edit markers.
    #expect(StackDiscovery.variantKind(
        fileName: "starless_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_seti_strech.fit"
    ) == .starless)
}

@Test func variantKindClassifiesStarmaskPrefix() throws {
    #expect(StackDiscovery.variantKind(
        fileName: "starmask_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956.fit"
    ) == .starmask)
}

@Test func variantKindClassifiesJPEGExportRegardlessOfEditMarkers() throws {
    // Real on-disk name, NGC2237_Rosette_Nebula/sessions -- carries "_seti"/
    // "_strech" edit markers, but the .jpg extension wins.
    #expect(StackDiscovery.variantKind(
        fileName: "NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_seti_strech.jpg"
    ) == .export_)
}

// MARK: - stem (R8-3)

@Test func stemGroupsRealNGC2244FamilyUnderOneKey() throws {
    // Every one of these is a REAL on-disk filename for the exact family the
    // user's screenshot complained about (NGC2237_Rosette_Nebula).
    let original = StackDiscovery.stem(for: "NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og.fit")
    let edited = StackDiscovery.stem(for: "NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_result_HOO_Improved.fit")
    let starless = StackDiscovery.stem(for: "starless_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_seti_strech.fit")
    let starmask = StackDiscovery.stem(for: "starmask_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956.fit")
    let jpgExport = StackDiscovery.stem(for: "NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_seti_strech.jpg")

    let expected = "ngc_2244_satellite_cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956"
    #expect(original == expected)
    #expect(edited == expected)
    #expect(starless == expected)
    #expect(starmask == expected)
    #expect(jpgExport == expected)
}

@Test func stemFallbackStripsSuffixMarkerWhenNoNxSubCore() throws {
    // Real on-disk shape: a bare "result.fit"/"result_final.tif" pair with
    // no ASIAIR NxSUBsec_TOTALs core to anchor on at all.
    #expect(StackDiscovery.stem(for: "result.fit") == "result")
    #expect(StackDiscovery.stem(for: "result_final.tif") == "result")
}

// MARK: - groupedStacks (R8-3)

@Test func groupedStacksGroupsNGC2244FamilyPreferringOriginalAsBase() throws {
    let db = try makeMemoryDB()
    try insertFile(
        db: db,
        path: "stacks/NGC2237_Rosette_Nebula/2026-04-04/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og.fit",
        size: 50_000_000, ext: "fit", area: .stacks, target: "NGC2237_Rosette_Nebula", sessionDate: "2026-04-04", role: .stack
    )
    try insertFile(
        db: db,
        path: "sessions/NGC2237_Rosette_Nebula/2026-02-25_2026-03-15/NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og_work_graxpert_result_HOO_Improved.fit",
        size: 900_000_000, ext: "fit", area: .sessions, target: "NGC2237_Rosette_Nebula", sessionDate: "2026-02-25_2026-03-15", role: .other
    )
    try insertFile(
        db: db,
        path: "stacks/NGC2237_Rosette_Nebula/2026-04-04/starless_NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956.fit",
        size: 60_000_000, ext: "fit", area: .stacks, target: "NGC2237_Rosette_Nebula", sessionDate: "2026-04-04", role: .stack
    )

    let groups = try StackDiscovery.groupedStacks(target: "NGC2237_Rosette_Nebula", db: db, config: AstroConfig())
    #expect(groups.count == 1)
    let group = try #require(groups.first)
    #expect(group.base.path.hasSuffix("_1956_og.fit"))
    #expect(group.variants.count == 2)
    #expect(group.framesBest == 145)
    #expect(group.totalSecondsBest == 12300)
    #expect(group.fromHeader == false)
}

@Test func groupedStacksFallsBackToHeaderSTACKCNTAndLIVETIMEWhenNameHasNoExposure() throws {
    let db = try makeMemoryDB()
    let fileID = try insertFile(
        db: db, path: "stacks/M42_Orion/2026-01-17/result.fit",
        ext: "fit", area: .stacks, target: "M42_Orion", sessionDate: "2026-01-17", role: .stack
    )
    // Real header_json shape (queried from the actual library's fits_meta).
    let header = #"{"STACKCNT":"155","LIVETIME":"13740.","EXPTIME":"120."}"#
    try db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, headerJSON: header))

    let groups = try StackDiscovery.groupedStacks(target: "M42_Orion", db: db, config: AstroConfig())
    let group = try #require(groups.first)
    #expect(group.framesBest == 155)
    #expect(group.totalSecondsBest == 13740)
    #expect(group.fromHeader == true)
    #expect(group.subSecondsBest == 13740.0 / 155.0)
}

@Test func groupedStacksReturnsSingletonForFileWithNoOtherVariant() throws {
    let db = try makeMemoryDB()
    try insertFile(
        db: db, path: "stacks/M42_Orion/2026-01-17/result.fit",
        ext: "fit", area: .stacks, target: "M42_Orion", sessionDate: "2026-01-17", role: .stack
    )

    let groups = try StackDiscovery.groupedStacks(target: "M42_Orion", db: db, config: AstroConfig())
    #expect(groups.count == 1)
    #expect(groups.first?.variants.isEmpty == true)
    #expect(groups.first?.base.path == "stacks/M42_Orion/2026-01-17/result.fit")
}

@Test func groupedStacksReturnsEmptyForTargetWithNoDiscoveredStacks() throws {
    let db = try makeMemoryDB()
    try insertFile(
        db: db, path: "sessions/M42_Orion/2026-01-17/lights/l1.fit",
        ext: "fit", area: .sessions, target: "M42_Orion", sessionDate: "2026-01-17", role: .light
    )

    let groups = try StackDiscovery.groupedStacks(target: "M42_Orion", db: db, config: AstroConfig())
    #expect(groups.isEmpty)
}
