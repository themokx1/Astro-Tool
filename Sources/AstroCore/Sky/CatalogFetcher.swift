import Foundation

/// One externally sourced deep-sky catalog `CatalogFetcher` knows how to
/// query and parse. Every identifier here was verified live against the
/// actual service on 2026-08-15 (see `docs/DATA-SOURCES.md` for the
/// request shape and a sample response per source) -- never add a case
/// without confirming its identifier against the live service the same way.
///
/// Five of the six sources are VizieR's classic ASU-TSV interface
/// (`https://vizier.cds.unistra.fr/viz-bin/asu-tsv`), which uniformly
/// exposes `_RAJ2000`/`_DEJ2000` (VizieR-computed J2000 decimal degrees)
/// regardless of a catalog's original epoch/format -- so every VizieR
/// source below requests those two columns instead of parsing each
/// catalog's own native RA/Dec representation. Abell's planetary nebulae
/// have no dedicated VizieR machine-readable table; SIMBAD itself carries
/// them under the `"PN A66 <n>"` identifier (Abell 1966's own numbering),
/// so that one source queries SIMBAD's TAP service instead.
public enum CatalogSource: String, Sendable, CaseIterable, Codable {
    case ngcIC
    case sharpless
    case lyndsBrightNebulae
    case vanDenBergh
    case barnard
    case abellPlanetaryNebulae

    /// Human label for progress text and attribution surfaces.
    public var displayName: String {
        switch self {
        case .ngcIC: "NGC/IC (Sinnott, NGC 2000.0)"
        case .sharpless: "Sharpless (Sh2)"
        case .lyndsBrightNebulae: "Lynds Bright Nebulae (LBN)"
        case .vanDenBergh: "van den Bergh (vdB)"
        case .barnard: "Barnard dark nebulae"
        case .abellPlanetaryNebulae: "Abell planetary nebulae"
        }
    }

    /// The exact VizieR table name (or SIMBAD identifier pattern) this
    /// source queries. See `docs/DATA-SOURCES.md` for the verification
    /// date and a recorded sample request/response for each.
    public var catalogueIdentifier: String {
        switch self {
        case .ngcIC: "VII/118/ngc2000"
        case .sharpless: "VII/20/catalog"
        case .lyndsBrightNebulae: "VII/9/catalog"
        case .vanDenBergh: "VII/21/catalog"
        case .barnard: "VII/220A/barnard"
        case .abellPlanetaryNebulae: "SIMBAD ident LIKE 'PN A66 %'"
        }
    }
}

public enum CatalogFetchError: Error, Equatable, Sendable {
    case invalidRequestURL(CatalogSource)
    case invalidResponse(CatalogSource)
    case transport(String)
}

/// Fetches a URL's raw bytes. Injected everywhere `CatalogFetcher` is used
/// so tests can drive the parser from fixed fixture data with ZERO network
/// access -- `CatalogFetcherTests` supplies a closure that returns recorded
/// VizieR/SIMBAD response text, never `URLSession`.
public typealias CatalogTransport = @Sendable (URL) async throws -> Data

/// Downloads and parses the extended target catalog. Deliberately never
/// called from the planning render path: it exists only for the explicit,
/// opt-in "Update Catalog" action, run through `OperationHost` with
/// progress and cancellation (see `ExtendedCatalogUpdateStore` in
/// `Sources/AstroUI/Settings/V2SettingsView.swift`). Its result is meant to
/// be persisted once via `CatalogCache` and merged on top of
/// `TargetCatalog.all` with `TargetCatalog.merged(builtIn:cached:)` --
/// everything after that first fetch works offline.
public struct CatalogFetcher: Sendable {
    public let transport: CatalogTransport

    public init(transport: @escaping CatalogTransport = CatalogFetcher.urlSessionTransport) {
        self.transport = transport
    }

