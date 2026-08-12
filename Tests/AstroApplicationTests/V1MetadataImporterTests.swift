@testable import AstroApplication
import Foundation
import Testing

struct V1MetadataImporterTests {
    @Test("Import copies only human metadata, is idempotent, and leaves V1 untouched")
    func importCopiesHumanDataAndLeavesV1Untouched() async throws {
        let fixture = try V1DatabaseFixture.make()
        defer { fixture.remove() }
        let before = try V1SourceManifest.capture(directory: fixture.storeDirectory)
        let snapshot = try await V1StoreSnapshotter.snapshotReadOnly(
            sourceDirectory: fixture.storeDirectory
        )
        defer { snapshot.remove() }
        let destination = try MetadataStore.temporary()

        let first = try await V1MetadataImporter.importReadOnly(
            from: snapshot,
            into: destination
        )
        #expect(first.tags == 1)
        #expect(first.sessionNotes == 3)
        #expect(first.verdicts == 1)
        #expect(first.filterProfiles == 1)
        #expect(first.captureGroups == 1)
        #expect(first.captureSources == 1)
        #expect(first.captureAssignments == 1)
        #expect(first.acknowledgements == 1)
        #expect(first.userConfigurations == 1)
        #expect(first.conversionReceipts == 1)
        #expect(first.quarantineReceipts == 1)
        #expect(first.sensorMeasurements == 2)
        #expect(first.inserted == first.discovered)

        let second = try await V1MetadataImporter.importReadOnly(
            from: snapshot,
            into: destination
        )
        #expect(second.discovered == first.discovered)
        #expect(second.inserted == 0)
        #expect(try await destination.legacyImportCount() == first.discovered)
        #expect(try V1SourceManifest.capture(directory: fixture.storeDirectory) == before)

        let imports = try await destination.legacyImports(kind: .frameVerdict)
        #expect(imports.count == 1)
        #expect(imports[0].sourceKey.contains("sessions/IC_1396/2026-08-08/lights/frame.fit"))
        #expect(!imports[0].sourceKey.contains("41"))
    }
}
