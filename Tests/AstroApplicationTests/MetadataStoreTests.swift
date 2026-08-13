@testable import AstroApplication
import AstroCore
import Foundation
import Testing

@Suite("Durable V2 workflow metadata")
struct MetadataStoreTests {
    @Test("Project goals and notes round-trip outside the image library")
    func projectAnnotationRoundTrip() async throws {
        let store = try MetadataStore.temporary()
        let project = ProjectRecord(
            id: UUID(), catalogID: "IC 1396", displayName: "Elephant Trunk", phase: .collecting
        )
        try await store.save(project)
        let annotation = ProjectAnnotationRecord(
            projectID: project.id,
            integrationGoalHours: 12.5,
            notes: "Continue SV220 capture after midnight.",
            updatedAt: Date(timeIntervalSince1970: 1_786_404_000)
        )

        try await store.save(annotation)

        #expect(try await store.projectAnnotation(projectID: project.id) == annotation)
    }

    @Test("Acknowledging a finding group upserts on ack key and revoking removes it")
    func acknowledgeFindingGroupUpsertsAndRevokes() async throws {
        let store = try MetadataStore.temporary()
        let ackedAt = Date(timeIntervalSince1970: 1_786_404_000)

        try await store.acknowledgeFindingGroup(category: "dark", groupKey: "IC1396|2026-08-08", note: "known gap", at: ackedAt)

        let acks = try await store.acknowledgements()
        #expect(acks.count == 1)
        let ack = try #require(acks.first)
        #expect(ack.ackKey == MetadataStore.ackKey(category: "dark", groupKey: "IC1396|2026-08-08"))
        #expect(ack.category == "dark")
        #expect(ack.groupKey == "IC1396|2026-08-08")
        #expect(ack.note == "known gap")
        #expect(abs(ack.ackedAt.timeIntervalSince1970 - ackedAt.timeIntervalSince1970) < 1)

        let updatedAt = Date(timeIntervalSince1970: 1_786_500_000)
        try await store.acknowledgeFindingGroup(category: "dark", groupKey: "IC1396|2026-08-08", note: "still fine", at: updatedAt)
        let updatedAcks = try await store.acknowledgements()
        #expect(updatedAcks.count == 1)
        #expect(updatedAcks.first?.note == "still fine")

        try await store.revokeAcknowledgement(ackKey: ack.ackKey)
        #expect(try await store.acknowledgements().isEmpty)
    }

    @Test("Revoking an acknowledgement that was never made is a no-op")
    func revokingUnknownAcknowledgementIsANoOp() async throws {
        let store = try MetadataStore.temporary()

        try await store.revokeAcknowledgement(ackKey: MetadataStore.ackKey(category: "dark", groupKey: "missing"))

        #expect(try await store.acknowledgements().isEmpty)
    }

    @Test("Audit run history records runs newest-first and diffs the two most recent")
    func auditRunHistoryRecordsAndDiffsRuns() async throws {
        let store = try MetadataStore.temporary()

        try await store.recordAuditRun(
            findingCount: 2, groupKeys: ["dark|A", "flat|B"],
            at: Date(timeIntervalSince1970: 1_786_400_000)
        )
        try await store.recordAuditRun(
            findingCount: 2, groupKeys: ["dark|A", "duplicate|C"],
            at: Date(timeIntervalSince1970: 1_786_500_000)
        )

        let history = try await store.auditRunHistory()
        #expect(history.count == 2)
        #expect(history[0].groupKeys == ["dark|A", "duplicate|C"])
        #expect(history[1].groupKeys == ["dark|A", "flat|B"])

        let diff = try await #require(store.auditRunDiff())
        #expect(diff.newGroupKeys == ["duplicate|C"])
        #expect(diff.resolvedGroupKeys == ["flat|B"])
    }

    @Test("A single audit run has no diff")
    func singleAuditRunHasNoDiff() async throws {
        let store = try MetadataStore.temporary()
        try await store.recordAuditRun(findingCount: 1, groupKeys: ["dark|A"])

        #expect(try await store.auditRunDiff() == nil)
    }

