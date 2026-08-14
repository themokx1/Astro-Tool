import AstroApplication
import SwiftUI

struct WorkspacePage<Content: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(
        eyebrow: String,
        title: String,
        subtitle: String,
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
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                    Text(eyebrow.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(1.3)
                        .foregroundStyle(AstroTokens.Color.spectralBlue)
                    Text(title)
                        .font(.largeTitle.weight(.semibold))
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                content
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(AstroTokens.Spacing.spacious)
        }
        .background(AstroTokens.Color.graphite.opacity(0.36))
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
    let eyebrow: String
    let title: String
    let subtitle: String
    @ViewBuilder let toolbar: Toolbar
    @ViewBuilder let table: TableContent
    @ViewBuilder let footer: Footer

    init(
        eyebrow: String,
        title: String,
        subtitle: String,
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
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                Text(eyebrow.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.3)
                    .foregroundStyle(AstroTokens.Color.spectralBlue)
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 920, alignment: .leading)

            toolbar

            table
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
        }
        .padding(AstroTokens.Spacing.spacious)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AstroTokens.Color.graphite.opacity(0.36))
    }
}

extension WorkspaceTablePage where Footer == EmptyView {
    init(
        eyebrow: String,
        title: String,
        subtitle: String,
        @ViewBuilder toolbar: () -> Toolbar,
        @ViewBuilder table: () -> TableContent
    ) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle, toolbar: toolbar, table: table, footer: { EmptyView() })
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title.weight(.semibold).monospacedDigit())
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
                .stroke(AstroTokens.Color.hairline, lineWidth: 1)
        }
    }
}
