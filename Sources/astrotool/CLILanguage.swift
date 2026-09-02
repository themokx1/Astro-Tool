import Foundation

/// The CLI's human-readable (non-`--json`) output language.
///
/// `--json` output is always English snake_case regardless of this setting --
/// this only controls the plain-text `print`/`eprint` strings a person reads
/// in a terminal. Resolved once, at first use, in this order:
///   1. `ASTROTOOL_LANG=en` / `ASTROTOOL_LANG=hu` -- explicit override, wins
///      over everything else.
///   2. `LC_ALL` / `LC_MESSAGES` / `LANG` (checked in that order, matching
///      normal POSIX locale-resolution precedence) starting with `"hu"`
///      (case-insensitive, e.g. `hu_HU.UTF-8`) -> Hungarian.
///   3. `Locale.current.language.languageCode == "hu"` (covers environments
///      with no POSIX locale env vars set, e.g. some GUI-launched contexts)
///      -> Hungarian.
///   4. Otherwise: English.
enum CLILanguage {
    case english
    case hungarian

    static let current: CLILanguage = resolve()

    private static func resolve() -> CLILanguage {
        let env = ProcessInfo.processInfo.environment

        if let override = env["ASTROTOOL_LANG"]?.lowercased() {
            if override == "hu" { return .hungarian }
            if override == "en" { return .english }
        }

        for key in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            if let value = env[key]?.lowercased(), value.hasPrefix("hu") {
                return .hungarian
            }
        }

        if Locale.current.language.languageCode?.identifier == "hu" {
            return .hungarian
        }

        return .english
    }
}

/// Picks `english` or `hungarian` based on `CLILanguage.current`. Every
/// human-readable (non-`--json`) string the CLI prints should be built
/// through this so `ASTROTOOL_LANG`/locale detection controls all of it
/// consistently; `--json` output never goes through this.
func L(_ english: @autoclosure () -> String, _ hungarian: @autoclosure () -> String) -> String {
    switch CLILanguage.current {
    case .english: return english()
    case .hungarian: return hungarian()
    }
}
