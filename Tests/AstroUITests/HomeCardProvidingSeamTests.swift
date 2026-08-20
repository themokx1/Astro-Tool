import AstroUI
import SwiftUI
import Testing

/// Wave 0 seam (V3 pre-stack program, `HomeCardProviding`'s own doc
/// comment): pins the protocol's own contract directly (a provider can
/// return `nil` -- "nothing to show" -- or hand back a card), independent of
/// `HomeView`'s wiring (pinned separately, as literal source text, by
/// `HomeViewPreflightChecklistSurfaceTests.extraCardProvidersDefaultToEmptyAndRenderAfterPreflight`,
/// following that suite's own "HomeView needs a live HomeStore snapshot to
/// render at all" rationale for using source text rather than a rendered
/// view hierarchy there).
@MainActor
@Suite("Home card provider seam (Wave 0)")
struct HomeCardProvidingSeamTests {
    private struct StubProvider: HomeCardProviding {
        let result: AnyView?
        func card(store: HomeStore) -> AnyView? { result }
    }

    @Test("A provider that has nothing real to show returns nil")
    func nilProviderContributesNothing() {
        let provider = StubProvider(result: nil)
        #expect(provider.card(store: HomeStore()) == nil)
    }

    @Test("A provider with something to show hands its card back verbatim")
    func nonNilProviderReturnsItsCard() {
        let provider = StubProvider(result: AnyView(Text("Stub card")))
        #expect(provider.card(store: HomeStore()) != nil)
    }
}
