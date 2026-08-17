@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// Task 7 (2026-08-17 owner-feedback wave 3): the Results page reads
/// `StackDiscovery`, the engine V1's target detail page and `astrotool
/// stacks` have always used, instead of the `results`/`lineage_edges`
/// tables that nothing in the product writes.
///
/// These are behavioural gates on the ENGINE'S rules, not on a list of
/// names: each fixture row below is a file only `StackDiscovery` classifies
/// correctly. A hand-rolled "does this look like a stack?" predicate written
/// here or in the view -- the thing this task exists to prevent -- would
/// list the Siril residue and the ASIAIR zero-exposure placeholder as
/// results, and would not collapse the starless/edited variants into their
/// parent's family. Every filename is a real on-disk shape from the owner's
/// library (the same ones `StackDiscoveryTests` uses).
@Suite("V2 Results reads the stack-discovery engine")
struct StackResultsQueryTests {
    /// One `files` row, exactly as the scanner writes them -- `files` is a
    /// table production genuinely populates (11 432 rows in the owner's
    /// real V2 index), unlike `results`/`lineage_edges`.
    @discardableResult
    private func insertFile(
        db: Database, path: String, size: Int64 = 50_000_000, ext: String = "fit",
        area: LibraryArea, target: String?, sessionDate: String?, role: FrameRole = .other
    ) throws -> Int64 {
        let fileID = try db.upsertFile(FileRecord(
            path: path, size: size, mtime: 1_700_000_000, ext: ext, kind: "fits",
            area: area, target: target, sessionDate: sessionDate, role: role,
            scannedAt: 1_700_000_100
        ))
        // A distinct inode per row, so the engine's hardlink dedup never
        // collapses two genuinely different fixture files.
        try db.backfillInode(id: fileID, inode: fileID, nlink: 1)
        return fileID
    }

    private func rosetteFixture() throws -> Database {
        let db = try Database(path: ":memory:")
        let target = "NGC2237_Rosette_Nebula"
        let stem = "NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956"
        // The raw stacker output -- the family's base.
        try insertFile(
            db: db, path: "stacks/\(target)/2026-04-04/\(stem)_og.fit",
            area: .stacks, target: target, sessionDate: "2026-04-04", role: .stack
        )
        // A star-removed variant of the SAME capture: must nest under the
        // base, not form its own row.
        try insertFile(
            db: db, path: "stacks/\(target)/2026-04-04/starless_\(stem).fit", size: 60_000_000,
            area: .stacks, target: target, sessionDate: "2026-04-04", role: .stack
        )
        // An edited variant left loose in a SESSION folder -- discovery is
        // filename-driven, so location must not hide it.
        try insertFile(
            db: db, path: "sessions/\(target)/2026-02-25/\(stem)_og_work_graxpert_result_HOO_Improved.fit",
            size: 900_000_000, area: .sessions, target: target, sessionDate: "2026-02-25"
        )
        // Siril registration residue. Contains "_stacked" and is 200 MB, so
        // any naive name check calls it a finished stack; only the engine's
        // `ResidueMatcher` pass rejects it.
        try insertFile(
            db: db, path: "stacks/\(target)/2026-04-04/r_merged_two_nights_stacked.fit", size: 200_000_000,
            area: .stacks, target: target, sessionDate: "2026-04-04", role: .stack
        )
        // ASIAIR's own "no exposure info" placeholder (`x0sec_0s`) -- shaped
        // like a stack name, but it is a raw mosaic panel-prep light.
        try insertFile(
            db: db, path: "stacks/\(target)/2026-04-04/Unknown_038x0sec_0s_2026-04-25_1737_session1.fit",
            size: 20_000_000, area: .stacks, target: target, sessionDate: "2026-04-04", role: .stack
        )
        // An ordinary light frame: never a result.
        try insertFile(
            db: db, path: "sessions/\(target)/2026-02-25/lights/light_0001.fit", size: 40_000_000,
            area: .sessions, target: target, sessionDate: "2026-02-25", role: .light
        )
        return db
    }

