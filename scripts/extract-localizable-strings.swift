#!/usr/bin/env swift
// Extracts every user-facing literal that SwiftUI resolves as a
// `LocalizedStringKey` from `Sources/AstroUI` -- the literal arguments to
// `Text`, `Button`, `Label`, `Toggle`, `Picker`, `TableColumn`, `GroupBox`,
// `Section`, `LabeledContent`, `TextField`, `DatePicker`, `Stepper`, `Menu`,
// `Link`, `.help`, `.accessibilityLabel`, `.navigationTitle`,
// `.navigationSubtitle`, `ContentUnavailableView`, `.confirmationDialog` and
// `.alert`.
//
// Every one of those is a construct whose FIRST positional argument is typed
// `LocalizedStringKey` (a title, a label, or a text-field placeholder) --
// that positional-first-argument shape is exactly what this script's single
// scanning strategy (match the construct, then require a literal
// immediately after the opening parenthesis) can extract. `GroupBox`,
// `Section`, `LabeledContent`, `TextField`, `DatePicker`, `Stepper`, `Menu`
// and `Link` were added after an owner screenshot showed English text
// (`GroupBox("Target recommendations")`, `GroupBox("Sky path tonight")`,
// `GroupBox("Saved projects")`, and others) surviving the Hungarian
// translation pass simply because the original construct list didn't cover
// their call sites -- verified with
// `grep -rnE '\b(GroupBox|Section|LabeledContent|TextField|DatePicker|Stepper|Menu|Link)\(\s*"' Sources/AstroUI`
// before and after this change: every literal-first-argument call site that
// grep finds is now also something this script extracts (the two
// intentional exceptions -- `TextField(Self.examplePlaceholder(for: key), …)`
// and `Menu(selectedNightFilter ?? "…")` -- aren't literals at all, see the
// design notes below). `Toggle`'s `isOn:`-first form
// (`Toggle(isOn: $x) { Text("…") }`) needed no new pattern: its label lives
// in a trailing `Text(…)`, which the existing `Text(` pattern already
// covers.
//
// A LocalizedStringKey construct whose literal is NOT its first positional
// argument -- `.searchable(text:prompt:)`'s `prompt:`, or any bespoke SwiftUI
// view's own `title:`/`label:`-named parameter -- is out of scope for this
// general pass; see `MetricCard`'s `title`/`detail` fix (V2 UI/UX audit,
// 2026-08-16) for how a specific named-parameter view gets its own
// extraction support once it actually carries `LocalizedStringKey`
// properties.
//
// This is the reproducible source of truth
// `Tests/AstroUITests/LocalizationCoverageTests.swift` checks against: it
// invokes this script as a subprocess and asserts every key it prints has
// either a `hu.lproj/Localizable.strings` entry or is on the allowlist.
// Run directly for a human-readable report:
//
//   swift scripts/extract-localizable-strings.swift
//   swift scripts/extract-localizable-strings.swift --missing   # only keys absent from hu.lproj
//
// Design notes (see docs/superpowers/plans/2026-08-15-localization.md):
//
// - Only call sites where the literal string immediately follows the
//   opening parenthesis are extracted. A `Text(someComputedString)` or
//   `Text(condition ? "A" : "B")` call is not a `LocalizedStringKey`
//   literal at all -- Swift resolves it through `Text`'s verbatim
//   `StringProtocol` overload instead, so it was never eligible for this
//   mechanism and has nothing to extract. That is a real, if small,
//   documented gap in "zero call-site changes": those specific strings stay
//   English-only until someone changes the call site itself.
//
// - Interpolated literals (`"\(x) frames"`) are supported. The extracted
//   "key" mirrors the exact key `LocalizedStringKey` builds internally
//   (verified empirically: Int-like interpolations become `%lld`,
//   floating-point become `%lf`, `String`/`.formatted()`/explicit
//   `, format:` values become `%@`) so that a translated `hu.lproj` entry
//   actually gets found by `Bundle.main.localizedString(forKey:)` at
//   runtime, not just by this script. Placeholder-type inference is a
//   best-effort heuristic (a small property-type index built from `let`/
//   `var` declarations across `Sources/`, plus a few naming fallbacks) --
//   a wrong guess fails safe: the key simply won't match at runtime and the
//   string silently stays in English, exactly like a key with no
//   translation at all. It does not crash and does not mistranslate.

