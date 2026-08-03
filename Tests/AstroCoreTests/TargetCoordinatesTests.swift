import Foundation
import Testing
@testable import AstroCore

private func headerJSON(_ cards: [String: String]) -> String {
    let data = try! JSONEncoder().encode(cards)
    return String(data: data, encoding: .utf8)!
}

// MARK: - parseSexagesimal

@Test func parseSexagesimalAcceptsSpaceSeparated() {
    let value = TargetCoordinates.parseSexagesimal("12 34 56")
    #expect(abs((value ?? -1) - (12 + 34.0 / 60 + 56.0 / 3600)) < 1e-9)
}

@Test func parseSexagesimalAcceptsColonSeparated() {
    let value = TargetCoordinates.parseSexagesimal("12:34:56")
    #expect(abs((value ?? -1) - (12 + 34.0 / 60 + 56.0 / 3600)) < 1e-9)
}

@Test func parseSexagesimalHandlesNegativeSign() {
    let value = TargetCoordinates.parseSexagesimal("-45 30 10")
    #expect(abs((value ?? 1) - -(45 + 30.0 / 60 + 10.0 / 3600)) < 1e-9)
}

@Test func parseSexagesimalReturnsNilForGarbage() {
    #expect(TargetCoordinates.parseSexagesimal("not a coordinate") == nil)
    #expect(TargetCoordinates.parseSexagesimal("12 34") == nil)
}

// MARK: - coordinates(headerJSON:)

@Test func coordinatesPrefersWCSCRVALWhenPresent() throws {
    let json = headerJSON(["CRVAL1": "83.633083", "CRVAL2": "22.0145", "RA": "'05 34 30'", "DEC": "'22 00 52'"])
    let coord = try #require(TargetCoordinates.coordinates(headerJSON: json))
    #expect(abs(coord.raDeg - 83.633083) < 1e-6)
    #expect(abs(coord.decDeg - 22.0145) < 1e-6)
}

@Test func coordinatesFallsBackToNumericRADECAsDegreesNoConversion() throws {
    let json = headerJSON(["RA": "83.633083", "DEC": "22.0145"])
    let coord = try #require(TargetCoordinates.coordinates(headerJSON: json))
    #expect(abs(coord.raDeg - 83.633083) < 1e-6)
    #expect(abs(coord.decDeg - 22.0145) < 1e-6)
}

@Test func coordinatesFallsBackToSexagesimalRAConvertedHoursToDegrees() throws {
    // RA 05h34m30s = 83.625 deg exactly (05:34:30 -> 5.575h * 15).
    let json = headerJSON(["RA": "'05 34 30'", "DEC": "'22 00 52'"])
    let coord = try #require(TargetCoordinates.coordinates(headerJSON: json))
    let expectedRA = (5 + 34.0 / 60 + 30.0 / 3600) * 15
    let expectedDec = 22 + 0.0 / 60 + 52.0 / 3600
    #expect(abs(coord.raDeg - expectedRA) < 1e-6)
    #expect(abs(coord.decDeg - expectedDec) < 1e-6)
}

@Test func coordinatesReturnsNilWhenNoUsableKeysPresent() {
    let json = headerJSON(["EXPTIME": "300.0"])
    #expect(TargetCoordinates.coordinates(headerJSON: json) == nil)
}

@Test func coordinatesReturnsNilForMissingHeaderJSON() {
    #expect(TargetCoordinates.coordinates(headerJSON: nil) == nil)
}

// MARK: - medianCoordinates

