import Foundation
import Testing
@testable import AstroCore

// MARK: - Fixtures
//
// Real calendar dates (2024-01) with real `SunMoon.moonIlluminationPercent`
// values, confirmed by direct computation against this exact engine:
//   2024-01-11 ->  0.19% (new moon)      -> .veryDark
//   2024-01-16 -> 31.63%                 -> .dark
//   2024-01-18 -> 53.71%                 -> .bright
//   2024-01-25 -> 99.76% (full moon)     -> .veryBright
// Picking real dates (rather than injecting a fake illumination function)
// matches `MoonSkyCorrelation.buckets(points:)`'s actual, single-parameter
// contract: it derives illumination itself from each point's own
// `sessionStartDate`, so a meaningful test has to feed it dates whose real
// Moon phase is independently known.

private func point(
    target: String = "M42",
    date: String,
    background: Double?
) -> TrendPoint {
    TrendPoint(target: target, date: date, sessionStartDate: date, backgroundEPerSecPerArcsec2: background)
}

// MARK: - Band assignment + medians

@Test func bucketsGroupOneSessionPerBandByItsOwnMoonIllumination() throws {
    let points = [
        point(date: "2024-01-11", background: 0.001), // veryDark
        point(date: "2024-01-16", background: 0.002), // dark
        point(date: "2024-01-18", background: 0.004), // bright
        point(date: "2024-01-25", background: 0.008)  // veryBright
    ]
    let result = MoonSkyCorrelation.buckets(points: points)
    #expect(result.buckets.count == 4)

    func bucket(_ band: MoonSkyCorrelation.IlluminationBand) -> MoonSkyCorrelation.Bucket {
        result.buckets.first { $0.band == band }!
    }
    #expect(bucket(.veryDark).sampleCount == 1)
    #expect(bucket(.veryDark).medianBackgroundEPerSecPerArcsec2 == 0.001)
    #expect(bucket(.dark).sampleCount == 1)
    #expect(bucket(.dark).medianBackgroundEPerSecPerArcsec2 == 0.002)
    #expect(bucket(.bright).sampleCount == 1)
    #expect(bucket(.bright).medianBackgroundEPerSecPerArcsec2 == 0.004)
    #expect(bucket(.veryBright).sampleCount == 1)
    #expect(bucket(.veryBright).medianBackgroundEPerSecPerArcsec2 == 0.008)
}

@Test func bucketsComputeMedianOverMultipleSessionsInTheSameBand() throws {
    // Three sessions all near full Moon (>=75%), median of 0.003/0.005/0.010 is 0.005.
    let points = [
        point(target: "T1", date: "2024-01-25", background: 0.003),
        point(target: "T2", date: "2024-01-24", background: 0.010),
        point(target: "T3", date: "2024-01-25", background: 0.005)
    ]
    let result = MoonSkyCorrelation.buckets(points: points)
    let veryBright = result.buckets.first { $0.band == .veryBright }!
    #expect(veryBright.sampleCount == 3)
    #expect(veryBright.medianBackgroundEPerSecPerArcsec2 == 0.005)
    #expect(veryBright.isLowConfidence == false)
}

// MARK: - Low-confidence flag

@Test func oneSampleBucketIsFlaggedLowConfidence() throws {
    let points = [point(date: "2024-01-25", background: 0.005)]
    let result = MoonSkyCorrelation.buckets(points: points)
    let veryBright = result.buckets.first { $0.band == .veryBright }!
    #expect(veryBright.sampleCount == 1)
    #expect(veryBright.isLowConfidence == true)
    // Still an honest median -- Core never hides the number, only flags it.
    #expect(veryBright.medianBackgroundEPerSecPerArcsec2 == 0.005)
}

@Test func meetingMinimumSampleCountClearsLowConfidence() throws {
    let points = (0..<MoonSkyCorrelation.minimumSampleCount).map {
        point(target: "T\($0)", date: "2024-01-25", background: 0.005)
    }
    let result = MoonSkyCorrelation.buckets(points: points)
    let veryBright = result.buckets.first { $0.band == .veryBright }!
    #expect(veryBright.sampleCount == MoonSkyCorrelation.minimumSampleCount)
    #expect(veryBright.isLowConfidence == false)
}

// MARK: - Headline ratio

