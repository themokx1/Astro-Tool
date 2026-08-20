import Foundation
import Testing
@testable import AstroCore

/// Every fixture below is a byte-for-byte-shaped (trimmed to a handful of
/// rows for readability) recording of a REAL response from the live
/// service, captured 2026-08-15 while verifying the endpoints/identifiers
/// this fetcher uses -- see `docs/DATA-SOURCES.md`. No test in this file
/// makes a network call: `CatalogFetcher.transport` is always a synchronous
/// closure returning one of these fixtures.
@Suite("CatalogFetcher parses recorded VizieR/SIMBAD responses, never the network")
struct CatalogFetcherTests {
    // MARK: - Fixtures (recorded VizieR asu-tsv / SIMBAD TAP JSON responses)

    static let ngcICFixture = """
    #
    #   VizieR Astronomical Server vizier.cds.unistra.fr
    #INFO	request=https://vizier.cds.unistra.fr/viz-bin/asu-tsv?-source=VII%2f118%2fngc2000
    #RESOURCE=yCat_7118
    #Name: VII/118
    #Title: NGC 2000.0 (Sky Publishing, ed. Sinnott 1988)
    #Table	VII_118_ngc2000:
    #Column	Name	(A5)	NGC or IC designation (preceded by I)
    #Column	_RAJ2000	(F10.6)	Right ascension
    #Column	_DEJ2000	(F9.4)	Declination
    #Column	Type	(A3)	Object classification
    #Column	size	(F5.1)	? Largest dimension
    #Column	mag	(F4.1)	? Integrated magnitude
    Name	_RAJ2000	_DEJ2000	Type	size	mag
     	deg	deg	 	arcmin	mag
    -----	--------	--------	---	-----	----
    I4604	246.4004	-23.4333	 Nb	 60.0	
     7000	314.7000	 44.5200	 Nb	 120.0	 4.0
    I5371	000.0500	 32.8200			
    """

    static let sharplessFixture = """
    #
    #   VizieR Astronomical Server vizier.cds.unistra.fr
    #RESOURCE=yCat_7020
    #Name: VII/20
    #Title: Catalogue of HII Regions (Sharpless 1959)
    #Table	VII_20_catalog:
    #Column	Sh2	(I4)	[1/313]+ Sharpless HII catalog number
    #Column	_RAJ2000	(F10.6)	Right ascension
    #Column	_DEJ2000	(F10.6)	Declination
    #Column	Diam	(I4)	Maximun angular diameter of H II region
    Sh2	_RAJ2000	_DEJ2000	Diam
     	deg	deg	arcmin
    ----	----------	----------	----
       1	239.713380	-26.120461	 150
       2	256.027575	-38.142463	  60
    """

    static let lyndsFixture = """
    #
    #   VizieR Astronomical Server vizier.cds.unistra.fr
    #RESOURCE=yCat_7009
    #Name: VII/9
    #Title: Lynds' Catalogue of Bright Nebulae (Lynds 1965)
    #Table	VII_9_catalog:
    #Column	Seq	(I4)	[1/1125]+ Running number
    #Column	_RAJ2000	(F10.6)	Right ascension
    #Column	_DEJ2000	(F10.6)	Declination
    #Column	Diam1	(I4)	Largest dimension of nebula
    Seq	_RAJ2000	_DEJ2000	Diam1
     	deg	deg	arcmin
    ----	--------	--------	----
     437	338.0510	 40.5910	  75
       1	 10.1000	 60.2000	  30
    """

    static let vanDenBerghFixture = """
    #
    #   VizieR Astronomical Server vizier.cds.unistra.fr
    #RESOURCE=yCat_7021
    #Name: VII/21
    #Title: The catalogue (Van den Bergh S.)
    #Table	VII_21_catalog:
    #Column	VdB	(I3)	[1-158]+ van den Bergh catalog number
    #Column	_RAJ2000	(F11.7)	Right ascension
    #Column	_DEJ2000	(F11.7)	Declination
    #Column	Type	(a6)	Type of nebula
    #Column	BRadMax	(F5.1)	? Maximum radii observed on blue PSS prints
    #Column	Vmag	(F5.2)	? V magnitude
    VdB	_RAJ2000	_DEJ2000	Type	BRadMax	Vmag
     	deg	deg	 	arcmin	mag
    ---	-----------	-----------	------	-----	-----
      1	002.6931914	+58.7695183	I     	  4.3	 8.60
    """

