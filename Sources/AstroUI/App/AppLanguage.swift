import Foundation
import SwiftUI

/// The user's V2 language override, layered over macOS's own per-app
/// language mechanism (`AppleLanguages` in `UserDefaults`). SwiftUI's
/// `Text("literal")`/`Button`/`Label`/etc. resolve `LocalizedStringKey`
/// against `Bundle.main` at render time, and `Bundle.main` itself consults
/// this same `AppleLanguages` override to decide which `.lproj` to load --
/// so writing this key is the entire mechanism. There is no live-apply path:
/// `Bundle.main`'s preferred localization is fixed for the process's
/// lifetime, which is why every write here only takes effect after a
/// restart (see `V2SettingsView`'s language picker).
public enum AppLanguage: String, CaseIterable, Hashable, Sendable {
    case system
    case hungarian
    case english

    /// A literal `LocalizedStringKey` (not a computed `String`) so the
    /// picker's `Text(language.displayName)` still resolves through
    /// `Bundle.main`'s `Localizable.strings` exactly like every other
    /// literal in the app -- a `String` here would take `Text`'s verbatim,
    /// never-localized overload instead.
    public var displayName: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .hungarian: "Hungarian"
        case .english: "English"
        }
    }

    /// The standard macOS per-app language override key. Setting it to a
    /// single-element array (e.g. `["hu"]`) pins the app to that
    /// localization regardless of the system language; the *absence* of the
    /// key (not an empty array) is what makes the app follow the system
    /// language again.
    static let defaultsKey = "AppleLanguages"

    /// Writes (or clears) the `AppleLanguages` override for this choice.
    /// `.system` removes the key entirely -- an empty array is not the same
    /// thing to `Bundle.main` and would not reliably fall back to the
    /// system language.
    public func apply(to defaults: UserDefaults = .standard) {
        switch self {
        case .system:
            defaults.removeObject(forKey: Self.defaultsKey)
        case .hungarian:
            defaults.set(["hu"], forKey: Self.defaultsKey)
        case .english:
            defaults.set(["en"], forKey: Self.defaultsKey)
        }
    }

    /// Reads back the current override.
    ///
    /// This deliberately compares the *whole* array against exactly `["hu"]`
    /// / `["en"]` rather than just checking whether the first preferred
    /// language has an "hu"/"en" prefix. `AppleLanguages` is not exclusive to
    /// this override: `NSGlobalDomain` -- which is always part of
    /// `UserDefaults`'s search list, standard or suite-based -- carries the
    /// system's own multi-element preferred-languages list (e.g.
    /// `["en-US", "hu-HU", "en-GB"]` on a Mac configured with Hungarian as a
    /// secondary language), and that list's first element can easily start
    /// with "hu" or "en" with no override in effect at all. Only the exact,
    /// single-element array this type itself writes counts as an override;
    /// anything else -- including no key, or the system's own list -- reads
    /// as `.system`.
    public static func current(defaults: UserDefaults = .standard) -> AppLanguage {
        guard let languages = defaults.array(forKey: defaultsKey) as? [String] else { return .system }
        if languages == ["hu"] { return .hungarian }
        if languages == ["en"] { return .english }
        return .system
    }
}
