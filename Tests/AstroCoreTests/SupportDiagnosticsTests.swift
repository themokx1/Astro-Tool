import Foundation
import Testing
@testable import AstroCore

@Suite("Privacy-safe support diagnostics")
struct SupportDiagnosticsTests {
    @Test("Export contains useful product and aggregate state")
    func usefulAggregateState() {
        let diagnostics = SupportDiagnostics(
            generatedAt: Date(timeIntervalSince1970: 1_786_363_200),
            productVersion: "1.0.0",
            build: "7",
            operatingSystem: "macOS 26.1",
            architecture: "arm64",
            databaseSchemaVersion: 12,
            libraryConnected: true,
            targetCount: 13,
            sessionCount: 25,
            filterProfileCount: 2,
            sensorProfileCount: 1,
            weatherEnabled: false,
            recentOperations: [
                .init(date: Date(timeIntervalSince1970: 1_786_310_000), kind: .scan, succeeded: true),
                .init(date: Date(timeIntervalSince1970: 1_786_309_000), kind: .quality, succeeded: false),
            ]
        )

        let text = diagnostics.plainText
        #expect(text.contains("AstroTool 1.0.0 (7)"))
        #expect(text.contains("Adatbázisséma: 12"))
        #expect(text.contains("Célpontok: 13"))
        #expect(text.contains("Sessionök: 25"))
        #expect(text.contains("Beolvasás — sikeres"))
        #expect(text.contains("Minőségmérés — sikertelen"))
    }

    @Test("The model cannot accept private library details")
    func excludesPrivateLibraryDetails() {
        let diagnostics = SupportDiagnostics(
            generatedAt: .distantPast,
            productVersion: "1.0.0",
            build: "1",
            operatingSystem: "macOS",
            architecture: "arm64",
            databaseSchemaVersion: nil,
            libraryConnected: false,
            targetCount: 0,
            sessionCount: 0,
            filterProfileCount: 0,
            sensorProfileCount: 0,
            weatherEnabled: false,
            recentOperations: []
        )

        let text = diagnostics.plainText
        for privateValue in [
            "/Volumes/private/Astro/secret.fit",
            "21h 40m 23.0s",
            "+57° 38′ 55.0″",
            "my observing note",
            "security-scoped bookmark",
            "api_token_123",
        ] {
            #expect(!text.contains(privateValue))
        }
        #expect(text.contains("Képkönyvtár kapcsolódik: nem"))
        #expect(text.contains("Adatbázisséma: nincs megnyitva"))
    }

    @Test("Suggested export name contains no library identity")
    func safeFilename() {
        let diagnostics = SupportDiagnostics(
            generatedAt: Date(timeIntervalSince1970: 1_786_363_200),
            productVersion: "1.0.0",
            build: "1",
            operatingSystem: "macOS",
            architecture: "arm64",
            databaseSchemaVersion: 12,
            libraryConnected: true,
            targetCount: 1,
            sessionCount: 1,
            filterProfileCount: 0,
            sensorProfileCount: 0,
            weatherEnabled: false,
            recentOperations: []
        )

        #expect(diagnostics.suggestedFilename == "AstroTool-diagnostics-2026-08-10.txt")
    }
}
