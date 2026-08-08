import Foundation

/// Tonight's calibration shopping list (R11-T6/F18b): the subset of
/// `CalibAnalyzer.coverage()`'s per-combo report that's both ACTIONABLE
/// (missing a master entirely, or matched but stale) and RELEVANT to tonight
/// (at least one of the combo's own `targets` is something tonight's plan
/// actually has up in the sky). Pure -- takes an already-computed `coverage`
/// report and `plans` (`Planner.plan(...)`), no `Database`/filesystem access
/// of its own, so callers that already have both (the app's dashboard load)
/// pay no extra query cost. Deliberately does NOT invent a "shoot N darks"
/// frame count -- `CalibNeed.todo` already carries the one number that IS
/// measured (how many session LIGHTS need this combo), and this list just
/// reuses that verbatim rather than guessing at a dark-frame count of its
/// own that no query here actually computes.
public enum CalibShoppingList {
    /// One shopping-list line: the combo (dark exposure/temp), which of
    /// tonight's targets would actually use it, and the existing
    /// `CalibNeed.todo` instruction text.
    public struct Item: Codable, Sendable, Equatable {
        public var kind: FrameRole
        public var exposureSeconds: Double
        public var tempC: Double?
        /// Sorted, distinct -- the subset of `CalibNeed.targets` that are
        /// ALSO one of tonight's observable targets (see
        /// `isObservableTonight`'s own doc comment for exactly which
        /// verdicts count).
        public var targets: [String]
        public var isStale: Bool
        /// `CalibNeed.todo`, verbatim -- never re-derived here.
        public var todo: String

        public init(kind: FrameRole, exposureSeconds: Double, tempC: Double?, targets: [String], isStale: Bool, todo: String) {
            self.kind = kind
            self.exposureSeconds = exposureSeconds
            self.tempC = tempC
            self.targets = targets
            self.isStale = isStale
            self.todo = todo
        }

        /// `"<todo> — M31, M42 használná"` -- the one line this item's own
        /// checklist row/Markdown export shows, combining the existing
        /// `todo` instruction with the affected-tonight target list. Kept
        /// as a computed property (not a stored/encoded field) so it can
        /// never drift out of sync with `todo`/`targets`.
        public var summary: String {
            "\(todo) — \(targets.joined(separator: ", ")) használná"
        }
    }

    /// `true` for a `TargetPlan` this list considers observable tonight --
    /// "ma jó" (optionally NB-augmented, R11-T6/F3: `"ma jó — Ha-ra"`) or
    /// "Hold zavar (…)" both count, since either is a target you could
    /// genuinely point at tonight; every other verdict (no coordinate, too
    /// low, not visible tonight, a comet's stale coordinate) doesn't.
    public static func isObservableTonight(_ plan: TargetPlan) -> Bool {
        plan.verdict.hasPrefix(SkyVerdict.good) || plan.verdict.hasPrefix("Hold zavar")
    }

    /// Builds tonight's shopping list. Sorted the same "missing before
    /// stale" order `CalibAnalyzer.coverage()` itself uses, then by exposure
    /// descending. `[]` whenever no target is observable tonight at all
    /// (nothing to shop for), or none of the actionable combos are used by
    /// any of them.
    public static func build(coverage: [CalibNeed], plans: [TargetPlan]) -> [Item] {
        let tonightTargets = Set(plans.filter(isObservableTonight).map(\.target))
        guard !tonightTargets.isEmpty else { return [] }

        var items: [Item] = []
        for need in coverage {
            guard need.matchedMasterPath == nil || need.isStale else { continue }
            guard let todo = need.todo else { continue }
            let relevantTargets = need.targets.filter { tonightTargets.contains($0) }.sorted()
            guard !relevantTargets.isEmpty else { continue }

            items.append(Item(
                kind: need.kind,
                exposureSeconds: need.exposureSeconds,
                tempC: need.tempC,
                targets: relevantTargets,
                isStale: need.isStale,
                todo: todo
            ))
        }

        return items.sorted { a, b in
            if a.isStale != b.isStale { return !a.isStale && b.isStale } // missing (false) before stale (true)
            return a.exposureSeconds > b.exposureSeconds
        }
    }

    /// `"- [ ] <summary>"` per line -- the "Másolás Markdownként" button's
    /// pasteboard content. `""` for an empty list (callers never call this
    /// on the empty-state UI branch anyway).
    public static func markdown(_ items: [Item]) -> String {
        items.map { "- [ ] \($0.summary)" }.joined(separator: "\n")
    }
}
