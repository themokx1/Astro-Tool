import SwiftUI

/// A titled card in the report vocabulary -- one `astroRaisedSurface()`
/// panel per report section, matching the "Projects captured this night" /
/// "Next action" card shape both `NightWorkspaceView` and
/// `ProjectWorkspaceView` already use elsewhere on the same Overview tab
/// (W5-1: the former HTML night/target reports' sections, moved in-app).
/// Raised surfaces never nest, so this is always a direct child of the
/// Overview tab's own `VStack`, never wrapped inside another card.
struct ReportSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
    }
}

/// One label/value fact -- the SwiftUI equivalent of the HTML report's
/// `.stat` div (`NightReport.stat(_:_:)` / `TargetReport.statBox(_:_:)`).
struct ReportStat: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A wrapping row of `ReportStat`s -- the SwiftUI equivalent of the HTML
/// report's `.grid` (a wrapping row of `.stat` boxes). `LazyVGrid` rather
/// than `Grid`/`Table` since these are unordered label/value facts, not a
/// row-and-column dataset -- no header, no per-column alignment need.
struct ReportStatGrid: View {
    let items: [(LocalizedStringKey, String)]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140), spacing: AstroTokens.Spacing.standard)],
            alignment: .leading,
            spacing: AstroTokens.Spacing.standard
        ) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                ReportStat(label: item.0, value: item.1)
            }
        }
    }
}

/// A muted explanatory line -- the SwiftUI equivalent of the HTML report's
/// `<p class="muted">` "n/a, because ..." fallback text every section prints
/// instead of silently disappearing when it has nothing to show (the same
/// "every section header renders unconditionally" rule `TargetReport`'s own
/// doc comment states).
struct ReportEmptyNote: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }
}

/// A small, non-virtualized tabular layout for report sections -- `Grid`
/// (never `Table`/`List`) so it is safe inside the Overview tab's
/// `ScrollView`: a target's own night/quality/stack/calibration rows number
/// in the tens, not the thousands, so no virtualization is needed, and
/// `Grid` lays out its full row set eagerly by design (unlike `Table`, which
/// proposes an unbounded height when hosted in a `ScrollView` and cannot
/// virtualize as a result -- see `WorkspaceComponents.swift`'s own doc
/// comment for the incident that rule exists to prevent).
struct ReportGrid<Rows: View>: View {
    let headers: [LocalizedStringKey]
    @ViewBuilder var rows: Rows

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: AstroTokens.Spacing.standard, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    Text(header).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Divider()
            rows
        }
    }
}
