@testable import AstroApplication
import Testing

struct LibraryHealthQueryTests {
    @Test("Health summary separates actionable calibration issues")
    func fixtureHealthSummary() async throws {
        let snapshot = try await LibraryHealthQuery.fixture().snapshot()

        #expect(snapshot.sessionCount == 1)
        #expect(snapshot.calibrationIssues == 2)
        #expect(snapshot.items.contains { $0.category == .flat && $0.severity == .warning })
        #expect(snapshot.isReadOnly)
    }
}
