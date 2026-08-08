import Foundation
import Testing
@testable import AstroCore

// MARK: - LibraryPercentiles.evaluate

@Test func evaluateReturnsNilBelowMinimumSampleSize() throws {
    let values: [Double] = [1, 2, 3, 4, 5]
    #expect(LibraryPercentiles.evaluate(value: 1, allValues: values, higherIsBetter: false) == nil)
}

@Test func evaluateAtMinimumSampleSizeComputesABand() throws {
    let values: [Double] = [1, 2, 3, 4, 5, 6]
    #expect(LibraryPercentiles.evaluate(value: 1, allValues: values, higherIsBetter: false) != nil)
}

@Test func evaluateFWHMLowerIsBetterBandsIntoThirds() throws {
    // FWHM: smaller is sharper -- `higherIsBetter: false`. Six values split
    // evenly into thirds of two: {1,2} best, {3,4} middle, {5,6} worst.
    let values: [Double] = [1, 2, 3, 4, 5, 6]

    #expect(LibraryPercentiles.evaluate(value: 1, allValues: values, higherIsBetter: false)?.band == .best)
    #expect(LibraryPercentiles.evaluate(value: 2, allValues: values, higherIsBetter: false)?.band == .best)
    #expect(LibraryPercentiles.evaluate(value: 3, allValues: values, higherIsBetter: false)?.band == .middle)
    #expect(LibraryPercentiles.evaluate(value: 4, allValues: values, higherIsBetter: false)?.band == .middle)
    #expect(LibraryPercentiles.evaluate(value: 5, allValues: values, higherIsBetter: false)?.band == .worst)
    #expect(LibraryPercentiles.evaluate(value: 6, allValues: values, higherIsBetter: false)?.band == .worst)
}

@Test func evaluateDutyCycleHigherIsBetterFlipsTheBandDirection() throws {
    // Hatékonyság: bigger percentage is better -- `higherIsBetter: true`.
    // Same six values, opposite ranking from the FWHM case above.
    let values: [Double] = [10, 20, 30, 40, 50, 60]

    #expect(LibraryPercentiles.evaluate(value: 60, allValues: values, higherIsBetter: true)?.band == .best)
    #expect(LibraryPercentiles.evaluate(value: 50, allValues: values, higherIsBetter: true)?.band == .best)
    #expect(LibraryPercentiles.evaluate(value: 30, allValues: values, higherIsBetter: true)?.band == .middle)
    #expect(LibraryPercentiles.evaluate(value: 10, allValues: values, higherIsBetter: true)?.band == .worst)
}

@Test func evaluateReportsTheDistributionsOwnMedian() throws {
    let values: [Double] = [1, 2, 3, 4, 5, 6]
    let result = try #require(LibraryPercentiles.evaluate(value: 1, allValues: values, higherIsBetter: false))
    #expect(result.medianValue == 3.5)
}

@Test func evaluateBetterThanFractionCountsStrictlyBetterValuesOnly() throws {
    // Ties: a value equal to itself elsewhere in the distribution never
    // counts as "worse than" -- so a repeated WORST value (tied with
    // another 5, nothing bigger in the array) beats nobody.
    let values: [Double] = [1, 2, 3, 4, 5, 5]
    let result = try #require(LibraryPercentiles.evaluate(value: 5, allValues: values, higherIsBetter: false))
    #expect(result.betterThanFraction == 0)
}

@Test func evaluateBestPossibleValueBeatsEveryoneElse() throws {
    let values: [Double] = [1, 2, 3, 4, 5, 6]
    let result = try #require(LibraryPercentiles.evaluate(value: 1, allValues: values, higherIsBetter: false))
    #expect(result.betterThanFraction == 5.0 / 6.0)
}
