import Foundation
import Testing
@testable import AstroMobileDomain

@Test func snapshotRoundTripsWithSortedJSON() throws {
    let snapshot = MobileLibrarySnapshot.testValue
    let data = try MobileJSON.encoder.encode(snapshot)
    #expect(try MobileJSON.decoder.decode(MobileLibrarySnapshot.self, from: data) == snapshot)
}

@Test func packagePurposeAndBaseSnapshotIdentityRoundTrip() throws {
    let snapshot = MobileLibrarySnapshot.testValue
    let envelope = MobilePackageEnvelope(
        purpose: .returnChanges,
        snapshot: snapshot,
        baseSnapshotID: snapshot.snapshotID,
        changes: [],
        acknowledgedChangeIDs: []
    )
    #expect(try MobileJSON.decoder.decode(MobilePackageEnvelope.self, from: MobileJSON.encoder.encode(envelope)) == envelope)
    #expect(envelope.purpose == .returnChanges)
    #expect(envelope.baseSnapshotID == snapshot.snapshotID)
}

@Test func encodedSnapshotContainsNoFilesystemMaterial() throws {
    let snapshot = MobileLibrarySnapshot.testValue
    let envelope = MobilePackageEnvelope(
        purpose: .returnChanges,
        snapshot: snapshot,
        baseSnapshotID: snapshot.snapshotID,
        changes: MobileChange.testValues,
        acknowledgedChangeIDs: [MobileChange.testChangeID]
    )
    let manifest = MobilePackageManifest(
        formatVersion: 1,
        packageID: MobileChange.testChangeID,
        createdAt: MobileChange.testDate,
        encryptedByteCount: 256,
        ciphertextSHA256: "abc123",
        keyMode: .pairedDevice,
        wrappedContentKeyBase64: "wrapped"
    )
    let summary = MobileSnapshotSummary(
        projectCount: 1,
        nightCount: 1,
        captureCount: 1,
        briefingCount: 1,
        noteCount: 1
    )
    let encodedValues = try [
        MobileJSON.encoder.encode(snapshot),
        MobileJSON.encoder.encode(envelope),
        MobileJSON.encoder.encode(manifest),
        MobileJSON.encoder.encode(summary)
    ]
    let text = encodedValues
        .map { String(decoding: $0, as: UTF8.self) }
        .joined(separator: "\n")
    for forbidden in ["/Users/", "file://", ".fits", "securityScopedBookmark", "SIMPLE  ="] {
        #expect(!text.localizedCaseInsensitiveContains(forbidden))
    }

    let actualKeys = try encodedValues.reduce(into: Set<String>()) { keys, data in
        let object = try JSONSerialization.jsonObject(with: data)
        keys.formUnion(allObjectKeys(in: object))
    }
    #expect(actualKeys == expectedAllowlistedKeys)
}

@Test func populatedSnapshotRoundTripsFractionalDates() throws {
    let snapshot = MobileLibrarySnapshot.testValue
    #expect(try MobileJSON.decoder.decode(MobileLibrarySnapshot.self, from: MobileJSON.encoder.encode(snapshot)) == snapshot)
}

private func allObjectKeys(in value: Any) -> Set<String> {
    if let object = value as? [String: Any] {
        return object.reduce(into: Set(object.keys)) { keys, entry in
            keys.formUnion(allObjectKeys(in: entry.value))
        }
    }
    if let array = value as? [Any] {
        return array.reduce(into: Set<String>()) { keys, entry in
            keys.formUnion(allObjectKeys(in: entry))
        }
    }
    return []
}

private let expectedAllowlistedKeys: Set<String> = [
    "schemaVersion", "libraryID", "snapshotID", "revision", "createdAt",
    "projects", "nights", "captures", "briefings", "notes", "rawValue",
    "id", "displayName", "catalogID", "phase", "integrationSeconds", "goalHours",
    "localDate", "timeZoneID", "projectID", "nightID", "filterName", "exposureSeconds",
    "savedAt", "nightDate", "readiness", "targets", "checklist", "noteID", "name",
    "role", "start", "end", "warnings", "title", "items", "explanation", "isCompleted",
    "baseRevision", "scope", "ownerID", "text", "updatedAt", "isEditableOnPhone",
    "snapshot", "purpose", "baseSnapshotID", "changes", "acknowledgedChangeIDs", "kind", "payload", "changeID", "deviceID",
    "briefingID", "itemID", "isCompleted", "formatVersion", "packageID",
    "encryptedByteCount", "ciphertextSHA256", "keyMode", "wrappedContentKeyBase64",
    "projectCount", "nightCount", "captureCount", "briefingCount", "noteCount", "checklistItemCount"
]

private extension MobileLibrarySnapshot {
    static let testValue = MobileLibrarySnapshot(
        schemaVersion: 1,
        libraryID: PortableLibraryID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
        snapshotID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        revision: 1,
        createdAt: MobileChange.testDate,
        projects: [MobileProject(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            displayName: "M31",
            catalogID: "M31",
            phase: "collecting",
            integrationSeconds: 1800.5,
            goalHours: 4.0
        )],
        nights: [MobileNight(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            localDate: "2026-08-23",
            timeZoneID: "Europe/Budapest"
        )],
        captures: [MobileCapture(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            nightID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            displayName: "M31 Light",
            filterName: "L",
            exposureSeconds: 60.25,
            integrationSeconds: 1800.5
        )],
        briefings: [MobileBriefing(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            revision: 2,
            savedAt: MobileChange.testDate,
            nightDate: MobileChange.testDate,
            readiness: "ready",
            targets: [MobileBriefingTarget(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
                name: "M31",
                role: "primary",
                start: MobileChange.testDate,
                end: MobileChange.testDate.addingTimeInterval(3600),
                warnings: ["Check focus"]
            )],
            checklist: [MobileChecklistSection(
                id: "setup",
                title: "Setup",
                items: [MobileChecklistItem(
                    id: "focus",
                    title: "Focus",
                    explanation: "Check focus before capture",
                    isCompleted: true,
                    baseRevision: 2
                )]
            )],
            noteID: "briefing-note"
        )],
        notes: [MobileNote(
            id: "briefing-note",
            scope: .briefing,
            ownerID: "briefing-0001",
            text: "Clear sky",
            baseRevision: 2,
            updatedAt: MobileChange.testDate,
            isEditableOnPhone: true
        )]
    )
}

private extension MobileChange {
    static let testChangeID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
    static let testDate = Date(timeIntervalSince1970: 1_700_000_000.123)
    static let testValues: [MobileChange] = [
        .checklistCompletion(ChecklistCompletionChange(
            changeID: testChangeID,
            deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            briefingID: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            itemID: "focus",
            baseRevision: 2,
            isCompleted: true,
            createdAt: testDate
        )),
        .noteRevision(NoteRevisionChange(
            changeID: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
            deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            noteID: "briefing-note",
            ownerID: "briefing-0001",
            baseRevision: 2,
            text: "Clear sky",
            createdAt: testDate
        ))
    ]
}
