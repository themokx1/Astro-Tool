import Foundation
import Testing
@testable import AstroCore

// MARK: - Messier

@Test func resolverParsesMessierNumberWithCommonName() {
    let resolved = TargetNameResolver.resolve(folderName: "M42_Orion_wide_field")
    #expect(resolved.designation == "M 42")
    #expect(resolved.properName == "Orion-köd")
    #expect(resolved.displayName == "M 42 · Orion-köd")
}

@Test func resolverParsesMessierNumberWithoutCommonName() {
    // M2 (a globular cluster) has no Hungarian common name in the table.
    let resolved = TargetNameResolver.resolve(folderName: "M2_globular")
    #expect(resolved.designation == "M 2")
    #expect(resolved.properName == nil)
    #expect(resolved.displayName == "M 2")
}

// MARK: - NGC (single token and underscore-separated)

@Test func resolverParsesNGCUnderscoreSeparatedNumber() {
    let resolved = TargetNameResolver.resolve(folderName: "NGC_7000_North_American_Nebula")
    #expect(resolved.designation == "NGC 7000")
    #expect(resolved.properName == "Észak-Amerika-köd")
    #expect(resolved.displayName == "NGC 7000 · Észak-Amerika-köd")
}

@Test func resolverParsesNGCSingleTokenNumber() {
    let resolved = TargetNameResolver.resolve(folderName: "NGC7000_wide")
    #expect(resolved.designation == "NGC 7000")
    #expect(resolved.displayName == "NGC 7000 · Észak-Amerika-köd")
}

// MARK: - IC range

@Test func resolverParsesICRangeWithCombinedName() {
    let resolved = TargetNameResolver.resolve(folderName: "IC1805-1848_Heart-and-Soul_Nebula")
    #expect(resolved.designation == "IC 1805–1848")
    #expect(resolved.properName == "Szív- és Lélek-köd")
    #expect(resolved.displayName == "IC 1805–1848 · Szív- és Lélek-köd")
}

@Test func resolverParsesSingleICNumber() {
    let resolved = TargetNameResolver.resolve(folderName: "IC434_Horsehead")
    #expect(resolved.designation == "IC 434")
    #expect(resolved.properName == "Lófej-köd térsége")
}

// MARK: - Sh2

@Test func resolverParsesSh2HyphenForm() {
    let resolved = TargetNameResolver.resolve(folderName: "Sh2-129_Flying_Bat")
    #expect(resolved.designation == "Sh2-129")
    #expect(resolved.properName == "Repülő Denevér")
    #expect(resolved.displayName == "Sh2-129 · Repülő Denevér")
}

@Test func resolverParsesSh2UnderscoreForm() {
    let resolved = TargetNameResolver.resolve(folderName: "Sh2_101_Tulip")
    #expect(resolved.designation == "Sh2-101")
    #expect(resolved.properName == "Tulipán-köd")
}

// MARK: - Comet dedup

@Test func resolverParsesDuplicatedCometDesignation() {
    let resolved = TargetNameResolver.resolve(folderName: "C2025_R3_C2025_R3_Panstarrs")
    #expect(resolved.designation == "C/2025 R3")
    #expect(resolved.displayName == "C/2025 R3")
}

@Test func resolverParsesCometDesignationWithoutDuplication() {
    let resolved = TargetNameResolver.resolve(folderName: "C2025_R3_Panstarrs")
    #expect(resolved.designation == "C/2025 R3")
}

// MARK: - isComet

@Test func resolverFlagsCometDesignationAsComet() {
    let resolved = TargetNameResolver.resolve(folderName: "C2025_R3_Panstarrs")
    #expect(resolved.isComet)
}

@Test func resolverDoesNotFlagOrdinaryCatalogTargetAsComet() {
    let resolved = TargetNameResolver.resolve(folderName: "M42_Orion_wide_field")
    #expect(!resolved.isComet)
}

// MARK: - M_ with no digits (special-case, no designation)

@Test func resolverResolvesBareMFolderByKeywordWithNoDesignation() {
    let resolved = TargetNameResolver.resolve(folderName: "M_Milky_Way")
    #expect(resolved.designation == nil)
    #expect(resolved.properName == "Tejút")
    #expect(resolved.displayName == "Tejút")
}

@Test func resolverStillResolvesMessierWhenMUnderscoreIsFollowedByDigits() {
    // "M_42_Orion" (underscore between M and the number) must still resolve
    // as Messier 42 -- the "no designation" special case is specifically
    // for an M_ folder with NO catalog number following, like M_Milky_Way.
    let resolved = TargetNameResolver.resolve(folderName: "M_42_Orion")
    #expect(resolved.designation == "M 42")
}

// MARK: - Unknown junk -> cleaned folder-name fallback

@Test func resolverFallsBackToCleanedFolderNameForUnrecognizedJunk() {
    let resolved = TargetNameResolver.resolve(folderName: "Random_Test_Target_70mm")
    #expect(resolved.designation == nil)
    #expect(resolved.properName == nil)
    #expect(resolved.displayName == "Random Test Target 70mm")
}

// MARK: - displayName composition rules

@Test func resolverDisplayNameIsDesignationAloneWhenNoProperNameKnown() {
    let resolved = TargetNameResolver.resolve(folderName: "NGC891_edge_on")
    #expect(resolved.designation == "NGC 891")
    #expect(resolved.properName == nil)
    #expect(resolved.displayName == "NGC 891")
}

// MARK: - Codable / Equatable sanity

@Test func resolvedTargetNameRoundTripsThroughJSON() throws {
    let resolved = TargetNameResolver.resolve(folderName: "M42_Orion_wide_field")
    let data = try JSONEncoder().encode(resolved)
    let decoded = try JSONDecoder().decode(ResolvedTargetName.self, from: data)
    #expect(decoded == resolved)
}

// MARK: - NameTag override

@Test func nameTagParsesOverrideText() {
    #expect(NameTag.parse(tags: ["name:Custom Name", "other"]) == "Custom Name")
}

@Test func nameTagReturnsNilWithoutMatchingTag() {
    #expect(NameTag.parse(tags: ["goal:6h", "other"]) == nil)
}

@Test func nameTagApplyOverridesPropernameAndRecomposesDisplayNameWithDesignation() {
    let resolved = TargetNameResolver.resolve(folderName: "NGC_7000_North_American_Nebula")
    let overridden = NameTag.apply(to: resolved, tags: ["name:Custom Common Name"])
    #expect(overridden.designation == "NGC 7000")
    #expect(overridden.properName == "Custom Common Name")
    #expect(overridden.displayName == "NGC 7000 · Custom Common Name")
}

@Test func nameTagApplyOverridesDisplayNameAloneWhenNoDesignation() {
    let resolved = TargetNameResolver.resolve(folderName: "Random_Junk")
    let overridden = NameTag.apply(to: resolved, tags: ["name:Custom Name"])
    #expect(overridden.designation == nil)
    #expect(overridden.displayName == "Custom Name")
}

@Test func nameTagApplyReturnsResolvedUnchangedWithoutOverrideTag() {
    let resolved = TargetNameResolver.resolve(folderName: "M42_Orion")
    let overridden = NameTag.apply(to: resolved, tags: ["goal:6h"])
    #expect(overridden == resolved)
}