@Test func headlineRatioIsBrightestOverDarkestWhenBothSufficient() throws {
    let darkSamples = (0..<MoonSkyCorrelation.minimumSampleCount).map {
        point(target: "D\($0)", date: "2024-01-11", background: 0.002)
    }
    let brightSamples = (0..<MoonSkyCorrelation.minimumSampleCount).map {
        point(target: "B\($0)", date: "2024-01-25", background: 0.006)
    }
    let result = MoonSkyCorrelation.buckets(points: darkSamples + brightSamples)
    #expect(result.headlineRatio == 3.0)
    #expect(result.usableBucketCount == 2)
}

@Test func headlineRatioIsNilWhenDarkestBucketIsLowConfidence() throws {
    let darkSamples = [point(date: "2024-01-11", background: 0.002)] // only 1 sample
    let brightSamples = (0..<MoonSkyCorrelation.minimumSampleCount).map {
        point(target: "B\($0)", date: "2024-01-25", background: 0.006)
    }
    let result = MoonSkyCorrelation.buckets(points: darkSamples + brightSamples)
    #expect(result.headlineRatio == nil)
}

@Test func headlineRatioIsNilWhenBrightestBucketIsLowConfidence() throws {
    let darkSamples = (0..<MoonSkyCorrelation.minimumSampleCount).map {
        point(target: "D\($0)", date: "2024-01-11", background: 0.002)
    }
    let brightSamples = [point(date: "2024-01-25", background: 0.006)] // only 1 sample
    let result = MoonSkyCorrelation.buckets(points: darkSamples + brightSamples)
    #expect(result.headlineRatio == nil)
}

@Test func headlineRatioIsNilWhenOneExtremeBandHasNoSamplesAtAll() throws {
    let brightSamples = (0..<MoonSkyCorrelation.minimumSampleCount).map {
        point(target: "B\($0)", date: "2024-01-25", background: 0.006)
    }
    let result = MoonSkyCorrelation.buckets(points: brightSamples)
    #expect(result.headlineRatio == nil)
    #expect(result.usableBucketCount == 1)
}

// MARK: - Exclusion rules

@Test func pointsWithoutMeasuredBackgroundAreExcluded() throws {
    let points = [point(date: "2024-01-25", background: nil)]
    let result = MoonSkyCorrelation.buckets(points: points)
    #expect(result.buckets.allSatisfy { $0.sampleCount == 0 })
}

@Test func pointsWithoutParseableSessionStartDateAreExcluded() throws {
    let unparseable = TrendPoint(
        target: "M42", date: "2024_stray", sessionStartDate: nil,
        backgroundEPerSecPerArcsec2: 0.004
    )
    let result = MoonSkyCorrelation.buckets(points: [unparseable])
    #expect(result.buckets.allSatisfy { $0.sampleCount == 0 })
}

@Test func nonPositiveOrNonFiniteBackgroundIsExcluded() throws {
    let points = [
        point(date: "2024-01-25", background: 0),
        point(date: "2024-01-24", background: -0.001),
        point(date: "2024-01-23", background: .nan)
    ]
    let result = MoonSkyCorrelation.buckets(points: points)
    #expect(result.buckets.allSatisfy { $0.sampleCount == 0 })
}

// MARK: - Empty input

@Test func emptyPointsYieldsFourEmptyLowConfidenceBucketsAndNoHeadline() throws {
    let result = MoonSkyCorrelation.buckets(points: [])
    #expect(result.buckets.count == 4)
    #expect(result.buckets.allSatisfy { $0.sampleCount == 0 && $0.isLowConfidence && $0.medianBackgroundEPerSecPerArcsec2 == nil })
    #expect(result.headlineRatio == nil)
    #expect(result.usableBucketCount == 0)
}

// MARK: - Band boundaries

@Test func illuminationBandBoundariesPartitionZeroToOneHundred() throws {
    #expect(MoonSkyCorrelation.IlluminationBand.containing(0) == .veryDark)
    #expect(MoonSkyCorrelation.IlluminationBand.containing(24.999) == .veryDark)
    #expect(MoonSkyCorrelation.IlluminationBand.containing(25) == .dark)
    #expect(MoonSkyCorrelation.IlluminationBand.containing(49.999) == .dark)
    #expect(MoonSkyCorrelation.IlluminationBand.containing(50) == .bright)
    #expect(MoonSkyCorrelation.IlluminationBand.containing(74.999) == .bright)
    #expect(MoonSkyCorrelation.IlluminationBand.containing(75) == .veryBright)
    #expect(MoonSkyCorrelation.IlluminationBand.containing(100) == .veryBright)
}
