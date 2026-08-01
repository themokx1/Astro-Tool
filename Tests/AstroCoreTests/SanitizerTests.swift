import Testing
@testable import AstroCore

@Test func sanitizeReplacesSpacesWithUnderscore() {
    #expect(Sanitizer.sanitize("Heart and Soul Nebula") == "Heart_and_Soul_Nebula")
}

@Test func sanitizeKeepsAllowedCharacters() {
    #expect(Sanitizer.sanitize("IC1805-1848") == "IC1805-1848")
}

@Test func sanitizeTrimsAndCollapsesAndStripsPunctuation() {
    #expect(Sanitizer.sanitize("  M45  Pleiades!! ") == "M45_Pleiades")
}

@Test func sanitizeDropsDisallowedCharactersAndCollapsesRuns() {
    #expect(Sanitizer.sanitize("a///b   c") == "a_b_c")
}

@Test func sanitizeOfEmptyStringIsEmpty() {
    #expect(Sanitizer.sanitize("") == "")
}

@Test func sanitizeOfOnlyDisallowedCharactersIsEmpty() {
    #expect(Sanitizer.sanitize("!!!   ///") == "")
}

@Test func makeTargetJoinsSanitizedCatalogAndName() {
    #expect(
        Sanitizer.makeTarget(catalog: "IC1805-1848", name: "Heart and Soul Nebula")
            == "IC1805-1848_Heart_and_Soul_Nebula"
    )
}

@Test func makeTargetWithMessyInputsStillProducesCleanTarget() {
    #expect(Sanitizer.makeTarget(catalog: "  NGC 2237  ", name: "Rosette!! Nebula")
            == "NGC_2237_Rosette_Nebula")
}
