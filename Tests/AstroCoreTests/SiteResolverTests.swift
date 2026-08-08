import Foundation
import Testing
@testable import AstroCore

// MARK: - haversineDistanceKm

@Test func haversineDistanceIsZeroForIdenticalPoints() {
    let distance = SiteResolver.haversineDistanceKm(lat1: 47.5, lon1: 19.0, lat2: 47.5, lon2: 19.0)
    #expect(distance == 0)
}

/// Budapest to Vienna is roughly 210 km -- a coarse sanity bound (not an
/// exact assertion, the haversine formula's own accuracy is well-established
/// elsewhere), just confirming this isn't off by an order of magnitude.
@Test func haversineDistanceMatchesKnownRoughDistance() {
    let distance = SiteResolver.haversineDistanceKm(lat1: 47.4979, lon1: 19.0402, lat2: 48.2082, lon2: 16.3738)
    #expect(distance > 180 && distance < 230)
}

@Test func haversineDistanceIsSymmetric() {
    let a = SiteResolver.haversineDistanceKm(lat1: 47.5, lon1: 19.0, lat2: 46.0, lon2: 18.0)
    let b = SiteResolver.haversineDistanceKm(lat1: 46.0, lon1: 18.0, lat2: 47.5, lon2: 19.0)
    #expect(abs(a - b) < 0.0001)
}

// MARK: - siteTagName

@Test func siteTagNameParsesFirstMatchingTag() {
    #expect(SiteResolver.siteTagName(tags: ["hibas", "site:Kert", "note:x"]) == "Kert")
}

@Test func siteTagNameIsCaseInsensitivePrefix() {
    #expect(SiteResolver.siteTagName(tags: ["SITE:Hegy"]) == "Hegy")
}

@Test func siteTagNameTrimsWhitespace() {
    #expect(SiteResolver.siteTagName(tags: ["site:  Kert  "]) == "Kert")
}

@Test func siteTagNameSkipsEmptyNameAfterPrefix() {
    #expect(SiteResolver.siteTagName(tags: ["site:", "site:   "]) == nil)
}

@Test func siteTagNameNilWhenNoTagMatches() {
    #expect(SiteResolver.siteTagName(tags: ["hibas", "goal:6h"]) == nil)
}

@Test func siteTagNameFirstMatchWinsOverLater() {
    #expect(SiteResolver.siteTagName(tags: ["site:First", "site:Second"]) == "First")
}

// MARK: - resolve(sessionTags:medianLat:medianLon:sites:maxDistanceKm:)

private let kert = SiteProfile(name: "Kert", latitudeDeg: 47.5, longitudeDeg: 19.0)
private let hegy = SiteProfile(name: "Hegy", latitudeDeg: 46.0, longitudeDeg: 18.0)

@Test func resolvePicksNearestSiteWithinThreshold() {
    // ~0.01 deg off Kert -- well within 50 km.
    let result = SiteResolver.resolve(sessionTags: [], medianLat: 47.51, medianLon: 19.01, sites: [kert, hegy])
    #expect(result?.name == "Kert")
}

@Test func resolveReturnsNilBeyondMaxDistance() {
    // Kert/Hegy are ~190 km apart; a point ~500 km from both should miss.
    let result = SiteResolver.resolve(sessionTags: [], medianLat: 42.0, medianLon: 12.0, sites: [kert, hegy])
    #expect(result == nil)
}

@Test func resolveRespectsCustomMaxDistance() {
    // A point ~5 km from Kert should miss a deliberately tight 1 km threshold.
    let result = SiteResolver.resolve(
        sessionTags: [], medianLat: 47.545, medianLon: 19.0, sites: [kert], maxDistanceKm: 1
    )
    #expect(result == nil)
}

@Test func resolveNilWhenSitesEmpty() {
    let result = SiteResolver.resolve(sessionTags: [], medianLat: 47.5, medianLon: 19.0, sites: [])
    #expect(result == nil)
}

@Test func resolveNilWhenNoCoordinateAndNoTag() {
    let result = SiteResolver.resolve(sessionTags: [], medianLat: nil, medianLon: nil, sites: [kert])
    #expect(result == nil)
}

@Test func resolveTagOverrideWinsEvenWhenCoordinateIsNearAnotherSite() {
    // Coordinate is right on top of Kert, but the tag explicitly says Hegy.
    let result = SiteResolver.resolve(sessionTags: ["site:Hegy"], medianLat: 47.5, medianLon: 19.0, sites: [kert, hegy])
    #expect(result?.name == "Hegy")
}

@Test func resolveTagOverrideIsCaseInsensitive() {
    let result = SiteResolver.resolve(sessionTags: ["site:HEGY"], medianLat: nil, medianLon: nil, sites: [kert, hegy])
    #expect(result?.name == "Hegy")
}

@Test func resolveTagOverrideNamingUnconfiguredSiteResolvesToNil() {
    // An intentional override that doesn't exist is still "no assignment" --
    // never a silent fall-through to the nearest-distance guess.
    let result = SiteResolver.resolve(sessionTags: ["site:Ismeretlen"], medianLat: 47.5, medianLon: 19.0, sites: [kert])
    #expect(result == nil)
}

@Test func resolvePicksTheCloserOfTwoSitesWithinThreshold() {
    // A point between Kert and Hegy, but closer to Hegy.
    let result = SiteResolver.resolve(sessionTags: [], medianLat: 46.2, medianLon: 18.2, sites: [kert, hegy])
    #expect(result?.name == "Hegy")
}
