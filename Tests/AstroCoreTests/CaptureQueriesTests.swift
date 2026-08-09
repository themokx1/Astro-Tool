import Foundation
import Testing
@testable import AstroCore

private let summaryTarget = "IC_1396"
private let summaryDate = "2026-08-08"

private func summaryGroup(
    slug: String,
    name: String,
    sensor: SensorMode = .osc,
    signal: SignalMode,
    manufacturer: String? = nil,
    model: String? = nil
) -> CaptureGroupRecord {
    CaptureGroupRecord(
        target: summaryTarget,
        sessionDate: summaryDate,
        slug: slug,
        displayName: name,
        sensorMode: sensor,
        signalMode: signal,
        filterManufacturer: manufacturer,
        filterModel: model,
        createdAt: 1,
        updatedAt: 1
    )
}

@discardableResult
private func addSummaryFile(
    _ path: String,
    db: Database,
    inode: Int64,
    exptime: Double? = nil,
    camera: String? = nil,
    filter: String? = nil,
    headerJSON: String? = nil
) throws -> Int64 {
    let info = PathClassifier.classify(relativePath: path)
    let fileID = try db.upsertFile(
        FileRecord(
            path: path,
            size: 1_024,
            mtime: 1,
            ext: (path as NSString).pathExtension.lowercased(),
            kind: path.lowercased().hasSuffix(".fit") ? "fits" : "image",
            area: info.area,
            target: info.target,
            sessionDate: info.dateRaw,
            role: info.role,
            scannedAt: 1,
            inode: inode,
            nlink: 1
        )
    )
    if exptime != nil || camera != nil || filter != nil || headerJSON != nil {
        try db.upsertFITSMeta(
            FITSMetaRecord(
                fileID: fileID,
                exptime: exptime,
                instrume: camera,
                filter: filter,
                headerJSON: headerJSON
            )
        )
    }
    return fileID
}

private func populatedCaptureSummaryDatabase() throws -> Database {
    let db = try Database(path: ":memory:")
    _ = try db.upsertCaptureGroup(
        summaryGroup(slug: "osc-30s", name: "OSC 30 s", signal: .broadband)
    )
    _ = try db.upsertCaptureGroup(
        summaryGroup(
            slug: "sv220-nb",
            name: "SV220 dual-band",
            signal: .dualBand,
            manufacturer: "SVBONY",
            model: "SV220"
        )
    )

    let bayerJSON = "{\"BAYERPAT\":\"RGGB\"}"
    try addSummaryFile(
        "sessions/\(summaryTarget)/\(summaryDate)/captures/osc-30s/lights/osc1.fit",
        db: db, inode: 1, exptime: 30, camera: "ZWO ASI2600MC Pro", headerJSON: bayerJSON
    )
    try addSummaryFile(
        "sessions/\(summaryTarget)/\(summaryDate)/captures/osc-30s/lights/osc2.fit",
        db: db, inode: 2, exptime: 30, camera: "ZWO ASI2600MC Pro", headerJSON: bayerJSON
    )
    try addSummaryFile(
        "sessions/\(summaryTarget)/\(summaryDate)/captures/osc-30s/lights/Stacked2_IC1396.fit",
        db: db, inode: 3, exptime: 30, camera: "ZWO ASI2600MC Pro", headerJSON: bayerJSON
    )
    try addSummaryFile(
        "sessions/\(summaryTarget)/\(summaryDate)/captures/osc-30s/flats/flat1.fit",
        db: db, inode: 4
    )
    try addSummaryFile(
        "processed/\(summaryTarget)/\(summaryDate)/osc-30s/result.tif",
        db: db, inode: 5
    )

    try addSummaryFile(
        "sessions/\(summaryTarget)/\(summaryDate)/captures/sv220-nb/lights/nb1.fit",
        db: db, inode: 6, exptime: 300, camera: "ZWO ASI2600MC Pro", headerJSON: bayerJSON
    )
    try addSummaryFile(
        "sessions/\(summaryTarget)/\(summaryDate)/captures/sv220-nb/lights/nb2.fit",
        db: db, inode: 7, exptime: 300, camera: "ZWO ASI2600MC Pro", headerJSON: bayerJSON
    )
    try addSummaryFile(
        "sessions/\(summaryTarget)/\(summaryDate)/captures/sv220-nb/darks/dark1.fit",
        db: db, inode: 8
    )

    try addSummaryFile(
        "sessions/\(summaryTarget)/\(summaryDate)/lights/unassigned.fit",
        db: db, inode: 9, exptime: 120, camera: "ZWO ASI2600MC Pro", headerJSON: bayerJSON
    )
    try addSummaryFile(
        "sessions/\(summaryTarget)/\(summaryDate)/flats/unassigned-flat.fit",
        db: db, inode: 10
    )
    return db
}

