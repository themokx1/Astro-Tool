import Foundation

/// Coarse deep-sky-object category for `CatalogTarget.kind` -- just enough
/// granularity for `DiscoveryPlanner`'s callers to label/group a suggestion
/// sensibly (nebula vs. cluster vs. galaxy), not a full astronomical
/// taxonomy. `.other` covers anything that doesn't fit the rest (a star
/// cloud, an asterism, a double star -- the handful of Messier entries that
/// aren't really "deep-sky objects" in the imaging sense at all, but are
/// still part of the 110).
public enum CatalogTargetKind: String, Sendable, Codable, Equatable, CaseIterable {
    case galaxy
    case emissionNebula
    case planetaryNebula
    case supernovaRemnant
    case openCluster
    case globularCluster
    case reflectionNebula
    case darkNebula
    case other
}

/// One embedded catalog entry -- a static (never scanned, never written to
/// disk, no network access) deep-sky-object record. `DiscoveryPlanner`
/// sweeps every entry in `TargetCatalog.all` against tonight's sky the same
/// way `Planner.plan` sweeps the user's own library targets.
public struct CatalogTarget: Sendable, Codable, Equatable {
    /// Normalized designation, in exactly the shape
    /// `TargetNameResolver.resolve(folderName:)` itself produces for the
    /// same object -- `"M 42"`, `"NGC 7000"`, `"IC 1396"`, `"Sh2-155"` (see
    /// that type's own doc comment for the full shape-per-catalog rules).
    /// `DiscoveryPlanner`'s `alreadyInLibrary` check is a plain set-
    /// membership test against the library's own resolved designations, so
    /// keeping this field in the resolver's exact output shape is what
    /// makes that check work with no extra normalization on either side.
    public let designation: String
    /// Hungarian common name, ALIGNED with (never contradicting)
    /// `CatalogNames.hungarian` where the two tables cover the same
    /// designation -- `nil` when no common Hungarian name is in use, same
    /// "absence is not a bug, just nothing to show" stance `CatalogNames`
    /// itself documents (R10 "honest n/a" rule: never guess a name).
    public let commonNameHU: String?
    /// J2000, degrees -- same epoch/units as every other RA/Dec in this
    /// module (`TargetCoordinates`, `SunMoon`).
    public let raDeg: Double
    public let decDeg: Double
    public let kind: CatalogTargetKind
    /// Major-axis angular size, in arcminutes. `nil` when genuinely
    /// unrecorded -- never a guess.
    public let sizeArcmin: Double?
    /// Apparent visual magnitude. `nil` when genuinely unrecorded.
    public let magnitude: Double?
    /// Curated or measured mean surface brightness in mag/arcsec². Most
    /// embedded records leave this nil and use the documented magnitude +
    /// angular-area estimate instead. A direct value is useful for targets
    /// whose integrated magnitude is not representative of the photographed
    /// structure, and for deterministic planning tests.
    public let surfaceBrightnessMagPerArcsec2: Double?

    public init(
        designation: String,
        commonNameHU: String?,
        raDeg: Double,
        decDeg: Double,
        kind: CatalogTargetKind,
        sizeArcmin: Double?,
        magnitude: Double?,
        surfaceBrightnessMagPerArcsec2: Double? = nil
    ) {
        self.designation = designation
        self.commonNameHU = commonNameHU
        self.raDeg = raDeg
        self.decDeg = decDeg
        self.kind = kind
        self.sizeArcmin = sizeArcmin
        self.magnitude = magnitude
        self.surfaceBrightnessMagPerArcsec2 = surfaceBrightnessMagPerArcsec2
    }
}

/// Embedded, static "what else is out there" catalog: all 110 Messier
/// objects plus a curated set of popular non-Messier astrophotography
/// targets (bright NGC/IC/Sharpless nebulae, galaxies, and clusters).
/// Deliberately NOT a full NGC/IC dump -- every entry here was picked (and
/// its coordinates checked against a reference) because it's a genuinely
/// popular imaging target, not because it happened to be easy to add; see
/// each section's own doc comment. No network access, no filesystem
/// access, never changes at runtime. The only consumer is
/// `DiscoveryPlanner.discover`.
public enum TargetCatalog {
    public static let all: [CatalogTarget] = messier + nonMessier

    /// English names are deliberately data, not UI translations: they are
    /// stable search aliases and therefore also provide deterministic ASCII
    /// folder names. Bare catalog objects remain searchable by designation.
    private static let englishNames: [String: String] = [
        "M 1": "Crab Nebula", "M 6": "Butterfly Cluster", "M 7": "Ptolemy Cluster",
        "M 8": "Lagoon Nebula", "M 11": "Wild Duck Cluster", "M 13": "Hercules Globular Cluster",
        "M 16": "Eagle Nebula", "M 17": "Omega Nebula", "M 20": "Trifid Nebula",
        "M 27": "Dumbbell Nebula", "M 31": "Andromeda Galaxy", "M 33": "Triangulum Galaxy",
        "M 42": "Orion Nebula", "M 44": "Beehive Cluster", "M 45": "Pleiades",
        "M 51": "Whirlpool Galaxy", "M 57": "Ring Nebula", "M 63": "Sunflower Galaxy",
        "M 64": "Black Eye Galaxy", "M 76": "Little Dumbbell Nebula", "M 81": "Bode's Galaxy",
        "M 82": "Cigar Galaxy", "M 83": "Southern Pinwheel Galaxy", "M 97": "Owl Nebula",
        "M 101": "Pinwheel Galaxy", "M 104": "Sombrero Galaxy",
        "NGC 40": "Bow-Tie Nebula", "NGC 104": "47 Tucanae", "NGC 246": "Skull Nebula",
        "NGC 253": "Sculptor Galaxy", "NGC 281": "Pacman Nebula",
        "NGC 300": "Sculptor Pinwheel Galaxy", "NGC 457": "Owl Cluster",
        "NGC 663": "Lawnmower Cluster", "NGC 772": "Fiddlehead Galaxy",
        "NGC 869": "Double Cluster h Persei", "NGC 884": "Double Cluster chi Persei",
        "NGC 891": "Silver Sliver Galaxy", "NGC 1333": "Embryo Nebula",
        "NGC 1435": "Merope Nebula", "NGC 1499": "California Nebula",
        "NGC 1502": "Golden Harp Cluster", "NGC 1579": "Northern Trifid Nebula",
        "NGC 1977": "Running Man Nebula", "NGC 2024": "Flame Nebula",
        "NGC 2070": "Tarantula Nebula", "NGC 2237": "Rosette Nebula",
        "NGC 2244": "Satellite Cluster", "NGC 2264": "Christmas Tree Cluster",
        "NGC 2359": "Thor's Helmet", "NGC 2392": "Eskimo Nebula",
        "NGC 2419": "Intergalactic Wanderer", "NGC 2516": "Southern Beehive Cluster",
        "NGC 2683": "UFO Galaxy", "NGC 3132": "Eight-Burst Nebula",
        "NGC 3242": "Ghost of Jupiter", "NGC 3372": "Carina Nebula",
        "NGC 3532": "Wishing Well Cluster", "NGC 3628": "Hamburger Galaxy",
        "NGC 4038": "Antennae Galaxies", "NGC 4039": "Antennae Galaxies",
        "NGC 4244": "Silver Needle Galaxy", "NGC 4490": "Cocoon Galaxy",
        "NGC 4565": "Needle Galaxy", "NGC 4631": "Whale Galaxy",
        "NGC 5128": "Centaurus A", "NGC 5139": "Omega Centauri",
        "NGC 5907": "Splinter Galaxy", "NGC 6164": "Dragon's Egg Nebula",
        "NGC 6165": "Dragon's Egg Nebula", "NGC 6188": "Fighting Dragons of Ara",
        "NGC 6210": "Turtle Nebula", "NGC 6231": "Baby Scorpion Cluster",
        "NGC 6334": "Cat's Paw Nebula", "NGC 6357": "Lobster Nebula",
        "NGC 6503": "Lost-in-Space Galaxy", "NGC 6543": "Cat's Eye Nebula",
        "NGC 6752": "Great Peacock Globular", "NGC 6819": "Foxhead Cluster",
        "NGC 6822": "Barnard's Galaxy", "NGC 6888": "Crescent Nebula",
        "NGC 6946": "Fireworks Galaxy", "NGC 6960": "Witch's Broom Nebula",
        "NGC 6992": "Eastern Veil Nebula", "NGC 7000": "North America Nebula",
        "NGC 7009": "Saturn Nebula", "NGC 7023": "Iris Nebula",
        "NGC 7217": "Ringed Spiral Galaxy", "NGC 7293": "Helix Nebula",
        "NGC 7331": "Deer Lick Group", "NGC 7380": "Wizard Nebula",
        "NGC 7635": "Bubble Nebula", "NGC 7789": "Caroline's Rose",
        "NGC 7814": "Little Sombrero Galaxy", "IC 63": "Ghost of Cassiopeia",
        "IC 405": "Flaming Star Nebula", "IC 410": "Tadpole Nebula",
        "IC 434": "Horsehead Nebula", "IC 443": "Jellyfish Nebula",
        "IC 1396": "Elephant's Trunk Nebula", "IC 1805": "Heart Nebula",
        "IC 1848": "Soul Nebula", "IC 2118": "Witch Head Nebula",
        "IC 2602": "Southern Pleiades", "IC 2944": "Running Chicken Nebula",
        "IC 4628": "Prawn Nebula", "IC 5070": "Pelican Nebula",
        "IC 5146": "Cocoon Nebula", "IC 5148": "Spare Tyre Nebula",
        "Sh2-101": "Tulip Nebula", "Sh2-115": "Sharpless 115",
        "Sh2-129": "Flying Bat Nebula", "Sh2-132": "Lion Nebula",
        "Sh2-155": "Cave Nebula", "Sh2-157": "Lobster Claw Nebula",
        "Sh2-240": "Spaghetti Nebula",
    ]

