@testable import AstroUI
import AstroApplication
import Foundation
import Testing

@MainActor
@Suite("Frame blink review store")
struct FrameBlinkReviewTests {
    @Test("Navigation clamps at the first and last frame without crashing")
    func navigationBounds() {
        let decisions = makeDecisions(count: 3)
        let store = FrameBlinkReviewStore(decisions: decisions) { _, _ in }

        store.goPrevious()
        #expect(store.index == 0)
        #expect(store.currentFrame?.relativePath == decisions[0].relativePath)

        store.goNext()
        store.goNext()
        #expect(store.index == 2)
        store.goNext()
        #expect(store.index == 2, "must not advance past the last frame")
        #expect(store.currentFrame?.relativePath == decisions[2].relativePath)
    }

    @Test("Accepting writes the verdict for the current frame and advances")
    func acceptAdvances() async {
        let decisions = makeDecisions(count: 3)
        let recorder = VerdictRecorder()
        let store = FrameBlinkReviewStore(decisions: decisions) { path, verdict in
            await recorder.record(path, verdict)
        }

        await store.accept()

        let recorded = await recorder.entries
        #expect(recorded.map(\.0) == [decisions[0].relativePath])
        #expect(recorded.map(\.1) == [.accepted])
        #expect(store.index == 1)
    }

    @Test("Rejecting writes the verdict and advances, same as accept")
    func rejectAdvances() async {
        let decisions = makeDecisions(count: 2)
        let recorder = VerdictRecorder()
        let store = FrameBlinkReviewStore(decisions: decisions) { path, verdict in
            await recorder.record(path, verdict)
        }

        await store.reject()

        let recorded = await recorder.entries
        #expect(recorded.map(\.1) == [.rejected])
        #expect(store.index == 1)
    }

    @Test("Clearing a verdict writes undecided but does not auto-advance")
    func clearDoesNotAdvance() async {
        let decisions = makeDecisions(count: 2)
        let recorder = VerdictRecorder()
        let store = FrameBlinkReviewStore(decisions: decisions) { path, verdict in
            await recorder.record(path, verdict)
        }

        await store.clearVerdict()

        let recorded = await recorder.entries
        #expect(recorded.map(\.1) == [.undecided])
        #expect(store.index == 0, "clearing is a fix-a-mistake action, not a move-on action")
    }

    @Test("A failed verdict write does not advance the blink position")
    func failedWriteDoesNotAdvance() async {
        let decisions = makeDecisions(count: 2)
        let store = FrameBlinkReviewStore(decisions: decisions) { _, _ in
            throw FrameBlinkReviewTestFailure.writeFailed
        }

        await store.accept()

        #expect(store.index == 0)
        #expect(store.errorMessage != nil)
    }

    @Test("Accepting the last frame stays put rather than crashing")
    func acceptAtLastFrameStaysPut() async {
        let decisions = makeDecisions(count: 1)
        let store = FrameBlinkReviewStore(decisions: decisions) { _, _ in }

        await store.accept()

        #expect(store.index == 0)
        #expect(store.currentFrame?.relativePath == decisions[0].relativePath)
    }

    @Test("Refreshing the decisions list keeps the blink position on the same frame")
    func refreshKeepsPositionOnSameFrame() {
        let decisions = makeDecisions(count: 3)
        let store = FrameBlinkReviewStore(decisions: decisions) { _, _ in }
        store.goNext()
        #expect(store.currentFrame?.relativePath == decisions[1].relativePath)

        let refreshedVerdictOnly = decisions.map { decision in
            decision.relativePath == decisions[1].relativePath
                ? FrameDecisionRecord(
                    id: decision.id, seriesID: decision.seriesID, relativePath: decision.relativePath,
                    verdict: .accepted, logicallyExcluded: false
                )
                : decision
        }
        store.refresh(decisions: refreshedVerdictOnly)

        #expect(store.index == 1)
        #expect(store.currentFrame?.verdict == .accepted)
    }

    @Test("Refreshing to a list missing the current frame clamps to a valid index")
    func refreshClampsWhenCurrentFrameIsGone() {
        let decisions = makeDecisions(count: 3)
        let store = FrameBlinkReviewStore(decisions: decisions) { _, _ in }
        store.goNext()
        store.goNext()
        #expect(store.index == 2)

        let shrunk = Array(decisions.prefix(1))
        store.refresh(decisions: shrunk)

        #expect(store.index == 0)
        #expect(store.currentFrame?.relativePath == shrunk[0].relativePath)
    }

    @Test("Refreshing to an empty list leaves no crash and no current frame")
    func refreshToEmptyListIsSafe() {
        let decisions = makeDecisions(count: 2)
        let store = FrameBlinkReviewStore(decisions: decisions) { _, _ in }

        store.refresh(decisions: [])

        #expect(store.currentFrame == nil)
        #expect(store.index == 0)
    }

    @Test("Opening with an initial relative path starts the blink there")
    func opensAtInitialRelativePath() {
        let decisions = makeDecisions(count: 3)
        let store = FrameBlinkReviewStore(
            decisions: decisions,
            initialRelativePath: decisions[2].relativePath
        ) { _, _ in }

        #expect(store.index == 2)
        #expect(store.currentFrame?.relativePath == decisions[2].relativePath)
    }

    private func makeDecisions(count: Int) -> [FrameDecisionRecord] {
        (0..<count).map { i in
            FrameDecisionRecord(
                id: UUID(), seriesID: UUID(), relativePath: "lights/frame_\(i).fit",
                verdict: .undecided, logicallyExcluded: false
            )
        }
    }
}

private enum FrameBlinkReviewTestFailure: Error {
    case writeFailed
}

/// A tiny actor to collect verdict-handler calls from within a `@Sendable`
/// closure without data races -- the store's `VerdictHandler` type is
/// `@Sendable`, so a plain captured `var` array isn't an option here.
private actor VerdictRecorder {
    private(set) var entries: [(String, FrameVerdict)] = []
    func record(_ path: String, _ verdict: FrameVerdict) {
        entries.append((path, verdict))
    }
}
