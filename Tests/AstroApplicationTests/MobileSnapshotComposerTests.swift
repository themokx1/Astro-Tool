import Foundation
import Testing
@testable import AstroApplication
@testable import AstroCore
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

    let sourceFixture = SensitiveSourceFixture(
        projects: [project],
        nights: [night],
        captures: [capture],
        annotations: [annotation],
        briefings: [briefing]
    )
    let input = MobileSnapshotComposer.Input(
        libraryID: libraryID,
        revision: 12,
        projects: sourceFixture.safeProjects,
        nights: sourceFixture.safeNights,
        captures: sourceFixture.safeCaptures,
        annotations: sourceFixture.safeAnnotations,
        briefings: sourceFixture.safeBriefings,
        // Query-layer frame decisions: two 300-second frames were usable;
        // excluded/rejected frames are deliberately absent from this total.
        integrationSecondsByCaptureID: [seriesID: 600]
    )
    let snapshot = try MobileSnapshotComposer().compose(input: input, now: now)
    let text = String(decoding: try MobileJSON.encoder.encode(snapshot), as: UTF8.self)

    #expect(snapshot.schemaVersion == MobileLibrarySnapshot.currentSchemaVersion)
    #expect(snapshot.libraryID == libraryID)
    #expect(snapshot.revision == 12)
    #expect(snapshot.createdAt == now)
    #expect(snapshot.projects.first?.displayName == "Orion Nebula")
    #expect(snapshot.projects.first?.catalogID == "M42")
    #expect(snapshot.projects.first?.integrationSeconds == 600)
    #expect(snapshot.projects.first?.goalHours == 12.5)
    #expect(snapshot.captures.first?.displayName == "ASI2600 / 400mm")
    #expect(snapshot.captures.first?.filterName == "Ha")
    #expect(snapshot.captures.first?.integrationSeconds == 600)
    #expect(snapshot.briefings.first?.targets.first?.name == "M42")
    #expect(snapshot.briefings.first?.checklist.first?.items.first?.isCompleted == true)
    #expect(snapshot.notes.contains { $0.text == "Field note" })
    #expect(snapshot.notes.contains { $0.text == "Bring dew heater" })

    for forbidden in sourceFixture.forbiddenStrings {
        #expect(!text.localizedCaseInsensitiveContains(forbidden))
    }
}

@Test func composerDropsHiddenChecklistItemsBeforeTheyReachThePhone() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let briefing = NightBriefingDraft(
        id: UUID(),
        revision: 2,
        savedAt: now,
        checklist: [BriefingChecklistSection(
            id: "setup",
            title: "Setup",
            items: [
                BriefingChecklistItem(id: "visible", title: "Visible", isVisible: true),
                BriefingChecklistItem(id: "hidden", title: "Hidden", isVisible: false)
            ]
        )]
    )
    let input = MobileSnapshotComposer.Input(
        libraryID: PortableLibraryID(rawValue: UUID()),
        revision: 1,
        projects: [], nights: [], captures: [], annotations: [], briefings: [briefing],
        integrationSecondsByCaptureID: [:]
    )

    let snapshot = try MobileSnapshotComposer().compose(input: input, now: now)
    #expect(snapshot.briefings[0].checklist[0].items.map(\.id) == ["visible"])
}

@Test func composerUsesExplicitSnapshotSchemaAndNowValue() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_123.456)
    let input = MobileSnapshotComposer.Input(
        libraryID: PortableLibraryID(rawValue: UUID()),
        revision: 3,
        projects: [], nights: [], captures: [], annotations: [], briefings: [],
        integrationSecondsByCaptureID: [:]
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

@Test func composerRejectsACaptureWithoutAQueryIntegrationTotal() throws {
    let capture = composerTestCapture()
    let input = MobileSnapshotComposer.Input(
        libraryID: PortableLibraryID(rawValue: UUID()),
        revision: 1,
        projects: [],
        nights: [],
        captures: [capture],
        annotations: [],
        briefings: [],
        integrationSecondsByCaptureID: [:]
    )

    #expect(throws: AstroError.self) {
        try MobileSnapshotComposer().compose(input: input, now: Date())
    }
}

