import Testing
@testable import AstroCore

@Test func parsesCanonicalDate() {
    let result = SessionDateParser.parse("2026-04-06")
    #expect(result?.kind == .canonical)
    #expect(result?.start == "2026-04-06")
    #expect(result?.end == "2026-04-06")
    #expect(result?.label == nil)
    #expect(result?.isCanonical == true)
    #expect(result?.raw == "2026-04-06")
}

@Test func parsesRunSuffix() {
    let result = SessionDateParser.parse("2026-04-06-2")
    #expect(result?.kind == .runSuffix(2))
    #expect(result?.start == "2026-04-06")
    #expect(result?.end == "2026-04-06")
    #expect(result?.isCanonical == false)
}

@Test func parsesUnderscoreJoinedRange() {
    let result = SessionDateParser.parse("2026-02-25_2026-03-15")
    #expect(result?.kind == .range)
    #expect(result?.start == "2026-02-25")
    #expect(result?.end == "2026-03-15")
}

@Test func parsesHyphenJoinedRange() {
    let result = SessionDateParser.parse("2026-04-18-2026-04-19")
    #expect(result?.kind == .range)
    #expect(result?.start == "2026-04-18")
    #expect(result?.end == "2026-04-19")
}

@Test func parsesLabeledWithHyphenSeparator() {
    let result = SessionDateParser.parse("2026-03-15-OSC")
    #expect(result?.kind == .labeled)
    #expect(result?.label == "OSC")
    #expect(result?.start == "2026-03-15")
    #expect(result?.end == "2026-03-15")
}

@Test func parsesLabeledWithUnderscoreSeparator() {
    let result = SessionDateParser.parse("2026-03-15_hibas")
    #expect(result?.kind == .labeled)
    #expect(result?.label == "hibas")
}

@Test func rejectsInvalidMonth() {
    #expect(SessionDateParser.parse("2026-13-01") == nil)
}

@Test func rejectsNonDateText() {
    #expect(SessionDateParser.parse("Please_enter") == nil)
}

@Test func rejectsNonExistentDay() {
    #expect(SessionDateParser.parse("2026-04-31") == nil)
}

@Test func rejectsFebruary29OnNonLeapYear() {
    #expect(SessionDateParser.parse("2026-02-29") == nil)
}

@Test func acceptsFebruary29OnLeapYear() {
    #expect(SessionDateParser.parse("2028-02-29")?.kind == .canonical)
}

@Test func runSuffixDisabledReturnsNil() {
    var patterns = IntentionalPatterns()
    patterns.runSuffix = false
    #expect(SessionDateParser.parse("2026-04-06-2", patterns: patterns) == nil)
}

@Test func dateRangeDisabledReturnsNil() {
    var patterns = IntentionalPatterns()
    patterns.dateRange = false
    #expect(SessionDateParser.parse("2026-02-25_2026-03-15", patterns: patterns) == nil)
}

@Test func labeledStillParsesWhenOtherPatternsDisabled() {
    var patterns = IntentionalPatterns()
    patterns.runSuffix = false
    patterns.dateRange = false
    let result = SessionDateParser.parse("2026-03-15-OSC", patterns: patterns)
    #expect(result?.kind == .labeled)
    #expect(result?.label == "OSC")
}

@Test func intentionalPatternsDefaults() {
    let patterns = IntentionalPatterns()
    #expect(patterns.runSuffix == true)
    #expect(patterns.dateRange == true)
    #expect(patterns.labels == ["hibas", "bad", "reject", "rejected", "schlecht", "OSC"])
}
