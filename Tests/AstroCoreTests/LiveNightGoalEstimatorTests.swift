import Foundation
import Testing
@testable import AstroCore

@Suite("LiveNightGoalEstimator ETA arithmetic")
struct LiveNightGoalEstimatorTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("A non-positive goal yields no estimate")
    func nonPositiveGoalYieldsNil() {
        let estimate = LiveNightGoalEstimator.estimate(
            exposureSeconds: [300], timestamps: [now], goalSeconds: 0, now: now
        )
        #expect(estimate == nil)
    }

    @Test("No captured frames yet yields no estimate")
    func noFramesYieldsNil() {
        let estimate = LiveNightGoalEstimator.estimate(
            exposureSeconds: [], timestamps: [], goalSeconds: 3600, now: now
        )
        #expect(estimate == nil)
    }

    @Test("A goal already met reports zero remaining frames and an ETA of now")
    func goalAlreadyMetReportsZeroRemaining() throws {
        let estimate = try #require(LiveNightGoalEstimator.estimate(
            exposureSeconds: [3600, 3600], timestamps: [now, now.addingTimeInterval(300)],
            goalSeconds: 3600, now: now
        ))
        #expect(estimate.remainingFrameCount == 0)
        #expect(estimate.etaDate == now)
        #expect(estimate.progressFraction >= 1)
    }

    @Test("A regular cadence projects the correct remaining-frame count and ETA")
    func regularCadenceProjectsCorrectETA() throws {
        // 10 frames of 300s each, captured exactly 300s apart (so the
        // median gap is 0 -- back-to-back exposures with no dead time
        // between them) -- 3000s integrated toward a 7200s (2h) goal.
        let exposures = Array(repeating: 300.0, count: 10)
        let timestamps = (0..<10).map { now.addingTimeInterval(Double($0) * 300) }
        let estimate = try #require(LiveNightGoalEstimator.estimate(
            exposureSeconds: exposures, timestamps: timestamps, goalSeconds: 7200, now: now
        ))
        // remaining = ceil((7200 - 3000) / 300) = 14 frames
        #expect(estimate.remainingFrameCount == 14)
        // perFrameSeconds = medianExposure(300) + medianGap(0) = 300
        let expectedETA = now.addingTimeInterval(14 * 300)
        #expect(estimate.etaDate == expectedETA)
        #expect(abs(estimate.progressFraction - (3000.0 / 7200.0)) < 0.0001)
    }

    @Test("A per-frame gap (dither/download dead time) is folded into the ETA")
    func gapBetweenFramesExtendsETA() throws {
        // 5 frames of 60s exposure, each frame arriving 90s after the
        // previous one STARTED (60s exposure + 30s dead time between the
        // shutter closing and the next one opening) -- the dead time
        // between consecutive frames is 90 - 60 = 30s, not the raw 90s
        // period itself (that period already contains the exposure).
        let exposures = Array(repeating: 60.0, count: 5)
        let timestamps = (0..<5).map { now.addingTimeInterval(Double($0) * 90) }
        let estimate = try #require(LiveNightGoalEstimator.estimate(
            exposureSeconds: exposures, timestamps: timestamps, goalSeconds: 3600, now: now
        ))
        // integrated = 300s, remaining = ceil((3600-300)/60) = 55 frames
        #expect(estimate.remainingFrameCount == 55)
        // perFrameSeconds = 60 (median exposure) + 30 (median dead time) = 90
        let expectedETA = now.addingTimeInterval(55 * 90)
        #expect(estimate.etaDate == expectedETA)
    }

    @Test("Out-of-order timestamps are paired with their own exposure and sorted before dead time is computed")
    func outOfOrderTimestampsAreSortedFirst() throws {
        let exposures = [60.0, 60.0, 60.0]
        // Deliberately out of order -- the function must pair each exposure
        // with its own timestamp and sort by time internally, not assume
        // the two arrays already arrived in chronological order.
        let timestamps = [
            now.addingTimeInterval(120),
            now,
            now.addingTimeInterval(60),
        ]
        let estimate = try #require(LiveNightGoalEstimator.estimate(
            exposureSeconds: exposures, timestamps: timestamps, goalSeconds: 3600, now: now
        ))
        // Sorted order is back-to-back (60s exposure, 60s period) -> dead
        // time is 60 - 60 = 0 for both gaps; perFrame = 60 + 0 = 60.
        // integrated = 180, remaining = ceil((3600-180)/60) = 57
        #expect(estimate.remainingFrameCount == 57)
        #expect(estimate.etaDate == now.addingTimeInterval(57 * 60))
    }

    @Test("A zero median exposure length cannot project a finish time")
    func zeroMedianExposureYieldsNoProjection() throws {
        let estimate = try #require(LiveNightGoalEstimator.estimate(
            exposureSeconds: [0, 0, 0], timestamps: [now, now.addingTimeInterval(10), now.addingTimeInterval(20)],
            goalSeconds: 3600, now: now
        ))
        #expect(estimate.remainingFrameCount == nil)
        #expect(estimate.etaDate == nil)
        #expect(estimate.integratedSeconds == 0)
    }
}
