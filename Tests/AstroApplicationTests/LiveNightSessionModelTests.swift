import Foundation
import Testing
@testable import AstroApplication

@Suite("LiveNightSessionModel accumulation")
struct LiveNightSessionModelTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    @Test("A freshly created session starts empty and watching")
    func freshSessionStartsEmpty() {
        let session = LiveNightSessionModel()
        #expect(session.totalFrameCount == 0)
        #expect(session.fitsFrameCount == 0)
        #expect(session.cr3FrameCount == 0)
        #expect(session.medianQuickProxyRadiusPixels == nil)
        #expect(session.connectionState == .watching)
        #expect(session.lastFrameAt == nil)
    }

    @Test("Recording a FITS frame increments the FITS count only")
    func recordingFITSFrameIncrementsFITSCountOnly() {
        var session = LiveNightSessionModel()
        session.recordFrame(.init(kind: .fits, exposureSeconds: 300, capturedAt: now))
        #expect(session.fitsFrameCount == 1)
        #expect(session.cr3FrameCount == 0)
        #expect(session.totalFrameCount == 1)
        #expect(session.lastFrameAt == now)
    }

    @Test("Recording a CR3 frame increments the CR3 count only")
    func recordingCR3FrameIncrementsCR3CountOnly() {
        var session = LiveNightSessionModel()
        session.recordFrame(.init(kind: .cr3, exposureSeconds: 120, capturedAt: now))
        #expect(session.fitsFrameCount == 0)
        #expect(session.cr3FrameCount == 1)
        #expect(session.totalFrameCount == 1)
    }

    @Test("A frame with an unknown exposure length still counts, but never enters goal integration")
    func unknownExposureLengthStillCounts() {
        var session = LiveNightSessionModel()
        session.recordFrame(.init(kind: .fits, exposureSeconds: nil, capturedAt: now))
        #expect(session.fitsFrameCount == 1)
        #expect(session.exposureSeconds.isEmpty)
        #expect(session.timestamps.isEmpty)
        // No goal-integration data at all -> no honest estimate possible.
        #expect(session.goalEstimate(goalSeconds: 3600, now: now) == nil)
    }

    @Test("A CR3 frame's quickProxyRadiusPixels is always ignored, even if a caller mistakenly supplies one")
    func cr3FrameNeverContributesAQuickProxyRadius() {
        var session = LiveNightSessionModel()
        session.recordFrame(.init(kind: .cr3, exposureSeconds: 60, capturedAt: now, quickProxyRadiusPixels: 3.2))
        #expect(session.medianQuickProxyRadiusPixels == nil)
    }

    @Test("A FITS frame's quickProxyRadiusPixels is folded into the running median")
    func fitsFrameContributesToMedianRadius() {
        var session = LiveNightSessionModel()
        session.recordFrame(.init(kind: .fits, exposureSeconds: 300, capturedAt: now, quickProxyRadiusPixels: 2.0))
        session.recordFrame(.init(kind: .fits, exposureSeconds: 300, capturedAt: now, quickProxyRadiusPixels: 4.0))
        session.recordFrame(.init(kind: .fits, exposureSeconds: 300, capturedAt: now, quickProxyRadiusPixels: 6.0))
        #expect(session.medianQuickProxyRadiusPixels == 4.0)
    }

    @Test("A FITS frame whose proxy could not be measured leaves the median unaffected")
    func unmeasuredFITSFrameLeavesMedianUnaffected() {
        var session = LiveNightSessionModel()
        session.recordFrame(.init(kind: .fits, exposureSeconds: 300, capturedAt: now, quickProxyRadiusPixels: 2.0))
        session.recordFrame(.init(kind: .fits, exposureSeconds: 300, capturedAt: now, quickProxyRadiusPixels: nil))
        #expect(session.medianQuickProxyRadiusPixels == 2.0)
    }

    @Test("goalEstimate delegates to LiveNightGoalEstimator with the session's own accumulated frames")
    func goalEstimateDelegatesToEstimator() throws {
        var session = LiveNightSessionModel()
        session.recordFrame(.init(kind: .fits, exposureSeconds: 300, capturedAt: now))
        session.recordFrame(.init(kind: .fits, exposureSeconds: 300, capturedAt: now.addingTimeInterval(300)))
        let estimate = try #require(session.goalEstimate(goalSeconds: 3600, now: now.addingTimeInterval(600)))
        #expect(estimate.integratedSeconds == 600)
        #expect(estimate.goalSeconds == 3600)
    }

    @Test("goalEstimate is nil when no goal is supplied")
    func goalEstimateIsNilWithoutAGoal() {
        var session = LiveNightSessionModel()
        session.recordFrame(.init(kind: .fits, exposureSeconds: 300, capturedAt: now))
        #expect(session.goalEstimate(goalSeconds: nil, now: now) == nil)
    }

    @Test("markIdleTooLong only transitions from watching, never overwrites disconnected")
    func markIdleTooLongOnlyTransitionsFromWatching() {
        var session = LiveNightSessionModel()
        session.markDisconnected()
        #expect(session.connectionState == .disconnected)
        session.markIdleTooLong()
        #expect(session.connectionState == .disconnected, "idle must never downgrade a disconnected state")

        var watchingSession = LiveNightSessionModel()
        watchingSession.markIdleTooLong()
        #expect(watchingSession.connectionState == .idleTooLong)
    }

    @Test("Recording a new frame resets the connection state back to watching")
    func recordingAFrameResetsConnectionState() {
        var session = LiveNightSessionModel()
        session.markIdleTooLong()
        #expect(session.connectionState == .idleTooLong)
        session.recordFrame(.init(kind: .fits, exposureSeconds: 300, capturedAt: now))
        #expect(session.connectionState == .watching)
    }

    @Test("markReconnected only transitions away from a non-watching state")
    func markReconnectedOnlyTransitionsAwayFromNonWatching() {
        var session = LiveNightSessionModel()
        session.markDisconnected()
        session.markReconnected()
        #expect(session.connectionState == .watching)

        var alreadyWatching = LiveNightSessionModel()
        alreadyWatching.markReconnected()
        #expect(alreadyWatching.connectionState == .watching)
    }
}