    static let barnardFixture = """
    #
    #   VizieR Astronomical Server vizier.cds.unistra.fr
    #RESOURCE=yCat_7220A
    #Name: VII/220A
    #Title: Barnard's Catalogue of 349 Dark Objects in the Sky
    #Table	VII_220A_barnard:
    #Column	Barn	(A4)	Barnard number
    #Column	_RAJ2000	(F9.4)	Right ascension
    #Column	_DEJ2000	(F9.4)	Declination
    #Column	Diam	(F5.1)	? Diameter of the nebula
    Barn	_RAJ2000	_DEJ2000	Diam
     	deg	deg	arcmin
    ----	--------	--------	-----
      1 	053.2392	+31.1592	 30.0
      4 	056.0100	+31.7988	
     33 	085.2458	 -2.4581	  6.0
    """

    static let abellPlanetaryNebulaeFixture = Data("""
    {"metadata":[{"name":"id"},{"name":"ra"},{"name":"dec"}],"data":[["PN A66    1",3.229166666666667,69.17333333333333],["PN A66    2",11.394491666666667,57.9596888888889]]}
    """.utf8)

    // MARK: - Transport that serves fixtures by source, never the network

    private static func fixtureTransport() -> CatalogTransport {
        { url in
            let text = url.absoluteString
            if text.contains("PN") || text.contains("simbad") {
                return abellPlanetaryNebulaeFixture
            }
            if text.contains("VII%2f118%2fngc2000") || text.contains("VII/118/ngc2000") {
                return Data(ngcICFixture.utf8)
            }
            if text.contains("VII%2f20%2fcatalog") || text.contains("VII/20/catalog") {
                return Data(sharplessFixture.utf8)
            }
            if text.contains("VII%2f9%2fcatalog") || text.contains("VII/9/catalog") {
                return Data(lyndsFixture.utf8)
            }
            if text.contains("VII%2f21%2fcatalog") || text.contains("VII/21/catalog") {
                return Data(vanDenBerghFixture.utf8)
            }
            if text.contains("VII%2f220A%2fbarnard") || text.contains("VII/220A/barnard") {
                return Data(barnardFixture.utf8)
            }
            Issue.record("unexpected request URL: \(text)")
            return Data()
        }
    }

    // MARK: - Anchor: IC 4604 (Rho Ophiuchi) with correct coordinates

    @Test("NGC/IC fixture yields IC 4604 (Rho Ophiuchi) with correct coordinates")
    func ngcICYieldsRhoOphiuchiWithCorrectCoordinates() async throws {
        let fetcher = CatalogFetcher(transport: { _ in Data(Self.ngcICFixture.utf8) })
        let targets = try await fetcher.fetch(.ngcIC)
        let rho = try #require(targets.first { $0.designation == "IC 4604" })
        #expect(abs(rho.raDeg - 246.4004) < 0.001)
        #expect(abs(rho.decDeg - (-23.4333)) < 0.001)
    }

    @Test("Rho Ophiuchi carries a Hungarian common name aligned with CatalogNames")
    func rhoOphiuchiCarriesCommonName() async throws {
        let fetcher = CatalogFetcher(transport: { _ in Data(Self.ngcICFixture.utf8) })
        let targets = try await fetcher.fetch(.ngcIC)
        let rho = try #require(targets.first { $0.designation == "IC 4604" })
        #expect(rho.commonNameHU == CatalogNames.hungarian["IC 4604"])
        #expect(rho.commonNameHU?.contains("Rho") == true)
    }

    // MARK: - Anchor: LBN 437 with correct coordinates

    @Test("Lynds fixture yields LBN 437 with correct coordinates")
    func lyndsYieldsLBN437WithCorrectCoordinates() async throws {
        let fetcher = CatalogFetcher(transport: { _ in Data(Self.lyndsFixture.utf8) })
        let targets = try await fetcher.fetch(.lyndsBrightNebulae)
        let lbn437 = try #require(targets.first { $0.designation == "LBN 437" })
        #expect(abs(lbn437.raDeg - 338.0510) < 0.001)
        #expect(abs(lbn437.decDeg - 40.5910) < 0.001)
        #expect(lbn437.sizeArcmin == 75)
    }

    // MARK: - Anchor: a row missing size/magnitude survives

    @Test("An NGC/IC row missing size and magnitude still survives parsing")
    func rowMissingSizeSurvives() async throws {
        let fetcher = CatalogFetcher(transport: { _ in Data(Self.ngcICFixture.utf8) })
        let targets = try await fetcher.fetch(.ngcIC)
        let unnamed = try #require(targets.first { $0.designation == "IC 5371" })
        #expect(unnamed.sizeArcmin == nil)
        #expect(unnamed.magnitude == nil)
    }

