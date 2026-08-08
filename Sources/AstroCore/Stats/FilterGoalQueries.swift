import Foundation

/// Merges a target's per-filter usable integration
/// (`FilterBreakdownQueries.breakdown`) with its `goal:<filter>=<hours>h`
/// tags (`GoalTag.parseFilterGoals`) -- the one place per-filter "usable vs
/// goal vs missing" gets computed, so `TargetDetailPage`'s "Szűrők" card,
/// its "Hiányzik" tile caption, `TonightPage`'s "Hiányzik" popover, and the
/// CLI (`stats --filters --json`, `goal list --json`) can never disagree
/// about the numbers. Pure (no `Database`/filesystem access of its own) --
/// callers already have both inputs from queries they run anyway.
public enum FilterGoalQueries {
    /// Attaches each filter's goal (if any) onto `breakdown`'s matching row
    /// (`FilterIntegration.withGoal`, case-insensitive name match against
    /// `GoalTag.parseFilterGoals(tags:)`), then appends one synthetic row
    /// per GOAL-ONLY filter -- tagged with a goal but with no usable frames
    /// shot yet at all -- with `usableFrameCount`/`integrationSeconds` both
    /// `0`. `breakdown`'s own order (seconds-descending) is preserved for
    /// the matched rows; goal-only rows are appended after, sorted by
    /// filter name for a deterministic order. Returns `breakdown` completely
    /// unchanged (same array, same order) when `tags` carries no filter
    /// goal at all -- the common case, and cheap to short-circuit.
    public static func merge(breakdown: [FilterIntegration], tags: [String]) -> [FilterIntegration] {
        let goals = GoalTag.parseFilterGoals(tags: tags)
        guard !goals.isEmpty else { return breakdown }

        // "Last one wins" for a (shouldn't-happen-in-practice) duplicate
        // filter goal tag -- see `GoalTag.parseFilterGoals`'s own doc
        // comment for why that's the natural behavior of building this
        // dictionary in tag order.
        var goalByLowercasedFilter: [String: GoalTag.FilterGoal] = [:]
        for goal in goals {
            goalByLowercasedFilter[goal.filter.lowercased()] = goal
        }

        var matchedLowercasedFilters = Set<String>()
        let merged = breakdown.map { entry -> FilterIntegration in
            let key = entry.filter.lowercased()
            guard let goal = goalByLowercasedFilter[key] else { return entry }
            matchedLowercasedFilters.insert(key)
            return entry.withGoal(seconds: goal.seconds)
        }

        let goalOnlyRows = goals
            .filter { !matchedLowercasedFilters.contains($0.filter.lowercased()) }
            .sorted { $0.filter < $1.filter }
            .map { goal in
                FilterIntegration(filter: goal.filter, usableFrameCount: 0, integrationSeconds: 0)
                    .withGoal(seconds: goal.seconds)
            }

        return merged + goalOnlyRows
    }

    /// The single biggest outstanding deficit among `merged`'s rows (i.e.
    /// the row with the largest `missingSeconds > 0`), or `nil` when every
    /// goaled filter is already met, or there were no filter goals at all
    /// (`merged`'s rows all have `missingSeconds == nil`) -- the
    /// "Hiányzik" tile's per-filter caption ("legtöbb hiány: SII 6,5h").
    /// Ties (equal `missingSeconds`) break on filter name ascending, for a
    /// deterministic result.
    public static func biggestDeficit(_ merged: [FilterIntegration]) -> FilterIntegration? {
        merged
            .filter { ($0.missingSeconds ?? 0) > 0 }
            .max { lhs, rhs in
                let lhsMissing = lhs.missingSeconds ?? 0
                let rhsMissing = rhs.missingSeconds ?? 0
                if lhsMissing != rhsMissing { return lhsMissing < rhsMissing }
                return lhs.filter > rhs.filter
            }
    }
}
