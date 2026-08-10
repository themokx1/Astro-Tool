import Foundation
import Testing
@testable import AstroCore

private func filterProfile(
    id: Int64? = nil,
    manufacturer: String? = "SVBONY",
    model: String? = "SV220",
    name: String? = nil,
    signalMode: SignalMode = .dualBand,
    notes: String? = "Hα + OIII"
) -> FilterProfileRecord {
    FilterProfileRecord(
        id: id,
        manufacturer: manufacturer,
        model: model,
        name: name,
        signalMode: signalMode,
        notes: notes,
        createdAt: 100,
        updatedAt: 200
    )
}
@Test func filterProfileCanonicalLabelAndIdentityAreStable() throws {
    let record = filterProfile(manufacturer: "  SVBONY ", model: "SV-220", name: "Hα + OIII")

    #expect(record.displayLabel == "SVBONY SV-220 Hα + OIII")
    #expect(record.identityKey == "svbonysv220haoiii")
    try FilterProfileValidator.validate(record)
}

@Test func filterProfileRejectsCompletelyEmptyIdentity() {
    let record = filterProfile(manufacturer: nil, model: "  ", name: nil)
    #expect(throws: AstroError.self) {
        try FilterProfileValidator.validate(record)
    }
}

@Test func filterProfileUpsertRoundTripsAndKeepsStableID() throws {
    let database = try Database(path: ":memory:")
    let id = try database.upsertFilterProfile(filterProfile())

    var updated = try #require(try database.filterProfile(id: id))
    updated.notes = "7 nm dual-band"
    updated.updatedAt = 300
    let updatedID = try database.upsertFilterProfile(updated)
    let fetched = try #require(try database.filterProfile(id: id))

    #expect(updatedID == id)
    #expect(fetched.displayLabel == "SVBONY SV220")
    #expect(fetched.notes == "7 nm dual-band")
    #expect(fetched.createdAt == 100)
    #expect(fetched.updatedAt == 300)
}

@Test func filterProfileIdentityUpsertIsIdempotent() throws {
    let database = try Database(path: ":memory:")
    let firstID = try database.upsertFilterProfile(filterProfile(manufacturer: "SVBONY", model: "SV-220"))
    let secondID = try database.upsertFilterProfile(filterProfile(manufacturer: "svbony", model: "sv 220"))

    #expect(firstID == secondID)
    #expect(try database.allFilterProfiles().count == 1)
}

@Test func filterProfilesSortByDisplayLabelAndDeleteWithoutCaptureSideEffects() throws {
    let database = try Database(path: ":memory:")
    let sv220ID = try database.upsertFilterProfile(filterProfile())
    _ = try database.upsertFilterProfile(filterProfile(manufacturer: "Optolong", model: "L-Ultimate"))
    _ = try database.upsertCaptureGroup(
        CaptureGroupRecord(
            target: "IC_1396",
            sessionDate: "2026-08-08",
            slug: "sv220",
            displayName: "SV220 300 s",
            sensorMode: .osc,
            signalMode: .dualBand,
            filterManufacturer: "SVBONY",
            filterModel: "SV220",
            createdAt: 1,
            updatedAt: 1
        )
    )

    #expect(try database.allFilterProfiles().map(\.displayLabel) == ["Optolong L-Ultimate", "SVBONY SV220"])
    try database.deleteFilterProfile(id: sv220ID)

    #expect(try database.allFilterProfiles().map(\.displayLabel) == ["Optolong L-Ultimate"])
    #expect(try database.captureGroups(target: "IC_1396", date: "2026-08-08").first?.filterLabel == "SVBONY SV220")
}

@Test func discoveredFilterProfilesFindCaptureAndFITSValuesButExcludeSavedOnes() throws {
    let database = try Database(path: ":memory:")
    _ = try database.upsertCaptureGroup(
        CaptureGroupRecord(
            target: "IC_1396",
            sessionDate: "2026-08-08",
            slug: "sv220",
            displayName: "SV220 300 s",
            sensorMode: .osc,
            signalMode: .dualBand,
            filterModel: "SV220",
            createdAt: 1,
            updatedAt: 1
        )
    )
    let fileID = try database.upsertFile(
        FileRecord(
            path: "sessions/T1/2026-01-01/lights/ha.fit",
            size: 1,
            mtime: 1,
            ext: "fit",
            kind: "fits",
            area: .sessions,
            target: "T1",
            sessionDate: "2026-01-01",
            role: .light,
            scannedAt: 1
        )
    )
    try database.upsertFITSMeta(FITSMetaRecord(fileID: fileID, filter: "Ha"))
    _ = try database.upsertFilterProfile(filterProfile(manufacturer: nil, model: nil, name: "Ha", signalMode: .narrowband))

    let candidates = try database.discoveredFilterProfiles()

    #expect(candidates.map(\.displayLabel) == ["SV220"])
    #expect(candidates.first?.signalMode == .dualBand)
}