    @Test("Audit run history honors the requested limit")
    func auditRunHistoryHonorsLimit() async throws {
        let store = try MetadataStore.temporary()
        for index in 0..<5 {
            try await store.recordAuditRun(
                findingCount: index, groupKeys: ["group|\(index)"],
                at: Date(timeIntervalSince1970: 1_786_400_000 + Double(index))
            )
        }

        let limited = try await store.auditRunHistory(limit: 2)
        #expect(limited.count == 2)
        #expect(limited[0].findingCount == 4)
        #expect(limited[1].findingCount == 3)
    }

    @Test("allResults joins every project's results with the owning project name")
    func allResultsJoinsProjectNamesAcrossProjects() async throws {
        let store = try MetadataStore.temporary()
        let firstProject = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elephant's Trunk", phase: .processing)
        let secondProject = ProjectRecord(id: UUID(), catalogID: "M 31", displayName: "Andromeda Galaxy", phase: .collecting)
        let firstResult = ResultRecord(
            id: UUID(), projectID: firstProject.id, parentResultID: nil, kind: .stack, role: .intermediate,
            relativePath: "stacks/master.fit", createdAt: Date(timeIntervalSince1970: 1_786_400_000),
            softwareName: "Siril", softwareVersion: "1.4"
        )
        let secondResult = ResultRecord(
            id: UUID(), projectID: secondProject.id, parentResultID: nil, kind: .processingVariant, role: .final,
            relativePath: "processed/final.fit", createdAt: Date(timeIntervalSince1970: 1_786_500_000),
            softwareName: "PixInsight", softwareVersion: "1.9"
        )
        try await store.save(MetadataWriteBatch(
            projects: [firstProject, secondProject],
            results: [firstResult, secondResult]
        ))

        let all = try await store.allResults()

        #expect(all.count == 2)
        let first = try #require(all.first { $0.result.id == firstResult.id })
        #expect(first.projectName == firstProject.displayName)
        let second = try #require(all.first { $0.result.id == secondResult.id })
        #expect(second.projectName == secondProject.displayName)
    }

    @Test("allResults on an empty database returns an empty list")
    func allResultsOnEmptyDatabaseIsEmpty() async throws {
        let store = try MetadataStore.temporary()

        #expect(try await store.allResults().isEmpty)
    }

    @Test("All UUID workflow records round-trip with stable lineage")
    func metadataRoundTripsStableIdentityAndLineage() async throws {
        let fixture = try StoreFixture.make()
        defer { fixture.remove() }
        let store = try MetadataStore(databaseURL: fixture.databaseURL)
        let records = SampleRecords.make()

        try await store.save(records.project)
        try await store.save(records.night)
        try await store.save(records.series)
        try await store.save(records.frameDecision)
        try await store.save(records.result)
        try await store.save(records.lineage)
        try await store.save(records.reviewState)
        try await store.save(records.mutationJournal)

        #expect(try await store.project(id: records.project.id) == records.project)
        #expect(try await store.night(id: records.night.id) == records.night)
        #expect(try await store.series(id: records.series.id) == records.series)
        #expect(try await store.frameDecision(id: records.frameDecision.id) == records.frameDecision)
        #expect(try await store.result(id: records.result.id) == records.result)
        #expect(try await store.lineageEdge(id: records.lineage.id) == records.lineage)
        #expect(try await store.reviewState(id: records.reviewState.id) == records.reviewState)
        #expect(try await store.mutationJournal(id: records.mutationJournal.id) == records.mutationJournal)
    }

    @Test("Saving the same UUID updates in place without breaking children")
    func stableIdentityUpsertPreservesChildren() async throws {
        let fixture = try StoreFixture.make()
        defer { fixture.remove() }
        let store = try MetadataStore(databaseURL: fixture.databaseURL)
        let records = SampleRecords.make()
        try await store.save(records.project)
        try await store.save(records.night)
        try await store.save(records.series)

        let updated = ProjectRecord(
            id: records.project.id,
            catalogID: records.project.catalogID,
            displayName: "Elephant Trunk Nebula",
            phase: .processing
        )
        try await store.save(updated)

        #expect(try await store.project(id: updated.id) == updated)
        #expect(try await store.series(id: records.series.id) == records.series)
        #expect(try await store.projectCount() == 1)
    }

