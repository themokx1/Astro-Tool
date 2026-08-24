@testable import AstroApplication
import Foundation
import Testing

@Suite("Immutable night briefing revisions")
struct NightBriefingRevisionStoreTests {
    @Test("Every save creates a new revision and preserves prior bytes")
    func savesImmutableRevisions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = NightBriefingRevisionStore(directory: fixture.directory)
        let original = fixture.draft(notes: "Első terv")

        let first = try await store.create(original)
        let firstURL = fixture.directory.appendingPathComponent("\(original.id.uuidString.lowercased())-r000001.json")
        let firstBytes = try Data(contentsOf: firstURL)
        var changed = original
        changed.notes = "Pontosított terv"
        let second = try await store.saveIfLatest(changed, expectedRevision: first.revision)

        #expect(first.revision == 1)
        #expect(second.revision == 2)
        #expect(try Data(contentsOf: firstURL) == firstBytes)
        #expect(try await store.latest(id: original.id)?.notes == "Pontosított terv")
    }

    @Test("Corrupt revisions fail closed instead of hiding authority")
    func corruptRevisionFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = NightBriefingRevisionStore(directory: fixture.directory)
        _ = try await store.create(fixture.draft(notes: "Ép"))
        let corrupt = fixture.directory.appendingPathComponent("22222222-2222-2222-2222-222222222222-r000001.json")
        try Data("not json".utf8).write(to: corrupt, options: .withoutOverwriting)

        await #expect(throws: NightBriefingRevisionStoreError.corruptRevision(corrupt.resolvingSymlinksInPath())) {
            _ = try await store.latestRevisions()
        }
    }

    @Test("A corrupt occupied filename is preserved and the next revision is used")
    func skipsOccupiedRevisionNameWithoutOverwriting() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let draft = fixture.draft(notes: "Nem írható felül")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let occupied = fixture.directory.appendingPathComponent("\(draft.id.uuidString.lowercased())-r000001.json")
        let sentinel = Data("sentinel".utf8)
        try sentinel.write(to: occupied, options: .withoutOverwriting)
        let store = NightBriefingRevisionStore(directory: fixture.directory)

        await #expect(throws: NightBriefingRevisionStoreError.corruptRevision(occupied.resolvingSymlinksInPath())) {
            _ = try await store.create(draft)
        }
        #expect(try Data(contentsOf: occupied) == sentinel)
    }

    @Test("A corrupt revision after a healthy one cannot block later saves")
    func savesAfterCorruptLatestRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = NightBriefingRevisionStore(directory: fixture.directory)
        let draft = fixture.draft(notes: "Első")
        let first = try await store.create(draft)
        let corrupt = fixture.directory.appendingPathComponent(
            "\(draft.id.uuidString.lowercased())-r000002.json"
        )
        let corruptBytes = Data("broken revision".utf8)
        try corruptBytes.write(to: corrupt, options: .withoutOverwriting)

        var changed = first
        changed.notes = "Harmadik"
        await #expect(throws: NightBriefingRevisionStoreError.corruptRevision(corrupt.resolvingSymlinksInPath())) {
            _ = try await store.saveIfLatest(changed, expectedRevision: first.revision)
        }
        #expect(try Data(contentsOf: corrupt) == corruptBytes)
    }

    @Test("compare-and-set rejects a stale mobile revision instead of writing over a Mac edit")
    func saveIfLatestRejectsStaleRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = NightBriefingRevisionStore(directory: fixture.directory)
        let original = try await store.create(fixture.draft(notes: "Phone base"))
        var macEdit = original
        macEdit.notes = "Mac edit"
        _ = try await store.saveIfLatest(macEdit, expectedRevision: original.revision)

        var stalePhoneEdit = original
        stalePhoneEdit.notes = "Phone edit"
        await #expect(throws: NightBriefingRevisionStoreError.self) {
            try await store.saveIfLatest(stalePhoneEdit, expectedRevision: original.revision)
        }
        #expect(try await store.latest(id: original.id)?.notes == "Mac edit")
    }

    @Test("create rejects a draft carrying fabricated mobile evidence and writes no file")
    func createRejectsFabricatedMobileEvidence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = NightBriefingRevisionStore(directory: fixture.directory)
        var poisoned = fixture.draft(notes: "Injected")
        let fabricatedID = UUID()
        poisoned.mobileChangeIDs = [fabricatedID]
        poisoned.mobileChangeMarkers = [MobileChangeMarker(
            changeID: fabricatedID,
            ownerID: "briefing:\(poisoned.id.uuidString.lowercased())",
            payloadFingerprint: String(repeating: "a", count: 64),
            resultingRevision: 1
        )]

        await #expect(throws: NightBriefingRevisionStoreError.mobileEvidenceNotWritable(poisoned.id)) {
            _ = try await store.create(poisoned)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test("First-revision saveIfLatest rejects fabricated mobile evidence and writes no file")
    func firstRevisionSaveIfLatestRejectsFabricatedMobileEvidence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = NightBriefingRevisionStore(directory: fixture.directory)
        var poisoned = fixture.draft(notes: "Injected")
        let fabricatedID = UUID()
        poisoned.mobileChangeIDs = [fabricatedID]

        await #expect(throws: NightBriefingRevisionStoreError.mobileEvidenceNotWritable(poisoned.id)) {
            _ = try await store.saveIfLatest(poisoned, expectedRevision: 0)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test("CAS saveIfLatest preserves durable mobile evidence and ignores caller-supplied evidence")
    func casSaveIfLatestPreservesDurableMobileEvidence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = NightBriefingRevisionStore(directory: fixture.directory)
        let base = try await store.create(fixture.draft(notes: "Base"))
        let realChangeID = UUID()
        let realMarker = MobileChangeMarker(
            changeID: realChangeID,
            ownerID: "briefing:\(base.id.uuidString.lowercased())",
            payloadFingerprint: String(repeating: "b", count: 64),
            resultingRevision: 2
        )
        var seeded = base
        seeded.notes = "Phone applied"
        seeded.mobileChangeIDs = [realChangeID]
        seeded.mobileChangeMarkers = [realMarker]
        let durable = try await store.saveIfLatestRecordingMobileEvidence(seeded, expectedRevision: base.revision)

        // (a) an extra fabricated marker must not be persisted.
        var withExtraMarker = durable
        withExtraMarker.notes = "Mac edit with injected extra"
        let fabricatedID = UUID()
        withExtraMarker.mobileChangeIDs.append(fabricatedID)
        withExtraMarker.mobileChangeMarkers.append(MobileChangeMarker(
            changeID: fabricatedID,
            ownerID: "briefing:\(base.id.uuidString.lowercased())",
            payloadFingerprint: String(repeating: "c", count: 64),
            resultingRevision: 3
        ))
        let afterExtra = try await store.saveIfLatest(withExtraMarker, expectedRevision: durable.revision)
        #expect(afterExtra.mobileChangeIDs == durable.mobileChangeIDs)
        #expect(afterExtra.mobileChangeMarkers == durable.mobileChangeMarkers)

        // (b) evidence stripped from the candidate must not be honored either;
        // the durable evidence must still be carried forward.
        var stripped = afterExtra
        stripped.notes = "Mac edit stripping evidence"
        stripped.mobileChangeIDs = []
        stripped.mobileChangeMarkers = []
        let afterStripped = try await store.saveIfLatest(stripped, expectedRevision: afterExtra.revision)
        #expect(afterStripped.mobileChangeIDs == durable.mobileChangeIDs)
        #expect(afterStripped.mobileChangeMarkers == durable.mobileChangeMarkers)
    }

    @Test("The internal mobile-evidence-recording save still persists markers verbatim")
    func internalSaveRecordsMobileEvidenceVerbatim() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = NightBriefingRevisionStore(directory: fixture.directory)
        let base = try await store.create(fixture.draft(notes: "Base"))
        let changeID = UUID()
        let marker = MobileChangeMarker(
            changeID: changeID,
            ownerID: "briefing:\(base.id.uuidString.lowercased())",
            payloadFingerprint: String(repeating: "d", count: 64),
            resultingRevision: 2
        )
        var withEvidence = base
        withEvidence.notes = "Phone applied"
        withEvidence.mobileChangeIDs = [changeID]
        withEvidence.mobileChangeMarkers = [marker]

        let saved = try await store.saveIfLatestRecordingMobileEvidence(withEvidence, expectedRevision: base.revision)

        #expect(saved.mobileChangeIDs == [changeID])
        #expect(saved.mobileChangeMarkers == [marker])
        #expect(try await store.latest(id: base.id)?.mobileChangeMarkers == [marker])
    }

    private struct Fixture {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AstroToolBriefing-\(UUID().uuidString)", isDirectory: true)
        }

        func draft(notes: String) -> NightBriefingDraft {
            let date = Date(timeIntervalSince1970: 1_786_738_400)
            return NightBriefingDraft(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                revision: 0,
                savedAt: date,
                nightDate: date,
                arrival: date,
                departure: date.addingTimeInterval(7_200),
                site: BriefingSiteSummary(id: "garden", name: "Kert"),
                setup: BriefingSetupSummary(id: "rig", name: "Kis setup"),
                weather: .missing(reason: "Nincs adat"),
                targets: [],
                notes: notes,
                language: .hu
            )
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
