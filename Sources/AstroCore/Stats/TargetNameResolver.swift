import Foundation

/// The result of resolving a session/stacks folder name (e.g.
/// `"NGC_7000_North_American_Nebula"`) into a proper catalog designation and
/// (when known) its Hungarian common name.
public struct ResolvedTargetName: Codable, Equatable, Sendable {
    /// Normalized catalog designation, e.g. `"M 42"`, `"NGC 7000"`,
    /// `"IC 1805"`, `"IC 1805–1848"`, `"Sh2-129"`, `"C/2025 R3"`. `nil` when
    /// no recognized designation could be parsed out of the folder name.
    public var designation: String?
    /// Hungarian common name from `CatalogNames`' built-in table (or, for a
    /// bare `M_<words>` folder with no catalog number at all, from a small
    /// keyword table -- see `TargetNameResolver`'s own doc comment). `nil`
    /// when nothing in the table matches.
    public var properName: String?
    /// The best available name to show a user: `"<designation> · <properName>"`
    /// when both are known, just the designation when only that's known,
    /// just the proper name when only that's known (the bare-`M_` keyword
    /// case), and the folder name itself (underscores turned into spaces)
    /// when neither is known.
    public var displayName: String
    /// `true` when `designation` is a comet's provisional designation
    /// (`matchComet`'s `"C/<year> <letter><number>"` output format).
    /// Computed, not stored -- comets are identified purely by the shape of
    /// `designation`, so this needs no extra state and doesn't affect
    /// `Codable`/`Equatable` (both are stored-properties-only). Callers
    /// (`Planner`) use this to treat a comet's session-derived coordinate as
    /// stale by the time anyone looks at "is it up tonight" -- comets move
    /// degrees per day, unlike every other cataloged target here.
    public var isComet: Bool { designation?.hasPrefix("C/") ?? false }

    public init(designation: String?, properName: String?, displayName: String) {
        self.designation = designation
        self.properName = properName
        self.displayName = displayName
    }
}

/// Resolves a session/stacks/processed folder name into a proper target
/// display name, purely from the folder name's own text -- no filesystem or
/// database access, no I/O. Callers that want a user-level override (the
/// `name:<text>` target tag) apply it themselves on top of this type's
/// `properName`/`displayName`; see `NameTag`.
///
/// Parsing outline: the folder name is split on `_` into tokens, then run
/// through `DuplicatedPrefixDetector.dedupe` (shared with the audit's
/// copy-paste-duplicated-name rule) to collapse an accidentally repeated
/// prefix like `"C2025_R3_C2025_R3_Panstarrs"` down to
/// `["C2025", "R3", "Panstarrs"]` before anything else looks at it. The
/// (possibly still multi-token) leading run is then matched, in order,
/// against: a comet designation (`C<yyyy>` + `<Letter><d+>`), `NGC`, an `IC`
/// range (`IC1805-1848`), a single `IC`, `Sh2` (hyphen OR underscore
/// separator), and `M`. Each recognizer accepts both the no-separator form
/// (`"NGC7000"`, one token) and the underscore-separated form (`"NGC"`,
/// `"7000"` as two tokens), since both show up on real disks.
///
/// A folder starting with a bare `M` token that is NOT followed by a
/// catalog number (e.g. `"M_Milky_Way"`) is a deliberate special case: it
/// never becomes a (bogus) Messier designation. Instead the remaining
/// tokens are checked against a tiny keyword table (`"milky"` ->
/// `"Tejút"`) for a properName with no designation at all.
public enum TargetNameResolver {
    public static func resolve(folderName: String) -> ResolvedTargetName {
        let rawTokens = folderName.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
        let cleanedFallback = folderName.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)

        guard !rawTokens.isEmpty else {
            return ResolvedTargetName(designation: nil, properName: nil, displayName: cleanedFallback.isEmpty ? folderName : cleanedFallback)
        }