    @Test("Foreign keys reject orphan workflow records")
    func orphanForeignKeyIsRejected() async throws {
        let fixture = try StoreFixture.make()
        defer { fixture.remove() }
        let store = try MetadataStore(databaseURL: fixture.databaseURL)
        let orphan = SeriesRecord(
            id: UUID(),
            projectID: UUID(),
            nightID: UUID(),
            setupID: "widefield-rig",
            setupDescriptor: "RedCat 51 · ASI2600MC",
            sensorMode: .osc,
            passband: .dualBand,
            exposureSeconds: 120,
            filterName: "SV220",
            filterID: "svbony-sv220",
            gain: 100,
            offset: 50,
            binning: "1x1"
        )

        await #expect(throws: AstroError.self) {
            try await store.save(orphan)
        }
        #expect(try await store.series(id: orphan.id) == nil)
    }

    @Test("Lineage rejects a typed source UUID that does not exist")
    func orphanLineageSourceIsRejected() async throws {
        let fixture = try StoreFixture.make()
        defer { fixture.remove() }
        let store = try MetadataStore(databaseURL: fixture.databaseURL)
        let records = SampleRecords.make()
        try await store.save(records.project)
        try await store.save(records.result)
        let orphan = LineageEdgeRecord(
            id: UUID(),
            resultID: records.result.id,
            sourceKind: .series,
            sourceID: UUID()
        )

        await #expect(throws: AstroError.self) {
            try await store.save(orphan)
        }
        #expect(try await store.lineageEdge(id: orphan.id) == nil)
    }

    @Test("A failed batch rolls back every earlier write")
    func failedBatchRollsBack() async throws {
        let fixture = try StoreFixture.make()
        defer { fixture.remove() }
        let store = try MetadataStore(databaseURL: fixture.databaseURL)
        let first = ProjectRecord(
            id: UUID(),
            catalogID: "IC 1396",
            displayName: "First",
            phase: .planned
        )
        let duplicateCatalog = ProjectRecord(
            id: UUID(),
            catalogID: "ic 1396",
            displayName: "Duplicate",
            phase: .collecting
        )

        await #expect(throws: AstroError.self) {
            try await store.save(MetadataWriteBatch(projects: [first, duplicateCatalog]))
        }

        #expect(try await store.project(id: first.id) == nil)
        #expect(try await store.projectCount() == 0)
    }

    @Test("A fresh database installs the current schema, foreign keys, and lookup indexes")
    func freshSchemaIsComplete() async throws {
        let fixture = try StoreFixture.make()
        defer { fixture.remove() }
        let store = try MetadataStore(databaseURL: fixture.databaseURL)

        #expect(try await store.schemaVersion() == MetadataSchema.currentVersion)
        #expect(try await store.foreignKeysEnabled())

        let objects = try schemaObjects(at: fixture.databaseURL)
        #expect(objects.tables.isSuperset(of: [
            "metadata_schema",
            "projects",
            "nights",
            "series",
            "frame_decisions",
            "results",
            "lineage_edges",
            "review_states",
            "mutation_journal",
            "project_annotations",
            "audit_acknowledgements",
            "audit_run_history",
        ]))
        #expect(objects.indexes.isSuperset(of: [
            "idx_series_project",
            "idx_series_night",
            "idx_frame_decisions_series",
            "idx_results_project",
            "idx_results_parent",
            "idx_lineage_result",
            "idx_lineage_series_source",
            "idx_lineage_frame_source",
            "idx_lineage_result_source",
            "idx_review_states_series",
            "idx_mutation_journal_operation",
            "idx_project_annotations_updated",
            "idx_audit_run_history_ran_at",
        ]))
    }

    @Test("A version-one database migrates once and reopening is idempotent")
    func migrationIsIdempotent() async throws {
        let fixture = try StoreFixture.make()
        defer { fixture.remove() }
        let project = ProjectRecord(
            id: UUID(),
            catalogID: "M 42",
            displayName: "Orion Nebula",
            phase: .collecting
        )
        try createVersionOneDatabase(at: fixture.databaseURL, project: project)

        let firstOpen = try MetadataStore(databaseURL: fixture.databaseURL)
        #expect(try await firstOpen.schemaVersion() == MetadataSchema.currentVersion)
        #expect(try await firstOpen.project(id: project.id) == project)

        let secondOpen = try MetadataStore(databaseURL: fixture.databaseURL)
        #expect(try await secondOpen.schemaVersion() == MetadataSchema.currentVersion)
        #expect(try await secondOpen.project(id: project.id) == project)
        #expect(try await secondOpen.projectCount() == 1)
    }

    @Test("A failed migration rolls back DDL and leaves the old version stamp")
    func failedMigrationDoesNotAdvanceVersion() throws {
        let fixture = try StoreFixture.make()
        defer { fixture.remove() }
        try createVersionOneDatabase(at: fixture.databaseURL)
        do {
            let database = try SQLiteDB(path: fixture.databaseURL.path)
            try database.exec("CREATE TABLE mutation_journal(unexpected TEXT NOT NULL);")
        }

        #expect(throws: AstroError.self) {
            _ = try MetadataStore(databaseURL: fixture.databaseURL)
        }

        let database = try SQLiteDB(path: fixture.databaseURL.path)
        #expect(try schemaVersion(in: database) == 1)
        #expect(try !tableExists("results", in: database))
        #expect(try !tableExists("lineage_edges", in: database))
        #expect(try !tableExists("review_states", in: database))
    }

    @Test("A version-four database migrates to version five preserving existing data")
    func migratesVersionFourToVersionFive() async throws {
        let fixture = try StoreFixture.make()
        defer { fixture.remove() }
        let project = ProjectRecord(
            id: UUID(), catalogID: "M 31", displayName: "Andromeda Galaxy", phase: .collecting
        )
        try createVersionFourDatabase(at: fixture.databaseURL, project: project)

        let store = try MetadataStore(databaseURL: fixture.databaseURL)

        #expect(try await store.schemaVersion() == 5)
        #expect(try await store.project(id: project.id) == project)
        #expect(try await store.acknowledgements().isEmpty)
        #expect(try await store.auditRunHistory().isEmpty)
    }

    @Test("A failed version-five migration rolls back DDL and leaves the old version stamp")
    func failedVersionFiveMigrationDoesNotAdvanceVersion() throws {
        let fixture = try StoreFixture.make()
        defer { fixture.remove() }
        try createVersionFourDatabase(at: fixture.databaseURL)
        do {
            let database = try SQLiteDB(path: fixture.databaseURL.path)
            try database.exec("CREATE TABLE idx_audit_run_history_ran_at(unexpected TEXT NOT NULL);")
        }

        #expect(throws: AstroError.self) {
            _ = try MetadataStore(databaseURL: fixture.databaseURL)
        }

        let database = try SQLiteDB(path: fixture.databaseURL.path)
        #expect(try schemaVersion(in: database) == 4)
        #expect(try !tableExists("audit_acknowledgements", in: database))
        #expect(try !tableExists("audit_run_history", in: database))
    }

    @Test("A schema newer than this build is rejected without modification")
    func futureSchemaIsRejected() throws {
        let fixture = try StoreFixture.make()
        defer { fixture.remove() }
        let futureVersion = MetadataSchema.currentVersion + 1
        do {
            let database = try SQLiteDB(path: fixture.databaseURL.path)
            try database.exec(Self.schemaVersionSQL)
            try database.run(
                "INSERT INTO metadata_schema(singleton, version) VALUES (1, ?);",
                bind: [.int(Int64(futureVersion))]
            )
            try database.exec("PRAGMA journal_mode=DELETE;")
        }

        let beforeBytes = try Data(contentsOf: fixture.databaseURL)
        let beforeNames = try Set(FileManager.default.contentsOfDirectory(
            atPath: fixture.container.path
        ))

        do {
            _ = try MetadataStore(databaseURL: fixture.databaseURL)
            Issue.record("Expected a future schema to be rejected")
        } catch let error as MetadataStoreError {
            #expect(error == .unsupportedSchemaVersion(
                found: futureVersion,
                supported: MetadataSchema.currentVersion
            ))
        }

        #expect(try Data(contentsOf: fixture.databaseURL) == beforeBytes)
        #expect(try Set(FileManager.default.contentsOfDirectory(
            atPath: fixture.container.path
        )) == beforeNames)
    }

    @Test("Concurrent store opens migrate one old schema exactly once")
    func concurrentMigrationIsIdempotent() async throws {
        let fixture = try StoreFixture.make()
        defer { fixture.remove() }
        try createVersionOneDatabase(at: fixture.databaseURL)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let store = try MetadataStore(databaseURL: fixture.databaseURL)
                    #expect(try await store.schemaVersion() == MetadataSchema.currentVersion)
                }
            }
            try await group.waitForAll()
        }

        let store = try MetadataStore(databaseURL: fixture.databaseURL)
        #expect(try await store.schemaVersion() == MetadataSchema.currentVersion)
    }

    @Test("Invalid civil dates, time zones, and non-finite measurements are rejected")
    func invalidDomainValuesAreRejected() async throws {
        let fixture = try StoreFixture.make()
        defer { fixture.remove() }
        let store = try MetadataStore(databaseURL: fixture.databaseURL)
        let records = SampleRecords.make()
        try await store.save(records.project)

        let invalidNights = [
            NightRecord(id: UUID(), localDate: "2026-02-30", timeZoneID: "Europe/Budapest"),
            NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Not/A_Timezone"),
        ]
        for night in invalidNights {
            await #expect(throws: MetadataStoreError.self) {
                try await store.save(night)
            }
        }

        try await store.save(records.night)
        let invalidSeries = SeriesRecord(
            id: UUID(),
            projectID: records.project.id,
            nightID: records.night.id,
            setupID: nil,
            setupDescriptor: "Fixture",
            sensorMode: .osc,
            passband: .broadband,
            exposureSeconds: .infinity,
            filterName: nil,
            filterID: nil,
            gain: .nan,
            offset: nil,
            binning: "1x1"
        )
        await #expect(throws: MetadataStoreError.self) {
            try await store.save(invalidSeries)
        }

        let invalidResult = ResultRecord(
            id: UUID(),
            projectID: records.project.id,
            parentResultID: nil,
            kind: .stack,
            role: .final,
            relativePath: nil,
            createdAt: Date(timeIntervalSince1970: .infinity),
            softwareName: nil,
            softwareVersion: nil
        )
        await #expect(throws: MetadataStoreError.self) {
            try await store.save(invalidResult)
        }
    }

    @Test("Result dependencies reject self references and multi-node cycles")
    func resultDependencyCyclesAreRejected() async throws {
        let fixture = try StoreFixture.make()
        defer { fixture.remove() }
        let store = try MetadataStore(databaseURL: fixture.databaseURL)
        let records = SampleRecords.make()
        try await store.save(records.project)

        let firstID = UUID()
        let secondID = UUID()
        let first = result(id: firstID, projectID: records.project.id, parentID: nil)
        let second = result(id: secondID, projectID: records.project.id, parentID: firstID)
        try await store.save(first)
        try await store.save(second)

        await #expect(throws: MetadataStoreError.self) {
            try await store.save(self.result(
                id: firstID,
                projectID: records.project.id,
                parentID: secondID
            ))
        }
        await #expect(throws: MetadataStoreError.self) {
            try await store.save(self.result(
                id: UUID(),
                projectID: records.project.id,
                parentID: nil,
                forcedSelfParent: true
            ))
        }

        let third = result(id: UUID(), projectID: records.project.id, parentID: nil)
        try await store.save(third)
        try await store.save(LineageEdgeRecord(
            id: UUID(),
            resultID: third.id,
            sourceKind: .result,
            sourceID: second.id
        ))
        await #expect(throws: MetadataStoreError.self) {
            try await store.save(LineageEdgeRecord(
                id: UUID(),
                resultID: first.id,
                sourceKind: .result,
                sourceID: third.id
            ))
        }
    }

    @Test("AppStorage metadata stays outside the read-only image manifest")
    func metadataUsesExternalStorageWithoutChangingLibrary() async throws {
        let fixture = try StoreFixture.makeLibrary()
        defer { fixture.remove() }
        let before = try await LibraryManifest.capture(root: fixture.libraryRoot)
        let paths = try AppStoragePaths(
            applicationSupport: fixture.applicationSupport,
            caches: fixture.caches,
            libraryID: LibraryIdentity(rootURL: fixture.libraryRoot),
            libraryRoot: fixture.libraryRoot
        )

        let store = try MetadataStore(storagePaths: paths)
        try await store.save(ProjectRecord(
            id: UUID(),
            catalogID: "NGC 7000",
            displayName: "North America Nebula",
            phase: .planned
        ))

        #expect(FileManager.default.fileExists(atPath: paths.metadataDatabase.path))
        #expect(!paths.metadataDatabase.path.hasPrefix(fixture.libraryRoot.path + "/"))
        #expect(!FileManager.default.fileExists(atPath: paths.indexDatabase.path))
        #expect(try await LibraryManifest.capture(root: fixture.libraryRoot) == before)
    }

    @Test("An AppStorage ancestor swapped to the library cannot redirect metadata writes")
    func metadataAncestorSwapFailsWithoutLibraryWrites() async throws {
        let fixture = try StoreFixture.makeLibrary()
        defer { fixture.remove() }
        let paths = try AppStoragePaths(
            applicationSupport: fixture.applicationSupport,
            caches: fixture.caches,
            libraryID: LibraryIdentity(rootURL: fixture.libraryRoot),
            libraryRoot: fixture.libraryRoot
        )
        let before = try await LibraryManifest.capture(root: fixture.libraryRoot)

        #expect(throws: (any Error).self) {
            _ = try MetadataStore(
                storagePaths: paths,
                beforeMetadataParentOpen: {
                    try FileManager.default.createSymbolicLink(
                        at: fixture.applicationSupport,
                        withDestinationURL: fixture.libraryRoot
                    )
                },
                beforeDatabaseOpen: {}
            )
        }

        #expect(try await LibraryManifest.capture(root: fixture.libraryRoot) == before)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.libraryRoot.appendingPathComponent("AstroTool").path
        ))
    }

    @Test("Concurrent callers serialize without losing UUID records")
    func concurrentSavesAreSerialized() async throws {
        let fixture = try StoreFixture.make()
        defer { fixture.remove() }
        let store = try MetadataStore(databaseURL: fixture.databaseURL)
        let projects = (0..<64).map { index in
            ProjectRecord(
                id: UUID(),
                catalogID: "fixture-\(index)",
                displayName: "Project \(index)",
                phase: .collecting
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for project in projects {
                group.addTask {
                    try await store.save(project)
                }
            }
            try await group.waitForAll()
        }

        #expect(try await store.projectCount() == projects.count)
        for project in projects {
            #expect(try await store.project(id: project.id) == project)
        }
    }

    @Test("Persisted enum values are stable language-neutral tokens")
    func enumRawValuesAreLanguageNeutral() {
        #expect(ProjectWorkflowPhase.allCases.map(\.rawValue) == [
            "planned", "collecting", "processing", "complete", "archived",
        ])
        #expect(SeriesSensorMode.allCases.map(\.rawValue) == [
            "osc", "mono", "dslr", "unknown",
        ])
        #expect(SeriesPassband.allCases.map(\.rawValue) == [
            "broadband", "dual_band", "narrowband", "lrgb", "luminance",
            "unfiltered", "other", "unknown",
        ])
        #expect(FrameVerdict.allCases.map(\.rawValue) == [
            "undecided", "accepted", "rejected",
        ])
        #expect(ResultKind.allCases.map(\.rawValue) == ["stack", "processing_variant"])
        #expect(ResultRole.allCases.map(\.rawValue) == [
            "intermediate", "starless", "mask", "final",
        ])
        #expect(LineageSourceKind.allCases.map(\.rawValue) == ["series", "frame", "result"])
        #expect(ReviewStatus.allCases.map(\.rawValue) == ["pending", "in_progress", "complete"])
        #expect(MutationJournalStatus.allCases.map(\.rawValue) == [
            "planned", "applying", "applied", "rolling_back", "rolled_back", "failed",
        ])
    }

    private static let schemaVersionSQL = """
    CREATE TABLE metadata_schema(
      singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
      version INTEGER NOT NULL CHECK(version >= 0)
    );
    """

    private func result(
        id: UUID,
        projectID: UUID,
        parentID: UUID?,
        forcedSelfParent: Bool = false
    ) -> ResultRecord {
        ResultRecord(
            id: id,
            projectID: projectID,
            parentResultID: forcedSelfParent ? id : parentID,
            kind: .processingVariant,
            role: .intermediate,
            relativePath: nil,
            createdAt: Date(timeIntervalSince1970: 1_786_404_200),
            softwareName: "AstroTool",
            softwareVersion: "2.0.0"
        )
    }

    private func createVersionOneDatabase(
        at url: URL,
        project: ProjectRecord? = nil
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let database = try SQLiteDB(path: url.path)
        try database.exec(Self.schemaVersionSQL)
        try database.exec("""
        CREATE TABLE projects(
          id TEXT PRIMARY KEY NOT NULL,
          catalog_id TEXT NOT NULL COLLATE NOCASE UNIQUE,
          display_name TEXT NOT NULL,
          phase TEXT NOT NULL
        );
        CREATE TABLE nights(
          id TEXT PRIMARY KEY NOT NULL,
          local_date TEXT NOT NULL,
          time_zone_id TEXT NOT NULL,
          UNIQUE(local_date, time_zone_id)
        );
        CREATE TABLE series(
          id TEXT PRIMARY KEY NOT NULL,
          project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
          night_id TEXT NOT NULL REFERENCES nights(id) ON DELETE RESTRICT,
          setup_id TEXT,
          setup_descriptor TEXT NOT NULL,
          sensor_mode TEXT NOT NULL,
          passband TEXT NOT NULL,
          exposure_seconds REAL NOT NULL,
          filter_name TEXT,
          filter_id TEXT,
          gain REAL,
          offset REAL,
          binning TEXT NOT NULL
        );
        CREATE TABLE frame_decisions(
          id TEXT PRIMARY KEY NOT NULL,
          series_id TEXT NOT NULL REFERENCES series(id) ON DELETE RESTRICT,
          relative_path TEXT NOT NULL UNIQUE,
          verdict TEXT NOT NULL,
          logically_excluded INTEGER NOT NULL
        );
        CREATE INDEX idx_series_project ON series(project_id);
        CREATE INDEX idx_series_night ON series(night_id);
        CREATE INDEX idx_frame_decisions_series ON frame_decisions(series_id);
        """)
        try database.run(
            "INSERT INTO metadata_schema(singleton, version) VALUES (1, 1);"
        )
        if let project {
            try database.run(
                "INSERT INTO projects(id, catalog_id, display_name, phase) VALUES (?, ?, ?, ?);",
                bind: [
                    .text(project.id.uuidString.lowercased()),
                    .text(project.catalogID),
                    .text(project.displayName),
                    .text(project.phase.rawValue),
                ]
            )
        }
    }

    private func createVersionFourDatabase(
        at url: URL,
        project: ProjectRecord? = nil
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let database = try SQLiteDB(path: url.path)
        try database.exec(Self.schemaVersionSQL)
        try database.exec(MetadataSchema.versionOneSQL)
        try database.exec(MetadataSchema.versionTwoSQL)
        try database.exec(MetadataSchema.versionThreeSQL)
        try database.exec(MetadataSchema.versionFourSQL)
        try database.run(
            "INSERT INTO metadata_schema(singleton, version) VALUES (1, 4);"
        )
        if let project {
            try database.run(
                "INSERT INTO projects(id, catalog_id, display_name, phase) VALUES (?, ?, ?, ?);",
                bind: [
                    .text(project.id.uuidString.lowercased()),
                    .text(project.catalogID),
                    .text(project.displayName),
                    .text(project.phase.rawValue),
                ]
            )
        }
    }

    private func schemaObjects(at url: URL) throws -> (tables: Set<String>, indexes: Set<String>) {
        let database = try SQLiteDB(path: url.path)
        var tables = Set<String>()
        var indexes = Set<String>()
        try database.query("SELECT type, name FROM sqlite_master WHERE type IN ('table', 'index');") { row in
            guard let type = row.string(0), let name = row.string(1) else { return }
            if type == "table" {
                tables.insert(name)
            } else if type == "index" {
                indexes.insert(name)
            }
        }
        return (tables, indexes)
    }

    private func schemaVersion(in database: SQLiteDB) throws -> Int {
        var version: Int?
        try database.query("SELECT version FROM metadata_schema WHERE singleton = 1;") { row in
            version = row.int64(0).map(Int.init)
        }
        return try #require(version)
    }

    private func tableExists(_ name: String, in database: SQLiteDB) throws -> Bool {
        var exists = false
        try database.query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
            bind: [.text(name)]
        ) { _ in exists = true }
        return exists
    }
}

