import Foundation
import Testing

@Suite("TrendsDashboardSurface") struct TrendsDashboardSurfaceTests {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/AstroToolApp/Views/TrendsPage.swift"),
            encoding: .utf8
        )
    }

    @Test func trendsExposeAcquisitionDashboardBeforeOptionalQualityMetrics() throws {
        let text = try source()
        #expect(text.contains("Fotózási aktivitás"))
        #expect(text.contains("Összes integráció"))
        #expect(text.contains("Fotózási éjszakák"))
        #expect(text.contains("Célpontok szerint"))
        #expect(text.contains("Szűrők szerint"))
        #expect(text.contains("Minőség és hatékonyság"))
        #expect(text.contains("TrendAnalytics.summarize(filteredPoints)"))
        #expect(!text.contains("filteredPoints.count < Self.minPointsForCharts"))
    }
}
