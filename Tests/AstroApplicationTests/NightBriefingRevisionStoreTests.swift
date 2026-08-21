import AstroApplication
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

        let first = try await store.save(original)
        let firstURL = fixture.directory.appendingPathComponent("\(original.id.uuidString.lowercased())-r000001.json")
        let firstBytes = try Data(contentsOf: firstURL)
        var changed = original
        changed.notes = "Pontosított terv"
        let second = try await store.save(changed)

        #expect(first.revision == 1)
        #expect(second.revision == 2)
        #expect(try Data(contentsOf: firstURL) == firstBytes)
        #expect(try await store.latest(id: original.id)?.notes == "Pontosított terv")
    }

    @Test("Corrupt revisions do not hide healthy briefings")
    func skipsCorruptRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = NightBriefingRevisionStore(directory: fixture.directory)
        let saved = try await store.save(fixture.draft(notes: "Ép"))
        let corrupt = fixture.directory.appendingPathComponent("22222222-2222-2222-2222-222222222222-r000001.json")
        try Data("not json".utf8).write(to: corrupt, options: .withoutOverwriting)

        let latest = try await store.latestRevisions()

        #expect(latest == [saved])
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

        let saved = try await store.save(draft)
        #expect(saved.revision == 2)
        #expect(try Data(contentsOf: occupied) == sentinel)
    }

    @Test("A corrupt revision after a healthy one cannot block later saves")
    func savesAfterCorruptLatestRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = NightBriefingRevisionStore(directory: fixture.directory)
        let draft = fixture.draft(notes: "Első")
        let first = try await store.save(draft)
        let corrupt = fixture.directory.appendingPathComponent(
            "\(draft.id.uuidString.lowercased())-r000002.json"
        )
        let corruptBytes = Data("broken revision".utf8)
        try corruptBytes.write(to: corrupt, options: .withoutOverwriting)

        var changed = first
        changed.notes = "Harmadik"
        let third = try await store.save(changed)

        #expect(third.revision == 3)
        #expect(try Data(contentsOf: corrupt) == corruptBytes)
        #expect(try await store.latest(id: draft.id)?.notes == "Harmadik")
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
