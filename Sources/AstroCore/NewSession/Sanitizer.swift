/// Ports the `sanitize()` shell-function from `add_new_session.sh` so target
/// names created by the GUI/CLI follow the exact same convention as the
/// existing library (`<TARGET> = sanitize(<catalog>)_sanitize(<name>)`).
public enum Sanitizer {
    /// Ground-truth rules, verified against the real script's `sanitize()`:
    /// `tr ' ' '_'` FIRST (only the literal space character becomes `_`),
    /// THEN `tr -cd 'A-Za-z0-9._-'` -- every other character outside that
    /// allow-list is DELETED, not replaced with `_` (e.g. `"a///b   c"` ->
    /// `"a///b___c"` -> `"ab___c"` -- not `"a_b_c"`). Finally, runs of `_`
    /// collapse to a single `_`, and `_` is trimmed from both ends.
    public static func sanitize(_ s: String) -> String {
        var spaceReplaced = ""
        spaceReplaced.reserveCapacity(s.count)
        for ch in s {
            spaceReplaced.append(ch == " " ? "_" : ch)
        }

        var filtered = ""
        filtered.reserveCapacity(spaceReplaced.count)
        for ch in spaceReplaced where isAllowed(ch) {
            filtered.append(ch)
        }

        return trimUnderscores(collapseUnderscores(filtered))
    }

    /// `<TARGET>` = `sanitize(<catalog>)_sanitize(<name>)`.
    public static func makeTarget(catalog: String, name: String) -> String {
        let combined = sanitize(catalog) + "_" + sanitize(name)
        // Re-run sanitize so edge cases (e.g. an empty catalog or name,
        // which would otherwise leave a stray "_" separator) still collapse
        // and trim correctly.
        return sanitize(combined)
    }

    private static func isAllowed(_ ch: Character) -> Bool {
        switch ch {
        case "a"..."z", "A"..."Z", "0"..."9", ".", "-", "_":
            return true
        default:
            return false
        }
    }

    private static func collapseUnderscores(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var previousWasUnderscore = false
        for ch in s {
            if ch == "_" {
                if !previousWasUnderscore {
                    result.append(ch)
                }
                previousWasUnderscore = true
            } else {
                result.append(ch)
                previousWasUnderscore = false
            }
        }
        return result
    }

    private static func trimUnderscores(_ s: String) -> String {
        var sub = Substring(s)
        while sub.first == "_" {
            sub.removeFirst()
        }
        while sub.last == "_" {
            sub.removeLast()
        }
        return String(sub)
    }
}
