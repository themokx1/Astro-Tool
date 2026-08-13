import Foundation
import Testing

struct V2FeatureParityTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("Every V1 workflow has one complete and honest parity record")
    func completeMatrix() throws {
        let url = root.appendingPathComponent("docs/superpowers/reviews/v2-feature-parity.csv")
        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = try parse(text)
        let expected = Set([
            "tonight", "calendar", "discover", "previous-night", "all-targets", "nights",
            "target-detail", "calibration", "audit", "cleanup", "trends", "sensor-profiles",
            "filter-profiles", "search", "settings-general", "settings-library", "settings-planning",
            "settings-equipment", "settings-support",
        ])

        #expect(Set(rows.map { $0["v1_workflow"]! }) == expected)
        #expect(rows.count == expected.count)
        for row in rows {
            for column in Self.columns { #expect(!(row[column] ?? "").trimmingCharacters(in: .whitespaces).isEmpty) }
            #expect(["complete", "beta-partial", "blocked"].contains(row["status"]!))
            if row["status"] == "complete" { #expect(row["known_gap"] == "none") }
            if row["status"] != "complete" { #expect(row["known_gap"] != "none") }
        }
    }

    @Test("No workflow may claim completion without named unit and UI evidence")
    func completedRowsNameEvidence() throws {
        let text = try String(contentsOf: root.appendingPathComponent("docs/superpowers/reviews/v2-feature-parity.csv"))
        for row in try parse(text) where row["status"] == "complete" {
            #expect(row["unit_test"]!.contains("Tests"))
            #expect(row["ui_test"]!.contains("Tests"))
            #expect(row["empty_error_state"] != "missing")
        }
    }

    @Test("Overstated rows are downgraded to beta-partial with an honest known gap")
    func overstatedRowsAreDowngraded() throws {
        let text = try String(contentsOf: root.appendingPathComponent("docs/superpowers/reviews/v2-feature-parity.csv"))
        let rows = try parse(text)
        let byWorkflow = Dictionary(uniqueKeysWithValues: rows.map { ($0["v1_workflow"]!, $0) })
        for workflow in ["target-detail", "all-targets", "settings-planning", "trends", "discover"] {
            let row = try #require(byWorkflow[workflow])
            #expect(row["status"] == "beta-partial")
            #expect(row["known_gap"] != "none")
        }
    }

    private static let columns = [
        "v1_workflow", "v2_route", "use_case", "permission_mode", "unit_test", "ui_test",
        "cli_report_parity", "accessibility", "empty_error_state", "status", "known_gap",
    ]

    private func parse(_ text: String) throws -> [[String: String]] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let header = try #require(lines.first?.split(separator: ",", omittingEmptySubsequences: false).map(String.init))
        #expect(header == Self.columns)
        return lines.dropFirst().map { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            #expect(fields.count == header.count)
            return Dictionary(uniqueKeysWithValues: zip(header, fields))
        }
    }
}
