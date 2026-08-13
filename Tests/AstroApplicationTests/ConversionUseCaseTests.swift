@testable import AstroApplication
import Testing

struct ConversionUseCaseTests {
    @Test("Converter is scoped to exactly one session and defaults logical")
    func oneSessionLogicalPreview() async throws {
        let plan = try await ConversionUseCase.fixture().plan(sessionID: .ic1396)

        #expect(plan.scope.sessionCount == 1)
        #expect(plan.mode == .logical)
        #expect(plan.moves.isEmpty)
        #expect(plan.proposedSeries.map(\.exposureSeconds).sorted() == [5, 30, 120, 300])
    }

    @Test("Physical conversion is never implicitly authorized")
    func physicalNeedsExplicitAuthorization() async throws {
        let useCase = ConversionUseCase.fixture()
        let plan = try await useCase.plan(sessionID: .ic1396, mode: .physical)

        #expect(!plan.canApply)
        #expect(plan.authorizationMessage != nil)
    }
}
