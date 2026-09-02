import Foundation
import Testing
@testable import AstroCore

/// Pure-function tests for `ExifDateConversion` -- no image file needed,
/// this is a plain string-in/string-out conversion.

@Test func utcDateObsStringConvertsUsingExplicitPositiveOffset() {
    // 04:36:24 at UTC+2 is 02:36:24 UTC.
    let result = ExifDateConversion.utcDateObsString(
        dateTaken: "2026:04:18 04:36:24",
        offsetTimeOriginal: "+02:00"
    )
    #expect(result == "2026-04-18T02:36:24")
}

@Test func utcDateObsStringConvertsUsingExplicitNegativeOffset() {
    // 22:00:00 at UTC-5 is 03:00:00 UTC the next day.
    let result = ExifDateConversion.utcDateObsString(
        dateTaken: "2026:04:18 22:00:00",
        offsetTimeOriginal: "-05:00"
    )
    #expect(result == "2026-04-19T03:00:00")
}

@Test func utcDateObsStringFallsBackToGivenTimeZoneWhenNoOffsetTag() {
    let cest = try! #require(TimeZone(identifier: "Europe/Budapest"))
    // 2026-04-18 is CEST (UTC+2) in Budapest.
    let result = ExifDateConversion.utcDateObsString(
        dateTaken: "2026:04:18 04:36:24",
        offsetTimeOriginal: nil,
        fallbackTimeZone: cest
    )
    #expect(result == "2026-04-18T02:36:24")
}

@Test func utcDateObsStringReturnsNilForMalformedDateTaken() {
    let result = ExifDateConversion.utcDateObsString(
        dateTaken: "not a real exif date",
        offsetTimeOriginal: "+02:00"
    )
    #expect(result == nil)
}

@Test func utcDateObsStringHandlesZOffsetAsUTC() {
    let result = ExifDateConversion.utcDateObsString(
        dateTaken: "2026:04:18 04:36:24",
        offsetTimeOriginal: "Z"
    )
    #expect(result == "2026-04-18T04:36:24")
}

@Test func utcDateObsStringIgnoresMalformedOffsetAndFallsBackInstead() {
    let utc = try! #require(TimeZone(identifier: "UTC"))
    let result = ExifDateConversion.utcDateObsString(
        dateTaken: "2026:04:18 04:36:24",
        offsetTimeOriginal: "garbage",
        fallbackTimeZone: utc
    )
    #expect(result == "2026-04-18T04:36:24")
}

@Test func parseExifOffsetHandlesPositiveAndNegativeAndZ() {
    #expect(ExifDateConversion.parseExifOffset("+02:00")?.secondsFromGMT() == 7200)
    #expect(ExifDateConversion.parseExifOffset("-05:30")?.secondsFromGMT() == -19800)
    #expect(ExifDateConversion.parseExifOffset("Z")?.secondsFromGMT() == 0)
    #expect(ExifDateConversion.parseExifOffset("not-an-offset") == nil)
}
