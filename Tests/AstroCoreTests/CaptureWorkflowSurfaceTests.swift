import Foundation
import Testing

@Suite("CaptureWorkflowSurface") struct CaptureWorkflowSurfaceTests {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func everySessionSurfaceExposesCaptureAndConversionSheets() throws {
        let pages = [
            "Sources/AstroToolApp/Views/AllTargetsPage.swift",
            "Sources/AstroToolApp/Views/NightsPage.swift",
            "Sources/AstroToolApp/Views/PreviousNightPage.swift",
            "Sources/AstroToolApp/Views/TargetDetail/SessionsSegment.swift",
        ]
        for page in pages {
            let text = try source(page)
            #expect(text.contains("onCreateCapture:"), Comment(rawValue: page))
            #expect(text.contains("onConvertSession:"), Comment(rawValue: page))
            #expect(text.contains("CaptureGroupSheet("), Comment(rawValue: page))
            #expect(text.contains("SessionConversionSheet("), Comment(rawValue: page))
        }
        let shared = try source("Sources/AstroToolApp/Views/SharedComponents.swift")
        #expect(shared.components(separatedBy: "Új capture-gyűjtés…").count == 2)
        #expect(shared.components(separatedBy: "Session átalakítása gyűjtésekre…").count == 2)
    }
}
