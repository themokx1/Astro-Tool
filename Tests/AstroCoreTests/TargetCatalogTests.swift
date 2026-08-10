import Foundation
import Testing
@testable import AstroCore

// MARK: - No duplicate designations

@Test func catalogHasNoDuplicateDesignations() {
    let designations = TargetCatalog.all.map(\.designation)
    let duplicates = Dictionary(grouping: designations, by: { $0 }).filter { $0.value.count > 1 }.keys
    #expect(designations.count == Set(designations).count, "duplicate designation(s): \(Array(duplicates))")
}

// MARK: - Coordinate ranges

@Test func catalogRightAscensionsAreInZeroToThreeSixtyRange() {
    for target in TargetCatalog.all {
        #expect(target.raDeg >= 0 && target.raDeg < 360, "\(target.designation) raDeg=\(target.raDeg) outside [0, 360)")
    }
}

@Test func catalogDeclinationsAreInValidRange() {
    for target in TargetCatalog.all {
        #expect(target.decDeg >= -90 && target.decDeg <= 90, "\(target.designation) decDeg=\(target.decDeg) outside [-90, 90]")
    }
}

// MARK: - All 110 Messier objects present exactly once

@Test func catalogContainsEveryMessierNumberExactlyOnce() {
    let messierEntries = TargetCatalog.all.filter { $0.designation.hasPrefix("M ") }
    let designations = messierEntries.map(\.designation)
    let expected = Set((1...110).map { "M \($0)" })

    #expect(Set(designations) == expected)
    #expect(designations.count == 110, "expected exactly 110 Messier entries, found \(designations.count)")
}

@Test func catalogHasAtLeastEightyNonMessierEntries() {
    let nonMessierCount = TargetCatalog.all.filter { !$0.designation.hasPrefix("M ") }.count
    #expect(nonMessierCount >= 80, "expected at least 80 non-Messier entries, found \(nonMessierCount)")
}

// MARK: - Designations parse through TargetNameResolver's own normalization

/// Every catalog designation is built from one of the shapes
/// `TargetNameResolver` itself produces (`"M <n>"`, `"NGC <n>"`,
/// `"IC <n>"`, `"Sh2-<n>"`) -- turning it into a plausible on-disk folder
/// name (spaces -> underscores; `Sh2-<n>` already has no spaces) and
/// resolving that back must reproduce the SAME designation byte-for-byte,
/// since `DiscoveryPlanner.discover`'s `alreadyInLibrary` flag is a plain
/// set-membership check between the two. Checked across every entry
/// (cheap, and every designation in this catalog is constrained to those
/// four shapes on purpose -- see `TargetCatalog`'s own doc comment) rather
/// than a hardcoded handful, so this doesn't silently stop covering
/// whichever non-Messier entries happen to be in the table.
@Test func everyCatalogDesignationRoundTripsThroughTargetNameResolver() {
    for target in TargetCatalog.all {
        let folderName = target.designation.replacingOccurrences(of: " ", with: "_")
        let resolved = TargetNameResolver.resolve(folderName: folderName)
        #expect(
            resolved.designation == target.designation,
            "designation=\(target.designation) folderName=\(folderName) resolved to \(resolved.designation ?? "nil")"
        )
    }
}

