import Foundation
import Testing
@testable import AstroCore

private func headerJSON(_ cards: [String: String]) -> String {
    let data = try! JSONEncoder().encode(cards)
    return String(data: data, encoding: .utf8)!
}

private func makeMemoryDB() throws -> Database {
    try Database(path: ":memory:")
}

@discardableResult
private func insertLight(
    db: Database,
    target: String,
    date: String,
    name: String,
    instrume: String? = nil,
    focallen: Double? = nil,
    xpixsz: Double? = nil,
    headerCards: [String: String] = [:],
    exptime: Double? = 60
) throws -> Int64 {
    let path = "sessions/\(target)/\(date)/lights/\(name).fit"
    let fileID = try db.upsertFile(
        FileRecord(
            path: path, size: 1024, mtime: 1_700_000_000, ext: "fit", kind: "fits",
            area: .sessions, target: target, sessionDate: date, role: .light,
            scannedAt: 1_700_000_100
        )
    )
    // Unique fake inode per row -- same reason as `NightHealthTests`/
    // `FieldGeometryTests`: without it, same-exptime/no-DATE-OBS frames in
    // one session collapse to a single canonical copy under `FrameSet`'s
    // fallback dedup key.
    try db.backfillInode(id: fileID, inode: fileID, nlink: 1)
    try db.upsertFITSMeta(
        FITSMetaRecord(
            fileID: fileID, exptime: exptime, instrume: instrume, focallen: focallen, xpixsz: xpixsz,
            headerJSON: headerCards.isEmpty ? nil : headerJSON(headerCards)
        )
    )
    return fileID
}

// MARK: - fingerprint(meta:headerJSON:)

@Test func fingerprintDescriptorMatchesExpectedFormat() {
    let meta = FITSMetaRecord(fileID: 1, instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76)
    let json = headerJSON(["BAYERPAT": "'RGGB'"])
    let fp = EquipmentProfile.fingerprint(meta: meta, headerJSON: json)
    #expect(fp?.descriptor == "ASI2600MC·302mm·3.76µm·RGGB")
}

@Test func fingerprintOmitsBinningWhenAbsentAndIncludesWhenPresent() {
    let meta = FITSMetaRecord(fileID: 1, instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76)
    let noBinning = EquipmentProfile.fingerprint(meta: meta, headerJSON: nil)
    #expect(noBinning?.descriptor == "ASI2600MC·302mm·3.76µm")

    let withBinning = EquipmentProfile.fingerprint(
        meta: meta, headerJSON: headerJSON(["XBINNING": "2", "YBINNING": "2"])
    )
    #expect(withBinning?.descriptor == "ASI2600MC·302mm·3.76µm·2x2")
}

@Test func fingerprintIncludesGuideCamWhenPresent() {
    let meta = FITSMetaRecord(fileID: 1, instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76)
    let json = headerJSON(["BAYERPAT": "'RGGB'", "GUIDECAM": "'ASI120MM'"])
    let fp = EquipmentProfile.fingerprint(meta: meta, headerJSON: json)
    #expect(fp?.descriptor == "ASI2600MC·302mm·3.76µm·RGGB·ASI120MM")
}

@Test func fingerprintReturnsNilWhenNoIdentifyingDataAtAll() {
    let meta = FITSMetaRecord(fileID: 1)
    let fp = EquipmentProfile.fingerprint(meta: meta, headerJSON: headerJSON(["BAYERPAT": "'RGGB'"]))
    #expect(fp == nil)
}

@Test func fingerprintRoundsFocalLengthAndPixelSize() {
    let meta = FITSMetaRecord(fileID: 1, instrume: "Cam", focallen: 301.6, xpixsz: 3.759)
    let fp = EquipmentProfile.fingerprint(meta: meta, headerJSON: nil)
    #expect(fp?.focalLengthMM == 302)
    #expect(fp?.pixelSizeUM == 3.76)
}

// MARK: - sessionFingerprints / dominant

