import AstroApplication
import SwiftUI

struct WorkspacePage<Content: View>: View {
    // Task 5b (2026-08-17): `title` is stored and supplied by every one of
    // this type's 7 call sites, but never read by `body` below -- only
    // `subtitle` renders (see its own doc comment). Left `String` on
    // purpose (see `V2PolishSurfaceTests.uiPropertyAllowlist`'s entry for
    // this file/name): it is dead, not untranslated, and translating a
    // field nobody draws would be theater. `eyebrow` is the same story, one
    // property over -- not gated (its name isn't in `uiPropertyNames`), but
    // just as dead.
    let eyebrow: String
    let title: String
    let subtitle: LocalizedStringKey
    @ViewBuilder let content: Content

    init(
        eyebrow: String,
        title: String,
        subtitle: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
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
        .background(AstroTokens.Color.ground.opacity(0.36))
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
    // Task 5b (2026-08-17): same dead-field story as `WorkspacePage.title`
    // above -- stored, supplied by every call site, never read by `body`.
    let eyebrow: String
    let title: String
    let subtitle: LocalizedStringKey
    @ViewBuilder let toolbar: Toolbar
    @ViewBuilder let table: TableContent
    @ViewBuilder let footer: Footer

    init(
        eyebrow: String,
        title: String,
        subtitle: LocalizedStringKey,
        @ViewBuilder toolbar: () -> Toolbar,
        @ViewBuilder table: () -> TableContent,
        @ViewBuilder footer: () -> Footer
    ) {
        self.eyebrow = eyebrow
        self.title = title
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

            toolbar

            table
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
        }
        .padding(AstroTokens.Spacing.spacious)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AstroTokens.Color.ground.opacity(0.36))
    }
}

extension WorkspaceTablePage where Footer == EmptyView {
    init(
        eyebrow: String,
        title: String,
        subtitle: LocalizedStringKey,
        @ViewBuilder toolbar: () -> Toolbar,
        @ViewBuilder table: () -> TableContent
    ) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle, toolbar: toolbar, table: table, footer: { EmptyView() })
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel)
                .stroke(AstroTokens.Color.edge, lineWidth: 1)
        }
    }
}
