import AstroApplication
import SwiftUI

struct WorkspacePage<Content: View>: View {
    let subtitle: LocalizedStringKey
    @ViewBuilder let content: Content

    init(
        subtitle: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) {
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
                // V2 UI/UX audit (2026-08-14) systemic pattern S6: this used
                // to also render an uppercased eyebrow and a `.largeTitle`
                // page title here, directly beneath the global
                // `BreadcrumbBar` and alongside each view's own
                // `.navigationTitle` -- the same page name shown three
                // times, burning ~120pt of the first screenful on chrome.
                // The subtitle survives: it carries real per-page guidance
                // the breadcrumb/title never did.
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                content
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(AstroTokens.Spacing.spacious)
        }
        // Task 6 (2026-08-17, Liquid Glass): this used to paint a 36% tint
        // of `ground` over the whole page, and Task 6 removed it with no
        // replacement, on the theory that a transparent page would show
        // "the window's own macOS 26 system glass". Task 7b disproved that
        // theory -- on macOS the system material is in the sidebar and the
        // toolbar, not in a plain window's content area, so this page fell
        // through to a white window background and every `surface` card on
        // it went white-on-white.
        //
        // Still no background HERE, though: the page backdrop now has a
        // single owner one level up, `V2RootView`'s detail column
        // (`.background(AstroTokens.Color.ground)`), which covers all 21
        // routes rather than just the 8 that happen to use this component.
        // This stays page-level scaffolding, not a card/panel.
        // `.scrollEdgeEffectStyle` gives the scroll position itself a soft
        // blend into whatever sits above it (the toolbar) instead of a hard
        // content/chrome seam.
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

/// A non-scrolling workspace container for pages whose primary content is a
/// `Table`. `WorkspacePage` is a `ScrollView`, and a `Table` placed inside a
/// `ScrollView` is proposed an unbounded height -- AppKit then cannot
/// virtualize rows, so every layout pass materializes and lays out ALL of
/// them (up to 217 for Planning's catalog, confirmed by sampling the live
/// frozen process at build 20017). `WorkspaceTablePage` fixes that by never
/// scrolling the page itself: the header and `toolbar` stay put at a fixed
/// size, and `table` is given `.frame(maxHeight: .infinity)` inside a plain
/// (non-scrolling) `VStack`, so it receives a genuinely bounded height from
/// the window and virtualizes normally, scrolling only itself. An optional
/// `footer` renders below the table for the rare page that needs a small
/// amount of fixed trailing content (e.g. a selected-item detail panel) --
/// it should bound its own height (with its own `ScrollView` if its content
/// could grow large) rather than assume unlimited space, since it shares the
/// remaining space with `table`.
///
/// Only the header matches `WorkspacePage`'s max-width column exactly (same
/// tokens, same background) -- `toolbar` and `table` intentionally use the
/// full available width, since a `Table` benefits from the extra room for
/// its columns.
struct WorkspaceTablePage<Toolbar: View, TableContent: View, Footer: View>: View {
    let subtitle: LocalizedStringKey
    @ViewBuilder let toolbar: Toolbar
    @ViewBuilder let table: TableContent
    @ViewBuilder let footer: Footer

    init(
        subtitle: LocalizedStringKey,
        @ViewBuilder toolbar: () -> Toolbar,
        @ViewBuilder table: () -> TableContent,
        @ViewBuilder footer: () -> Footer
    ) {
        self.subtitle = subtitle
        self.toolbar = toolbar()
        self.table = table()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            // V2 UI/UX audit (2026-08-14) systemic pattern S6: same fix as
            // `WorkspacePage` above -- see its own doc comment. The subtitle
            // survives; the redundant eyebrow + large title do not.
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 920, alignment: .leading)

            // Task 6 (2026-08-17, Liquid Glass): the "lebegő akciósáv"
            // (floating action bar) row of the plan's own material table.
            // Every `WorkspaceTablePage` caller's own filter/search/action
            // row now floats as one glass bar above its table, in a single
            // shared spot rather than eight separate call sites.
            //
            // *** DIAL-IT-BACK POINT ***: if this reads as too much glass,
            // change `.regular` immediately below to `.identity` (or delete
            // the `GlassEffectContainer`/`.glassEffect` pair and put back a
            // plain `toolbar` line) -- every page built on this component
            // reverts at once, because this is the one place all eight of
            // them share.
            GlassEffectContainer {
                toolbar
                    .padding(.horizontal, AstroTokens.Spacing.standard)
                    .padding(.vertical, AstroTokens.Spacing.compact)
                    .glassEffect(.regular, in: ConcentricRectangle())
            }

            // Task 6: the dense content itself -- up to 3,231 rows in the
            // real reference library's worst case (see
            // `ArchiveTaskDetailView`'s own doc comment) -- stays on an
            // explicit SOLID `surface`, never glass. This is the one
            // container in the file whose direct child is a caller-supplied
            // `Table`/`List`, so it is exactly the shape
            // `V2PolishSurfaceTests`'s `noTableOrListHasAGlassParent` gate
            // exists to keep solid: `.background` here, never
            // `.glassEffect`.
            table
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AstroTokens.Color.surface, in: ConcentricRectangle())

            footer
        }
        .padding(AstroTokens.Spacing.spacious)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Task 6 removed the same self-inflicted 36% tint `WorkspacePage`
        // used to paint, for the same (wrong) reason -- see that view's own
        // comment above and Task 7b's correction. Still no background here:
        // this outer frame is page scaffolding around the toolbar/table
        // pair above, not itself a card, and `V2RootView`'s detail column
        // is the single owner of the opaque `ground` backdrop it sits on.
        // The `surface` behind `table` a few lines up is the raised layer
        // that reads AGAINST that backdrop.
    }
}

extension WorkspaceTablePage where Footer == EmptyView {
    init(
        subtitle: LocalizedStringKey,
        @ViewBuilder toolbar: () -> Toolbar,
        @ViewBuilder table: () -> TableContent
    ) {
        self.init(subtitle: subtitle, toolbar: toolbar, table: table, footer: { EmptyView() })
    }
}

struct MetricCard: View {
    // V2 UI/UX audit (2026-08-16): these two used to be plain `String`,
    // which routes `Label`/`Text` through their verbatim `StringProtocol`
    // overload instead of the `LocalizedStringKey` one -- so every metric
    // card's title and detail ("Reference", "Focal length", "Useful
    // matches", …) stayed English even after the Hungarian table shipped.
    // `value` and `systemImage` stay `String`: `value` is almost always a
    // formatted number/duration, never a phrase to translate.
    let title: LocalizedStringKey
    let value: String
    let detail: LocalizedStringKey
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .astroDataHero()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .padding(AstroTokens.Spacing.standard)
        // Task 6 (2026-08-17, Liquid Glass): a real "kártya" (card) in the
        // plan's own sense -- a title, a hero value, a detail line, never a
        // Table/List -- so it is one of the containers that gets true glass
        // instead of the former `.regularMaterial` approximation.
        // `ConcentricRectangle` (no explicit radius) matches the nearest
        // enclosing container's own corner rounding rather than a fixed
        // value baked in here.
        .glassEffect(.regular, in: ConcentricRectangle())
    }
}