@Test func sessionFingerprintsCountsDistinctSetupsAmongUsableLights() throws {
    let db = try makeMemoryDB()
    for i in 0..<3 {
        try insertLight(db: db, target: "T1", date: "2026-06-01", name: "a\(i)", instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76)
    }
    for i in 0..<2 {
        try insertLight(db: db, target: "T1", date: "2026-06-01", name: "b\(i)", instrume: "ASI2600MC", focallen: 480, xpixsz: 3.76)
    }

    let counts = try EquipmentProfile.sessionFingerprints(target: "T1", date: "2026-06-01", db: db, config: AstroConfig())
    #expect(counts.count == 2)
    #expect(counts.values.sorted() == [2, 3])
}

@Test func dominantPicksTheMostFrequentFingerprint() throws {
    let db = try makeMemoryDB()
    for i in 0..<5 {
        try insertLight(db: db, target: "T2", date: "2026-06-02", name: "a\(i)", instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76)
    }
    try insertLight(db: db, target: "T2", date: "2026-06-02", name: "b0", instrume: "ASI2600MC", focallen: 480, xpixsz: 3.76)

    let counts = try EquipmentProfile.sessionFingerprints(target: "T2", date: "2026-06-02", db: db, config: AstroConfig())
    let dominant = try #require(EquipmentProfile.dominant(counts))
    #expect(dominant.descriptor.contains("302mm"))
}

// MARK: - SessionDetail.setupDescriptor

@Test func sessionDetailCarriesDominantSetupDescriptor() throws {
    let db = try makeMemoryDB()
    for i in 0..<4 {
        try insertLight(db: db, target: "T3", date: "2026-06-03", name: "l\(i)", instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76)
    }

    let sessions = try SessionStatsQueries.sessions(target: "T3", db: db, config: AstroConfig())
    let session = try #require(sessions.first)
    #expect(session.setupDescriptor == "ASI2600MC·302mm·3.76µm")
}

@Test func sessionDetailSetupDescriptorNilWhenNoUsableLightHasFingerprint() throws {
    let db = try makeMemoryDB()
    try insertLight(db: db, target: "T4", date: "2026-06-04", name: "l0")

    let sessions = try SessionStatsQueries.sessions(target: "T4", db: db, config: AstroConfig())
    let session = try #require(sessions.first)
    #expect(session.setupDescriptor == nil)
}

// MARK: - JSON round-trip

@Test func setupFingerprintJSONRoundTrips() throws {
    let fp = SetupFingerprint(
        camera: "ASI2600MC", focalLengthMM: 302, pixelSizeUM: 3.76,
        bayerPattern: "RGGB", guideCam: nil, descriptor: "ASI2600MC·302mm·3.76µm·RGGB"
    )
    let data = try JSONEncoder().encode(fp)
    let decoded = try JSONDecoder().decode(SetupFingerprint.self, from: data)
    #expect(decoded == fp)
}

// MARK: - Audit rules

private func makeAuditContext(files: [FileRecord], meta: [Int64: FITSMetaRecord], config: AstroConfig = AstroConfig()) -> AuditContext {
    AuditContext(config: config, files: files, directories: [], fitsMetaByFileID: meta)
}

private func lightFile(id: Int64, target: String, date: String, name: String) -> FileRecord {
    FileRecord(
        id: id, path: "sessions/\(target)/\(date)/lights/\(name).fit", size: 1024, mtime: 0,
        ext: "fit", kind: "fits", area: .sessions, target: target, sessionDate: date, role: .light,
        scannedAt: 0, inode: id, nlink: 1
    )
}