    private func query(_ db: Database) -> ResultsQuery {
        ResultsQuery(stackGroups: { target in
            try StackDiscovery.groupedStacks(target: target, db: db, config: AstroConfig())
        })
    }

    @Test("A project's results are its discovered stack families, base plus nested variants")
    func stackResultsCollapseVariantsIntoFamilies() async throws {
        let snapshot = try await query(try rosetteFixture()).stackResults(target: "NGC2237_Rosette_Nebula")

        #expect(snapshot.groups.count == 1)
        let group = try #require(snapshot.groups.first)
        #expect(group.base.fileName == "NGC_2244_Satellite_Cluster_145x120sec_12300s__drizzle-2-0x_2026-03-17_1956_og.fit")
        #expect(group.base.variantKind == .original)
        #expect(group.variants.count == 2)
        #expect(group.fileCount == 3)
        #expect(snapshot.fileCount == 3)
        #expect(snapshot.bestGroup?.id == group.id)
    }

    @Test("Files only the engine's own rules exclude never reach the page")
    func engineExclusionsAreHonoured() async throws {
        let snapshot = try await query(try rosetteFixture()).stackResults(target: "NGC2237_Rosette_Nebula")
        let paths = snapshot.groups.flatMap { [$0.base.relativePath] + $0.variants.map(\.relativePath) }

        // Siril residue: matches "_stacked" and is 200 MB, rejected only by
        // `StackDiscovery`'s `ResidueMatcher` pass.
        #expect(!paths.contains { $0.hasSuffix("r_merged_two_nights_stacked.fit") })
        // ASIAIR `x0sec_0s` placeholder: stack-shaped name, not a stack.
        #expect(!paths.contains { $0.contains("Unknown_038x0sec_0s") })
        // A plain light frame.
        #expect(!paths.contains { $0.hasSuffix("light_0001.fit") })
    }

    @Test("Each variant keeps the engine's own kind and its real on-disk location")
    func variantsCarryKindAndLocation() async throws {
        let snapshot = try await query(try rosetteFixture()).stackResults(target: "NGC2237_Rosette_Nebula")
        let group = try #require(snapshot.groups.first)

        let edited = try #require(group.variants.first { $0.fileName.contains("graxpert") })
        #expect(edited.variantKind == .edited)
        // Filename-driven discovery: an edited output left in a session
        // folder is still a result, and the page says where it actually is.
        #expect(edited.location == .sessions)
        #expect(edited.category == .stack)

        let starless = try #require(group.variants.first { $0.fileName.hasPrefix("starless_") })
        #expect(starless.variantKind == .starless)
        #expect(starless.location == .stacks)

        // Variant order is the engine's: edited before starless.
        #expect(group.variants.map(\.variantKind) == [.edited, .starless])
    }

