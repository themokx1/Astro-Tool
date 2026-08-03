import Foundation

/// Parses the free-form `Key: value` lines a session's `README.txt`
/// accumulates -- both the template's own header lines (`Target folder`,
/// `Date`, ...) and whatever the user typed under "Fill in metadata"
/// (`Camera:`, `Location/Bortle:`, `Notes/issues:`, plus any custom key the
/// user invents, e.g. `SQM:`) -- into a flat `[key: value]` dictionary. This
/// is the only thing that makes sky conditions (Bortle, SQM, seeing, dew,
/// notes) searchable at all: they never appear in a FITS header, only in
/// what the user hand-typed into the README the `new-session` template
/// leaves for them. Read-only: this type never writes back to the file --
/// `LibraryScanner` is the only caller, and only ever reads it.
enum ReadmeNotesParser {
    /// Defensive cap on how much of a `README.txt` this parser will ever
    /// look at. Every real README the tool itself generates (via
    /// `SessionCreator`) is a few hundred bytes; a file anywhere near 64 KiB
    /// is either not really a session README or got corrupted some other
    /// way, and scanning/regex-matching it line by line on every rescan
    /// would be wasted work for no useful data.
    static let maxBytes = 64 * 1024

    /// `key` is capped at 41 characters (1 leading letter + up to 40 more)
    /// of letters/digits/space/parentheses/slash/underscore/hyphen, mirroring
    /// the exact key shapes the template ships (`Location/Bortle`,
    /// `Exposure (lights)`, `Notes/issues`) -- this keeps a stray line deep
    /// in the "Folder map"/"Calibration reminder" sections (which start with
    /// `-` or have no colon at all) from ever matching, while still allowing
    /// any custom `Key: value` line the user adds by hand.
    /// Force-unwrapped: the pattern is a fixed literal verified by this
    /// file's own tests, so a failure here could only mean a typo introduced
    /// in a future edit -- there is no runtime input that could make this
    /// initializer throw.
    private static let linePattern = try! NSRegularExpression(pattern: "^([A-Za-z][A-Za-z0-9 ()/_-]{0,40}):\\s*(.*)$")

    /// `nil` when `data` shouldn't be parsed at all: bigger than
    /// `maxBytes`, or not valid UTF-8 (a `README.txt` is always meant to be
    /// plain text; anything else reading as raw bytes is not one this
    /// parser can make sense of). Returns `[:]` -- not `nil` -- for a
    /// perfectly valid but empty/all-blank file.
    static func parse(data: Data) -> [String: String]? {
        guard data.count <= maxBytes else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text: text)
    }

    /// One entry per matching line; a line whose value is empty (or
    /// whitespace-only) after trimming is skipped entirely -- the template
    /// ships most "Fill in metadata" keys blank, and an empty value is not a
    /// fact worth indexing. A key seen more than once keeps its LAST value
    /// (matches how a human reading top-to-bottom would resolve it, though
    /// real README.txt files never actually repeat a key).
    static func parse(text: String) -> [String: String] {
        var result: [String: String] = [:]
        text.enumerateLines { line, _ in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = linePattern.firstMatch(in: line, range: range),
                  let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line)
            else { return }

            let key = line[keyRange].trimmingCharacters(in: .whitespaces)
            let value = line[valueRange].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { return }
            result[key] = value
        }
        return result
    }
}
