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
    // Ground truth (`add_new_session.sh`'s `sanitize()`): `tr ' ' '_'` FIRST,
    // then `tr -cd 'A-Za-z0-9._-'` -- disallowed characters are DELETED, not
    // replaced with `_`. So "a///b   c" -> (spaces -> _) "a///b___c" ->
    // (delete "/") "ab___c" -> (collapse "_+") "ab_c" -- NOT "a_b_c".
    #expect(Sanitizer.sanitize("a///b   c") == "ab_c")
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
