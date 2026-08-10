import AstroUI
import Testing

@Suite("AstroUI smoke tests")
struct AstroUISmokeTests {
    @Test("AstroUI module is available")
    func moduleIsAvailable() {
        #expect(AstroUIModule.isAvailable)
    }
}
