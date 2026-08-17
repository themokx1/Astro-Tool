import SwiftUI

/// How a raised surface insets the content it raises. Deliberately a CLOSED
/// two-case enum rather than a `CGFloat` parameter: the whole point of Task
/// 7c is that there is exactly ONE padding value and ONE corner shape in the
/// app, so a caller can pick which of the two *shapes of content* it has, but
/// never its own numbers.
///
/// - `padded`: ordinary card content (headings, rows, label/value pairs,
///   charts). Gets `AstroTokens.Spacing.standard` on all four sides.
/// - `flush`: content that draws its own insets right out to the card's edge
///   -- a `Table`, a `List`, or a full-pane panel that already carries its own
///   header/divider/footer chrome. Gets none, because AppKit's own row insets
///   and scrollers must reach the card boundary; padding here produces a
///   double gutter and a scroller floating in the middle of the card.
public enum AstroSurfaceFit: Sendable {
    case padded
    case flush
}

public extension View {
    /// THE raised layer of this design system, and the only one.
    ///
    /// # What it is
    ///
    /// `AstroTokens.Color.ground` is the grouped window backdrop, painted
    /// once by `V2RootView`'s detail column (Task 7b). This is the other
    /// half of that pair: the content surface that reads *against* it. It is
    /// derived from what macOS itself does for layered content -- System
    /// Settings' grouped panes, Finder's info pane, Mail's message list: a
    /// light content surface on a grouped grey backdrop.
    ///
    /// # Why it needs an edge at all
    ///
    /// In LIGHT appearance the tonal delta between the two tokens is tiny --
    /// `ground` is `0xF6F7FB`, `surface` is `0xFFFFFF`, roughly 4%. That is
    /// deliberate (macOS's own grouped backdrop is equally subtle), and it is
    /// also why the system does not rely on fill alone: it adds a hairline
    /// border and a very soft shadow so the card has a definite edge. This
    /// modifier does both. In DARK appearance the fill delta does the work on
    /// its own (`0x070A10` -> `0x10151F`), a shadow over near-black is
    /// invisible anyway, and `edge` is correspondingly restrained, so the
    /// shadow is dropped there and only the hairline remains.
    ///
    /// `AstroTokens.Color.surfaceRaised`'s doc comment used to promise that
    /// light appearance "additionally carries a shadow at the call site".
    /// That call site was never written -- until this one. It lives here now,
    /// once, instead of in twenty call sites that would each have guessed a
    /// different radius.
    ///
    /// # This is not `GroupBox` coming back
    ///
    /// The owner's complaint about `GroupBox` (Task 7) was never "no boxes";
    /// it was *inconsistent* boxes. All four of its symptoms are structurally
    /// impossible here rather than merely discouraged:
    ///
    /// 1. **Mismatched padding/corners.** Both come from `AstroTokens` and
    ///    neither is a parameter -- see `AstroSurfaceFit`.
    /// 2. **Wrong tonal direction.** `GroupBox` painted macOS's own opaque
    ///    grey *over* white content. This paints `surface`, which is lighter
    ///    than `ground` in light appearance and lighter than `ground` in dark
    ///    appearance too. Raised is always lighter, never grey-on-white.
    /// 3. **Box in a box.** A raised surface never contains another raised
    ///    surface: the modifier publishes `astroIsInsideRaisedSurface` into
    ///    the environment, and a nested call reading that flag collapses to
    ///    its inset alone -- no second fill, no second border, no second
    ///    shadow. This is a rendering guarantee, not a convention, so it
    ///    holds even across the file boundaries a source-scanning gate cannot
    ///    see. `V2PolishSurfaceTests`' `RaisedSurfaceGate` gates the
    ///    same-file case as well, so the defect is *also* caught at review
    ///    time rather than only silently absorbed at runtime.
    /// 4. **Content hanging over the edge.** The fill, the hairline and the
    ///    clip all use the same shape, and `.containerShape` publishes it so
    ///    a `ConcentricRectangle` inside matches it concentrically.
    ///
    /// # When NOT to use it
    ///
    /// Glass and this treatment are alternatives, not layers. `MetricCard`
    /// and `WorkspaceTablePage`'s floating action bar are `.glassEffect`
    /// surfaces; giving them a fill as well would put an opaque layer under
    /// the glass and undo Task 7b's fix a second time. Page scaffolding -- a
    /// subtitle line, a page header, a `ContentUnavailableView` filling an
    /// empty pane -- is deliberately bare: a sentence is not a card.
    func astroRaisedSurface(_ fit: AstroSurfaceFit = .padded) -> some View {
        modifier(AstroRaisedSurface(fit: fit))
    }
}

/// `true` for every descendant of an `astroRaisedSurface`. Read by the
/// modifier itself so a nested application can collapse instead of painting a
/// second card -- see `astroRaisedSurface`'s own doc comment, point 3.
extension EnvironmentValues {
    @Entry var astroIsInsideRaisedSurface: Bool = false
}

struct AstroRaisedSurface: ViewModifier {
    let fit: AstroSurfaceFit

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.astroIsInsideRaisedSurface) private var isNested

    /// The one corner shape. `.continuous` is macOS's own squircle, the same
    /// curve the system uses for grouped panes and popovers; a plain circular
    /// `RoundedRectangle` reads subtly wrong next to real system chrome.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel, style: .continuous)
    }

    private var inset: CGFloat {
        switch fit {
        case .padded: AstroTokens.Spacing.standard
        case .flush: 0
        }
    }

    /// Light appearance only. Very soft and very close to the card -- this is
    /// an *edge cue*, not a drop shadow; anything bigger reads as a floating
    /// dialog rather than a grouped pane. `.clear` in dark appearance because
    /// a black shadow over a `0x070A10` backdrop is invisible, and the fill
    /// delta plus the hairline already do the job there.
    private var shadowColor: Color {
        colorScheme == .dark ? .clear : .black.opacity(0.07)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isNested {
            // Point 3: a raised surface inside a raised surface is the
            // box-in-box defect. Keep the caller's intended breathing room,
            // drop every painted layer. Grouping *within* a card is a heading
            // plus spacing or a `Divider`, exactly as macOS does it -- never
            // a border on a border.
            content.padding(inset)
        } else {
            content
                .padding(inset)
                .clipShape(shape)
                // The shadow lives on the BACKGROUND SHAPE, not on the
                // composed view. `.shadow` applied to the outer view would
                // make SwiftUI rasterize everything inside the card to
                // compute the silhouette -- for `WorkspaceTablePage`'s table
                // slot that is up to 3,231 rows, re-rendered on every scroll
                // frame, in a project that has already spent five rounds
                // fixing table-layout freezes. The silhouette is a rounded
                // rectangle either way, so computing it from the rectangle
                // is both cheaper and more honest.
                .background {
                    shape
                        .fill(AstroTokens.Color.surface)
                        .shadow(color: shadowColor, radius: 3, y: 1)
                }
                .overlay { shape.strokeBorder(AstroTokens.Color.edge, lineWidth: 1) }
                .containerShape(shape)
                .environment(\.astroIsInsideRaisedSurface, true)
        }
    }
}