        let tokens = DuplicatedPrefixDetector.dedupe(rawTokens) ?? rawTokens

        if let designation = matchComet(tokens) {
            return compose(designation: designation, properName: CatalogNames.hungarian[designation], cleanedFallback: cleanedFallback)
        }

        if let number = matchNGC(tokens) {
            let designation = "NGC \(number)"
            return compose(designation: designation, properName: CatalogNames.hungarian[designation], cleanedFallback: cleanedFallback)
        }

        if let range = matchICRange(tokens) {
            let designation = "IC \(range.first)–\(range.second)"
            let combinedKey = "IC\(range.first)-\(range.second)"
            let properName = CatalogNames.hungarian[combinedKey] ?? CatalogNames.hungarian["IC \(range.first)"]
            return compose(designation: designation, properName: properName, cleanedFallback: cleanedFallback)
        }

        if let number = matchIC(tokens) {
            let designation = "IC \(number)"
            return compose(designation: designation, properName: CatalogNames.hungarian[designation], cleanedFallback: cleanedFallback)
        }

        if let number = matchSh2(tokens) {
            let designation = "Sh2-\(number)"
            return compose(designation: designation, properName: CatalogNames.hungarian[designation], cleanedFallback: cleanedFallback)
        }

        if let number = matchMessier(tokens) {
            let designation = "M \(number)"
            return compose(designation: designation, properName: CatalogNames.hungarian[designation], cleanedFallback: cleanedFallback)
        }

        // Bare "M_<words>" with no catalog number -- no designation, only a
        // possible keyword-table properName from the remaining tokens.
        if tokens[0].caseInsensitiveCompare("M") == .orderedSame {
            if let properName = keywordLookup(tokens.dropFirst()) {
                return ResolvedTargetName(designation: nil, properName: properName, displayName: properName)
            }
            return ResolvedTargetName(designation: nil, properName: nil, displayName: cleanedFallback)
        }

        // No recognized catalog designation at all -- last chance: a
        // keyword match anywhere in the (deduped) tokens.
        if let properName = keywordLookup(tokens) {
            return ResolvedTargetName(designation: nil, properName: properName, displayName: properName)
        }

