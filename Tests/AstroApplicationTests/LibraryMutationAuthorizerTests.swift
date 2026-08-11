@testable import AstroApplication
import CryptoKit
import Foundation
import Testing

@Suite("Fail-closed library mutation authorization")
struct LibraryMutationAuthorizerTests {
    @Test("Plans and receipts have stable Codable value semantics")
    func codableValueTypes() throws {
        let fixture = try MutationFixture.make(mode: .mutationEnabled)
        defer { fixture.remove() }
        let plan = try fixture.plan([("b.fit", "Archive/b.fit")])

        let encoded = try JSONEncoder().encode(plan)

        #expect(try JSONDecoder().decode(LibraryMutationPlan.self, from: encoded) == plan)
    }

    @Test("Read-only authorization rejects apply without moving files")
    func readOnlyRejectsApply() async throws {
        let fixture = try MutationFixture.make()
        defer { fixture.remove() }
        let plan = try fixture.plan([("a.fit", "Archive/a.fit")])
        try await fixture.authorizer.register(plan)

        await #expect(throws: LibraryMutationError.readOnly) {
            try await fixture.authorizer.apply(planID: plan.id, confirmation: plan.confirmationToken)
        }
        #expect(fixture.exists("a.fit"))
        #expect(!fixture.exists("Archive/a.fit"))
    }

    @Test("Apply requires the registered confirmation token")
    func rejectsWrongConfirmation() async throws {
        let fixture = try MutationFixture.make(mode: .mutationEnabled)
        defer { fixture.remove() }
        let plan = try fixture.plan([("a.fit", "Archive/a.fit")])
        try await fixture.authorizer.register(plan)

        await #expect(throws: LibraryMutationError.invalidConfirmation) {
            try await fixture.authorizer.apply(planID: plan.id, confirmation: "wrong")
        }
        #expect(fixture.exists("a.fit"))
    }

    @Test("Registration rejects another library and a stale revision")
    func rejectsWrongLibraryAndRevision() async throws {
        let fixture = try MutationFixture.make(mode: .mutationEnabled, revision: 7)
        defer { fixture.remove() }
        let plan = try fixture.plan([("a.fit", "Archive/a.fit")])
        let otherRoot = fixture.container.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)

        await #expect(throws: LibraryMutationError.libraryIdentityMismatch) {
            try await fixture.authorizer.register(plan.replacing(libraryID: LibraryIdentity(rootURL: otherRoot)))
        }
        await #expect(throws: LibraryMutationError.staleRevision) {
            try await fixture.authorizer.register(plan.replacing(revision: 6))
        }
    }

    @Test("A changed source fingerprint fails closed")
    func rejectsStaleFingerprint() async throws {
        let fixture = try MutationFixture.make(mode: .mutationEnabled)
        defer { fixture.remove() }
        let plan = try fixture.plan([("a.fit", "Archive/a.fit")])
        try await fixture.authorizer.register(plan)
        try Data("changed".utf8).write(to: fixture.url("a.fit"))

        await #expect(throws: LibraryMutationError.stalePlan) {
            try await fixture.authorizer.apply(planID: plan.id, confirmation: plan.confirmationToken)
        }
        #expect(fixture.exists("a.fit"))
        #expect(!fixture.exists("Archive/a.fit"))
    }

    @Test("Replacing the configured library root invalidates registered plans")
    func rejectsStaleRootIdentity() async throws {
        let fixture = try MutationFixture.make(mode: .mutationEnabled)
        defer { fixture.remove() }
        let plan = try fixture.plan([("a.fit", "Archive/a.fit")])
        try await fixture.authorizer.register(plan)
        let displaced = fixture.container.appendingPathComponent("displaced", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.root, to: displaced)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.url("Archive"), withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: fixture.url("a.fit"))

        await #expect(throws: LibraryMutationError.staleLibraryIdentity) {
            try await fixture.authorizer.apply(planID: plan.id, confirmation: plan.confirmationToken)
        }
        #expect(fixture.exists("a.fit"))
    }

    @Test("Sources and destinations must remain within the library")
    func rejectsScopeEscapes() async throws {
        let fixture = try MutationFixture.make(mode: .mutationEnabled)
        defer { fixture.remove() }
        let outsideSource = fixture.container.appendingPathComponent("outside.fit")
        try Data("outside".utf8).write(to: outsideSource)
        let valid = try fixture.plan([("a.fit", "Archive/a.fit")])

        let sourceEscape = valid.replacing(entries: [
            .init(source: outsideSource, destination: fixture.url("Archive/a.fit"), fingerprint: sha256(Data("outside".utf8)))
        ])
        await #expect(throws: LibraryMutationError.sourceOutsideLibrary) {
            try await fixture.authorizer.register(sourceEscape)
        }

        let destinationEscape = valid.replacing(entries: [
            .init(source: fixture.url("a.fit"), destination: fixture.container.appendingPathComponent("escaped.fit"), fingerprint: sha256(Data("alpha".utf8)))
        ])
        await #expect(throws: LibraryMutationError.destinationOutsideLibrary) {
            try await fixture.authorizer.register(destinationEscape)
        }
    }

    @Test("Symbolic-link source and destination components are never followed")
    func rejectsSymbolicLinks() async throws {
        let fixture = try MutationFixture.make(mode: .mutationEnabled)
        defer { fixture.remove() }
        let outside = fixture.container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.fit"))
        try FileManager.default.createSymbolicLink(at: fixture.url("linked-source"), withDestinationURL: outside)
        let sourcePlan = LibraryMutationPlan(
            libraryID: fixture.identity,
            revision: fixture.revision,
            entries: [.init(
                source: fixture.url("linked-source/secret.fit"),
                destination: fixture.url("Archive/secret.fit"),
                fingerprint: sha256(Data("secret".utf8))
            )],
            totalBytes: 6,
            confirmationToken: "confirm"
        )
        await #expect(throws: LibraryMutationError.unsafeSource) {
            try await fixture.authorizer.register(sourcePlan)
        }

        try FileManager.default.createSymbolicLink(at: fixture.url("linked-destination"), withDestinationURL: outside)
        let destinationPlan = try fixture.plan([("a.fit", "Archive/a.fit")]).replacing(entries: [
            .init(
                source: fixture.url("a.fit"),
                destination: fixture.url("linked-destination/a.fit"),
                fingerprint: sha256(Data("alpha".utf8))
            )
        ])
        await #expect(throws: LibraryMutationError.unsafeDestination) {
            try await fixture.authorizer.register(destinationPlan)
        }
    }

    @Test("All entries are preflighted before the first deterministic move")
    func collisionMovesNothing() async throws {
        let fixture = try MutationFixture.make(mode: .mutationEnabled)
        defer { fixture.remove() }
        try Data("occupied".utf8).write(to: fixture.url("Archive/b.fit"))
        let plan = try fixture.plan([("b.fit", "Archive/b.fit"), ("a.fit", "Archive/a.fit")])
        try await fixture.authorizer.register(plan)

        await #expect(throws: LibraryMutationError.collision) {
            try await fixture.authorizer.apply(planID: plan.id, confirmation: plan.confirmationToken)
        }
        #expect(fixture.exists("a.fit"))
        #expect(fixture.exists("b.fit"))
        #expect(!fixture.exists("Archive/a.fit"))
    }

    @Test("A partial execution failure automatically restores earlier moves")
    func partialFailureRollsBack() async throws {
        let fixture = try MutationFixture.make(mode: .mutationEnabled, failBeforeMove: 1)
        defer { fixture.remove() }
        let plan = try fixture.plan([("b.fit", "Archive/b.fit"), ("a.fit", "Archive/a.fit")])
        try await fixture.authorizer.register(plan)

        await #expect(throws: MutationFixture.InjectedFailure.self) {
            try await fixture.authorizer.apply(planID: plan.id, confirmation: plan.confirmationToken)
        }
        #expect(fixture.exists("a.fit"))
        #expect(fixture.exists("b.fit"))
        #expect(!fixture.exists("Archive/a.fit"))
        #expect(!fixture.exists("Archive/b.fit"))
        #expect((try FileManager.default.contentsOfDirectory(atPath: fixture.journal.path)).isEmpty)
    }

    @Test("Successful moves are deterministic, journaled externally, and plans are single-use")
    func appliesJournalsAndRejectsReuse() async throws {
        let fixture = try MutationFixture.make(mode: .mutationEnabled)
        defer { fixture.remove() }
        let plan = try fixture.plan([("b.fit", "Archive/b.fit"), ("a.fit", "Archive/a.fit")])
        try await fixture.authorizer.register(plan)

        let receipt = try await fixture.authorizer.apply(planID: plan.id, confirmation: plan.confirmationToken)

        #expect(receipt.planID == plan.id)
        #expect(receipt.entries.map(\.source.lastPathComponent) == ["a.fit", "b.fit"])
        #expect(fixture.exists("Archive/a.fit"))
        #expect(fixture.exists("Archive/b.fit"))
        #expect(!fixture.journal.path.hasPrefix(fixture.root.path + "/"))
        let journalFiles = try FileManager.default.contentsOfDirectory(at: fixture.journal, includingPropertiesForKeys: nil)
        #expect(journalFiles.count == 1)
        #expect(try JSONDecoder().decode(MutationReceipt.self, from: Data(contentsOf: journalFiles[0])) == receipt)

        await #expect(throws: LibraryMutationError.planAlreadyUsed) {
            try await fixture.authorizer.apply(planID: plan.id, confirmation: plan.confirmationToken)
        }
    }

    @Test("Rollback validates collisions and symbolic-link scope, then succeeds in reverse order once")
    func rollbackIsValidatedAndSingleUse() async throws {
        let fixture = try MutationFixture.make(mode: .mutationEnabled)
        defer { fixture.remove() }
        let plan = try fixture.plan([("a.fit", "Archive/a.fit"), ("b.fit", "Archive/b.fit")])
        try await fixture.authorizer.register(plan)
        let receipt = try await fixture.authorizer.apply(planID: plan.id, confirmation: plan.confirmationToken)

        try Data("collision".utf8).write(to: fixture.url("a.fit"))
        await #expect(throws: LibraryMutationError.rollbackCollision) {
            try await fixture.authorizer.rollback(receiptID: receipt.id)
        }
        try FileManager.default.removeItem(at: fixture.url("a.fit"))
        try await fixture.authorizer.rollback(receiptID: receipt.id)
        #expect(fixture.exists("a.fit"))
        #expect(fixture.exists("b.fit"))
        #expect(!fixture.exists("Archive/a.fit"))
        #expect(!fixture.exists("Archive/b.fit"))

        await #expect(throws: LibraryMutationError.receiptAlreadyRolledBack) {
            try await fixture.authorizer.rollback(receiptID: receipt.id)
        }
    }

    @Test("Rollback refuses a destination tree replaced by a symbolic link")
    func rollbackRejectsSymlinkEscape() async throws {
        let fixture = try MutationFixture.make(mode: .mutationEnabled)
        defer { fixture.remove() }
        let plan = try fixture.plan([("a.fit", "Archive/a.fit")])
        try await fixture.authorizer.register(plan)
        let receipt = try await fixture.authorizer.apply(
            planID: plan.id,
            confirmation: plan.confirmationToken
        )
        let displacedArchive = fixture.container.appendingPathComponent("DisplacedArchive", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.url("Archive"), to: displacedArchive)
        try FileManager.default.createSymbolicLink(
            at: fixture.url("Archive"),
            withDestinationURL: displacedArchive
        )

        await #expect(throws: LibraryMutationError.unsafeSource) {
            try await fixture.authorizer.rollback(receiptID: receipt.id)
        }
        #expect(try Data(contentsOf: displacedArchive.appendingPathComponent("a.fit")) == Data("alpha".utf8))
    }
}

