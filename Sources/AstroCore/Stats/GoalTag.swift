import Foundation

/// Parses the `"goal:<hours>h"` target-tag convention (e.g. `"goal:6h"`,
/// `"goal:6.5h"`) into seconds. Shared by `Planner` (tonight's plan) and
/// `ProjectStatusQueries` (per-target pipeline status) so the two features
/// never disagree about what counts as a goal tag -- this used to be a
/// private helper on `Planner` alone.
///
/// R11-T5/F2 adds a second, independent tag shape: `"goal:<filter>=<hours>h"`
/// (e.g. `"goal:Ha=12h"`) for a PER-FILTER goal (mono/filter-wheel imagers
/// wanting "12h of Ha", not just an overall integration target). The two
/// coexist freely on the same target -- `parse(tags:)` above already skips
/// every `goal:<filter>=...` tag on its own (the `=` makes the text after
/// `"goal:"` fail `Double(...)`, so the `for` loop just moves on to the next
/// tag), so no change was needed there for backward compatibility.
public enum GoalTag {
    /// Scans `tags` for the first one matching the `goal:<hours>h` shape
    /// (case-insensitive, leniently parsed -- the trailing `h` is optional).
    /// `nil` if none match. Never matches a `goal:<filter>=<hours>h` tag --
    /// see this type's own doc comment for why that's automatic, not a
    /// special case here.
    public static func parse(tags: [String]) -> Double? {
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard trimmed.hasPrefix("goal:") else { continue }
            var numberText = String(trimmed.dropFirst("goal:".count))
            if numberText.hasSuffix("h") { numberText.removeLast() }
            if let hours = Double(numberText) { return hours * 3600.0 }
        }
        return nil
    }

    /// Formats `hours` as a `"goal:<hours>h"` tag -- integral hours print
    /// without a decimal (`"goal:6h"`, not `"goal:6.0h"`), anything else
    /// gets one decimal place (`"goal:6.5h"`). MUST stay byte-for-byte
    /// identical to `AppState.formatGoalTag` (private, `AstroToolApp`,
    /// deliberately not touched/imported from here) so a goal set from the
    /// CLI and one set from the app's hour-stepper popover always produce
    /// the exact same tag text and round-trip identically through `parse`.
    public static func format(hours: Double) -> String {
        if hours.rounded() == hours { return "goal:\(Int(hours))h" }
        return "goal:\(String(format: "%.1f", hours))h"
    }

    // MARK: - Per-filter goals (R11-T5/F2)

    /// One parsed `goal:<filter>=<hours>h` tag -- `filter` keeps the exact
    /// casing it was written with (matched case-insensitively against real
    /// FITS `FILTER` values by callers, e.g. `FilterGoalQueries.merge`;
    /// never itself lowercased here, so a round-tripped tag/display text
    /// still reads the way the user/app wrote it).
    public struct FilterGoal: Sendable, Equatable {
        public let filter: String
        public let seconds: Double

        public init(filter: String, seconds: Double) {
            self.filter = filter
            self.seconds = seconds
        }
    }

    /// Scans `tags` for every `goal:<filter>=<hours>h` tag (the trailing
    /// `h` optional, same leniency as `parse(tags:)`) -- `=` is the
    /// filter/hours separator (a `:` inside a filter name would collide with
    /// the `goal:` prefix itself, which is exactly why `=` was chosen; a
    /// blank filter name, a missing `=`, or an unparseable number are all
    /// silently skipped rather than guessed at, same "skip, don't guess"
    /// rule `parse(tags:)` already follows). Multiple tags for the SAME
    /// filter (shouldn't happen in practice -- every writer here removes the
    /// existing tag before adding a new one) all still appear, in tag order;
    /// callers merging this into a single per-filter view (`FilterGoalQueries`)
    /// take the last one, mirroring `parse(tags:)`'s own "first match wins"
    /// stance loosely (this is "last match wins" since a `Dictionary` built
    /// from these naturally keeps the latest).
    public static func parseFilterGoals(tags: [String]) -> [FilterGoal] {
        var results: [FilterGoal] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("goal:") else { continue }
            let rest = trimmed.dropFirst(5) // "goal:".count, fixed regardless of case
            guard let equalsIndex = rest.firstIndex(of: "=") else { continue }
            let filterName = String(rest[rest.startIndex..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            guard !filterName.isEmpty else { continue }
            var numberText = String(rest[rest.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
            if numberText.lowercased().hasSuffix("h") { numberText.removeLast() }
            guard let hours = Double(numberText) else { continue }
            results.append(FilterGoal(filter: filterName, seconds: hours * 3600.0))
        }
        return results
    }

    /// Formats a `"goal:<filter>=<hours>h"` tag -- same integral-hours-print-
    /// without-decimal convention as `format(hours:)`, so `"goal:Ha=12h"`
    /// (not `"goal:Ha=12.0h"`) round-trips identically whether written by
    /// the CLI (`goal set --filter`) or the app (`GoalEditSheet`'s
    /// "Szűrőnként" stepper).
    public static func formatFilter(filter: String, hours: Double) -> String {
        if hours.rounded() == hours { return "goal:\(filter)=\(Int(hours))h" }
        return "goal:\(filter)=\(String(format: "%.1f", hours))h"
    }

    /// `true` when `tag` is a `goal:<filter>=...h` tag for `filter`
    /// specifically (case-insensitive name match) -- lets a writer
    /// (`AppState.setFilterGoals`, `cmdGoal`'s `set --filter`/`clear
    /// --filter`) find the existing tag(s) to remove before adding a new
    /// one, the same "remove every existing goal tag first" pattern the
    /// overall `goal:<hours>h` tag already follows.
    public static func isFilterGoalTag(_ tag: String, filter: String) -> Bool {
        parseFilterGoals(tags: [tag]).contains { $0.filter.caseInsensitiveCompare(filter) == .orderedSame }
    }

    /// `true` when `tag` is an OVERALL `goal:<hours>h` tag (i.e. what
    /// `parse(tags:)` would match), as opposed to a per-filter
    /// `goal:<filter>=<hours>h` one -- lets a writer editing the overall
    /// goal (`AppState.setGoal`, `cmdGoal`'s plain `set`/`clear`) find only
    /// ITS OWN prior tag(s) to remove, without also deleting any per-filter
    /// goals that happen to share the same `goal:` prefix. Before this
    /// existed, both writers filtered on a bare `hasPrefix("goal:")`, which
    /// matched (and silently destroyed) per-filter tags too -- exactly the
    /// bug this type's own doc comment warns the two conventions must never
    /// step on each other's toes.
    public static func isOverallGoalTag(_ tag: String) -> Bool {
        parse(tags: [tag]) != nil
    }
}