    @Test("Exposure comes from the engine, filename first and FITS header as the stated fallback")
    func exposureFollowsTheEnginesOwnFallback() async throws {
        let named = try await query(try rosetteFixture()).stackResults(target: "NGC2237_Rosette_Nebula")
        let fromName = try #require(named.groups.first)
        #expect(fromName.framesBest == 145)
        #expect(fromName.subSecondsBest == 120)
        #expect(fromName.totalSecondsBest == 12300)
        #expect(fromName.exposureFromHeader == false)

        let db = try Database(path: ":memory:")
        let fileID = try insertFile(
            db: db, path: "stacks/M42_Orion/2026-01-17/result.fit",
            area: .stacks, target: "M42_Orion", sessionDate: "2026-01-17", role: .stack
        )
        try db.upsertFITSMeta(FITSMetaRecord(
            fileID: fileID, headerJSON: #"{"STACKCNT":"155","LIVETIME":"13740.","EXPTIME":"120."}"#
        ))
        let headerBacked = try #require(
            try await query(db).stackResults(target: "M42_Orion").groups.first
        )
        #expect(headerBacked.framesBest == 155)
        #expect(headerBacked.totalSecondsBest == 13740)
        // The page must be able to say "from the header" rather than imply
        // the filename carried these numbers.
        #expect(headerBacked.exposureFromHeader == true)
    }

    @Test("A calibration master found among the stacks is flagged, not passed off as a light stack")
    func calibrationMastersAreFlagged() async throws {
        let db = try Database(path: ":memory:")
        try insertFile(
            db: db, path: "stacks/M42_Orion/2026-01-17/session1_6s_2026-01-17_-9.6C_flats_stacked.fit",
            size: 20_000_000, area: .stacks, target: "M42_Orion", sessionDate: "2026-01-17", role: .flat
        )
        let group = try #require(
            try await query(db).stackResults(target: "M42_Orion").groups.first
        )
        #expect(group.base.category == .calibrationMasterCandidate)
    }

    /// Caught by replaying the query against the owner's real V2 index, not
    /// by any fixture: the `NGC 7000` project's canonical folder name is
    /// `NGC_7000_North_America_Nebula` (the catalog's own English name) and
    /// all 62 of its discovered stack files live under
    /// `NGC_7000_North_American_Nebula`. With an exact string match the
    /// library's largest target showed nothing at all, and every unit test
    /// was green.
    @Test("A project whose folder is spelled differently on disk still finds its stacks")
    func legacyFolderSpellingStillResolves() async throws {
        let db = try Database(path: ":memory:")
        let onDisk = "NGC_7000_North_American_Nebula"
        try insertFile(
            db: db, path: "stacks/\(onDisk)/2026-06-06/NGC_7000_106x120sec_12720s_drizzle-1-0x_2026-06-06_1627_og.fit",
            area: .stacks, target: onDisk, sessionDate: "2026-06-06", role: .stack
        )
        let query = ResultsQuery(
            stackGroups: { target in
                try StackDiscovery.groupedStacks(target: target, db: db, config: AstroConfig())
            },
            libraryTargets: { [onDisk] }
        )

        let canonical = ProjectsQuery.canonicalFolderName(
            for: ProjectRecord(id: UUID(), catalogID: "NGC 7000", displayName: "NGC 7000", phase: .processing)
        )
        let snapshot = try await query.stackResults(target: canonical)

        // The snapshot reports the folder it actually read, so the reader is
        // never told a name the library does not use.
        #expect(snapshot.target == onDisk)
        #expect(snapshot.groups.count == 1)
    }

    @Test("Folder resolution never guesses: an unrelated folder is not adopted")
    func folderResolutionOnlyMatchesTheSameCatalogIdentity() {
        let folders = ["NGC_7000_North_American_Nebula", "M42_Orion", "M_Milky_Way"]
        #expect(ResultsQuery.libraryFolder(matching: "M42_Orion", among: folders) == "M42_Orion")
        #expect(
            ResultsQuery.libraryFolder(matching: "NGC_7000_North_America_Nebula", among: folders)
                == "NGC_7000_North_American_Nebula"
        )
        // A free-text folder that resolves to no catalog identity must not
        // be matched to anything -- the caller keeps the requested name.
        #expect(ResultsQuery.libraryFolder(matching: "M_Milky_Way_Wide", among: folders) == nil)
        // And a target the library simply does not have stays unresolved.
        #expect(ResultsQuery.libraryFolder(matching: "IC_1396_Elephants_Trunk_Nebula", among: folders) == nil)
    }

    @Test("A target with no discovered stack yields an empty snapshot, not a fabricated one")
    func targetWithoutStacksIsEmpty() async throws {
        let db = try Database(path: ":memory:")
        try insertFile(
            db: db, path: "sessions/M42_Orion/2026-01-17/lights/l1.fit",
            area: .sessions, target: "M42_Orion", sessionDate: "2026-01-17", role: .light
        )

        let snapshot = try await query(db).stackResults(target: "M42_Orion")
        #expect(snapshot.groups.isEmpty)
        #expect(snapshot.fileCount == 0)
        #expect(snapshot.bestGroup == nil)
    }
}

