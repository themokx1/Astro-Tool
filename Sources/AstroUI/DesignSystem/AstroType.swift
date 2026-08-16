import SwiftUI

/// The app's type scale -- spec
/// `docs/superpowers/specs/2026-08-16-archive-map-ux-redesign-design.md`
/// section 5.2. There is no downloaded font, deliberately: this project
/// already had one `.lproj`-resource-bundle failure and will not carry a
/// second resource-bundling risk for a look it can get from two system
/// type families instead. The app's identity comes entirely from the
/// contrast between tight-tracked sans headings (`display`/`sectionTitle`)
/// and tabular monospace data (`data`/`dataHero`) -- everything else
/// (`body`, `micro`) is the connective tissue between the two.
///
/// Two rules hold everywhere this scale is used:
///
/// 1. Every numeric display is `monospacedDigit()` -- `data`/`dataHero`
///    bake it into the modifier itself, so a call site cannot adopt the
///    role and forget the digit contract.
///    `V2PolishSurfaceTests.numericDisplayIsAlwaysTabular` gates this for
///    any OTHER fixed-size numeric `Text` that does not go through here.
/// 2. Point-based sizes scale with the system's accessibility text size.
///    `display`/`sectionTitle`/`body`/`data`/`micro` are all built on
///    `Font.TextStyle` (`.title`, `.title3`, `.body`, `.callout`,
///    `.caption2`), which already scale with Dynamic Type on their own.
///    Only `dataHero` uses a literal point size (30pt in the spec), so it
///    alone reads that size through `@ScaledMetric` -- someone who
///    enlarges their system text must not have a card's hero value break
///    out of the band it lives in.
public enum AstroType {
    /// The judgment sentence at the top of a screen.
    public static let display = Font.system(.title, weight: .semibold)
    /// Card title, section header.
    public static let sectionTitle = Font.system(.title3, weight: .semibold)
    /// Explanatory prose.
    public static let body = Font.system(.body)
    /// Table cell, row value -- tabular monospace so a column never jitters
    /// as values change.
    public static let data = Font.system(.callout, design: .monospaced)
    /// Microlabel ("LAST CHECK · 4 MIN AGO").
    public static let micro = Font.system(.caption2, design: .monospaced)

    /// `dataHero`'s literal 30pt base size, scaled by `@ScaledMetric` at
    /// the call site (`AstroDataHeroText`) -- kept here as a single named
    /// constant so the scale's one point-based number has one source.
    static let dataHeroBaseSize: CGFloat = 30
}

/// `dataHero` (spec 5.2): a card's headline numeric value, e.g. "142.1 GB".
/// A `ViewModifier` rather than a plain `Font` constant because
/// `@ScaledMetric` only works as a property of something SwiftUI installs
/// into the view tree -- a static `Font` has no environment to read the
/// user's accessibility text size from.
private struct AstroDataHeroText: ViewModifier {
    @ScaledMetric(relativeTo: .title) private var size = AstroType.dataHeroBaseSize

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .monospacedDigit()
    }
}

extension View {
    /// `display`: the page's one judgment sentence. Tight tracking plus
    /// balanced wrapping (spec 5.2's SwiftUI equivalent of CSS
    /// `text-wrap: balance`) so a long headline never truncates mid-word.
    public func astroDisplay() -> some View {
        font(AstroType.display)
            .tracking(-0.5)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// `sectionTitle`: card title, section header.
    public func astroSectionTitle() -> some View {
        font(AstroType.sectionTitle)
            .tracking(-0.2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// `body`: explanatory prose.
    public func astroBody() -> some View {
        font(AstroType.body)
    }

    /// `dataHero`: a card's headline numeric value, `@ScaledMetric`-scaled
    /// and always tabular.
    public func astroDataHero() -> some View {
        modifier(AstroDataHeroText())
    }

    /// `data`: table cell, row value. Always tabular.
    public func astroData() -> some View {
        font(AstroType.data)
            .monospacedDigit()
    }

    /// `micro`: a microlabel, e.g. "LAST CHECK · 4 MIN AGO". Callers pass
    /// already-uppercase text or rely on `.textCase(.uppercase)` here;
    /// applying both is harmless.
    public func astroMicro() -> some View {
        font(AstroType.micro)
            .tracking(1.4)
            .textCase(.uppercase)
    }
}
