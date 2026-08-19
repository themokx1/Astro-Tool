@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// Morning Triage Digest (expert ideation spec #1) -- `TriageDigestQuery`
/// groups one review session's already-outlier-flagged frames by
/// `OutlierBreakdown.dominantMetric`, purely from `FrameQualityMetrics` the
/// V2 review pipeline already loaded (`ReviewStore.qualityByPath`). It never
/// re-derives the z-score math itself; these fixtures pick raw fwhm/
/// background values whose group mean/std/oriented-z are hand-computed
/// below so each frame's expected dominant metric is unambiguous.
struct TriageDigestQueryTests {
    /// One shared 4-frame fixture: `a` is the clean baseline (never an
    /// outlier, exists only to shape the group's mean/std), `b`/`d` are
    /// both flagged outliers whose WORST metric is fwhm (values 6.0/5.5
    /// against the group's fwhm mean ~4.13), and `c` is a flagged outlier
    /// whose worst metric is background (400 against the group's mean 175,
    /// the other three all sitting at 100). `starCount` is identical (50)
    /// on every frame so its z-score is always exactly 0 (the
    /// `RatingGroupMath` std-is-zero guard) and can never become any
    /// frame's dominant metric -- `roundness` is left `nil` throughout so
    /// it never even enters `OutlierBreakdown`'s per-frame entries.
    private static func fourFrameFixture() -> (frames: [TriageDigestFrame], b: UUID, c: UUID, d: UUID) {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let idD = UUID()

        func quality(path: String, fwhm: Double, background: Double, isOutlier: Bool) -> FrameQualityMetrics {
            FrameQualityMetrics(
                relativePath: path,
                fwhm: fwhm,
                roundness: nil,
                starCount: 50,
                background: background,
                saturatedFraction: nil,
                score: isOutlier ? -2.0 : 0.9,
                isOutlier: isOutlier,
                libraryPercentile: nil
            )
        }

        let frames = [
            TriageDigestFrame(id: idA, relativePath: "a", quality: quality(path: "a", fwhm: 2.0, background: 100, isOutlier: false)),
            TriageDigestFrame(id: idB, relativePath: "b", quality: quality(path: "b", fwhm: 6.0, background: 100, isOutlier: true)),
            TriageDigestFrame(id: idC, relativePath: "c", quality: quality(path: "c", fwhm: 3.0, background: 400, isOutlier: true)),
            TriageDigestFrame(id: idD, relativePath: "d", quality: quality(path: "d", fwhm: 5.5, background: 100, isOutlier: true)),
        ]
        return (frames, idB, idC, idD)
    }

    @Test("Groups outlier frames by dominant metric with correct counts")
    func groupedCountsByDominantMetric() throws {
        let fixture = Self.fourFrameFixture()
        let digest = TriageDigestQuery(frames: fixture.frames)

        #expect(!digest.isEmpty)
        #expect(digest.totalOutlierCount == 3)

        let fwhmCause = try #require(digest.causes.first { $0.metric == .fwhm })
        #expect(fwhmCause.count == 2, "b and d are both fwhm-dominant outliers")

        let backgroundCause = try #require(digest.causes.first { $0.metric == .background })
        #expect(backgroundCause.count == 1, "only c is background-dominant")

        #expect(digest.causes.first { $0.metric == .roundness } == nil)
        #expect(digest.causes.first { $0.metric == .starCount } == nil)
    }

    @Test("selectFrames(forCause:) returns exactly the frames dominant in that cause")
    func selectFramesReturnsExactCauseMembers() throws {
        let fixture = Self.fourFrameFixture()
        let digest = TriageDigestQuery(frames: fixture.frames)

        #expect(Set(digest.selectFrames(forCause: .fwhm)) == Set([fixture.b, fixture.d]))
        #expect(digest.selectFrames(forCause: .background) == [fixture.c])
        #expect(digest.selectFrames(forCause: .roundness).isEmpty)
        #expect(digest.selectFrames(forCause: .starCount).isEmpty)
    }

    @Test("A session with zero outliers produces an empty digest")
    func zeroOutlierSessionIsEmpty() {
        let idA = UUID()
        let idB = UUID()
        let frames = [
            TriageDigestFrame(
                id: idA, relativePath: "a",
                quality: FrameQualityMetrics(
                    relativePath: "a", fwhm: 2.0, roundness: nil, starCount: 50, background: 100,
                    saturatedFraction: nil, score: 0.9, isOutlier: false, libraryPercentile: nil
                )
            ),
            TriageDigestFrame(
                id: idB, relativePath: "b",
                quality: FrameQualityMetrics(
                    relativePath: "b", fwhm: 2.1, roundness: nil, starCount: 50, background: 105,
                    saturatedFraction: nil, score: 0.8, isOutlier: false, libraryPercentile: nil
                )
            ),
        ]

        let digest = TriageDigestQuery(frames: frames)

        #expect(digest.isEmpty)
        #expect(digest.totalOutlierCount == 0)
        #expect(digest.causes.isEmpty)
        #expect(digest.selectFrames(forCause: .fwhm).isEmpty)
    }
}