@Test func captureSummariesKeepExplicitGroupsAndUnassignedBucketSeparate() throws {
    let db = try populatedCaptureSummaryDatabase()
    let summaries = try CaptureQueries.summaries(
        target: summaryTarget,
        date: summaryDate,
        db: db,
        config: AstroConfig()
    )

    #expect(summaries.map(\.displayName) == ["OSC 30 s", "SV220 dual-band", "Nincs gyűjtéshez rendelve"])

    let osc = summaries[0]
    #expect(osc.slug == "osc-30s")
    #expect(osc.rawLightCount == 3)
    #expect(osc.usableLightCount == 2)
    #expect(osc.integrationSeconds == 60)
    #expect(osc.exposureBreakdown == ["30.0": 2])
    #expect(osc.flatCount == 1)
    #expect(osc.artifactCount == 2) // Stacked2_ derivative + processed result
    #expect(osc.processedCount == 1)
    #expect(osc.cameras == ["ZWO ASI2600MC Pro"])

    let nb = summaries[1]
    #expect(nb.sensorModes == [.osc])
    #expect(nb.signalModes == [.dualBand])
    #expect(nb.filters == ["SVBONY SV220"])
    #expect(nb.usableLightCount == 2)
    #expect(nb.integrationSeconds == 600)
    #expect(nb.darkCount == 1)

    let unassigned = summaries[2]
    #expect(unassigned.isImplicit)
    #expect(unassigned.groupID == nil)
    #expect(unassigned.usableLightCount == 1)
    #expect(unassigned.integrationSeconds == 120)
    #expect(unassigned.flatCount == 1)
}

@Test func captureSummaryTotalsEqualSessionUsableTotalsAndExcludeDerivatives() throws {
    let db = try populatedCaptureSummaryDatabase()
    let config = AstroConfig()
    let summaries = try CaptureQueries.summaries(
        target: summaryTarget,
        date: summaryDate,
        db: db,
        config: config
    )
    let session = try #require(
        try SessionStatsQueries.sessions(target: summaryTarget, db: db, config: config).first
    )

    #expect(summaries.map(\.usableLightCount).reduce(0, +) == 5)
    #expect(summaries.map(\.integrationSeconds).reduce(0, +) == 780)
    #expect(session.usableLightCount == 5)
    #expect(session.integrationSeconds == 780)
    #expect(session.captureGroups == summaries)
}

@Test func classicSessionKeepsAggregateNumbersAndGetsOneHonestImplicitSummary() throws {
    let db = try Database(path: ":memory:")
    try addSummaryFile(
        "sessions/M31/2026-01-01/lights/a.fit",
        db: db, inode: 20, exptime: 60, camera: "Canon EOS R8"
    )
    try addSummaryFile(
        "sessions/M31/2026-01-01/lights/b.fit",
        db: db, inode: 21, exptime: 60, camera: "Canon EOS R8"
    )

    let config = AstroConfig()
    let summaries = try CaptureQueries.summaries(target: "M31", date: "2026-01-01", db: db, config: config)
    let session = try #require(try SessionStatsQueries.sessions(target: "M31", db: db, config: config).first)

    #expect(summaries.count == 1)
    #expect(summaries[0].isImplicit)
    #expect(summaries[0].usableLightCount == 2)
    #expect(session.lightCount == 2)
    #expect(session.usableLightCount == 2)
    #expect(session.integrationSeconds == 120)
    #expect(session.exposureBreakdown == ["60.0": 2])
}

@Test func olderSessionDetailJSONDecodesWithoutCaptureGroups() throws {
    let original = SessionDetail(
        target: "M31",
        dateRaw: "2026-01-01",
        lightCount: 2,
        flatCount: 0,
        darkCount: 0,
        biasCount: 0,
        integrationSeconds: 120,
        exposureBreakdown: ["60.0": 2],
        cameras: [],
        focalLengthsMM: [],
        gains: [],
        sensorTempsC: [],
        filters: [],
        hasReadme: false
    )
    let data = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "captureGroups")

    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(SessionDetail.self, from: legacyData)
    #expect(decoded.captureGroups == [])
}

@Test func readmeAndOtherSessionFilesDoNotCreateAFakeUnassignedCapture() throws {
    let db = try Database(path: ":memory:")
    _ = try db.upsertCaptureGroup(
        summaryGroup(slug: "osc-30s", name: "OSC 30 s", signal: .broadband)
    )
    try addSummaryFile(
        "sessions/\(summaryTarget)/\(summaryDate)/captures/osc-30s/lights/a.fit",
        db: db, inode: 30, exptime: 30
    )
    _ = try db.upsertFile(
        FileRecord(
            path: "sessions/\(summaryTarget)/\(summaryDate)/README.txt",
            size: 10,
            mtime: 1,
            ext: "txt",
            kind: "text",
            area: .sessions,
            target: summaryTarget,
            sessionDate: summaryDate,
            role: .other,
            scannedAt: 1,
            inode: 31,
            nlink: 1
        )
    )

    let summaries = try CaptureQueries.summaries(
        target: summaryTarget,
        date: summaryDate,
        db: db,
        config: AstroConfig()
    )
    #expect(summaries.map(\.displayName) == ["OSC 30 s"])
}
