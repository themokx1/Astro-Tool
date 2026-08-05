import Foundation

/// Parses the `"name:<text>"` target-tag convention -- a user's manual
/// override for a target's proper/common name, e.g. when
/// `TargetNameResolver` can't recognize the folder name at all, or gets it
/// wrong. Same shape as `GoalTag`'s `"goal:<hours>h"` convention: the
/// PREFIX match is case-insensitive, but the override text itself is kept
/// exactly as written (not lowercased) since it's meant to be displayed.
///
/// `TargetNameResolver` itself stays pure (folder name in, resolved name
/// out, no database access) -- callers that have the target's tags on hand
/// (`StatsQueries`, `Planner`, ...) apply this override on top of the
/// resolver's own `properName`/`displayName` themselves.
public enum NameTag {
    /// The first tag matching `name:<text>` (case-insensitive prefix,
    /// leading/trailing whitespace trimmed off both the tag and the
    /// resulting text), or `nil` if none match or the text after the prefix
    /// is empty.
    public static func parse(tags: [String]) -> String? {
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("name:") else { continue }
            let text = trimmed.dropFirst("name:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            return text
        }
        return nil
    }

    /// Applies a `name:<text>` override (if `tags` has one) on top of an
    /// already-resolved `TargetNameResolver` result: the override REPLACES
    /// `properName`, and `displayName` is recomposed from it (still
    /// combined with `resolved.designation` when one was parsed, e.g. a
    /// user overriding `"NGC 7000"`'s common name still sees
    /// `"NGC 7000 · <override>"`, not just the bare override text). Returns
    /// `resolved` unchanged when `tags` has no `name:` tag.
    public static func apply(to resolved: ResolvedTargetName, tags: [String]) -> ResolvedTargetName {
        guard let override = parse(tags: tags) else { return resolved }
        let displayName: String
        if let designation = resolved.designation {
            displayName = "\(designation) · \(override)"
        } else {
            displayName = override
        }
        return ResolvedTargetName(designation: resolved.designation, properName: override, displayName: displayName)
    }
}
