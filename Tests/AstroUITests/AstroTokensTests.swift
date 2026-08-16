import Foundation
import Testing

/// Wave 2 Task 2: gates for the rebuilt `AstroTokens` color system.
///
/// Both gates were proven to fail before they passed: gate 1 was run against
/// the pre-rewrite `AstroTokens.swift` (five single-`NSColor` tokens) and
/// failed as expected; gate 2 was run once with a deliberately-injected
/// `AstroTokens.Color.data*` + `severity` line under `Features/`, watched to
/// fail, then reverted.
///
/// Wave 2 Task 2b: gate 2 was extended to also catch the reverse direction
/// (a status color carrying data). Proven against the live tree, not a
/// synthetic injection: run before `InsightsView.swift`'s Efficiency trend
/// chart was fixed, it failed and named exactly that call site
/// (`AstroTokens.Color.ok` reaching `trendChart`'s `Chart` via its `color`
/// argument); run again after the fix, it passed. See
/// `statusColorOffenses`'s doc comment for exactly what the reverse check
/// catches and what it does not.
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

    // MARK: Gate 2 -- data-category colors never carry status meaning, and vice versa.

    @Test("Semantic colors never cross the data/status boundary in either direction")
    func dataColorsAreNotStatus() throws {
        for file in try filenames(under: "Sources/AstroUI/Features", recursive: true) {
            let source = strippingComments(try contents(file))

            // Forward: a data-category color must never carry status meaning.
            for line in source.split(separator: "\n") where line.contains("AstroTokens.Color.data") {
                #expect(!line.contains("severity") && !line.contains("isHealthy") && !line.contains("verdict"),
                        "\(file): a data-category color is carrying status meaning")
            }

            // Reverse: a status color must never paint a data series.
            let offenses = statusColorOffenses(in: source)
            #expect(offenses.isEmpty, "\(file): status color(s) appear to paint a data series: \(offenses.joined(separator: ", "))")
        }
    }

    // MARK: Gate 2, reverse direction -- status colors never paint a data series.

    /// Finds uses of a status token (`ok`/`attention`/`critical`) that look
    /// like they are painting a chart's data series rather than expressing
    /// status.
    ///
    /// What this catches:
    /// - the token attached to a `LineMark`/`PointMark`/`BarMark`/`AreaMark`
    ///   statement -- either as a direct argument or via a chained
    ///   `.foregroundStyle(...)`/other modifier on that same statement.
    ///   `RuleMark` is deliberately excluded: a threshold/reference line is
    ///   not a data series, and coloring one `attention` is the correct fix
    ///   for `SkyPathChart.swift`'s imaging-altitude threshold, not a
    ///   violation of this rule;
    /// - the token passed as an argument to a call whose callee name
    ///   contains "Chart" (case-sensitively, so SwiftUI's own lowercase
    ///   `.chartYAxis`/`.chartXAxis`/... modifiers never match) -- this is
    ///   what catches a local helper such as `trendChart(..., color:
    ///   AstroTokens.Color.ok)` that builds its own `Chart` elsewhere in the
    ///   same file from a color parameter, one level removed from the
    ///   `Chart { }` block itself.
    ///
    /// What this does NOT catch:
    /// - a status color threaded through more than one layer of
    ///   indirection -- stored in a local `let`/property first, passed
    ///   through a helper whose name does not contain "Chart", or passed
    ///   across files entirely;
    /// - a data series drawn without Swift Charts' `Chart`/`*Mark` types --
    ///   a hand-rolled `Canvas`/`Path` drawing that mimics a chart;
    /// - a status color that reaches a series via a computed property or a
    ///   ternary whose branches are not textually adjacent to the token
    ///   (e.g. `condition ? .ok : .critical` assigned to a `let` well before
    ///   the `Chart` block that consumes it).
    private func statusColorOffenses(in source: String) -> [String] {
        let suspectRanges = markStatementRanges(in: source) + chartNamedCallArgumentRanges(in: source)
        guard !suspectRanges.isEmpty else { return [] }
        var offenses: [String] = []
        var seenLocations = Set<Int>()
        for token in ["ok", "attention", "critical"] {
            guard let regex = try? NSRegularExpression(pattern: "AstroTokens\\.Color\\.\(token)\\b") else { continue }
            let nsSource = source as NSString
            let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
            for match in matches {
                let location = match.range.location
                guard !seenLocations.contains(location) else { continue }
                if suspectRanges.contains(where: { $0.contains(location) }) {
                    seenLocations.insert(location)
                    offenses.append("AstroTokens.Color.\(token)")
                }
            }
        }
        return offenses
    }

    /// UTF-16 offset ranges spanning each `LineMark`/`PointMark`/`BarMark`/
    /// `AreaMark` statement, from the mark's own constructor through any
    /// chained fluent modifiers (`.foregroundStyle(...)`,
    /// `.interpolationMethod(...)`, ...) on the same statement. Stops at the
    /// first following token that isn't a chained `.` modifier -- i.e. the
    /// start of the next statement. `RuleMark`/`AxisMarks`/etc. are excluded
    /// by construction: only these four literal names are matched.
    private func markStatementRanges(in source: String) -> [Range<Int>] {
        guard let markRegex = try? NSRegularExpression(pattern: #"\b(LineMark|PointMark|BarMark|AreaMark)\("#) else { return [] }
        let nsSource = source as NSString
        let units = Array(source.utf16)
        let openParen: UInt16 = 40, closeParen: UInt16 = 41, dot: UInt16 = 46
        let matches = markRegex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
        var ranges: [Range<Int>] = []
        for match in matches {
            // The constructor's own argument list: from the "(" the regex
            // matched through its balanced close.
            var idx = match.range.location + match.range.length - 1
            guard let constructorClose = matchingClose(units, openIndex: idx, open: openParen, close: closeParen) else { continue }
            var statementEnd = constructorClose
            idx = constructorClose + 1
            // Extend through any chained ".modifier(...)" calls.
            while idx < units.count {
                while idx < units.count, isWhitespaceOrNewline(units[idx]) { idx += 1 }
                guard idx < units.count, units[idx] == dot else { break }
                idx += 1
                while idx < units.count, units[idx] != openParen, !isWhitespaceOrNewline(units[idx]), units[idx] != dot { idx += 1 }
                if idx < units.count, units[idx] == openParen {
                    guard let close = matchingClose(units, openIndex: idx, open: openParen, close: closeParen) else { break }
                    statementEnd = close
                    idx = close + 1
                } else {
                    statementEnd = idx - 1
                }
            }
            ranges.append(match.range.location..<(statementEnd + 1))
        }
        return ranges
    }

    /// UTF-16 offset ranges spanning the parenthesized argument list of
    /// every call whose callee name contains "Chart" (case-sensitive, so
    /// SwiftUI's lowercase `.chartYAxis`/... modifiers never match).
    private func chartNamedCallArgumentRanges(in source: String) -> [Range<Int>] {
        guard let callRegex = try? NSRegularExpression(pattern: #"[A-Za-z0-9_]*Chart[A-Za-z0-9_]*\("#) else { return [] }
        let nsSource = source as NSString
        let units = Array(source.utf16)
        let openParen: UInt16 = 40, closeParen: UInt16 = 41
        let matches = callRegex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
        var ranges: [Range<Int>] = []
        for match in matches {
            let start = match.range.location + match.range.length - 1
            guard let close = matchingClose(units, openIndex: start, open: openParen, close: closeParen) else { continue }
            ranges.append(start..<(close + 1))
        }
        return ranges
    }

    /// Scans forward from `openIndex` (which must hold `open`), counting
    /// nested `open`/`close` pairs, and returns the index of the matching
    /// `close`, or `nil` if the source ends unbalanced.
    private func matchingClose(_ units: [UInt16], openIndex: Int, open: UInt16, close: UInt16) -> Int? {
        var depth = 0
        var j = openIndex
        while j < units.count {
            if units[j] == open { depth += 1 }
            else if units[j] == close {
                depth -= 1
                if depth == 0 { return j }
            }
            j += 1
        }
        return nil
    }

    private func isWhitespaceOrNewline(_ unit: UInt16) -> Bool {
        unit == 32 || unit == 9 || unit == 10 || unit == 13
    }
}
