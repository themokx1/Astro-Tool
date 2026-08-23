import Foundation
import Testing
@testable import AstroMobileDomain

@Test func snapshotRoundTripsWithSortedJSON() throws {
    let snapshot = MobileLibrarySnapshot.testValue
    let data = try MobileJSON.encoder.encode(snapshot)
    #expect(try MobileJSON.decoder.decode(MobileLibrarySnapshot.self, from: data) == snapshot)
}

@Test func encodedSnapshotContainsNoFilesystemMaterial() throws {
    let text = String(decoding: try MobileJSON.encoder.encode(MobileLibrarySnapshot.testValue), as: UTF8.self)
    for forbidden in ["/Users/", "file://", ".fits", "securityScopedBookmark", "SIMPLE  ="] {
        #expect(!text.localizedCaseInsensitiveContains(forbidden))
    }
}

private extension MobileLibrarySnapshot {
    static let testValue = MobileLibrarySnapshot(
        schemaVersion: 1,
        libraryID: PortableLibraryID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
        snapshotID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        revision: 1,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        projects: [], nights: [], captures: [], briefings: [], notes: []
    )
}