import Foundation

// MARK: - Paths

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let scriptsDir = scriptURL.deletingLastPathComponent()
let repoRoot = scriptsDir.lastPathComponent == "scripts"
    ? scriptsDir.deletingLastPathComponent()
    : FileManager.default.currentDirectoryPath.hasSuffix("scripts")
        ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent()
        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourcesRoot = repoRoot.appendingPathComponent("Sources")
let astroUIRoot = sourcesRoot.appendingPathComponent("AstroUI")

func swiftFiles(under root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ) else { return [] }
    var result: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        result.append(url)
    }
    return result.sorted { $0.path < $1.path }
}

// MARK: - Comment stripping
//
// Doc comments sometimes quote example call sites (see this very file's own
// header, or `AppLanguage.swift`'s doc comments) -- without stripping
// comments first, those examples would be extracted as if they were real
// call sites.

func removingComments(_ source: String) -> String {
    var result = ""
    result.reserveCapacity(source.count)
    var i = source.startIndex
    var inLineComment = false
    var inBlockComment = false
    var inString = false
    while i < source.endIndex {
        let c = source[i]
        let next = source.index(after: i)
        if inLineComment {
            if c == "\n" { inLineComment = false; result.append(c) }
            i = next
            continue
        }
        if inBlockComment {
            if c == "*", next < source.endIndex, source[next] == "/" {
                inBlockComment = false
                i = source.index(after: next)
                continue
            }
            if c == "\n" { result.append(c) }
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
        if c == "/", next < source.endIndex, source[next] == "*" {
            inBlockComment = true
            i = source.index(after: next)
            continue
        }
        result.append(c)
        i = next
    }
    return result
}

// MARK: - Property-type index (for interpolation placeholder inference)

enum TypeCategory: String {
    case integer = "%lld"
    case floating = "%lf"
    case other = "%@"
}

func categoryFor(_ typeName: String) -> TypeCategory {
    let base = typeName.trimmingCharacters(in: CharacterSet(charactersIn: "? "))
    switch base {
    case "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
        return .integer
    case "Double", "Float", "CGFloat":
        return .floating
    default:
        return .other
    }
}

/// Local view helpers like `private func duration(_ seconds: Double) -> String`
/// are extremely common in `Sources/AstroUI` as inline formatters
/// (`duration(...)`, `exposure(...)`, `formattedNumber(...)`); an
/// interpolation like `\(duration(snapshot.integrationSeconds))` must be
/// classified by `duration`'s own *return* type, not by digging into its
/// argument (`integrationSeconds: Double`) -- that argument-vs-return-type
/// confusion was an early bug this index exists to fix.
func buildFunctionReturnTypeIndex() -> [String: TypeCategory] {
    var index: [String: TypeCategory] = [:]
    let declarationPattern = try! NSRegularExpression(
        pattern: #"func\s+([A-Za-z_][A-Za-z0-9_]*)\s*\([^)]*\)(?:\s*async)?(?:\s*throws)?\s*->\s*([A-Za-z][A-Za-z0-9_]*\??)"#
    )
    for file in swiftFiles(under: sourcesRoot) {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let source = removingComments(raw)
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        declarationPattern.enumerateMatches(in: source, range: nsRange) { match, _, _ in
            guard let match, match.numberOfRanges == 3,
                  let nameRange = Range(match.range(at: 1), in: source),
                  let typeRange = Range(match.range(at: 2), in: source)
            else { return }
            let name = String(source[nameRange])
            let category = categoryFor(String(source[typeRange]))
            if let existing = index[name] {
                if existing != category { index[name] = .other }
            } else {
                index[name] = category
            }
        }
    }
    return index
}

func buildPropertyTypeIndex() -> [String: TypeCategory] {
    var index: [String: TypeCategory] = [:]
    let declarationPattern = try! NSRegularExpression(
        pattern: #"(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([A-Za-z][A-Za-z0-9_]*\??)"#
    )
    for file in swiftFiles(under: sourcesRoot) {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let source = removingComments(raw)
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        declarationPattern.enumerateMatches(in: source, range: nsRange) { match, _, _ in
            guard let match, match.numberOfRanges == 3,
                  let nameRange = Range(match.range(at: 1), in: source),
                  let typeRange = Range(match.range(at: 2), in: source)
            else { return }
            let name = String(source[nameRange])
            let category = categoryFor(String(source[typeRange]))
            // Only record a category if every declaration of this property
            // name agrees -- an ambiguous name (declared as different types
            // in different places) falls back to `.other` (`%@`), which is
            // the safe default anyway.
            if let existing = index[name] {
                if existing != category { index[name] = .other }
            } else {
                index[name] = category
            }
        }
    }
    return index
}

// A handful of local closure/loop variables never appear in a `let`/`var`
// type declaration (their type is inferred), so the property-type index
// above cannot see them. These are the only such cases observed in
// `Sources/AstroUI` today; extend this list if `--missing` ever reports a
// new one that turns out to be numeric.
let knownIntegerIdentifiers: Set<String> = ["index", "count", "number"]

// MARK: - Interpolation placeholder inference

let wholeExpressionIsACallPattern = try! NSRegularExpression(
    pattern: #"^[A-Za-z_][A-Za-z0-9_]*\(.*\)$"#
)

func inferPlaceholder(
    for rawExpr: String,
    typeIndex: [String: TypeCategory],
    functionReturnTypeIndex: [String: TypeCategory]
) -> String {
    let expr = rawExpr.trimmingCharacters(in: .whitespacesAndNewlines)

    if expr.contains(", format:") || expr.contains(",format:") { return "%@" }
    if expr.contains(".formatted(") || expr.hasSuffix(".formatted()") { return "%@" }
    if expr.hasSuffix(".count") { return "%lld" }
    if expr.range(of: #"^-?\d+$"#, options: .regularExpression) != nil { return "%lld" }
    if expr.range(of: #"^-?\d+\.\d+$"#, options: .regularExpression) != nil { return "%lf" }

    // A bare top-level call like "duration(snapshot.integrationSeconds)" must
    // be classified by what `duration` RETURNS, not by digging into its
    // argument -- otherwise an argument like `integrationSeconds: Double`
    // leaks through as if the whole expression were a Double.
    let fullRange = NSRange(expr.startIndex..<expr.endIndex, in: expr)
    if wholeExpressionIsACallPattern.firstMatch(in: expr, range: fullRange) != nil,
       let openParen = expr.firstIndex(of: "(") {
        let calleeName = String(expr[expr.startIndex..<openParen])
        if let category = functionReturnTypeIndex[calleeName] { return category.rawValue }
        // An unrecognized callee (defined outside Sources/, or a SwiftUI/
        // Foundation API we didn't index) still isn't a bare property --
        // default to the same safe %@ every other unresolved case uses.
        return "%@"
    }

    if let lastComponent = lastIdentifierComponent(of: expr) {
        if knownIntegerIdentifiers.contains(lastComponent) { return "%lld" }
        if let category = typeIndex[lastComponent] { return category.rawValue }
        if lastComponent.hasSuffix("Count") { return "%lld" }
    }
    return "%@"
}

/// Best-effort: the trailing identifier word in an interpolation expression,
/// e.g. "row.snapshot.usableFrames" -> "usableFrames", "total" -> "total",
/// "index + 1" -> "index" is intentionally NOT what this returns (the `+ 1`
/// makes "1" the trailing token, which the numeric-literal check above
/// already handles as a fallback to the identifier check) -- this function
/// only needs to find *a* representative identifier, and for a bare
/// arithmetic expression like "index + 1" the plain numeric-literal branch
/// never matches "index + 1" as a whole, so this function is reached; it
/// returns the LAST identifier-shaped token, which for "index + 1" is
/// nothing (since "1" is numeric, not identifier-shaped) -- so it falls
/// through to scanning right-to-left for the first alphabetic token.
func lastIdentifierComponent(of expr: String) -> String? {
    let scalars = Array(expr)
    var i = scalars.count - 1
    func isIdentifierChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
    while i >= 0 {
        if isIdentifierChar(scalars[i]) && !scalars[i].isNumber {
            var j = i
            while j >= 0, isIdentifierChar(scalars[j]) { j -= 1 }
            let token = String(scalars[(j + 1)...i])
            return token
        }
        if isIdentifierChar(scalars[i]) {
            // trailing numeric token (e.g. "+ 1") -- skip back over it and
            // any following non-identifier characters to find the real
            // identifier before it.
            var j = i
            while j >= 0, isIdentifierChar(scalars[j]) { j -= 1 }
            i = j
            continue
        }
        i -= 1
    }
    return nil
}

// MARK: - String literal scanning

struct ScannedLiteral {
    let displayKey: String
    let endIndex: String.Index
}

/// `start` must point at the opening `"`. Returns nil if `start` isn't a
/// quote, or the literal never closes (malformed/truncated input).
func scanStringLiteral(
    _ source: String,
    from start: String.Index,
    typeIndex: [String: TypeCategory],
    functionReturnTypeIndex: [String: TypeCategory]
) -> ScannedLiteral? {
    guard start < source.endIndex, source[start] == "\"" else { return nil }
    var i = source.index(after: start)
    var result = ""
    while i < source.endIndex {
        let c = source[i]
        if c == "\\" {
            let next = source.index(after: i)
            guard next < source.endIndex else { return nil }
            let nc = source[next]
            if nc == "(" {
                var depth = 1
                let exprStart = source.index(after: next)
                var j = exprStart
                while j < source.endIndex, depth > 0 {
                    let cj = source[j]
                    if cj == "(" { depth += 1 } else if cj == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    j = source.index(after: j)
                }
                guard j < source.endIndex else { return nil }
                let expr = String(source[exprStart..<j])
                result += inferPlaceholder(for: expr, typeIndex: typeIndex, functionReturnTypeIndex: functionReturnTypeIndex)
                i = source.index(after: j)
                continue
            } else {
                result.append(c)
                result.append(nc)
                i = source.index(after: next)
                continue
            }
        } else if c == "\"" {
            return ScannedLiteral(displayKey: result, endIndex: source.index(after: i))
        } else {
            result.append(c)
            i = source.index(after: i)
        }
    }
    return nil
}

// MARK: - Construct scanning

/// Each entry is a regex matching everything up to (and including) the
/// character immediately before the literal's opening quote, so the match's
/// end index is where `scanStringLiteral` should start.
let constructPatterns: [String] = [
    #"\bText\(\s*"#,
    #"\bButton\(\s*"#,
    #"\bLabel\(\s*"#,
    #"\bToggle\(\s*"#,
    #"\bPicker\(\s*"#,
    #"\bTableColumn\(\s*"#,
    #"\bGroupBox\(\s*"#,
    #"\bSection\(\s*"#,
    #"\bLabeledContent\(\s*"#,
    #"\bTextField\(\s*"#,
    #"\bDatePicker\(\s*"#,
    #"\bStepper\(\s*"#,
    #"\bMenu\(\s*"#,
    #"\bLink\(\s*"#,
    // `MetricCard`'s `title:` (V2 UI/UX audit, 2026-08-16 -- was a plain
    // `String`, so it never localized at all; see `WorkspaceComponents.swift`).
    // `detail:` is deliberately NOT covered here: it's the same named
    // parameter `ConversionWorkspace.swift`'s still-`String`-typed
    // `stepLabel`/`LibraryWelcomeView.swift`'s `safetyRow` helpers also use,
    // and this script has no balanced-parenthesis call-site tracking to tell
    // "inside a MetricCard(...) call" from "inside a stepLabel(...) call" --
    // extracting it there would silently claim strings are localized that
    // aren't yet. `MetricCard`'s `detail:` literals are translated by hand
    // in `hu.lproj` instead (see the commit that made this change).
    #"\bMetricCard\(\s*title:\s*"#,
    #"\.help\(\s*"#,
    #"\.accessibilityLabel\(\s*"#,
    #"\.navigationTitle\(\s*"#,
    #"\.navigationSubtitle\(\s*"#,
    #"\bContentUnavailableView\(\s*"#,
    #"\.confirmationDialog\(\s*"#,
    #"\.alert\(\s*"#,
]

struct Extraction {
    let key: String
    let file: String
    let line: Int
}

func lineNumber(of index: String.Index, in source: String) -> Int {
    source.distance(from: source.startIndex, to: index) == 0
        ? 1
        : source[source.startIndex..<index].reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
}

/// `Text("segment one" + "segment two")` is not a `LocalizedStringKey`
/// literal at all -- `String + String` concatenation produces a plain
/// `String`, which routes through `Text`'s verbatim (never-localized)
/// overload. Extracting just the first segment as if it were a real key
/// would be a false positive with nothing at runtime to match it against;
/// this call site needs to change (e.g. build one combined literal, or use
/// separate `Text` views) before it can be localized at all, which is
/// outside this script's "zero call-site changes" scope.
func isFollowedByStringConcatenation(_ source: String, after index: String.Index) -> Bool {
    var i = index
    while i < source.endIndex, source[i].isWhitespace { i = source.index(after: i) }
    return i < source.endIndex && source[i] == "+"
}

func extractAll(typeIndex: [String: TypeCategory], functionReturnTypeIndex: [String: TypeCategory]) -> [Extraction] {
    let combinedPattern = constructPatterns.joined(separator: "|")
    let regex = try! NSRegularExpression(pattern: combinedPattern)
    var extractions: [Extraction] = []

    for file in swiftFiles(under: astroUIRoot) {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let source = removingComments(raw)
        let relativePath = file.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        var searchStart = 0
        while searchStart <= source.utf16.count {
            let remainingRange = NSRange(location: searchStart, length: nsRange.length - searchStart)
            guard remainingRange.location >= 0, remainingRange.length >= 0,
                  let match = regex.firstMatch(in: source, range: remainingRange),
                  let matchRange = Range(match.range, in: source)
            else { break }

            // Skip any additional whitespace the pattern itself didn't
            // consume isn't necessary -- each pattern already ends in `\s*`.
            if let scanned = scanStringLiteral(
                source, from: matchRange.upperBound, typeIndex: typeIndex, functionReturnTypeIndex: functionReturnTypeIndex
            ),
               !scanned.displayKey.isEmpty,
               !isFollowedByStringConcatenation(source, after: scanned.endIndex) {
                let line = lineNumber(of: matchRange.lowerBound, in: source)
                extractions.append(Extraction(key: scanned.displayKey, file: relativePath, line: line))
                searchStart = NSRange(scanned.endIndex..<scanned.endIndex, in: source).location
            } else {
                searchStart = match.range.location + max(match.range.length, 1)
            }
        }
    }
    return extractions
}

// MARK: - Allowlist and hu.lproj parsing (only needed for --missing)

func parseStringsFile(_ url: URL) -> Set<String> {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    let withoutComments = removingComments(contents)
    let pattern = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)"\s*=\s*"(?:[^"\\]|\\.)*"\s*;"#)
    let nsRange = NSRange(withoutComments.startIndex..<withoutComments.endIndex, in: withoutComments)
    var keys: Set<String> = []
    pattern.enumerateMatches(in: withoutComments, range: nsRange) { match, _, _ in
        guard let match, let range = Range(match.range(at: 1), in: withoutComments) else { return }
        keys.insert(String(withoutComments[range]))
    }
    return keys
}

// MARK: - Main

let typeIndex = buildPropertyTypeIndex()
let functionReturnTypeIndex = buildFunctionReturnTypeIndex()
let extractions = extractAll(typeIndex: typeIndex, functionReturnTypeIndex: functionReturnTypeIndex)
let uniqueKeys = Set(extractions.map(\.key)).sorted()

let arguments = Set(CommandLine.arguments.dropFirst())

if arguments.contains("--missing") {
    let stringsURL = sourcesRoot
        .appendingPathComponent("AstroToolApp/Resources/hu.lproj/Localizable.strings")
    let translated = parseStringsFile(stringsURL)
    let missing = uniqueKeys.filter { !translated.contains($0) }
    for key in missing { print(key) }
    FileHandle.standardError.write("\(missing.count) of \(uniqueKeys.count) keys have no hu.lproj entry\n".data(using: .utf8)!)
} else if arguments.contains("--verbose") {
    for extraction in extractions.sorted(by: { ($0.file, $0.line) < ($1.file, $1.line) }) {
        print("\(extraction.file):\(extraction.line): \(extraction.key)")
    }
} else {
    for key in uniqueKeys { print(key) }
}
