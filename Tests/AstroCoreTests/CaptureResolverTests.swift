import Foundation
import Testing
@testable import AstroCore

private func resolverFile(
    id: Int64? = 1,
    path: String = "sessions/IC_1396/2026-08-08/lights/a.fit",
    role: FrameRole = .light
) -> FileRecord {
    FileRecord(
        id: id,
        path: path,
        size: 1,
        mtime: 1,
        ext: "fit",
        kind: "fits",
        area: path.hasPrefix("stacks/") ? .stacks : (path.hasPrefix("processed/") ? .processed : .sessions),
        target: "IC_1396",
        sessionDate: "2026-08-08",
        role: role,
        scannedAt: 1
    )
}

private func resolverGroup(
    id: Int64? = 10,
    slug: String = "sv220-nb",
    sensor: SensorMode = .osc,
    signal: SignalMode = .dualBand,
    filterName: String? = "SV220"
) -> CaptureGroupRecord {
    CaptureGroupRecord(
        id: id,
        target: "IC_1396",
        sessionDate: "2026-08-08",
        slug: slug,
        displayName: slug == "sv220-nb" ? "SV220 dual-band" : "OSC 30 s",
        sensorMode: sensor,
        signalMode: signal,
        filterManufacturer: filterName == nil ? nil : "SVBONY",
        filterModel: filterName,
        createdAt: 1,
        updatedAt: 1
    )
}

private func resolverMeta(
    filter: String? = nil,
    bayerPattern: String? = "RGGB"
) -> FITSMetaRecord {
    var cards: [String: String] = [:]
    if let bayerPattern { cards["BAYERPAT"] = bayerPattern }
    let json = try? String(data: JSONEncoder().encode(cards), encoding: .utf8)
    return FITSMetaRecord(fileID: 1, filter: filter, headerJSON: json)
}

@Test func manualOverridesWinOverGroupAndFITSMetadata() {
    let group = resolverGroup()
    let assignment = FileCaptureAssignmentRecord(
        fileID: 1,
        captureGroupID: 10,
        sensorModeOverride: .mono,
        signalModeOverride: .narrowband,
        filterManufacturerOverride: "Astronomik",
        filterModelOverride: "Ha 6nm",
        assignmentSource: "app"
    )
    let resolver = CaptureResolver(groups: [group], sources: [], assignments: [1: assignment])

    let result = resolver.resolve(file: resolverFile(), meta: resolverMeta(filter: "UV/IR Cut"))

    #expect(result.groupID == 10)
    #expect(result.sensorMode == .mono)
    #expect(result.signalMode == .narrowband)
    #expect(result.filterManufacturer == "Astronomik")
    #expect(result.filterModel == "Ha 6nm")
    #expect(result.sensorOrigin == .manualOverride)
    #expect(result.signalOrigin == .manualOverride)
    #expect(result.filterOrigin == .manualOverride)
}

@Test func captureGroupMetadataWinsOverFITSThenReportsConflict() {
    let group = resolverGroup()
    let resolver = CaptureResolver(groups: [group], sources: [], assignments: [
        1: FileCaptureAssignmentRecord(fileID: 1, captureGroupID: 10),
    ])

    let result = resolver.resolve(file: resolverFile(), meta: resolverMeta(filter: "UV/IR Cut", bayerPattern: nil))

    #expect(result.filterModel == "SV220")
    #expect(result.filterOrigin == .captureGroup)
    #expect(result.hasConflict)
    #expect(result.conflicts.contains { $0.contains("FILTER") })
}

@Test func FITSHeaderInfersOSCAndSuppliesFilterWhenGroupIsUnknown() {
    let group = resolverGroup(sensor: .unknown, signal: .unknown, filterName: nil)
    let resolver = CaptureResolver(groups: [group], sources: [], assignments: [
        1: FileCaptureAssignmentRecord(fileID: 1, captureGroupID: 10),
    ])

    let result = resolver.resolve(file: resolverFile(), meta: resolverMeta(filter: "L-eXtreme", bayerPattern: "'RGGB    '"))

    #expect(result.sensorMode == .osc)
    #expect(result.sensorOrigin == .fitsHeader)
    #expect(result.filterName == "L-eXtreme")
    #expect(result.filterOrigin == .fitsHeader)
    #expect(result.signalMode == .dualBand)
}