    @Test("A Barnard row missing diameter still survives parsing")
    func barnardRowMissingDiamSurvives() async throws {
        let fetcher = CatalogFetcher(transport: { _ in Data(Self.barnardFixture.utf8) })
        let targets = try await fetcher.fetch(.barnard)
        #expect(targets.count == 3)
        let missingDiam = try #require(targets.first { $0.designation == "Barnard 4" })
        #expect(missingDiam.sizeArcmin == nil)
    }

    // MARK: - Other sources parse into the expected designation shape

    @Test("Sharpless fixture parses into Sh2-<n> designations with no magnitude")
    func sharplessParsesExpectedShape() async throws {
        let fetcher = CatalogFetcher(transport: { _ in Data(Self.sharplessFixture.utf8) })
        let targets = try await fetcher.fetch(.sharpless)
        #expect(targets.map(\.designation).sorted() == ["Sh2-1", "Sh2-2"])
        #expect(targets.allSatisfy { $0.magnitude == nil })
        #expect(targets.allSatisfy { $0.kind == .emissionNebula })
    }

    @Test("van den Bergh fixture parses into vdB <n>, magnitude present, size doubled from radius")
    func vanDenBerghParsesExpectedShape() async throws {
        let fetcher = CatalogFetcher(transport: { _ in Data(Self.vanDenBerghFixture.utf8) })
        let targets = try await fetcher.fetch(.vanDenBergh)
        let vdb1 = try #require(targets.first { $0.designation == "vdB 1" })
        #expect(vdb1.magnitude == 8.6)
        #expect(vdb1.sizeArcmin == 8.6) // BRadMax (radius) 4.3 * 2
        #expect(vdb1.kind == .reflectionNebula)
    }

    @Test("Barnard fixture parses into Barnard <n> designations, dark-nebula kind, no magnitude")
    func barnardParsesExpectedShape() async throws {
        let fetcher = CatalogFetcher(transport: { _ in Data(Self.barnardFixture.utf8) })
        let targets = try await fetcher.fetch(.barnard)
        let b33 = try #require(targets.first { $0.designation == "Barnard 33" })
        #expect(b33.sizeArcmin == 6.0)
        #expect(b33.kind == .darkNebula)
        #expect(b33.magnitude == nil)
    }

    @Test("Abell planetary nebula SIMBAD fixture collapses padded identifiers to 'PN A66 <n>'")
    func abellPlanetaryNebulaeParsesFromSIMBADJSON() throws {
        let targets = try CatalogFetcher.parseAbellPlanetaryNebulae(json: Self.abellPlanetaryNebulaeFixture)
        #expect(targets.map(\.designation) == ["PN A66 1", "PN A66 2"])
        #expect(targets.allSatisfy { $0.kind == .planetaryNebula })
        #expect(abs(targets[0].raDeg - 3.229166666666667) < 0.0001)
        #expect(abs(targets[0].decDeg - 69.17333333333333) < 0.0001)
    }

    // MARK: - fetchAll merges every source and de-duplicates by designation

    @Test("fetchAll queries every source and de-duplicates designations across them")
    func fetchAllMergesEverySource() async throws {
        let fetcher = CatalogFetcher(transport: Self.fixtureTransport())
        let targets = try await fetcher.fetchAll()
        #expect(targets.contains { $0.designation == "IC 4604" })
        #expect(targets.contains { $0.designation == "LBN 437" })
        #expect(targets.contains { $0.designation == "Sh2-1" })
        #expect(targets.contains { $0.designation == "vdB 1" })
        #expect(targets.contains { $0.designation == "Barnard 33" })
        #expect(targets.contains { $0.designation == "PN A66 1" })
        let designations = targets.map(\.designation)
        #expect(designations.count == Set(designations).count, "fetchAll must not yield duplicate designations")
    }

    @Test("fetchAll throws CancellationError when isCancelled reports true before any source completes")
    func fetchAllRespectsCancellation() async {
        let fetcher = CatalogFetcher(transport: Self.fixtureTransport())
        await #expect(throws: CancellationError.self) {
            _ = try await fetcher.fetchAll(isCancelled: { true })
        }
    }

    // MARK: - Malformed responses fail loudly rather than silently parsing garbage

    @Test("A response with no recognizable table shape throws invalidResponse")
    func malformedResponseThrows() async {
        let fetcher = CatalogFetcher(transport: { _ in Data("not a vizier response at all".utf8) })
        await #expect(throws: CatalogFetchError.self) {
            _ = try await fetcher.fetch(.sharpless)
        }
    }
}