@Test func composerPreservesAnExplicitZeroIntegrationTotal() throws {
    let capture = composerTestCapture()
    let project = ProjectRecord(
        id: capture.projectID,
        catalogID: "M42",
        displayName: "Orion Nebula",
        phase: .collecting
    )
    let input = MobileSnapshotComposer.Input(
        libraryID: PortableLibraryID(rawValue: UUID()),
        revision: 1,
        projects: [project],
        nights: [],
        captures: [capture],
        annotations: [],
        briefings: [],
        integrationSecondsByCaptureID: [capture.id: 0]
    )

    let snapshot = try MobileSnapshotComposer().compose(input: input, now: Date())
    #expect(snapshot.projects.first?.integrationSeconds == 0)
    #expect(snapshot.captures.first?.integrationSeconds == 0)
}

private func composerTestCapture() -> SeriesRecord {
    SeriesRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
        projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
        nightID: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!,
        setupID: "rig-1",
        setupDescriptor: "Test rig",
        sensorMode: .mono,
        passband: .broadband,
        exposureSeconds: 300,
        filterName: nil,
        filterID: nil,
        gain: nil,
        offset: nil,
        binning: "1x1"
    )
}

private struct SensitiveSourceFixture {
    private struct SourceProject {
        let record: ProjectRecord
        let folderName: String
        let rootURL: String
    }

    private struct SourceNight {
        let record: NightRecord
        let filename: String
        let bookmark: String
    }

    private struct SourceCapture {
        let record: SeriesRecord
        let fitsHeader: String
    }

    private struct SourceAnnotation {
        let record: ProjectAnnotationRecord
        let databaseObject: String
    }

    private struct SourceBriefing {
        let record: NightBriefingDraft
        let imageContent: String
    }

    private let sourceProjects: [SourceProject]
    private let sourceNights: [SourceNight]
    private let sourceCaptures: [SourceCapture]
    private let sourceAnnotations: [SourceAnnotation]
    private let sourceBriefings: [SourceBriefing]

    init(
        projects: [ProjectRecord],
        nights: [NightRecord],
        captures: [SeriesRecord],
        annotations: [ProjectAnnotationRecord],
        briefings: [NightBriefingDraft]
    ) {
        sourceProjects = projects.map {
            SourceProject(record: $0, folderName: "Library Folder Name", rootURL: "file:///private/astro/cache")
        }
        sourceNights = nights.map {
            SourceNight(record: $0, filename: "frame-0001.fits", bookmark: "securityScopedBookmark")
        }
        sourceCaptures = captures.map {
            SourceCapture(record: $0, fitsHeader: "SIMPLE  =")
        }
        sourceAnnotations = annotations.map {
            SourceAnnotation(record: $0, databaseObject: "DATABASE_OBJECT")
        }
        sourceBriefings = briefings.map {
            SourceBriefing(record: $0, imageContent: "raw-image-bytes")
        }
    }

    var safeProjects: [ProjectRecord] { sourceProjects.map(\.record) }
    var safeNights: [NightRecord] { sourceNights.map(\.record) }
    var safeCaptures: [SeriesRecord] { sourceCaptures.map(\.record) }
    var safeAnnotations: [ProjectAnnotationRecord] { sourceAnnotations.map(\.record) }
    var safeBriefings: [NightBriefingDraft] { sourceBriefings.map(\.record) }

    var forbiddenStrings: [String] {
        sourceProjects.flatMap { [$0.folderName, $0.rootURL] }
            + sourceNights.flatMap { [$0.filename, $0.bookmark] }
            + sourceCaptures.map(\.fitsHeader)
            + sourceAnnotations.map(\.databaseObject)
            + sourceBriefings.map(\.imageContent)
    }
}