@Test func medianCoordinatesIgnoresFilesWithoutResolvableHeader() throws {
    let files = [
        FileRecord(id: 1, path: "a", size: 0, mtime: 0, ext: "fit", kind: "fits", area: .sessions, target: "T1", sessionDate: "2026-01-01", role: .light, scannedAt: 0),
        FileRecord(id: 2, path: "b", size: 0, mtime: 0, ext: "fit", kind: "fits", area: .sessions, target: "T1", sessionDate: "2026-01-01", role: .light, scannedAt: 0),
        FileRecord(id: 3, path: "c", size: 0, mtime: 0, ext: "fit", kind: "fits", area: .sessions, target: "T1", sessionDate: "2026-01-01", role: .light, scannedAt: 0),
    ]
    let meta: [Int64: FITSMetaRecord] = [
        1: FITSMetaRecord(fileID: 1, headerJSON: headerJSON(["CRVAL1": "10.0", "CRVAL2": "20.0"])),
        2: FITSMetaRecord(fileID: 2, headerJSON: headerJSON(["CRVAL1": "12.0", "CRVAL2": "22.0"])),
        3: FITSMetaRecord(fileID: 3, headerJSON: nil),
    ]
    let coord = try #require(TargetCoordinates.medianCoordinates(files: files, meta: meta))
    #expect(abs(coord.raDeg - 11.0) < 1e-9)
    #expect(abs(coord.decDeg - 21.0) < 1e-9)
}

@Test func medianCoordinatesReturnsNilWhenNoFileResolves() {
    let files = [FileRecord(id: 1, path: "a", size: 0, mtime: 0, ext: "fit", kind: "fits", area: .sessions, target: "T1", sessionDate: "2026-01-01", role: .light, scannedAt: 0)]
    let meta: [Int64: FITSMetaRecord] = [1: FITSMetaRecord(fileID: 1, headerJSON: nil)]
    #expect(TargetCoordinates.medianCoordinates(files: files, meta: meta) == nil)
}

// MARK: - site resolution

@Test func medianSiteDerivesFromSITELATSITELONGAcrossFiles() {
    let files = [
        FileRecord(id: 1, path: "a", size: 0, mtime: 0, ext: "fit", kind: "fits", area: .sessions, target: "T1", sessionDate: "2026-01-01", role: .light, scannedAt: 0),
        FileRecord(id: 2, path: "b", size: 0, mtime: 0, ext: "fit", kind: "fits", area: .sessions, target: "T1", sessionDate: "2026-01-01", role: .light, scannedAt: 0),
    ]
    let meta: [Int64: FITSMetaRecord] = [
        1: FITSMetaRecord(fileID: 1, headerJSON: headerJSON(["SITELAT": "47.4", "SITELONG": "19.0"])),
        2: FITSMetaRecord(fileID: 2, headerJSON: headerJSON(["SITELAT": "47.6", "SITELONG": "19.2"])),
    ]
    let site = TargetCoordinates.medianSite(files: files, meta: meta)
    #expect(abs((site.latitudeDeg ?? 0) - 47.5) < 1e-9)
    #expect(abs((site.longitudeDeg ?? 0) - 19.1) < 1e-9)
}

@Test func resolveSitePrefersExplicitConfigOverDerivedMedian() {
    let files = [FileRecord(id: 1, path: "a", size: 0, mtime: 0, ext: "fit", kind: "fits", area: .sessions, target: "T1", sessionDate: "2026-01-01", role: .light, scannedAt: 0)]
    let meta: [Int64: FITSMetaRecord] = [1: FITSMetaRecord(fileID: 1, headerJSON: headerJSON(["SITELAT": "10.0", "SITELONG": "20.0"]))]
    let configured = SiteRule(latitudeDeg: 47.5, longitudeDeg: 19.0)
    let resolved = TargetCoordinates.resolveSite(files: files, meta: meta, config: configured)
    #expect(resolved == configured)
}

@Test func resolveSiteFillsInOnlyMissingComponent() {
    let files = [FileRecord(id: 1, path: "a", size: 0, mtime: 0, ext: "fit", kind: "fits", area: .sessions, target: "T1", sessionDate: "2026-01-01", role: .light, scannedAt: 0)]
    let meta: [Int64: FITSMetaRecord] = [1: FITSMetaRecord(fileID: 1, headerJSON: headerJSON(["SITELAT": "10.0", "SITELONG": "20.0"]))]
    let partial = SiteRule(latitudeDeg: 47.5, longitudeDeg: nil)
    let resolved = TargetCoordinates.resolveSite(files: files, meta: meta, config: partial)
    #expect(resolved.latitudeDeg == 47.5)
    #expect(resolved.longitudeDeg == 20.0)
}
