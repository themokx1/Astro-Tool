import Foundation
import Testing

@Suite("V4 night briefing surface")
struct NightBriefingSurfaceTests {
    private var source: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(
                contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Briefing/NightBriefingView.swift"),
                encoding: .utf8
            )
        }
    }

    @Test("The opening screen offers the three approved human choices")
    func approvedStartChoices() throws {
        let source = try source
        #expect(source.contains("A ma estét szeretném megtervezni"))
        #expect(source.contains("Másik dátumra készülök"))
        #expect(source.contains("Egy korábbi briefinget folytatok"))
    }

    @Test("The night ribbon exposes every part of the five-step workflow")
    func fiveStepRibbon() throws {
        let source = try source
        for label in ["Alapok", "Célpontok", "Capture-terv", "Checklist és B terv", "Ellenőrzés és export"] {
            #expect(source.contains(label))
        }
        #expect(source.contains("AZ ÉJSZAKA ÚTVONALA"))
    }

    @Test("Export and draft-removal copy clearly state the no-delete no-overwrite boundary")
    func safetyBoundaryIsVisible() throws {
        let source = try source
        #expect(source.contains("Nem töröl, nem mozgat és nem ír felül semmit."))
        #expect(source.contains("Meglévő fájlt az AstroTool nem ír felül."))
        #expect(source.contains("fotót nem töröl"))
    }
}