private struct MutationFixture {
    struct InjectedFailure: Error {}

    let container: URL
    let root: URL
    let journal: URL
    let identity: LibraryIdentity
    let revision: UInt64
    let authorizer: LibraryMutationAuthorizer

    static func make(
        mode: LibraryAccessMode = .readOnly,
        revision: UInt64 = 1,
        failBeforeMove: Int? = nil
    ) throws -> Self {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroMutationTests-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("Library", isDirectory: true)
        let journal = container.appendingPathComponent("Journal", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Archive"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: root.appendingPathComponent("a.fit"))
        try Data("bravo".utf8).write(to: root.appendingPathComponent("b.fit"))
        let identity = LibraryIdentity(rootURL: root)
        let authorizer = try LibraryMutationAuthorizer(
            root: root,
            identity: identity,
            currentRevision: revision,
            accessMode: mode,
            journalDirectory: journal,
            beforeMove: { index in
                if index == failBeforeMove { throw InjectedFailure() }
            }
        )
        return Self(
            container: container,
            root: root,
            journal: journal,
            identity: identity,
            revision: revision,
            authorizer: authorizer
        )
    }

    func plan(_ moves: [(String, String)]) throws -> LibraryMutationPlan {
        let entries = try moves.map { source, destination in
            let data = try Data(contentsOf: url(source))
            return LibraryMutationPlan.Entry(
                source: url(source),
                destination: url(destination),
                fingerprint: sha256(data)
            )
        }
        return LibraryMutationPlan(
            libraryID: identity,
            revision: revision,
            entries: entries,
            totalBytes: try moves.reduce(Int64(0)) { total, move in
                total + Int64(try Data(contentsOf: url(move.0)).count)
            },
            confirmationToken: "confirm-\(UUID().uuidString)"
        )
    }

    func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(relativePath).path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }
}

private extension LibraryMutationPlan {
    func replacing(
        libraryID: LibraryIdentity? = nil,
        revision: UInt64? = nil,
        entries: [Entry]? = nil
    ) -> Self {
        Self(
            id: id,
            libraryID: libraryID ?? self.libraryID,
            revision: revision ?? self.revision,
            entries: entries ?? self.entries,
            totalBytes: totalBytes,
            confirmationToken: confirmationToken
        )
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