@Test func monoGroupRemainsMonoWhenFITSHasNoBayerEvidence() {
    let group = resolverGroup(sensor: .mono, signal: .narrowband, filterName: "H-alpha")
    let resolver = CaptureResolver(groups: [group], sources: [], assignments: [
        1: FileCaptureAssignmentRecord(fileID: 1, captureGroupID: 10),
    ])

    let result = resolver.resolve(file: resolverFile(), meta: resolverMeta(bayerPattern: nil))

    #expect(result.sensorMode == .mono)
    #expect(result.sensorOrigin == .captureGroup)
}

@Test func canonicalCapturePathResolvesStoredGroupWithoutFileAssignment() {
    let group = resolverGroup()
    let resolver = CaptureResolver(groups: [group], sources: [], assignments: [:])
    let file = resolverFile(
        path: "sessions/IC_1396/2026-08-08/captures/sv220-nb/lights/a.fit"
    )

    let result = resolver.resolve(file: file, meta: resolverMeta())

    #expect(result.groupID == 10)
    #expect(result.slug == "sv220-nb")
    #expect(result.displayName == "SV220 dual-band")
}

@Test func legacySourceMappingResolvesGroupWithoutMovingFile() {
    let group = resolverGroup(slug: "osc-30s", sensor: .osc, signal: .broadband, filterName: nil)
    let source = CaptureSourceRecord(
        id: 2,
        captureGroupID: 10,
        relativePath: "sessions/IC_1396/2026-08-08/lights_osc",
        role: .light
    )
    let resolver = CaptureResolver(groups: [group], sources: [source], assignments: [:])
    let file = resolverFile(path: "sessions/IC_1396/2026-08-08/lights_osc/a.fit")

    let result = resolver.resolve(file: file, meta: resolverMeta())

    #expect(result.groupID == 10)
    #expect(result.slug == "osc-30s")
    #expect(result.signalMode == .broadband)
}

@Test func unmappedLegacyOSCFolderIsOnlyAnInference() {
    let resolver = CaptureResolver(groups: [], sources: [], assignments: [:])
    let file = resolverFile(path: "sessions/IC_1396/2026-08-08/lights_osc/a.fit")

    let result = resolver.resolve(file: file, meta: resolverMeta(bayerPattern: nil))

    #expect(result.groupID == nil)
    #expect(result.slug == nil)
    #expect(result.displayName == "osc")
    #expect(result.sensorMode == .osc)
    #expect(result.sensorOrigin == .pathInference)
}

@Test func classicUnassignedPathStaysHonestAndUnknown() {
    let resolver = CaptureResolver(groups: [], sources: [], assignments: [:])

    let result = resolver.resolve(file: resolverFile(), meta: resolverMeta(filter: nil, bayerPattern: nil))

    #expect(result.groupID == nil)
    #expect(result.slug == nil)
    #expect(result.displayName == nil)
    #expect(result.sensorMode == .unknown)
    #expect(result.signalMode == .unknown)
    #expect(result.filterOrigin == .unknown)
}

@Test func databaseLoadedResolverBulkResolvesAssignmentsAndSources() throws {
    let database = try Database(path: ":memory:")
    let groupID = try database.upsertCaptureGroup(resolverGroup(id: nil))
    let firstID = try database.upsertFile(resolverFile(id: nil).withPath(
        "sessions/IC_1396/2026-08-08/lights/a.fit"
    ))
    let secondID = try database.upsertFile(resolverFile(id: nil).withPath(
        "sessions/IC_1396/2026-08-08/lights_osc/b.fit"
    ))
    try database.upsertFileCaptureAssignment(
        FileCaptureAssignmentRecord(fileID: firstID, captureGroupID: groupID)
    )
    _ = try database.upsertCaptureSource(
        CaptureSourceRecord(
            captureGroupID: groupID,
            relativePath: "sessions/IC_1396/2026-08-08/lights_osc",
            role: .light
        )
    )

    let resolver = try CaptureResolver.load(db: database)
    let files = try database.allFiles(includeMissing: false)
    let resolved = Dictionary(uniqueKeysWithValues: files.map { file in
        (file.id ?? 0, resolver.resolve(file: file, meta: nil))
    })

    #expect(resolved[firstID]?.groupID == groupID)
    #expect(resolved[secondID]?.groupID == groupID)
}

private extension FileRecord {
    func withPath(_ newPath: String) -> FileRecord {
        var copy = self
        copy.path = newPath
        return copy
    }
}
