import Foundation

/// Which deliberate deviations from the canonical `YYYY-MM-DD` date-folder
/// name are recognized, rather than flagged as an error. See PROMPT.md
/// ("Szabálytalan dátum-mappák") for the real-world examples this models.
public struct IntentionalPatterns: Codable, Equatable, Sendable {
    /// Recognize a numeric run suffix, e.g. `2026-04-06-2` (second run of
    /// the same night).
    public var runSuffix: Bool
    /// Recognize a second full date joined by `-` or `_`, e.g.
    /// `2026-02-25_2026-03-15` (multiple nights stacked together).
    public var dateRange: Bool
    /// Known labels (informational only — any short alphanumeric suffix
    /// that isn't a run-suffix or a second date parses as `.labeled`
    /// regardless of whether it appears in this list).
    public var labels: [String]

    public init() {
        self.runSuffix = true
        self.dateRange = true
        self.labels = ["hibas", "OSC"]
    }
}

/// How a session date-folder name relates to the canonical `YYYY-MM-DD`
/// form.
public enum SessionDateKind: Equatable, Sendable {
    case canonical
    case runSuffix(Int)
    case range
    case labeled
}

/// A parsed session date-folder name.
public struct SessionDate: Equatable, Sendable {
    public var raw: String
    public var kind: SessionDateKind
    public var start: String   // "YYYY-MM-DD"
    public var end: String     // == start when not a range
    public var label: String?

    public var isCanonical: Bool { kind == .canonical }
}

/// Parses `sessions/<TARGET>/<DATE>` folder names into a canonical date plus
/// a recognized "intentional" variation, or `nil` if the name isn't a real
/// calendar date (optionally followed by a recognized pattern) at all.
public enum SessionDateParser {
    public static func parse(
        _ name: String,
        patterns: IntentionalPatterns = .init()
    ) -> SessionDate? {
        let chars = Array(name)
        guard chars.count >= 10 else { return nil }

        let datePart = String(chars[0..<10])
        guard isDateShape(datePart), isValidDate(datePart) else { return nil }

        if chars.count == 10 {
            return SessionDate(raw: name, kind: .canonical, start: datePart, end: datePart, label: nil)
        }

        let separator = chars[10]
        guard separator == "-" || separator == "_" else { return nil }
        guard chars.count > 11 else { return nil }
        let remainder = String(chars[11...])

        // Numeric-only suffix -> run suffix (e.g. "-2").
        if remainder.allSatisfy({ $0.isASCII && $0.isNumber }) {
            guard patterns.runSuffix, let n = Int(remainder) else { return nil }
            return SessionDate(raw: name, kind: .runSuffix(n), start: datePart, end: datePart, label: nil)
        }

        // A full second date -> range (joined by "-" or "_").
        if remainder.count == 10, isDateShape(remainder) {
            guard isValidDate(remainder) else { return nil }
            guard patterns.dateRange else { return nil }
            return SessionDate(raw: name, kind: .range, start: datePart, end: remainder, label: nil)
        }

        // Any other short alphanumeric suffix -> label (e.g. "OSC", "hibas").
        if !remainder.isEmpty, remainder.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            return SessionDate(raw: name, kind: .labeled, start: datePart, end: datePart, label: remainder)
        }

        return nil
    }

    private static func isDateShape(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count == 10 else { return false }
        for (index, ch) in chars.enumerated() {
            if index == 4 || index == 7 {
                guard ch == "-" else { return false }
            } else {
                guard ch.isASCII, ch.isNumber else { return false }
            }
        }
        return true
    }

    private static func isValidDate(_ s: String) -> Bool {
        let parts = s.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return false }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .init(secondsFromGMT: 0)!

        guard let date = calendar.date(from: components) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
    }
}
