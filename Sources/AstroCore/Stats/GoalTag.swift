import Foundation

/// Parses the `"goal:<hours>h"` target-tag convention (e.g. `"goal:6h"`,
/// `"goal:6.5h"`) into seconds. Shared by `Planner` (tonight's plan) and
/// `ProjectStatusQueries` (per-target pipeline status) so the two features
/// never disagree about what counts as a goal tag -- this used to be a
/// private helper on `Planner` alone.
public enum GoalTag {
    /// Scans `tags` for the first one matching the `goal:<hours>h` shape
    /// (case-insensitive, leniently parsed -- the trailing `h` is optional).
    /// `nil` if none match.
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
}