    private static let extraAliases: [String: [String]] = [
        "IC 1396": ["Elephant Trunk Nebula", "Elephant Trunk", "IC 1396A"],
        "NGC 869": ["Double Cluster", "h Persei"],
        "NGC 884": ["Double Cluster", "chi Persei"],
        "NGC 2237": ["Rosette", "Caldwell 49"],
        "NGC 7000": ["North America", "Caldwell 20"],
        "M 31": ["Andromeda"], "M 42": ["Orion"], "M 45": ["Seven Sisters"],
    ]

    public static func englishName(for target: CatalogTarget) -> String? {
        englishNames[target.designation]
    }

    /// Offline, forgiving target search used by new-session creation. Search
    /// normalization removes accents, punctuation and whitespace, so
    /// `IC1396`, `Elephant's Trunk` and `elefantormany` all hit one record.
    public static func search(_ query: String, limit: Int = 20) -> [CatalogTarget] {
        let needle = normalizedSearch(query)
        guard !needle.isEmpty, limit > 0 else { return [] }

        return all.compactMap { target -> (CatalogTarget, Int)? in
            let values = [target.designation, target.commonNameHU, englishNames[target.designation]]
                .compactMap { $0 } + (extraAliases[target.designation] ?? [])
            let normalized = values.map(normalizedSearch)
            let rank: Int
            if normalized.contains(needle) { rank = 0 }
            else if normalized.contains(where: { $0.hasPrefix(needle) }) { rank = 1 }
            else if normalized.contains(where: { $0.contains(needle) }) { rank = 2 }
            else { return nil }
            return (target, rank)
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.designation.localizedStandardCompare($1.0.designation) == .orderedAscending
        }
        .prefix(limit)
        .map(\.0)
    }

    /// Stable ASCII path component. A well-known English name makes the
    /// folder understandable across locales; unnamed entries use the catalog
    /// designation alone instead of inventing a translation.
    public static func canonicalFolderName(for target: CatalogTarget) -> String {
        guard let english = englishNames[target.designation] else {
            return Sanitizer.sanitize(target.designation)
        }
        return Sanitizer.makeTarget(catalog: target.designation, name: english)
    }

    /// Finds the already existing folder for the same catalog identity. The
    /// canonical spelling wins if it is present; otherwise the shortest,
    /// then lexical spelling makes the choice deterministic.
    public static func existingFolder(for target: CatalogTarget, among folders: [String]) -> String? {
        let matches = folders.filter {
            TargetNameResolver.resolve(folderName: $0).designation == target.designation
        }
        let canonical = canonicalFolderName(for: target)
        if matches.contains(canonical) { return canonical }
        return matches.sorted {
            if $0.count != $1.count { return $0.count < $1.count }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }.first
    }

    public static func target(matchingFolderName folderName: String) -> CatalogTarget? {
        guard let designation = TargetNameResolver.resolve(folderName: folderName).designation else { return nil }
        return all.first { $0.designation == designation }
    }

    /// Mean surface-brightness estimate in mag/arcsec². A direct curated
    /// value wins. Otherwise the integrated magnitude is spread over an
    /// ellipse whose minor axis uses a conservative type-specific ratio.
    /// This is explicitly a planning estimate, not scientific photometry.
    public static func estimatedSurfaceBrightness(for target: CatalogTarget) -> Double? {
        if let direct = target.surfaceBrightnessMagPerArcsec2,
           direct.isFinite, direct > 0 { return direct }
        guard let magnitude = target.magnitude, magnitude.isFinite,
              let majorArcmin = target.sizeArcmin, majorArcmin.isFinite, majorArcmin > 0
        else { return nil }

        let minorArcmin = majorArcmin * axisRatio(for: target.kind)
        let semiMajorArcsec = majorArcmin * 30
        let semiMinorArcsec = minorArcmin * 30
        let areaArcsec2 = Double.pi * semiMajorArcsec * semiMinorArcsec
        guard areaArcsec2.isFinite, areaArcsec2 > 0 else { return nil }
        return magnitude + 2.5 * log10(areaArcsec2)
    }

