import Foundation
import Testing
@testable import AstroMobileDomain

@Test func mobileChangesExposeExactlyTwoKinds() throws {
    #expect(MobileChangeKind.allCases == [.checklistCompletion, .noteRevision])
}

@Test func bothMobileChangesRoundTripWithFractionalDates() throws {
    for change in MobileChange.testValues {
        #expect(try MobileJSON.decoder.decode(MobileChange.self, from: MobileJSON.encoder.encode(change)) == change)
    }
}

private extension MobileChange {
    static let testValues: [MobileChange] = [
        .checklistCompletion(ChecklistCompletionChange(
            changeID: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            briefingID: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            itemID: "focus",
            baseRevision: 2,
            isCompleted: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.123)
        )),
        .noteRevision(NoteRevisionChange(
            changeID: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
            deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            noteID: "briefing-note",
            ownerID: "briefing-0001",
            baseRevision: 2,
            text: "Clear sky",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.123)
        ))
    ]
}
