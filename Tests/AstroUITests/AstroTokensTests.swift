import Foundation
import Testing

/// Wave 2 Task 2: gates for the rebuilt `AstroTokens` color system.
///
/// Both gates were proven to fail before they passed: gate 1 was run against
/// the pre-rewrite `AstroTokens.swift` (five single-`NSColor` tokens) and
/// failed as expected; gate 2 was run once with a deliberately-injected
/// `AstroTokens.Color.data*` + `severity` line under `Features/`, watched to
/// fail, then reverted.
@Suite("AstroTokens color system")
struct AstroTokensTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func filenames(under relativePath: String, recursive: Bool) throws -> [String] {
        let directory = repositoryRoot.appendingPathComponent(relativePath)
        guard recursive else {
            return try FileManager.default.contentsOfDirectory(atPath: directory.path)
        }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var results: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            results.append(url.path.replacingOccurrences(of: repositoryRoot.path + "/", with: ""))
        }
        return results
    }

    /// Strips `//` and `///` line comments, string-literal-aware, so a
    /// doc comment mentioning a banned word by name never trips a gate.
    /// Same algorithm as `V2PolishSurfaceTests.removingLineComments`.
    private func strippingComments(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var i = source.startIndex
        var inLineComment = false
        var inString = false
        while i < source.endIndex {
            let c = source[i]
            let next = source.index(after: i)
            if inLineComment {
                if c == "\n" { inLineComment = false; result.append(c) }
                i = next
                continue
            }
            if inString {
                result.append(c)
                if c == "\\", next < source.endIndex {
                    result.append(source[next])
                    i = source.index(after: next)
                    continue
                }
                if c == "\"" { inString = false }
                i = next
                continue
            }
            if c == "\"" {
                inString = true
                result.append(c)
                i = next
                continue
            }
            if c == "/", next < source.endIndex, source[next] == "/" {
                inLineComment = true
                i = source.index(after: next)
                continue
            }
            result.append(c)
            i = next
        }
        return result
    }

    // MARK: Gate 1 -- every token adapts to both appearances.

    @Test("Every semantic color token defines both appearances")
    func everyColorDefinesBothAppearances() throws {
        let source = try contents("Sources/AstroUI/DesignSystem/AstroTokens.swift")
        // A token whose only definition is a single NSColor never adapts: it
        // renders one appearance's ink on the other appearance's ground.
        // Every token here is built from a dynamic provider with two
        // distinct values.
        let singleValued = source.components(separatedBy: "static let")
            .filter { $0.contains("SwiftUI.Color(") && !$0.contains("dynamicProvider") && !$0.contains("dynamic(") }
        #expect(singleValued.isEmpty, "a token is defined for one appearance only")
    }

    // MARK: Gate 2 -- data-category colors never carry status meaning.

    @Test("Data-category colors are never used to express status")
    func dataColorsAreNotStatus() throws {
        for file in try filenames(under: "Sources/AstroUI/Features", recursive: true) {
            let source = strippingComments(try contents(file))
            for line in source.split(separator: "\n") where line.contains("AstroTokens.Color.data") {
                #expect(!line.contains("severity") && !line.contains("isHealthy") && !line.contains("verdict"),
                        "\(file): a data-category color is carrying status meaning")
            }
        }
    }
}
