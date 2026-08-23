import Foundation
import Testing
@testable import AstroApplication
@testable import AstroMobileDomain

@Test func composerMapsAllowlistedDomainValuesAndOmitsFilesystemMaterial() throws {
    let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let nightID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    let seriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
    let briefingID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
    let libraryID = PortableLibraryID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000105")!)
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    let project = ProjectRecord(id: projectID, catalogID: "M42", displayName: "Orion Nebula", phase: .collecting)
    let annotation = ProjectAnnotationRecord(
        projectID: projectID,
        integrationGoalHours: 12.5,
        notes: "Field note",
        updatedAt: now
    )
    let night = NightRecord(id: nightID, localDate: "2026-08-23", timeZoneID: "Europe/Budapest")
    let capture = SeriesRecord(
        id: seriesID,
        projectID: projectID,
        nightID: nightID,
        setupID: "rig-1",
        setupDescriptor: "ASI2600 / 400mm",
        sensorMode: .mono,
        passband: .narrowband,
        exposureSeconds: 300,
        filterName: "Ha",
        filterID: "ha-7nm",
        gain: 100,
        offset: 30,
        binning: "1x1"
    )
    let target = BriefingTargetBlock(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000106")!,
        name: "M42",
        role: .primary,
        start: now,
        end: now.addingTimeInterval(3_600),
        warnings: ["Check focus"]
    )
    let briefing = NightBriefingDraft(
        id: briefingID,
        revision: 7,
        savedAt: now,
        nightDate: now,
        site: BriefingSiteSummary(id: "site-1", name: "Pilis"),
        setup: BriefingSetupSummary(id: "rig-1", name: "Travel rig"),
        targets: [target],
        checklist: [BriefingChecklistSection(
            id: "setup",
            title: "Setup",
            items: [BriefingChecklistItem(id: "focus", title: "Focus", isCompleted: true)]
        )],
        notes: "Bring dew heater",
        language: .en
    )

    let input = MobileSnapshotComposer.Input(
        libraryID: libraryID,
        revision: 12,
        projects: [project],
        nights: [night],
        captures: [capture],
        annotations: [annotation],
        briefings: [briefing]
    )
    let snapshot = try MobileSnapshotComposer().compose(input: input, now: now)
    let text = String(decoding: try MobileJSON.encoder.encode(snapshot), as: UTF8.self)

    #expect(snapshot.schemaVersion == MobileLibrarySnapshot.currentSchemaVersion)
    #expect(snapshot.libraryID == libraryID)
    #expect(snapshot.revision == 12)
    #expect(snapshot.createdAt == now)
    #expect(snapshot.projects.first?.displayName == "Orion Nebula")
    #expect(snapshot.projects.first?.catalogID == "M42")
    #expect(snapshot.projects.first?.integrationSeconds == 300)
    #expect(snapshot.projects.first?.goalHours == 12.5)
    #expect(snapshot.captures.first?.displayName == "ASI2600 / 400mm")
    #expect(snapshot.captures.first?.filterName == "Ha")
    #expect(snapshot.briefings.first?.targets.first?.name == "M42")
    #expect(snapshot.briefings.first?.checklist.first?.items.first?.isCompleted == true)
    #expect(snapshot.notes.contains { $0.text == "Field note" })
    #expect(snapshot.notes.contains { $0.text == "Bring dew heater" })

    for forbidden in [
        "Library Folder Name", "/private/astro/cache", "frame-0001.fits",
        "securityScopedBookmark", "SIMPLE  =", "DATABASE_OBJECT", "raw-image-bytes"
    ] {
        #expect(!text.localizedCaseInsensitiveContains(forbidden))
    }
}

@Test func composerUsesExplicitSnapshotSchemaAndNowValue() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_123.456)
    let input = MobileSnapshotComposer.Input(
        libraryID: PortableLibraryID(rawValue: UUID()),
        revision: 3,
        projects: [], nights: [], captures: [], annotations: [], briefings: []
    )
    let snapshot = try MobileSnapshotComposer().compose(input: input, now: now)
    #expect(snapshot.schemaVersion == 1)
    #expect(snapshot.revision == 3)
    #expect(snapshot.createdAt == now)
    #expect(snapshot.projects.isEmpty)
    #expect(snapshot.nights.isEmpty)
    #expect(snapshot.captures.isEmpty)
    #expect(snapshot.briefings.isEmpty)
    #expect(snapshot.notes.isEmpty)
}