/// Named spot-checks (task's own wording) across each of the four
/// catalog-designation shapes in use, independent of the generic
/// round-trip sweep above -- these four are guaranteed present regardless
/// of exactly which non-Messier entries a given catalog revision carries.
@Test func spotCheckedDesignationsResolveToExpectedCatalogShape() throws {
    let m42 = try #require(TargetCatalog.all.first { $0.designation == "M 42" })
    #expect(TargetNameResolver.resolve(folderName: "M_42").designation == m42.designation)

    let m110 = try #require(TargetCatalog.all.first { $0.designation == "M 110" })
    #expect(TargetNameResolver.resolve(folderName: "M_110").designation == m110.designation)

    // At least one NGC/IC/Sh2 entry each -- whatever they are, they must
    // exist (the catalog isn't Messier-only) and must round-trip.
    let ngc = try #require(TargetCatalog.all.first { $0.designation.hasPrefix("NGC ") })
    #expect(TargetNameResolver.resolve(folderName: ngc.designation.replacingOccurrences(of: " ", with: "_")).designation == ngc.designation)

    let ic = try #require(TargetCatalog.all.first { $0.designation.hasPrefix("IC ") })
    #expect(TargetNameResolver.resolve(folderName: ic.designation.replacingOccurrences(of: " ", with: "_")).designation == ic.designation)

    let sh2 = try #require(TargetCatalog.all.first { $0.designation.hasPrefix("Sh2-") })
    #expect(TargetNameResolver.resolve(folderName: sh2.designation).designation == sh2.designation)
}

// MARK: - Sizes/magnitudes non-negative where present

@Test func catalogSizesAreNonNegativeWherePresent() {
    for target in TargetCatalog.all {
        if let size = target.sizeArcmin {
            #expect(size >= 0, "\(target.designation) has negative sizeArcmin \(size)")
        }
    }
}

@Test func catalogMagnitudesAreNonNegativeWherePresent() {
    for target in TargetCatalog.all {
        if let magnitude = target.magnitude {
            #expect(magnitude >= 0, "\(target.designation) has negative magnitude \(magnitude)")
        }
    }
}

// MARK: - Hungarian common names never contradict CatalogNames

/// `CatalogTarget.commonNameHU` is documented to ALIGN with
/// `CatalogNames.hungarian`, never contradict it -- for every designation
/// the two tables both cover, the text must be identical.
@Test func catalogCommonNamesNeverContradictCatalogNames() {
    for target in TargetCatalog.all {
        guard let existing = CatalogNames.hungarian[target.designation] else { continue }
        #expect(target.commonNameHU == existing, "\(target.designation): TargetCatalog says \(target.commonNameHU ?? "nil"), CatalogNames says \(existing)")
    }
}

// MARK: - Human search and canonical session folders

@Test func catalogSearchFindsTargetByCompactDesignation() throws {
    let result = try #require(TargetCatalog.search("ic1396").first)
    #expect(result.designation == "IC 1396")
}

@Test func catalogSearchFindsTargetByEnglishCommonName() throws {
    let result = try #require(TargetCatalog.search("elephant trunk").first)
    #expect(result.designation == "IC 1396")
    #expect(TargetCatalog.englishName(for: result) == "Elephant's Trunk Nebula")
}

@Test func catalogSearchFindsTargetByAccentlessHungarianName() throws {
    let result = try #require(TargetCatalog.search("elefantormany").first)
    #expect(result.designation == "IC 1396")
}

@Test func catalogCanonicalFolderUsesStableEnglishName() throws {
    let target = try #require(TargetCatalog.all.first { $0.designation == "IC 1396" })
    #expect(TargetCatalog.canonicalFolderName(for: target) == "IC_1396_Elephants_Trunk_Nebula")
}

@Test func existingFolderForCatalogTargetPreventsSpellingDuplicate() throws {
    let target = try #require(TargetCatalog.all.first { $0.designation == "IC 1396" })
    let existing = TargetCatalog.existingFolder(
        for: target,
        among: ["M42_Orion_Nebula", "IC_1396_Elephants_Trunk_Nebula", "IC1396_elefant_kod"]
    )
    #expect(existing == "IC_1396_Elephants_Trunk_Nebula")
}

@Test func catalogSurfaceBrightnessUsesMagnitudeAndAngularArea() throws {
    let target = try #require(TargetCatalog.all.first { $0.designation == "M 42" })
    let brightness = try #require(TargetCatalog.estimatedSurfaceBrightness(for: target))

    #expect(brightness > (target.magnitude ?? 0))
    #expect(brightness > 21 && brightness < 23)
}