        return ResolvedTargetName(designation: nil, properName: nil, displayName: cleanedFallback)
    }

    // MARK: - Composition

    private static func compose(designation: String, properName: String?, cleanedFallback: String) -> ResolvedTargetName {
        let displayName: String
        if let properName {
            displayName = "\(designation) · \(properName)"
        } else {
            displayName = designation
        }
        return ResolvedTargetName(designation: designation, properName: properName, displayName: displayName)
    }

    // MARK: - Keyword table (non-cataloged common names)

    /// Common names for targets that don't carry a catalog number in their
    /// folder name at all -- checked (case-insensitively, against any
    /// token) only once every catalog-designation pattern above has failed.
    private static let keywordNames: [String: String] = [
        "milky": "Tejút",
    ]

    private static func keywordLookup(_ tokens: some Sequence<String>) -> String? {
        for token in tokens {
            if let name = keywordNames[token.lowercased()] { return name }
        }
        return nil
    }

    // MARK: - Catalog matchers

    /// `"C2025"` + `"R3"` -> `"C/2025 R3"` (a provisional comet designation:
    /// `C/<year> <Letter><half-month-number>`). Both tokens are required as
    /// SEPARATE tokens (a comet folder is always underscore-separated, e.g.
    /// `"C2025_R3_Panstarrs"`) -- there's no single-token form to also
    /// support, unlike the catalog numbers below.
    private static func matchComet(_ tokens: [String]) -> String? {
        guard tokens.count >= 2 else { return nil }
        let first = tokens[0]
        guard first.count == 5, first.first?.lowercased() == "c" else { return nil }
        let yearPart = first.dropFirst()
        guard yearPart.count == 4, yearPart.allSatisfy(\.isNumber) else { return nil }

        let second = tokens[1]
        guard let letter = second.first, letter.isLetter else { return nil }
        let numberPart = second.dropFirst()
        guard !numberPart.isEmpty, numberPart.allSatisfy(\.isNumber) else { return nil }

        return "C/\(yearPart) \(letter.uppercased())\(numberPart)"
    }

    private static func matchNGC(_ tokens: [String]) -> Int? {
        matchCatalogNumber(tokens, prefix: "ngc")
    }

    private static func matchIC(_ tokens: [String]) -> Int? {
        matchCatalogNumber(tokens, prefix: "ic")
    }

    private static func matchMessier(_ tokens: [String]) -> Int? {
        matchCatalogNumber(tokens, prefix: "m")
    }

    /// `"NGC7000"` (one token) OR `"NGC"` + `"7000"` (two tokens, the
    /// underscore-separated on-disk form) -> `7000`. Shared shape for
    /// `NGC`/`IC`/`M` (all three folder-naming conventions this tool has
    /// seen use both forms).
    private static func matchCatalogNumber(_ tokens: [String], prefix: String) -> Int? {
        if let n = matchPrefixNumber(tokens[0], prefix: prefix) { return n }
        if tokens[0].caseInsensitiveCompare(prefix) == .orderedSame, tokens.count >= 2, isAllDigits(tokens[1]) {
            return Int(tokens[1])
        }
        return nil
    }

    /// `"IC1805-1848"` (one token) OR `"IC"` + `"1805-1848"` (two tokens) ->
    /// `(first: "1805", second: "1848")`. Numbers are kept as strings (not
    /// `Int`) so the designation/combined-lookup-key text is built from
    /// exactly the digits on disk.
    private static func matchICRange(_ tokens: [String]) -> (first: String, second: String)? {
        if let range = rangeAfterPrefix(tokens[0], prefix: "ic") { return range }
        if tokens[0].caseInsensitiveCompare("ic") == .orderedSame, tokens.count >= 2, let range = parseRange(tokens[1]) {
            return range
        }
        return nil
    }

    /// `"Sh2-129"` (one token, hyphen kept -- `_` is the only folder-name
    /// separator this resolver splits on) OR `"Sh2"` + `"129"` (two tokens,
    /// the underscore-separated form) -> `129`.
    private static func matchSh2(_ tokens: [String]) -> Int? {
        let first = tokens[0]
        let lower = first.lowercased()
        if lower.hasPrefix("sh2-") {
            let digits = lower.dropFirst(4)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) { return Int(digits) }
        }
        if lower == "sh2", tokens.count >= 2, isAllDigits(tokens[1]) {
            return Int(tokens[1])
        }
        return nil
    }

    // MARK: - Low-level token parsing

    private static func matchPrefixNumber(_ token: String, prefix: String) -> Int? {
        let lower = token.lowercased()
        guard lower.hasPrefix(prefix) else { return nil }
        let rest = lower.dropFirst(prefix.count)
        guard !rest.isEmpty, rest.allSatisfy(\.isNumber) else { return nil }
        return Int(rest)
    }

    private static func rangeAfterPrefix(_ token: String, prefix: String) -> (first: String, second: String)? {
        let lower = token.lowercased()
        guard lower.hasPrefix(prefix) else { return nil }
        return parseRange(String(lower.dropFirst(prefix.count)))
    }

    private static func parseRange(_ text: String) -> (first: String, second: String)? {
        guard let dashIndex = text.firstIndex(of: "-") else { return nil }
        let first = text[text.startIndex..<dashIndex]
        let second = text[text.index(after: dashIndex)...]
        guard !first.isEmpty, !second.isEmpty, first.allSatisfy(\.isNumber), second.allSatisfy(\.isNumber) else { return nil }
        return (String(first), String(second))
    }

    private static func isAllDigits(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy(\.isNumber)
    }
}