    public static let urlSessionTransport: CatalogTransport = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CatalogFetchError.transport("HTTP error fetching \(url.absoluteString)")
        }
        return data
    }

    /// Fetches and parses every known source, merging duplicate
    /// designations across sources (first source in `CatalogSource.allCases`
    /// order wins -- an arbitrary but deterministic tie-break; the caller-
    /// facing rule that actually matters, "the built-in entry always wins",
    /// lives in `TargetCatalog.merged`, applied after this returns).
    public func fetchAll(isCancelled: @Sendable () -> Bool = { false }) async throws -> [CatalogTarget] {
        var seen = Set<String>()
        var merged: [CatalogTarget] = []
        for source in CatalogSource.allCases {
            if isCancelled() { throw CancellationError() }
            let targets = try await fetch(source)
            for target in targets where !seen.contains(target.designation) {
                seen.insert(target.designation)
                merged.append(target)
            }
        }
        return merged
    }

    public func fetch(_ source: CatalogSource) async throws -> [CatalogTarget] {
        guard let url = Self.requestURL(for: source) else { throw CatalogFetchError.invalidRequestURL(source) }
        let data = try await transport(url)
        switch source {
        case .abellPlanetaryNebulae:
            return try Self.parseAbellPlanetaryNebulae(json: data)
        default:
            guard let text = String(data: data, encoding: .utf8) else {
                throw CatalogFetchError.invalidResponse(source)
            }
            return try Self.parseVizieRTSV(source: source, text: text)
        }
    }

    // MARK: - Request URLs

    static func requestURL(for source: CatalogSource) -> URL? {
        switch source {
        case .abellPlanetaryNebulae:
            var components = URLComponents(string: "https://simbad.cds.unistra.fr/simbad/sim-tap/sync")
            components?.queryItems = [
                URLQueryItem(name: "request", value: "doQuery"),
                URLQueryItem(name: "lang", value: "adql"),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(
                    name: "query",
                    value: "SELECT id.id, b.ra, b.dec FROM ident id JOIN basic b ON id.oidref = b.oid WHERE id.id LIKE 'PN A66 %'"
                ),
            ]
            return components?.url
        default:
            var components = URLComponents(string: "https://vizier.cds.unistra.fr/viz-bin/asu-tsv")
            components?.queryItems = [
                URLQueryItem(name: "-source", value: source.catalogueIdentifier),
                URLQueryItem(name: "-out", value: outColumns(for: source)),
                URLQueryItem(name: "-out.max", value: "999999"),
            ]
            return components?.url
        }
    }

    private static func outColumns(for source: CatalogSource) -> String {
        switch source {
        case .ngcIC: "Name,_RAJ2000,_DEJ2000,Type,size,mag"
        case .sharpless: "Sh2,_RAJ2000,_DEJ2000,Diam"
        case .lyndsBrightNebulae: "Seq,_RAJ2000,_DEJ2000,Diam1"
        case .vanDenBergh: "VdB,_RAJ2000,_DEJ2000,Type,BRadMax,Vmag"
        case .barnard: "Barn,_RAJ2000,_DEJ2000,Diam"
        case .abellPlanetaryNebulae: ""
        }
    }

    // MARK: - VizieR ASU-TSV parsing

    /// VizieR's `asu-tsv` interface always shapes a table the same way:
    /// comment lines (`#...`), then a header row (column names), a units
    /// row, a row of dashes marking the start of data, the data rows
    /// themselves, then EOF or another comment/blank line. This parses that
    /// shape generically -- `isSeparatorLine` finds the dashes row, the
    /// line right before it is the header, everything after it up to the
    /// first blank/`#` line is data -- and hands each data row, as a
    /// `[columnName: rawText]` record, to `buildTarget(source:record:)`.
    static func parseVizieRTSV(source: CatalogSource, text: String) throws -> [CatalogTarget] {
        let lines = text.components(separatedBy: "\n")
        // Layout is always: header row (column names), units row, dashes
        // row (what `isSeparatorLine` finds), then data -- so the header is
        // TWO lines above the separator, not one (the units row sits
        // between them).
        guard let separatorIndex = lines.firstIndex(where: isSeparatorLine), separatorIndex >= 2 else {
            throw CatalogFetchError.invalidResponse(source)
        }
        let header = lines[separatorIndex - 2].components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }

        var targets: [CatalogTarget] = []
        for line in lines[(separatorIndex + 1)...] {
            if line.isEmpty || line.hasPrefix("#") { break }
            let fields = line.components(separatedBy: "\t")
            guard fields.count == header.count else { continue }
            var record: [String: String] = [:]
            for (key, value) in zip(header, fields) {
                record[key] = value.trimmingCharacters(in: .whitespaces)
            }
            if let target = buildTarget(source: source, record: record) {
                targets.append(target)
            }
        }
        return targets
    }

    private static func isSeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0 == "-" || $0 == "\t" || $0 == " " }
    }

    private static func buildTarget(source: CatalogSource, record: [String: String]) -> CatalogTarget? {
        switch source {
        case .ngcIC: return buildNGCICTarget(record)
        case .sharpless: return buildSharplessTarget(record)
        case .lyndsBrightNebulae: return buildLyndsTarget(record)
        case .vanDenBergh: return buildVanDenBerghTarget(record)
        case .barnard: return buildBarnardTarget(record)
        case .abellPlanetaryNebulae: return nil // handled by parseAbellPlanetaryNebulae
        }
    }

    /// `record["Name"]` is Sinnott's own on-disk shape: an IC entry is
    /// prefixed with a bare `"I"` (`"I4604"`), an NGC entry has no prefix at
    /// all (`"7000"`, left-padded with spaces -- already trimmed by the
    /// time this runs). Rebuilding through `Int(...)` drops that padding,
    /// so the result lands in exactly the same `"NGC <n>"`/`"IC <n>"` shape
    /// `TargetNameResolver` produces for the same object (see
    /// `CatalogTarget.designation`'s own doc comment).
    private static func buildNGCICTarget(_ record: [String: String]) -> CatalogTarget? {
        guard let name = record["Name"], !name.isEmpty,
              let ra = Double(record["_RAJ2000"] ?? ""), let dec = Double(record["_DEJ2000"] ?? "")
        else { return nil }

        let designation: String
        if name.hasPrefix("I") {
            guard let number = Int(name.dropFirst()) else { return nil }
            designation = "IC \(number)"
        } else {
            guard let number = Int(name) else { return nil }
            designation = "NGC \(number)"
        }

        return CatalogTarget(
            designation: designation,
            commonNameHU: CatalogNames.hungarian[designation],
            raDeg: ra,
            decDeg: dec,
            kind: ngcICKind(for: record["Type"] ?? ""),
            sizeArcmin: Double(record["size"] ?? ""),
            magnitude: Double(record["mag"] ?? "")
        )
    }

    /// Sinnott's own type codes, straight from the NGC 2000.0 book (values
    /// confirmed by sampling every distinct `Type` in the live table on
    /// 2026-08-15 -- see `docs/DATA-SOURCES.md`). Anything not confidently
    /// one of the specific `CatalogTargetKind` cases maps to `.other`
    /// rather than guessing (`"Nb"` alone doesn't say emission vs.
    /// reflection vs. dark, for instance).
    private static func ngcICKind(for type: String) -> CatalogTargetKind {
        switch type.trimmingCharacters(in: .whitespaces) {
        case "Gx": .galaxy
        case "OC": .openCluster
        case "Gb": .globularCluster
        case "Pl": .planetaryNebula
        case "C+N": .openCluster
        default: .other
        }
    }

    private static func buildSharplessTarget(_ record: [String: String]) -> CatalogTarget? {
        guard let number = Int(record["Sh2"] ?? ""),
              let ra = Double(record["_RAJ2000"] ?? ""), let dec = Double(record["_DEJ2000"] ?? "")
        else { return nil }
        let designation = "Sh2-\(number)"
        return CatalogTarget(
            designation: designation,
            commonNameHU: CatalogNames.hungarian[designation],
            raDeg: ra,
            decDeg: dec,
            kind: .emissionNebula,
            sizeArcmin: Double(record["Diam"] ?? ""),
            magnitude: nil // Sharpless's own catalog carries no magnitude, only a 1-3 brightness class.
        )
    }

    /// LBN designations use Lynds' own running number (`Seq`, 1-1125,
    /// documented in VizieR as "the" catalog number amateurs write as
    /// `"LBN <n>"`) -- NOT the separate `ID`/`Name` columns, which are
    /// cross-references to other catalogs, not the LBN number itself.
    private static func buildLyndsTarget(_ record: [String: String]) -> CatalogTarget? {
        guard let number = Int(record["Seq"] ?? ""),
              let ra = Double(record["_RAJ2000"] ?? ""), let dec = Double(record["_DEJ2000"] ?? "")
        else { return nil }
        let designation = "LBN \(number)"
        return CatalogTarget(
            designation: designation,
            commonNameHU: CatalogNames.hungarian[designation],
            raDeg: ra,
            decDeg: dec,
            // Lynds' Bright Nebulae mixes emission and reflection nebulae
            // with no per-object type field in this table -- `.other`
            // rather than guessing which.
            kind: .other,
            sizeArcmin: Double(record["Diam1"] ?? ""),
            magnitude: nil // no magnitude column in this catalog.
        )
    }

    private static func buildVanDenBerghTarget(_ record: [String: String]) -> CatalogTarget? {
        guard let number = Int(record["VdB"] ?? ""),
              let ra = Double(record["_RAJ2000"] ?? ""), let dec = Double(record["_DEJ2000"] ?? "")
        else { return nil }
        let designation = "vdB \(number)"
        // `BRadMax` is a RADIUS ("maximum radii observed on blue PSS
        // prints"); `sizeArcmin` is documented as major-AXIS (diameter), so
        // this doubles it to stay consistent with every other source.
        let radius = Double(record["BRadMax"] ?? "")
        return CatalogTarget(
            designation: designation,
            commonNameHU: CatalogNames.hungarian[designation],
            raDeg: ra,
            decDeg: dec,
            kind: .reflectionNebula, // van den Bergh's catalog is specifically reflection nebulae by definition.
            sizeArcmin: radius.map { $0 * 2 },
            magnitude: Double(record["Vmag"] ?? "")
        )
    }

    /// `Barn` is `CHAR(4)`, `[0-9a]` -- almost always a bare number
    /// (`"33"`), occasionally a numbered sub-object (`"142a"`). Kept as the
    /// raw trimmed text rather than forced through `Int(...)` so a
    /// sub-object designation survives instead of silently being dropped.
    private static func buildBarnardTarget(_ record: [String: String]) -> CatalogTarget? {
        guard let barn = record["Barn"], !barn.isEmpty,
              let ra = Double(record["_RAJ2000"] ?? ""), let dec = Double(record["_DEJ2000"] ?? "")
        else { return nil }
        let designation = "Barnard \(barn)"
        return CatalogTarget(
            designation: designation,
            commonNameHU: CatalogNames.hungarian[designation],
            raDeg: ra,
            decDeg: dec,
            kind: .darkNebula,
            sizeArcmin: Double(record["Diam"] ?? ""),
            magnitude: nil // Barnard's own catalog carries no magnitude.
        )
    }

    // MARK: - SIMBAD TAP (Abell planetary nebulae) parsing

    /// SIMBAD's own JSON TAP response shape: `{"data": [[id, ra, dec], ...]}`.
    /// `id` comes back internally padded (`"PN A66    1"`, matching the
    /// catalog's fixed-width original) -- this collapses the padding to a
    /// single space (`"PN A66 1"`) so it matches the plain-text designation
    /// shape every other source in this file uses.
    static func parseAbellPlanetaryNebulae(json data: Data) throws -> [CatalogTarget] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[Any]]
        else { throw CatalogFetchError.invalidResponse(.abellPlanetaryNebulae) }

        var targets: [CatalogTarget] = []
        for row in rows {
            guard row.count >= 3, let rawID = row[0] as? String else { continue }
            guard let ra = doubleValue(row[1]), let dec = doubleValue(row[2]) else { continue }
            let parts = rawID.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            guard parts.count == 3 else { continue }
            let designation = parts.joined(separator: " ")
            targets.append(CatalogTarget(
                designation: designation,
                commonNameHU: CatalogNames.hungarian[designation],
                raDeg: ra,
                decDeg: dec,
                kind: .planetaryNebula,
                sizeArcmin: nil, // not requested from this query -- genuinely unrecorded here, not a guess.
                magnitude: nil
            ))
        }
        return targets
    }

    private static func doubleValue(_ any: Any) -> Double? {
        if let value = any as? Double { return value }
        if let value = any as? Int { return Double(value) }
        if let value = any as? String { return Double(value) }
        return nil
    }
}