private struct SampleRecords {
    let project: ProjectRecord
    let night: NightRecord
    let series: SeriesRecord
    let frameDecision: FrameDecisionRecord
    let result: ResultRecord
    let lineage: LineageEdgeRecord
    let reviewState: ReviewStateRecord
    let mutationJournal: MutationJournalRecord

    static func make() -> Self {
        let project = ProjectRecord(
            id: UUID(),
            catalogID: "IC 1396",
            displayName: "Elephant Trunk Nebula",
            phase: .collecting
        )
        let night = NightRecord(
            id: UUID(),
            localDate: "2026-08-08",
            timeZoneID: "Europe/Budapest"
        )
        let series = SeriesRecord(
            id: UUID(),
            projectID: project.id,
            nightID: night.id,
            setupID: "widefield-rig",
            setupDescriptor: "RedCat 51 · ASI2600MC",
            sensorMode: .osc,
            passband: .dualBand,
            exposureSeconds: 120,
            filterName: "SV220",
            filterID: "svbony-sv220",
            gain: 100,
            offset: 50,
            binning: "1x1"
        )
        let frame = FrameDecisionRecord(
            id: UUID(),
            seriesID: series.id,
            relativePath: "IC1396/2026-08-08/Lights/frame-001.fit",
            verdict: .accepted,
            logicallyExcluded: false
        )
        let result = ResultRecord(
            id: UUID(),
            projectID: project.id,
            parentResultID: nil,
            kind: .stack,
            role: .intermediate,
            relativePath: "IC1396/Results/stack-001.fit",
            createdAt: Date(timeIntervalSince1970: 1_786_403_900),
            softwareName: "Siril",
            softwareVersion: "1.4.0"
        )
        return Self(
            project: project,
            night: night,
            series: series,
            frameDecision: frame,
            result: result,
            lineage: LineageEdgeRecord(
                id: UUID(),
                resultID: result.id,
                sourceKind: .series,
                sourceID: series.id
            ),
            reviewState: ReviewStateRecord(
                id: UUID(),
                seriesID: series.id,
                status: .complete,
                updatedAt: Date(timeIntervalSince1970: 1_786_404_000)
            ),
            mutationJournal: MutationJournalRecord(
                id: UUID(),
                operationID: UUID(),
                status: .applied,
                createdAt: Date(timeIntervalSince1970: 1_786_404_100),
                payloadJSON: "{\"kind\":\"archive\"}"
            )
        )
    }
}

private struct StoreFixture {
    let container: URL
    let databaseURL: URL
    let libraryRoot: URL
    let applicationSupport: URL
    let caches: URL

    static func make() throws -> Self {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroTool-MetadataStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        return Self(
            container: container,
            databaseURL: container.appendingPathComponent("metadata.sqlite"),
            libraryRoot: container.appendingPathComponent("Library", isDirectory: true),
            applicationSupport: container.appendingPathComponent("ApplicationSupport", isDirectory: true),
            caches: container.appendingPathComponent("Caches", isDirectory: true)
        )
    }

    static func makeLibrary() throws -> Self {
        let fixture = try make()
        try FileManager.default.createDirectory(
            at: fixture.libraryRoot.appendingPathComponent("Project/Night", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("immutable image bytes".utf8).write(
            to: fixture.libraryRoot.appendingPathComponent("Project/Night/frame.fit")
        )
        return fixture
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }
}
