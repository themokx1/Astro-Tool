@testable import AstroApplication
import Testing

struct PlanningQueryTests {
    @Test("Tiny objects rank behind composition-sized targets at 200 mm")
    func tinyObjectsRankBehindUsefulCompositions() {
        let result = PlanningQuery.fixture(focalLength: 200).recommendations()

        #expect(result.first?.frameCoverage ?? 0 > result.last?.frameCoverage ?? 0)
        #expect(result.last?.fit == .tooSmall)
        #expect(result.first?.compositionScore ?? 0 > result.last?.compositionScore ?? 0)
    }

    @Test("Planning exposes honest source and confidence for goal time")
    func recommendationExplainsItsEstimate() throws {
        let elephant = try #require(
            PlanningQuery.fixture(focalLength: 200).recommendations()
                .first { $0.target.designation == "IC 1396" }
        )

        #expect(elephant.integrationHours > 0)
        #expect(!elephant.integrationSource.isEmpty)
        #expect(elephant.integrationConfidence != .unknown)
    }
}
