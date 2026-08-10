import AstroApplication
import Testing

@Suite("AstroApplication smoke tests")
struct AstroApplicationSmokeTests {
    @Test("AstroApplication module is available")
    func moduleIsAvailable() {
        #expect(AstroApplicationModule.isAvailable)
    }
}