    private static func normalizedSearch(_ raw: String) -> String {
        let folded = raw.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "hu_HU")
        ).lowercased()
        return String(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func axisRatio(for kind: CatalogTargetKind) -> Double {
        switch kind {
        case .galaxy: 0.55
        case .emissionNebula, .reflectionNebula, .supernovaRemnant: 0.65
        case .planetaryNebula: 0.85
        case .openCluster: 0.85
        case .globularCluster: 0.90
        case .darkNebula, .other: 0.80
        }
    }

    // MARK: - Messier (all 110, M1...M110)

    /// RA/Dec/magnitude/size sourced from Wikipedia's "List of Messier
    /// objects" table (J2000, converted from sexagesimal to decimal
    /// degrees). `kind` mostly follows that table's own object-type column,
    /// with a few corrections from general astronomical knowledge where the
    /// table's category is too coarse to map 1:1 onto `CatalogTargetKind`
    /// (M78 is a REFLECTION nebula, not an emission nebula, despite the
    /// source table lumping every diffuse nebula together; M24 is a star
    /// cloud and M40/M73 are a double star/asterism, none of which are
    /// discrete objects, so all three are `.other`). `commonNameHU` mirrors
    /// `CatalogNames.hungarian`'s Messier section exactly -- most Messier
    /// globular clusters and bare galaxies simply have no Hungarian common
    /// name in everyday use, hence `nil`, same as that table.
    private static let messier: [CatalogTarget] = [
        CatalogTarget(designation: "M 1", commonNameHU: "Rák-köd", raDeg: 83.633, decDeg: 22.015, kind: .supernovaRemnant, sizeArcmin: 7.0, magnitude: 8.4),
        CatalogTarget(designation: "M 2", commonNameHU: nil, raDeg: 323.363, decDeg: -0.823, kind: .globularCluster, sizeArcmin: 16.0, magnitude: 6.5),
        CatalogTarget(designation: "M 3", commonNameHU: nil, raDeg: 205.548, decDeg: 28.377, kind: .globularCluster, sizeArcmin: 18.0, magnitude: 6.2),
        CatalogTarget(designation: "M 4", commonNameHU: nil, raDeg: 245.897, decDeg: -26.526, kind: .globularCluster, sizeArcmin: 26.0, magnitude: 5.6),
        CatalogTarget(designation: "M 5", commonNameHU: nil, raDeg: 229.638, decDeg: 2.081, kind: .globularCluster, sizeArcmin: 23.0, magnitude: 5.6),
        CatalogTarget(designation: "M 6", commonNameHU: "Lepke-halmaz", raDeg: 265.025, decDeg: -32.217, kind: .openCluster, sizeArcmin: 25.0, magnitude: 4.2),
        CatalogTarget(designation: "M 7", commonNameHU: "Ptolemaiosz-halmaz", raDeg: 268.463, decDeg: -34.793, kind: .openCluster, sizeArcmin: 80.0, magnitude: 3.3),
        CatalogTarget(designation: "M 8", commonNameHU: "Lagúna-köd", raDeg: 270.904, decDeg: -24.387, kind: .emissionNebula, sizeArcmin: 90.0, magnitude: 4.6),
        CatalogTarget(designation: "M 9", commonNameHU: nil, raDeg: 259.799, decDeg: -18.516, kind: .globularCluster, sizeArcmin: 9.3, magnitude: 7.7),
        CatalogTarget(designation: "M 10", commonNameHU: nil, raDeg: 254.287, decDeg: -4.099, kind: .globularCluster, sizeArcmin: 20.0, magnitude: 6.6),
        CatalogTarget(designation: "M 11", commonNameHU: "Vadkacsa-halmaz", raDeg: 282.775, decDeg: -6.267, kind: .openCluster, sizeArcmin: 22.8, magnitude: 5.8),
        CatalogTarget(designation: "M 12", commonNameHU: nil, raDeg: 251.809, decDeg: -1.949, kind: .globularCluster, sizeArcmin: 16.0, magnitude: 6.7),
        CatalogTarget(designation: "M 13", commonNameHU: "Herkules-gömbhalmaz", raDeg: 250.422, decDeg: 36.46, kind: .globularCluster, sizeArcmin: 20.0, magnitude: 5.8),
        CatalogTarget(designation: "M 14", commonNameHU: nil, raDeg: 264.401, decDeg: -3.246, kind: .globularCluster, sizeArcmin: 11.0, magnitude: 7.6),
        CatalogTarget(designation: "M 15", commonNameHU: nil, raDeg: 322.493, decDeg: 12.167, kind: .globularCluster, sizeArcmin: 18.0, magnitude: 6.2),
        CatalogTarget(designation: "M 16", commonNameHU: "Sas-köd", raDeg: 274.7, decDeg: -13.817, kind: .emissionNebula, sizeArcmin: 70.0, magnitude: 6.4),
        CatalogTarget(designation: "M 17", commonNameHU: "Omega-köd", raDeg: 275.108, decDeg: -16.177, kind: .emissionNebula, sizeArcmin: 11.0, magnitude: 6.0),
        CatalogTarget(designation: "M 18", commonNameHU: nil, raDeg: 274.975, decDeg: -17.133, kind: .openCluster, sizeArcmin: 9.8, magnitude: 7.5),
        CatalogTarget(designation: "M 19", commonNameHU: nil, raDeg: 255.657, decDeg: -26.268, kind: .globularCluster, sizeArcmin: 17.0, magnitude: 6.8),
        CatalogTarget(designation: "M 20", commonNameHU: "Trifid-köd", raDeg: 270.596, decDeg: -23.03, kind: .emissionNebula, sizeArcmin: 28.0, magnitude: 6.3),
        CatalogTarget(designation: "M 21", commonNameHU: nil, raDeg: 271.15, decDeg: -22.5, kind: .openCluster, sizeArcmin: 14.0, magnitude: 6.5),
        CatalogTarget(designation: "M 22", commonNameHU: nil, raDeg: 279.1, decDeg: -23.905, kind: .globularCluster, sizeArcmin: 32.0, magnitude: 5.1),
        CatalogTarget(designation: "M 23", commonNameHU: nil, raDeg: 269.2, decDeg: -19.017, kind: .openCluster, sizeArcmin: 35.0, magnitude: 5.5),
        CatalogTarget(designation: "M 24", commonNameHU: "Kis Sagittarius-csillagfelhő", raDeg: 274.25, decDeg: -18.55, kind: .other, sizeArcmin: 120.0, magnitude: 2.5),
        CatalogTarget(designation: "M 25", commonNameHU: nil, raDeg: 277.9, decDeg: -19.25, kind: .openCluster, sizeArcmin: 36.0, magnitude: 4.6),
        CatalogTarget(designation: "M 26", commonNameHU: nil, raDeg: 281.3, decDeg: -9.4, kind: .openCluster, sizeArcmin: 14.0, magnitude: 8.0),
        CatalogTarget(designation: "M 27", commonNameHU: "Súlyzó-köd", raDeg: 299.901, decDeg: 22.721, kind: .planetaryNebula, sizeArcmin: 8.0, magnitude: 7.4),
        CatalogTarget(designation: "M 28", commonNameHU: nil, raDeg: 276.137, decDeg: -24.87, kind: .globularCluster, sizeArcmin: 11.2, magnitude: 6.8),
        CatalogTarget(designation: "M 29", commonNameHU: nil, raDeg: 305.983, decDeg: 38.523, kind: .openCluster, sizeArcmin: 7.0, magnitude: 7.1),
        CatalogTarget(designation: "M 30", commonNameHU: nil, raDeg: 325.092, decDeg: -23.18, kind: .globularCluster, sizeArcmin: 12.0, magnitude: 7.2),
        CatalogTarget(designation: "M 31", commonNameHU: "Androméda-galaxis", raDeg: 10.685, decDeg: 41.269, kind: .galaxy, sizeArcmin: 190.2, magnitude: 3.4),
        CatalogTarget(designation: "M 32", commonNameHU: nil, raDeg: 10.674, decDeg: 40.865, kind: .galaxy, sizeArcmin: 8.7, magnitude: 8.1),
        CatalogTarget(designation: "M 33", commonNameHU: "Triangulum-galaxis", raDeg: 23.458, decDeg: 30.66, kind: .galaxy, sizeArcmin: 70.8, magnitude: 5.7),
        CatalogTarget(designation: "M 34", commonNameHU: nil, raDeg: 40.525, decDeg: 42.767, kind: .openCluster, sizeArcmin: 35.0, magnitude: 5.5),
        CatalogTarget(designation: "M 35", commonNameHU: nil, raDeg: 92.275, decDeg: 24.35, kind: .openCluster, sizeArcmin: 28.0, magnitude: 5.3),
        CatalogTarget(designation: "M 36", commonNameHU: nil, raDeg: 84.05, decDeg: 34.134, kind: .openCluster, sizeArcmin: 12.0, magnitude: 6.3),
        CatalogTarget(designation: "M 37", commonNameHU: nil, raDeg: 88.075, decDeg: 32.551, kind: .openCluster, sizeArcmin: 24.0, magnitude: 6.2),
        CatalogTarget(designation: "M 38", commonNameHU: nil, raDeg: 82.175, decDeg: 35.855, kind: .openCluster, sizeArcmin: 21.0, magnitude: 7.4),
        CatalogTarget(designation: "M 39", commonNameHU: nil, raDeg: 322.925, decDeg: 48.433, kind: .openCluster, sizeArcmin: 29.0, magnitude: 4.6),
        CatalogTarget(designation: "M 40", commonNameHU: nil, raDeg: 185.552, decDeg: 58.083, kind: .other, sizeArcmin: nil, magnitude: 8.4),
        CatalogTarget(designation: "M 41", commonNameHU: nil, raDeg: 101.5, decDeg: -20.767, kind: .openCluster, sizeArcmin: 38.0, magnitude: 4.5),
        CatalogTarget(designation: "M 42", commonNameHU: "Orion-köd", raDeg: 83.822, decDeg: -5.391, kind: .emissionNebula, sizeArcmin: 65.0, magnitude: 4.0),
        CatalogTarget(designation: "M 43", commonNameHU: nil, raDeg: 83.9, decDeg: -5.267, kind: .emissionNebula, sizeArcmin: 20.0, magnitude: 9.0),
        CatalogTarget(designation: "M 44", commonNameHU: "Méhkas-halmaz", raDeg: 130.1, decDeg: 19.983, kind: .openCluster, sizeArcmin: 95.0, magnitude: 3.7),
        CatalogTarget(designation: "M 45", commonNameHU: "Fiastyúk", raDeg: 56.85, decDeg: 24.117, kind: .openCluster, sizeArcmin: 120.0, magnitude: 1.6),
        CatalogTarget(designation: "M 46", commonNameHU: nil, raDeg: 115.45, decDeg: -14.817, kind: .openCluster, sizeArcmin: 22.8, magnitude: 6.0),
        CatalogTarget(designation: "M 47", commonNameHU: nil, raDeg: 114.15, decDeg: -14.5, kind: .openCluster, sizeArcmin: 30.0, magnitude: 4.4),
        CatalogTarget(designation: "M 48", commonNameHU: nil, raDeg: 123.425, decDeg: -5.75, kind: .openCluster, sizeArcmin: 30.0, magnitude: 5.5),
        CatalogTarget(designation: "M 49", commonNameHU: nil, raDeg: 187.445, decDeg: 8.001, kind: .galaxy, sizeArcmin: 10.2, magnitude: 8.4),
        CatalogTarget(designation: "M 50", commonNameHU: nil, raDeg: 105.8, decDeg: -8.333, kind: .openCluster, sizeArcmin: 16.0, magnitude: 5.9),
        CatalogTarget(designation: "M 51", commonNameHU: "Örvény-galaxis", raDeg: 202.47, decDeg: 47.195, kind: .galaxy, sizeArcmin: 11.2, magnitude: 8.4),
        CatalogTarget(designation: "M 52", commonNameHU: nil, raDeg: 351.05, decDeg: 61.583, kind: .openCluster, sizeArcmin: 13.0, magnitude: 7.3),
        CatalogTarget(designation: "M 53", commonNameHU: nil, raDeg: 198.23, decDeg: 18.168, kind: .globularCluster, sizeArcmin: 13.0, magnitude: 7.6),
        CatalogTarget(designation: "M 54", commonNameHU: nil, raDeg: 283.764, decDeg: -30.48, kind: .globularCluster, sizeArcmin: 12.0, magnitude: 7.6),
        CatalogTarget(designation: "M 55", commonNameHU: nil, raDeg: 294.999, decDeg: -30.965, kind: .globularCluster, sizeArcmin: 19.0, magnitude: 6.3),
        CatalogTarget(designation: "M 56", commonNameHU: nil, raDeg: 289.148, decDeg: 30.183, kind: .globularCluster, sizeArcmin: 8.8, magnitude: 8.3),
        CatalogTarget(designation: "M 57", commonNameHU: "Gyűrűs-köd", raDeg: 283.396, decDeg: 33.029, kind: .planetaryNebula, sizeArcmin: 3.83, magnitude: 8.8),
        CatalogTarget(designation: "M 58", commonNameHU: nil, raDeg: 189.431, decDeg: 11.818, kind: .galaxy, sizeArcmin: 5.9, magnitude: 9.7),
        CatalogTarget(designation: "M 59", commonNameHU: nil, raDeg: 190.51, decDeg: 11.647, kind: .galaxy, sizeArcmin: 5.4, magnitude: 9.6),
        CatalogTarget(designation: "M 60", commonNameHU: nil, raDeg: 190.915, decDeg: 11.553, kind: .galaxy, sizeArcmin: 7.4, magnitude: 8.8),
        CatalogTarget(designation: "M 61", commonNameHU: nil, raDeg: 185.479, decDeg: 4.474, kind: .galaxy, sizeArcmin: 6.5, magnitude: 9.7),
        CatalogTarget(designation: "M 62", commonNameHU: nil, raDeg: 255.302, decDeg: -30.112, kind: .globularCluster, sizeArcmin: 15.0, magnitude: 6.5),
        CatalogTarget(designation: "M 63", commonNameHU: "Napraforgó-galaxis", raDeg: 198.955, decDeg: 42.029, kind: .galaxy, sizeArcmin: 12.6, magnitude: 8.6),
        CatalogTarget(designation: "M 64", commonNameHU: "Fekete Szem", raDeg: 194.182, decDeg: 21.683, kind: .galaxy, sizeArcmin: 10.7, magnitude: 8.5),
        CatalogTarget(designation: "M 65", commonNameHU: nil, raDeg: 169.733, decDeg: 13.092, kind: .galaxy, sizeArcmin: 8.7, magnitude: 9.3),
        CatalogTarget(designation: "M 66", commonNameHU: nil, raDeg: 170.062, decDeg: 12.992, kind: .galaxy, sizeArcmin: 9.1, magnitude: 8.9),
        CatalogTarget(designation: "M 67", commonNameHU: nil, raDeg: 132.825, decDeg: 11.817, kind: .openCluster, sizeArcmin: 30.0, magnitude: 6.1),
        CatalogTarget(designation: "M 68", commonNameHU: nil, raDeg: 189.867, decDeg: -26.744, kind: .globularCluster, sizeArcmin: 11.0, magnitude: 7.8),
        CatalogTarget(designation: "M 69", commonNameHU: nil, raDeg: 277.846, decDeg: -32.348, kind: .globularCluster, sizeArcmin: 10.8, magnitude: 7.6),
        CatalogTarget(designation: "M 70", commonNameHU: nil, raDeg: 280.803, decDeg: -32.292, kind: .globularCluster, sizeArcmin: 8.0, magnitude: 7.9),
        CatalogTarget(designation: "M 71", commonNameHU: nil, raDeg: 298.444, decDeg: 18.779, kind: .globularCluster, sizeArcmin: 7.2, magnitude: 8.2),
        CatalogTarget(designation: "M 72", commonNameHU: nil, raDeg: 313.365, decDeg: -12.537, kind: .globularCluster, sizeArcmin: 6.6, magnitude: 9.3),
        CatalogTarget(designation: "M 73", commonNameHU: nil, raDeg: 314.725, decDeg: -12.633, kind: .other, sizeArcmin: 2.8, magnitude: 9.0),
        CatalogTarget(designation: "M 74", commonNameHU: nil, raDeg: 24.174, decDeg: 15.784, kind: .galaxy, sizeArcmin: 10.5, magnitude: 9.4),
        CatalogTarget(designation: "M 75", commonNameHU: nil, raDeg: 301.52, decDeg: -21.921, kind: .globularCluster, sizeArcmin: 6.8, magnitude: 8.5),
        CatalogTarget(designation: "M 76", commonNameHU: "Kis Súlyzó-köd", raDeg: 25.6, decDeg: 51.575, kind: .planetaryNebula, sizeArcmin: 2.7, magnitude: 10.1),
        CatalogTarget(designation: "M 77", commonNameHU: nil, raDeg: 40.67, decDeg: -0.013, kind: .galaxy, sizeArcmin: 7.1, magnitude: 8.9),
        CatalogTarget(designation: "M 78", commonNameHU: nil, raDeg: 86.695, decDeg: 0.014, kind: .reflectionNebula, sizeArcmin: 8.0, magnitude: 8.3),
        CatalogTarget(designation: "M 79", commonNameHU: nil, raDeg: 81.044, decDeg: -24.524, kind: .globularCluster, sizeArcmin: 8.7, magnitude: 7.7),
        CatalogTarget(designation: "M 80", commonNameHU: nil, raDeg: 244.26, decDeg: -22.976, kind: .globularCluster, sizeArcmin: 10.0, magnitude: 7.3),
        CatalogTarget(designation: "M 81", commonNameHU: "Bode-galaxis", raDeg: 148.888, decDeg: 69.065, kind: .galaxy, sizeArcmin: 26.9, magnitude: 6.9),
        CatalogTarget(designation: "M 82", commonNameHU: "Szivar-galaxis", raDeg: 148.968, decDeg: 69.68, kind: .galaxy, sizeArcmin: 11.2, magnitude: 8.4),
        CatalogTarget(designation: "M 83", commonNameHU: "Déli Szélkerék-galaxis", raDeg: 204.254, decDeg: -29.866, kind: .galaxy, sizeArcmin: 12.9, magnitude: 7.6),
        CatalogTarget(designation: "M 84", commonNameHU: nil, raDeg: 186.265, decDeg: 12.887, kind: .galaxy, sizeArcmin: 6.5, magnitude: 9.1),
        CatalogTarget(designation: "M 85", commonNameHU: nil, raDeg: 186.35, decDeg: 18.191, kind: .galaxy, sizeArcmin: 7.1, magnitude: 9.1),
        CatalogTarget(designation: "M 86", commonNameHU: nil, raDeg: 186.549, decDeg: 12.946, kind: .galaxy, sizeArcmin: 8.9, magnitude: 8.9),
        CatalogTarget(designation: "M 87", commonNameHU: nil, raDeg: 187.706, decDeg: 12.391, kind: .galaxy, sizeArcmin: 7.2, magnitude: 8.6),
        CatalogTarget(designation: "M 88", commonNameHU: nil, raDeg: 187.997, decDeg: 14.421, kind: .galaxy, sizeArcmin: 6.9, magnitude: 9.6),
        CatalogTarget(designation: "M 89", commonNameHU: nil, raDeg: 188.916, decDeg: 12.556, kind: .galaxy, sizeArcmin: 5.1, magnitude: 9.8),
        CatalogTarget(designation: "M 90", commonNameHU: nil, raDeg: 189.207, decDeg: 13.163, kind: .galaxy, sizeArcmin: 9.5, magnitude: 9.5),
        CatalogTarget(designation: "M 91", commonNameHU: nil, raDeg: 188.86, decDeg: 14.496, kind: .galaxy, sizeArcmin: 5.4, magnitude: 10.2),
        CatalogTarget(designation: "M 92", commonNameHU: nil, raDeg: 259.281, decDeg: 43.136, kind: .globularCluster, sizeArcmin: 14.0, magnitude: 6.4),
        CatalogTarget(designation: "M 93", commonNameHU: nil, raDeg: 116.15, decDeg: -23.867, kind: .openCluster, sizeArcmin: 10.0, magnitude: 6.0),
        CatalogTarget(designation: "M 94", commonNameHU: nil, raDeg: 192.721, decDeg: 41.121, kind: .galaxy, sizeArcmin: 11.2, magnitude: 8.2),
        CatalogTarget(designation: "M 95", commonNameHU: nil, raDeg: 160.99, decDeg: 11.704, kind: .galaxy, sizeArcmin: 3.1, magnitude: 9.7),
        CatalogTarget(designation: "M 96", commonNameHU: nil, raDeg: 161.69, decDeg: 11.82, kind: .galaxy, sizeArcmin: 7.6, magnitude: 9.2),
        CatalogTarget(designation: "M 97", commonNameHU: "Bagoly-köd", raDeg: 168.699, decDeg: 55.019, kind: .planetaryNebula, sizeArcmin: 3.4, magnitude: 9.9),
        CatalogTarget(designation: "M 98", commonNameHU: nil, raDeg: 183.451, decDeg: 14.9, kind: .galaxy, sizeArcmin: 9.8, magnitude: 10.1),
        CatalogTarget(designation: "M 99", commonNameHU: nil, raDeg: 184.707, decDeg: 14.416, kind: .galaxy, sizeArcmin: 5.4, magnitude: 9.9),
        CatalogTarget(designation: "M 100", commonNameHU: nil, raDeg: 185.729, decDeg: 15.822, kind: .galaxy, sizeArcmin: 7.4, magnitude: 9.3),
        CatalogTarget(designation: "M 101", commonNameHU: "Szélkerék-galaxis", raDeg: 210.803, decDeg: 54.349, kind: .galaxy, sizeArcmin: 28.8, magnitude: 7.9),
        CatalogTarget(designation: "M 102", commonNameHU: nil, raDeg: 226.623, decDeg: 55.763, kind: .galaxy, sizeArcmin: 4.7, magnitude: 9.9),
        CatalogTarget(designation: "M 103", commonNameHU: nil, raDeg: 23.3, decDeg: 60.7, kind: .openCluster, sizeArcmin: 6.0, magnitude: 7.4),
        CatalogTarget(designation: "M 104", commonNameHU: "Sombrero-galaxis", raDeg: 189.998, decDeg: -11.623, kind: .galaxy, sizeArcmin: 9.0, magnitude: 8.0),
        CatalogTarget(designation: "M 105", commonNameHU: nil, raDeg: 161.957, decDeg: 12.582, kind: .galaxy, sizeArcmin: 5.4, magnitude: 9.3),
        CatalogTarget(designation: "M 106", commonNameHU: nil, raDeg: 184.74, decDeg: 47.304, kind: .galaxy, sizeArcmin: 18.6, magnitude: 8.4),
        CatalogTarget(designation: "M 107", commonNameHU: nil, raDeg: 248.133, decDeg: -13.054, kind: .globularCluster, sizeArcmin: 10.0, magnitude: 7.9),
        CatalogTarget(designation: "M 108", commonNameHU: nil, raDeg: 167.879, decDeg: 55.674, kind: .galaxy, sizeArcmin: 8.7, magnitude: 10.0),
        CatalogTarget(designation: "M 109", commonNameHU: nil, raDeg: 179.4, decDeg: 53.374, kind: .galaxy, sizeArcmin: 7.6, magnitude: 9.8),
        CatalogTarget(designation: "M 110", commonNameHU: nil, raDeg: 10.092, decDeg: 41.685, kind: .galaxy, sizeArcmin: 21.9, magnitude: 8.5),
    ]

    // MARK: - Non-Messier popular targets

    /// 107 bright NGC/IC/Sharpless targets popular with astrophotographers
    /// (85 NGC, 15 IC, 7 Sh2) -- every coordinate individually verified
    /// against Wikipedia/SEDS/SIMBAD rather than recalled from memory;
    /// anything the check couldn't confirm was dropped rather than guessed.
    /// Every designation uses one of the three shapes `TargetNameResolver`
    /// understands (`"NGC <n>"`, `"IC <n>"`, `"Sh2-<n>"`); no Barnard/
    /// Caldwell/vdB numbers, since the resolver (and therefore
    /// `alreadyInLibrary` matching) has no way to produce those from a
    /// folder name anyway. Trailing `//` comments are the object's common
    /// English name, kept only as a human cross-reference -- NOT parsed by
    /// anything.
    ///
    /// A few `kind` notes: NGC 2244/2264/7380 are `.openCluster` by their
    /// PRIMARY classification (the NGC number designates the embedded star
    /// cluster), but keep the surrounding nebula's common name, since
    /// that's what an astrophotographer is actually pointing at (NGC 2237,
    /// the Rosette Nebula's own emission glow, is its own separate entry).
    /// IC 434 is the emission glow behind the Horsehead -- the Horsehead
    /// silhouette itself is the dark nebula Barnard 33, out of scope (no
    /// Barnard numbers, per this type's own designation-shape rule above).
    ///
    /// `commonNameHU`: reused verbatim from `CatalogNames.hungarian`
    /// wherever a designation appears in both tables (never contradicted --
    /// e.g. NGC 6960/NGC 7293 keep `CatalogNames`' "Fátyol-köd"/"Csiga-köd"
    /// even though a more specific translation exists, since the R10 rule
    /// is alignment, not precision); `nil` for anything with no confidently
    /// established Hungarian name rather than a fresh translation guess.
    private static let nonMessier: [CatalogTarget] = [
        CatalogTarget(designation: "NGC 40", commonNameHU: nil, raDeg: 3.3, decDeg: 72.5, kind: .planetaryNebula, sizeArcmin: 0.6, magnitude: 11.6), // Bow-Tie Nebula
        CatalogTarget(designation: "NGC 104", commonNameHU: nil, raDeg: 6.0, decDeg: -72.1, kind: .globularCluster, sizeArcmin: 43.8, magnitude: 4.1), // 47 Tucanae
        CatalogTarget(designation: "NGC 246", commonNameHU: nil, raDeg: 11.8, decDeg: -11.9, kind: .planetaryNebula, sizeArcmin: 3.8, magnitude: 8.0), // Skull Nebula
        CatalogTarget(designation: "NGC 253", commonNameHU: "Sculptor-galaxis", raDeg: 11.9, decDeg: -25.3, kind: .galaxy, sizeArcmin: 27.5, magnitude: 8.0), // Sculptor Galaxy
        CatalogTarget(designation: "NGC 281", commonNameHU: "Pacman-köd", raDeg: 13.2, decDeg: 56.6, kind: .emissionNebula, sizeArcmin: 35.0, magnitude: nil), // Pacman Nebula
        CatalogTarget(designation: "NGC 288", commonNameHU: nil, raDeg: 13.2, decDeg: -26.6, kind: .globularCluster, sizeArcmin: 13.8, magnitude: 9.4),
        CatalogTarget(designation: "NGC 300", commonNameHU: nil, raDeg: 13.7, decDeg: -37.7, kind: .galaxy, sizeArcmin: 21.9, magnitude: 9.0), // Sculptor Pinwheel Galaxy
        CatalogTarget(designation: "NGC 362", commonNameHU: nil, raDeg: 15.8, decDeg: -70.8, kind: .globularCluster, sizeArcmin: 12.9, magnitude: 6.4),
        CatalogTarget(designation: "NGC 457", commonNameHU: nil, raDeg: 19.9, decDeg: 58.3, kind: .openCluster, sizeArcmin: 13.0, magnitude: 6.4), // Owl Cluster
        CatalogTarget(designation: "NGC 663", commonNameHU: nil, raDeg: 26.5, decDeg: 61.3, kind: .openCluster, sizeArcmin: 16.0, magnitude: 7.1), // Lawnmower Cluster
        CatalogTarget(designation: "NGC 772", commonNameHU: nil, raDeg: 29.8, decDeg: 19.0, kind: .galaxy, sizeArcmin: 7.2, magnitude: 11.1), // Fiddlehead Galaxy
        CatalogTarget(designation: "NGC 869", commonNameHU: "Ikerhalmaz", raDeg: 34.8, decDeg: 57.2, kind: .openCluster, sizeArcmin: 30.0, magnitude: 3.7), // Double Cluster (h Persei)
        CatalogTarget(designation: "NGC 884", commonNameHU: "Ikerhalmaz", raDeg: 35.5, decDeg: 57.1, kind: .openCluster, sizeArcmin: 30.0, magnitude: 3.8), // Double Cluster (chi Persei)
        CatalogTarget(designation: "NGC 891", commonNameHU: nil, raDeg: 35.6, decDeg: 42.3, kind: .galaxy, sizeArcmin: 13.5, magnitude: 10.8), // Silver Sliver Galaxy
        CatalogTarget(designation: "NGC 1333", commonNameHU: nil, raDeg: 52.3, decDeg: 31.3, kind: .reflectionNebula, sizeArcmin: 6.0, magnitude: 5.6), // Embryo Nebula
        CatalogTarget(designation: "NGC 1435", commonNameHU: nil, raDeg: 56.5, decDeg: 23.9, kind: .reflectionNebula, sizeArcmin: 30.0, magnitude: 13.0), // Merope Nebula
        CatalogTarget(designation: "NGC 1499", commonNameHU: "Kalifornia-köd", raDeg: 60.8, decDeg: 36.4, kind: .emissionNebula, sizeArcmin: 150.0, magnitude: 6.0), // California Nebula
        CatalogTarget(designation: "NGC 1502", commonNameHU: nil, raDeg: 62.0, decDeg: 62.3, kind: .openCluster, sizeArcmin: 9.7, magnitude: 6.0), // Golden Harp Cluster
        CatalogTarget(designation: "NGC 1579", commonNameHU: nil, raDeg: 67.5, decDeg: 35.3, kind: .emissionNebula, sizeArcmin: 12.0, magnitude: nil), // Northern Trifid Nebula
        CatalogTarget(designation: "NGC 1893", commonNameHU: nil, raDeg: 80.7, decDeg: 33.4, kind: .openCluster, sizeArcmin: 11.0, magnitude: 7.5),
        CatalogTarget(designation: "NGC 1977", commonNameHU: nil, raDeg: 83.8, decDeg: -4.8, kind: .reflectionNebula, sizeArcmin: 40.0, magnitude: 7.0), // Running Man Nebula
        CatalogTarget(designation: "NGC 2024", commonNameHU: "Láng-köd", raDeg: 85.5, decDeg: -1.9, kind: .emissionNebula, sizeArcmin: 30.0, magnitude: 10.0), // Flame Nebula
        CatalogTarget(designation: "NGC 2070", commonNameHU: "Tarantula-köd", raDeg: 84.7, decDeg: -69.1, kind: .emissionNebula, sizeArcmin: 40.0, magnitude: 8.0), // Tarantula Nebula
        CatalogTarget(designation: "NGC 2237", commonNameHU: "Rozetta-köd", raDeg: 98.4, decDeg: 5.0, kind: .emissionNebula, sizeArcmin: 78.0, magnitude: 9.0), // Rosette Nebula
        CatalogTarget(designation: "NGC 2244", commonNameHU: "Rozetta-köd", raDeg: 98.0, decDeg: 4.9, kind: .openCluster, sizeArcmin: 24.0, magnitude: 4.8), // Satellite Cluster
        CatalogTarget(designation: "NGC 2264", commonNameHU: "Karácsonyfa-halmaz", raDeg: 100.3, decDeg: 9.9, kind: .openCluster, sizeArcmin: 20.0, magnitude: 3.9), // Christmas Tree Cluster
        CatalogTarget(designation: "NGC 2359", commonNameHU: "Thor sisakja", raDeg: 109.6, decDeg: -13.2, kind: .emissionNebula, sizeArcmin: 8.0, magnitude: 11.5), // Thor's Helmet
        CatalogTarget(designation: "NGC 2392", commonNameHU: "Eszkimó-köd", raDeg: 112.3, decDeg: 20.9, kind: .planetaryNebula, sizeArcmin: 0.8, magnitude: 10.1), // Eskimo Nebula
        CatalogTarget(designation: "NGC 2403", commonNameHU: nil, raDeg: 114.2, decDeg: 65.6, kind: .galaxy, sizeArcmin: 21.9, magnitude: 8.9),
        CatalogTarget(designation: "NGC 2419", commonNameHU: nil, raDeg: 114.5, decDeg: 38.9, kind: .globularCluster, sizeArcmin: 6.0, magnitude: 9.1), // Intergalactic Wanderer
        CatalogTarget(designation: "NGC 2438", commonNameHU: nil, raDeg: 115.5, decDeg: -14.7, kind: .planetaryNebula, sizeArcmin: 1.1, magnitude: 10.8),
        CatalogTarget(designation: "NGC 2516", commonNameHU: nil, raDeg: 119.6, decDeg: -60.9, kind: .openCluster, sizeArcmin: 30.0, magnitude: 3.8), // Southern Beehive Cluster
        CatalogTarget(designation: "NGC 2683", commonNameHU: nil, raDeg: 133.2, decDeg: 33.4, kind: .galaxy, sizeArcmin: 9.3, magnitude: 10.6), // UFO Galaxy
        CatalogTarget(designation: "NGC 2903", commonNameHU: nil, raDeg: 143.0, decDeg: 21.5, kind: .galaxy, sizeArcmin: 11.5, magnitude: 9.0),
        CatalogTarget(designation: "NGC 3079", commonNameHU: nil, raDeg: 150.5, decDeg: 55.7, kind: .galaxy, sizeArcmin: 7.9, magnitude: 11.5),
        CatalogTarget(designation: "NGC 3132", commonNameHU: nil, raDeg: 151.8, decDeg: -40.4, kind: .planetaryNebula, sizeArcmin: 1.0, magnitude: 9.9), // Eight-Burst Nebula
        CatalogTarget(designation: "NGC 3242", commonNameHU: "Jupiter szelleme", raDeg: 156.2, decDeg: -18.6, kind: .planetaryNebula, sizeArcmin: 0.4, magnitude: 8.6), // Ghost of Jupiter
        CatalogTarget(designation: "NGC 3372", commonNameHU: nil, raDeg: 161.3, decDeg: -59.9, kind: .emissionNebula, sizeArcmin: 120.0, magnitude: 1.0), // Carina Nebula
        CatalogTarget(designation: "NGC 3532", commonNameHU: nil, raDeg: 166.6, decDeg: -58.7, kind: .openCluster, sizeArcmin: 55.0, magnitude: 3.0), // Wishing Well Cluster
        CatalogTarget(designation: "NGC 3628", commonNameHU: "Hamburger-galaxis", raDeg: 170.1, decDeg: 13.6, kind: .galaxy, sizeArcmin: 14.0, magnitude: 9.5), // Hamburger Galaxy
        CatalogTarget(designation: "NGC 3766", commonNameHU: nil, raDeg: 174.0, decDeg: -61.6, kind: .openCluster, sizeArcmin: 12.0, magnitude: 5.3),
        CatalogTarget(designation: "NGC 4038", commonNameHU: "Csáp-galaxisok", raDeg: 180.5, decDeg: -18.9, kind: .galaxy, sizeArcmin: 5.2, magnitude: 11.2), // Antennae Galaxies
        CatalogTarget(designation: "NGC 4039", commonNameHU: "Csáp-galaxisok", raDeg: 180.5, decDeg: -18.9, kind: .galaxy, sizeArcmin: 3.1, magnitude: 11.1), // Antennae Galaxies
        CatalogTarget(designation: "NGC 4244", commonNameHU: nil, raDeg: 184.4, decDeg: 37.8, kind: .galaxy, sizeArcmin: 17.0, magnitude: 10.2), // Silver Needle Galaxy
        CatalogTarget(designation: "NGC 4449", commonNameHU: nil, raDeg: 187.0, decDeg: 44.1, kind: .galaxy, sizeArcmin: 6.2, magnitude: 10.0),
        CatalogTarget(designation: "NGC 4490", commonNameHU: nil, raDeg: 187.7, decDeg: 41.6, kind: .galaxy, sizeArcmin: 6.3, magnitude: 9.8), // Cocoon Galaxy
        CatalogTarget(designation: "NGC 4565", commonNameHU: "Tű-galaxis", raDeg: 189.1, decDeg: 26.0, kind: .galaxy, sizeArcmin: 15.9, magnitude: 10.4), // Needle Galaxy
        CatalogTarget(designation: "NGC 4631", commonNameHU: "Bálna-galaxis", raDeg: 190.5, decDeg: 32.5, kind: .galaxy, sizeArcmin: 15.5, magnitude: 9.8), // Whale Galaxy
        CatalogTarget(designation: "NGC 4833", commonNameHU: nil, raDeg: 194.9, decDeg: -70.9, kind: .globularCluster, sizeArcmin: 13.5, magnitude: 7.8),
        CatalogTarget(designation: "NGC 5128", commonNameHU: nil, raDeg: 201.4, decDeg: -43.0, kind: .galaxy, sizeArcmin: 25.7, magnitude: 6.8), // Centaurus A
        CatalogTarget(designation: "NGC 5139", commonNameHU: nil, raDeg: 201.7, decDeg: -47.5, kind: .globularCluster, sizeArcmin: 36.3, magnitude: 3.9), // Omega Centauri
        CatalogTarget(designation: "NGC 5195", commonNameHU: nil, raDeg: 202.5, decDeg: 47.3, kind: .galaxy, sizeArcmin: 5.8, magnitude: 10.5),
        CatalogTarget(designation: "NGC 5286", commonNameHU: nil, raDeg: 206.6, decDeg: -51.4, kind: .globularCluster, sizeArcmin: 9.1, magnitude: 7.6),
        CatalogTarget(designation: "NGC 5907", commonNameHU: nil, raDeg: 229.0, decDeg: 56.3, kind: .galaxy, sizeArcmin: 12.7, magnitude: 11.1), // Splinter Galaxy
        CatalogTarget(designation: "NGC 6164", commonNameHU: "Sárkánytojás-köd", raDeg: 248.4, decDeg: -48.1, kind: .emissionNebula, sizeArcmin: 3.0, magnitude: nil), // Dragon's Egg Nebula
        CatalogTarget(designation: "NGC 6165", commonNameHU: "Sárkánytojás-köd", raDeg: 248.5, decDeg: -48.2, kind: .emissionNebula, sizeArcmin: 2.5, magnitude: nil), // Dragon's Egg Nebula
        CatalogTarget(designation: "NGC 6188", commonNameHU: nil, raDeg: 250.0, decDeg: -48.8, kind: .emissionNebula, sizeArcmin: 20.0, magnitude: nil), // Fighting Dragons of Ara
        CatalogTarget(designation: "NGC 6210", commonNameHU: nil, raDeg: 251.1, decDeg: 23.8, kind: .planetaryNebula, sizeArcmin: 0.7, magnitude: 9.6), // Turtle Nebula
        CatalogTarget(designation: "NGC 6231", commonNameHU: nil, raDeg: 253.5, decDeg: -41.8, kind: .openCluster, sizeArcmin: 15.0, magnitude: 2.6), // Baby Scorpion Cluster
        CatalogTarget(designation: "NGC 6334", commonNameHU: "Macskamancs-köd", raDeg: 260.2, decDeg: -36.1, kind: .emissionNebula, sizeArcmin: 35.0, magnitude: nil), // Cat's Paw Nebula
        CatalogTarget(designation: "NGC 6357", commonNameHU: "Homár-köd", raDeg: 261.2, decDeg: -34.2, kind: .emissionNebula, sizeArcmin: 50.0, magnitude: nil), // Lobster Nebula
        CatalogTarget(designation: "NGC 6397", commonNameHU: nil, raDeg: 265.2, decDeg: -53.7, kind: .globularCluster, sizeArcmin: 32.0, magnitude: 6.7),
        CatalogTarget(designation: "NGC 6503", commonNameHU: nil, raDeg: 267.4, decDeg: 70.1, kind: .galaxy, sizeArcmin: 7.1, magnitude: 10.2), // Lost-in-Space Galaxy
        CatalogTarget(designation: "NGC 6541", commonNameHU: nil, raDeg: 272.0, decDeg: -43.7, kind: .globularCluster, sizeArcmin: 15.0, magnitude: 6.3),
        CatalogTarget(designation: "NGC 6543", commonNameHU: "Macskaszem-köd", raDeg: 269.6, decDeg: 66.6, kind: .planetaryNebula, sizeArcmin: 0.3, magnitude: 8.1), // Cat's Eye Nebula
        CatalogTarget(designation: "NGC 6752", commonNameHU: nil, raDeg: 287.7, decDeg: -60.0, kind: .globularCluster, sizeArcmin: 20.4, magnitude: 5.4), // Great Peacock Globular
        CatalogTarget(designation: "NGC 6772", commonNameHU: nil, raDeg: 288.7, decDeg: -2.7, kind: .planetaryNebula, sizeArcmin: 1.1, magnitude: 12.7),
        CatalogTarget(designation: "NGC 6819", commonNameHU: nil, raDeg: 295.3, decDeg: 40.2, kind: .openCluster, sizeArcmin: 5.0, magnitude: 7.3), // Foxhead Cluster
        CatalogTarget(designation: "NGC 6820", commonNameHU: nil, raDeg: 295.6, decDeg: 23.1, kind: .emissionNebula, sizeArcmin: 40.0, magnitude: nil),
        CatalogTarget(designation: "NGC 6822", commonNameHU: "Barnard-galaxis", raDeg: 296.2, decDeg: -14.8, kind: .galaxy, sizeArcmin: 15.5, magnitude: 9.3), // Barnard's Galaxy
        CatalogTarget(designation: "NGC 6823", commonNameHU: nil, raDeg: 295.8, decDeg: 23.3, kind: .openCluster, sizeArcmin: 6.0, magnitude: 7.1),
        CatalogTarget(designation: "NGC 6888", commonNameHU: "Sarló-köd", raDeg: 303.0, decDeg: 38.4, kind: .emissionNebula, sizeArcmin: 18.0, magnitude: 7.4), // Crescent Nebula
        CatalogTarget(designation: "NGC 6946", commonNameHU: "Tűzijáték-galaxis", raDeg: 308.7, decDeg: 60.2, kind: .galaxy, sizeArcmin: 16.0, magnitude: 9.6), // Fireworks Galaxy
        CatalogTarget(designation: "NGC 6960", commonNameHU: "Fátyol-köd", raDeg: 311.4, decDeg: 30.7, kind: .supernovaRemnant, sizeArcmin: 70.0, magnitude: 7.0), // Witch's Broom Nebula
        CatalogTarget(designation: "NGC 6992", commonNameHU: "Fátyol-köd", raDeg: 314.1, decDeg: 31.7, kind: .supernovaRemnant, sizeArcmin: 70.0, magnitude: 7.0), // Eastern Veil Nebula
        CatalogTarget(designation: "NGC 7000", commonNameHU: "Észak-Amerika-köd", raDeg: 314.8, decDeg: 44.5, kind: .emissionNebula, sizeArcmin: 120.0, magnitude: 4.0), // North America Nebula
        CatalogTarget(designation: "NGC 7009", commonNameHU: "Szaturnusz-köd", raDeg: 316.0, decDeg: -11.4, kind: .planetaryNebula, sizeArcmin: 0.7, magnitude: 8.0), // Saturn Nebula
        CatalogTarget(designation: "NGC 7023", commonNameHU: "Írisz-köd", raDeg: 315.4, decDeg: 68.2, kind: .reflectionNebula, sizeArcmin: 18.0, magnitude: 6.8), // Iris Nebula
        CatalogTarget(designation: "NGC 7217", commonNameHU: nil, raDeg: 332.0, decDeg: 31.4, kind: .galaxy, sizeArcmin: 3.9, magnitude: 11.0), // Ringed Spiral Galaxy
        CatalogTarget(designation: "NGC 7293", commonNameHU: "Csiga-köd", raDeg: 337.4, decDeg: -20.8, kind: .planetaryNebula, sizeArcmin: 25.0, magnitude: 7.6), // Helix Nebula
        CatalogTarget(designation: "NGC 7331", commonNameHU: nil, raDeg: 339.3, decDeg: 34.4, kind: .galaxy, sizeArcmin: 10.5, magnitude: 10.4), // Deer Lick Group
        CatalogTarget(designation: "NGC 7380", commonNameHU: "Varázsló-köd", raDeg: 341.8, decDeg: 58.1, kind: .openCluster, sizeArcmin: 25.0, magnitude: 7.2), // Wizard Nebula
        CatalogTarget(designation: "NGC 7635", commonNameHU: "Buborék-köd", raDeg: 350.2, decDeg: 61.2, kind: .emissionNebula, sizeArcmin: 15.0, magnitude: 10.0), // Bubble Nebula
        CatalogTarget(designation: "NGC 7789", commonNameHU: "Caroline Rózsája", raDeg: 359.4, decDeg: 56.7, kind: .openCluster, sizeArcmin: 16.0, magnitude: 6.7), // Caroline's Rose
        CatalogTarget(designation: "NGC 7814", commonNameHU: "Kis Sombrero-galaxis", raDeg: 0.8, decDeg: 16.1, kind: .galaxy, sizeArcmin: 5.5, magnitude: 11.6), // Little Sombrero Galaxy
        CatalogTarget(designation: "IC 63", commonNameHU: nil, raDeg: 14.8, decDeg: 60.9, kind: .emissionNebula, sizeArcmin: 10.0, magnitude: 13.3), // Ghost of Cassiopeia
        CatalogTarget(designation: "IC 405", commonNameHU: nil, raDeg: 79.0, decDeg: 34.5, kind: .emissionNebula, sizeArcmin: 37.0, magnitude: 6.0), // Flaming Star Nebula
        CatalogTarget(designation: "IC 410", commonNameHU: nil, raDeg: 80.5, decDeg: 33.5, kind: .emissionNebula, sizeArcmin: 55.0, magnitude: nil), // Tadpole Nebula
        CatalogTarget(designation: "IC 434", commonNameHU: "Lófej-köd térsége", raDeg: 85.2, decDeg: -2.5, kind: .emissionNebula, sizeArcmin: 60.0, magnitude: 4.5), // Horsehead Nebula
        CatalogTarget(designation: "IC 443", commonNameHU: "Medúza-köd", raDeg: 94.3, decDeg: 22.5, kind: .supernovaRemnant, sizeArcmin: 50.0, magnitude: 12.0), // Jellyfish Nebula
        CatalogTarget(designation: "IC 1396", commonNameHU: "Elefántormány-köd", raDeg: 324.7, decDeg: 57.5, kind: .emissionNebula, sizeArcmin: 170.0, magnitude: 5.6), // Elephant's Trunk Nebula
        CatalogTarget(designation: "IC 1805", commonNameHU: "Szív-köd", raDeg: 38.3, decDeg: 61.4, kind: .emissionNebula, sizeArcmin: 150.0, magnitude: 6.5), // Heart Nebula
        CatalogTarget(designation: "IC 1848", commonNameHU: "Lélek-köd", raDeg: 43.9, decDeg: 60.4, kind: .emissionNebula, sizeArcmin: 150.0, magnitude: 6.5), // Soul Nebula
        CatalogTarget(designation: "IC 2118", commonNameHU: nil, raDeg: 75.5, decDeg: -7.9, kind: .reflectionNebula, sizeArcmin: 180.0, magnitude: 13.0), // Witch Head Nebula
        CatalogTarget(designation: "IC 2602", commonNameHU: nil, raDeg: 160.7, decDeg: -64.4, kind: .openCluster, sizeArcmin: 50.0, magnitude: 1.9), // Southern Pleiades
        CatalogTarget(designation: "IC 2944", commonNameHU: nil, raDeg: 174.2, decDeg: -63.0, kind: .emissionNebula, sizeArcmin: 75.0, magnitude: 4.5), // Running Chicken Nebula
        CatalogTarget(designation: "IC 4628", commonNameHU: nil, raDeg: 254.2, decDeg: -40.5, kind: .emissionNebula, sizeArcmin: 90.0, magnitude: 7.3), // Prawn Nebula
        CatalogTarget(designation: "IC 5070", commonNameHU: "Pelikán-köd", raDeg: 312.7, decDeg: 44.4, kind: .emissionNebula, sizeArcmin: 60.0, magnitude: 8.0), // Pelican Nebula
        CatalogTarget(designation: "IC 5146", commonNameHU: "Gubó-köd", raDeg: 328.4, decDeg: 47.3, kind: .emissionNebula, sizeArcmin: 12.0, magnitude: 7.2), // Cocoon Nebula
        CatalogTarget(designation: "IC 5148", commonNameHU: nil, raDeg: 329.9, decDeg: -39.4, kind: .planetaryNebula, sizeArcmin: 2.0, magnitude: 16.5), // Spare Tyre Nebula
        CatalogTarget(designation: "Sh2-101", commonNameHU: "Tulipán-köd", raDeg: 300.0, decDeg: 35.3, kind: .emissionNebula, sizeArcmin: 16.0, magnitude: 9.0), // Tulip Nebula
        CatalogTarget(designation: "Sh2-115", commonNameHU: nil, raDeg: 308.8, decDeg: 47.0, kind: .emissionNebula, sizeArcmin: nil, magnitude: nil), // Sharpless 115
        CatalogTarget(designation: "Sh2-129", commonNameHU: "Repülő Denevér", raDeg: 318.0, decDeg: 60.0, kind: .emissionNebula, sizeArcmin: 140.0, magnitude: nil), // Flying Bat Nebula
        CatalogTarget(designation: "Sh2-132", commonNameHU: nil, raDeg: 334.8, decDeg: 56.1, kind: .emissionNebula, sizeArcmin: 42.0, magnitude: nil), // Lion Nebula
        CatalogTarget(designation: "Sh2-155", commonNameHU: "Barlang-köd", raDeg: 344.3, decDeg: 62.6, kind: .emissionNebula, sizeArcmin: 50.0, magnitude: 7.7), // Cave Nebula
        CatalogTarget(designation: "Sh2-157", commonNameHU: nil, raDeg: 349.0, decDeg: 60.0, kind: .emissionNebula, sizeArcmin: 3.3, magnitude: nil), // Lobster Claw Nebula
        CatalogTarget(designation: "Sh2-240", commonNameHU: nil, raDeg: 84.8, decDeg: 28.0, kind: .supernovaRemnant, sizeArcmin: 180.0, magnitude: nil), // Spaghetti Nebula
    ]
}