@Test func mixedSetupInSessionRuleFiresWhenSessionHasTwoDistinctFingerprints() throws {
    var files: [FileRecord] = []
    var meta: [Int64: FITSMetaRecord] = [:]
    for i in 1...3 {
        let id = Int64(i)
        files.append(lightFile(id: id, target: "T1", date: "2026-07-01", name: "l\(i)"))
        meta[id] = FITSMetaRecord(fileID: id, instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76)
    }
    for i in 4...5 {
        let id = Int64(i)
        files.append(lightFile(id: id, target: "T1", date: "2026-07-01", name: "l\(i)"))
        meta[id] = FITSMetaRecord(fileID: id, instrume: "ASI2600MC", focallen: 480, xpixsz: 3.76)
    }

    let ctx = makeAuditContext(files: files, meta: meta)
    let findings = MixedSetupInSessionRule().evaluate(ctx)

    #expect(findings.count == 1)
    let finding = try #require(findings.first)
    #expect(finding.category == "mixed-setup-in-session")
    #expect(finding.severity == .suspicious)
    #expect(finding.path == "sessions/T1/2026-07-01")
}

@Test func mixedSetupInSessionRuleStaysSilentWhenSessionIsUniform() {
    var files: [FileRecord] = []
    var meta: [Int64: FITSMetaRecord] = [:]
    for i in 1...5 {
        let id = Int64(i)
        files.append(lightFile(id: id, target: "T2", date: "2026-07-02", name: "l\(i)"))
        meta[id] = FITSMetaRecord(fileID: id, instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76)
    }

    let ctx = makeAuditContext(files: files, meta: meta)
    let findings = MixedSetupInSessionRule().evaluate(ctx)
    #expect(findings.isEmpty)
}

@Test func mixedSetupInSessionRuleIgnoresFramesWithNoDerivableFingerprint() {
    var files: [FileRecord] = []
    var meta: [Int64: FITSMetaRecord] = [:]
    for i in 1...3 {
        let id = Int64(i)
        files.append(lightFile(id: id, target: "T3", date: "2026-07-03", name: "l\(i)"))
        meta[id] = FITSMetaRecord(fileID: id, instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76)
    }
    // A bare frame with no camera/focal length/pixel size at all.
    files.append(lightFile(id: 10, target: "T3", date: "2026-07-03", name: "bare"))
    meta[10] = FITSMetaRecord(fileID: 10)

    let ctx = makeAuditContext(files: files, meta: meta)
    let findings = MixedSetupInSessionRule().evaluate(ctx)
    #expect(findings.isEmpty)
}

@Test func mixedSetupInTargetRuleFiresWhenDominantFingerprintDiffersAcrossSessions() throws {
    var files: [FileRecord] = []
    var meta: [Int64: FITSMetaRecord] = [:]
    var id: Int64 = 1
    for _ in 0..<5 {
        files.append(lightFile(id: id, target: "T5", date: "2026-07-05", name: "a\(id)"))
        meta[id] = FITSMetaRecord(fileID: id, instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76)
        id += 1
    }
    for _ in 0..<5 {
        files.append(lightFile(id: id, target: "T5", date: "2026-07-06", name: "b\(id)"))
        meta[id] = FITSMetaRecord(fileID: id, instrume: "ASI2600MC", focallen: 480, xpixsz: 3.76)
        id += 1
    }

    let ctx = makeAuditContext(files: files, meta: meta)
    let findings = MixedSetupInTargetRule().evaluate(ctx)

    #expect(findings.count == 1)
    let finding = try #require(findings.first)
    #expect(finding.category == "mixed-setup-in-target")
    #expect(finding.severity == .probablyIntentional)
    #expect(finding.path == "sessions/T5")
}

@Test func mixedSetupInTargetRuleStaysSilentWhenSameSetupAcrossSessions() {
    var files: [FileRecord] = []
    var meta: [Int64: FITSMetaRecord] = [:]
    var id: Int64 = 1
    for date in ["2026-07-07", "2026-07-08"] {
        for _ in 0..<3 {
            files.append(lightFile(id: id, target: "T6", date: date, name: "l\(id)"))
            meta[id] = FITSMetaRecord(fileID: id, instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76)
            id += 1
        }
    }

    let ctx = makeAuditContext(files: files, meta: meta)
    let findings = MixedSetupInTargetRule().evaluate(ctx)
    #expect(findings.isEmpty)
}
