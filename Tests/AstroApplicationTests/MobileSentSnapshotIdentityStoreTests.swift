import Foundation
import Testing
@testable import AstroApplication

@Suite("Mobile sent snapshot identity store")
struct MobileSentSnapshotIdentityStoreTests {
    private func makeStore() -> (MobileSentSnapshotIdentityStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sent-snapshot-store-\(UUID().uuidString)", isDirectory: true)
        return (MobileSentSnapshotIdentityStore(fileURL: root.appendingPathComponent("sent.json")), root)
    }

    @Test("releasing an exactly matching claim republishes it and preserves acknowledgements")
    func releaseClaimRepublishesExactMatch() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotID = UUID()
        let packageID = UUID()
        let acknowledgementID = UUID()
        let fingerprint = String(repeating: "a", count: 64)
        try store.reserve(snapshotID: snapshotID, acknowledgementIDs: [acknowledgementID])
        try store.markPublished(snapshotID: snapshotID)
        _ = try store.claimPublished(snapshotID: snapshotID, packageID: packageID, sourceFingerprint: fingerprint)

        try store.releaseClaim(snapshotID: snapshotID, packageID: packageID, sourceFingerprint: fingerprint)

        let record = try #require(try store.loadRecords().first { $0.snapshotID == snapshotID })
        #expect(record.state == .published)
        #expect(record.acknowledgementIDs == [acknowledgementID])
        #expect(record.claimedPackageID == nil)
        #expect(record.claimedSourceFingerprint == nil)

        // A different package may now claim the republished base.
        let otherPackageID = UUID()
        let otherFingerprint = String(repeating: "b", count: 64)
        let reclaimed = try store.claimPublished(snapshotID: snapshotID, packageID: otherPackageID, sourceFingerprint: otherFingerprint)
        #expect(reclaimed.claimedPackageID == otherPackageID)
        #expect(reclaimed.acknowledgementIDs == [acknowledgementID])
    }

    @Test("releasing with a mismatched package ID throws and leaves the record unchanged")
    func releaseClaimRejectsWrongPackageID() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotID = UUID()
        let packageID = UUID()
        let fingerprint = String(repeating: "a", count: 64)
        try store.reserve(snapshotID: snapshotID, acknowledgementIDs: [])
        try store.markPublished(snapshotID: snapshotID)
        let claimed = try store.claimPublished(snapshotID: snapshotID, packageID: packageID, sourceFingerprint: fingerprint)

        #expect(throws: MobileChangeImportError.snapshotMismatch) {
            try store.releaseClaim(snapshotID: snapshotID, packageID: UUID(), sourceFingerprint: fingerprint)
        }
        let unchanged = try #require(try store.loadRecords().first { $0.snapshotID == snapshotID })
        #expect(unchanged == claimed)
    }

    @Test("releasing with a mismatched fingerprint throws and leaves the record unchanged")
    func releaseClaimRejectsWrongFingerprint() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotID = UUID()
        let packageID = UUID()
        let fingerprint = String(repeating: "a", count: 64)
        try store.reserve(snapshotID: snapshotID, acknowledgementIDs: [])
        try store.markPublished(snapshotID: snapshotID)
        let claimed = try store.claimPublished(snapshotID: snapshotID, packageID: packageID, sourceFingerprint: fingerprint)

        #expect(throws: MobileChangeImportError.snapshotMismatch) {
            try store.releaseClaim(snapshotID: snapshotID, packageID: packageID, sourceFingerprint: String(repeating: "b", count: 64))
        }
        let unchanged = try #require(try store.loadRecords().first { $0.snapshotID == snapshotID })
        #expect(unchanged == claimed)
    }

    @Test("releasing a record that is not claimed throws and leaves it unchanged")
    func releaseClaimRejectsNotClaimedState() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotID = UUID()
        try store.reserve(snapshotID: snapshotID, acknowledgementIDs: [])
        try store.markPublished(snapshotID: snapshotID)
        let published = try #require(try store.loadRecords().first { $0.snapshotID == snapshotID })

        #expect(throws: MobileChangeImportError.snapshotMismatch) {
            try store.releaseClaim(snapshotID: snapshotID, packageID: UUID(), sourceFingerprint: String(repeating: "a", count: 64))
        }
        let unchanged = try #require(try store.loadRecords().first { $0.snapshotID == snapshotID })
        #expect(unchanged == published)
    }

    @Test("releasing an unknown snapshot ID throws snapshot mismatch")
    func releaseClaimRejectsUnknownSnapshotID() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: MobileChangeImportError.snapshotMismatch) {
            try store.releaseClaim(snapshotID: UUID(), packageID: UUID(), sourceFingerprint: String(repeating: "a", count: 64))
        }
    }
}
