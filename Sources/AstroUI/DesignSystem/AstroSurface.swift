import SwiftUI

/// How a surface -- raised or recessed -- insets the content it holds.
/// Deliberately a CLOSED two-case enum rather than a `CGFloat` parameter: the
/// whole point of Task 7c is that there is exactly ONE padding value and ONE
/// corner shape in the app, so a caller can pick which of the two *shapes of
/// content* it has, but never its own numbers.
///
/// - `padded`: ordinary card content (headings, rows, label/value pairs,
///   charts). Gets `AstroTokens.Spacing.standard` on all four sides.
/// - `flush`: content that draws its own insets right out to the card's edge
///   -- a `Table`, a `List`, or a full-pane panel that already carries its own
///   header/divider/footer chrome. Gets none, because AppKit's own row insets
///   and scrollers must reach the card boundary; padding here produces a
///   double gutter and a scroller floating in the middle of the card.
///
/// Task 7d shares this type with the recessed treatment rather than giving
/// that one its own parallel enum. A well and a card face the identical
/// question (does the content inset itself already?), and two enums answering
/// it would be two places for the ONE padding value to drift apart -- which
/// is the defect this whole sequence of tasks exists to close.
public enum AstroSurfaceFit: Sendable {
    case padded
    case flush

    /// The one padding value, resolved in one place for both treatments.
    var inset: CGFloat {
        switch self {
        case .padded: AstroTokens.Spacing.standard
        case .flush: 0
        }
    }
}

/// The one corner shape, shared by both treatments. `.continuous` is macOS's
/// own squircle, the same curve the system uses for grouped panes and
/// popovers; a plain circular `RoundedRectangle` reads subtly wrong next to
/// real system chrome.
private var astroSurfaceShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel, style: .continuous)
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

    /// THE recessed layer of this design system, and the only one.
    ///
    /// # What it is
    ///
    /// The mirror of `astroRaisedSurface(_:)`: a well sunk INTO whatever it
    /// sits in, for content that is a read-only summary of something rather
    /// than the page's own subject -- a night's frame breakdown inside a
    /// project card, a "what this will affect" block above a confirm button,
    /// a metric tile. Raised says "this is a thing"; recessed says "this is
    /// a slot showing you a value".
    ///
    /// # Why it exists
    ///
    /// The three wells in the tree before Task 7d were `.quaternary` at
    /// 1.0, 0.5 and 0.45 opacity, one of them at a corner radius of 10 that
    /// matched nothing else in the app -- three recipes and a rogue radius
    /// for one concept, the owner's own complaint ("nem egységesek a
    /// padding-ek, margók és a lekerekítések") in miniature.
    ///
    /// They were also, all three, WRONG IN DARK APPEARANCE, which is the
    /// part no amount of tidying would have found. `.quaternary` is a
    /// hierarchical FOREGROUND style: black at ~10% alpha in light, white at
    /// ~10% alpha in dark. Over `surface` (.0810) the three recipes measure
    /// .1711/.1261/.1216 in dark -- every one of them lighter than the
    /// surface they were meant to be sunk into, i.e. raised. See
    /// `AstroTokens.Color.recess` for the full measurement table. A
    /// hierarchical style cannot express "darker than my parent" because it
    /// does not know what its parent is; an explicit two-appearance token
    /// can, and can be gated.
    ///
    /// # Why it is NOT just the raised treatment with another fill
    ///
    /// It paints the fill and nothing else -- no hairline, no shadow. Both
    /// omissions are deliberate:
    ///
    /// - **No hairline.** A card needs one because in light appearance
    ///   `surface` is a 3% step off `ground` and 3% is not an edge. A well
    ///   is an 8.3% step BELOW `surface` in light and 66% below it in dark
    ///   (relative), so the fill alone is already a definite edge. Adding a
    ///   stroke would also put a border immediately inside the card's own
    ///   border -- "never a border on a border", the same rule point 3 of
    ///   `astroRaisedSurface` states. And in light appearance `edge`
    ///   (.8928) and `recess` (.9166) are 2.4 points apart: a hairline
    ///   around this fill would be very nearly invisible anyway.
    /// - **No shadow.** A drop shadow says "above". Putting one under a well
    ///   would say the opposite of what the fill says.
    ///
    /// # When NOT to use it
    ///
    /// A full-bleed stage is not a well. `FrameBlinkReview`'s image preview
    /// spans edge to edge between two `Divider`s; giving it panel corners
    /// would round a pane that is butted against full-width rules. There is
    /// deliberately no third `AstroSurfaceFit` case for that -- one call
    /// site is not a treatment, and a `.bleed` case would be the first crack
    /// in the closed enum that keeps this app to one padding value.
    ///
    /// Status chips and badges are not wells either. A tinted `Capsule` or
    /// `Circle` behind a count is the STATUS vocabulary
    /// (`AstroTokens.Color.ok`/`attention`/`critical`), which encodes what a
    /// value means; a well encodes only where a value sits.
    func astroRecessedSurface(_ fit: AstroSurfaceFit = .padded) -> some View {
        modifier(AstroRecessedSurface(fit: fit))
    }
}

/// `true` for every descendant of an `astroRaisedSurface`. Read by the
/// modifier itself so a nested application can collapse instead of painting a
/// second card -- see `astroRaisedSurface`'s own doc comment, point 3.
extension EnvironmentValues {
    @Entry var astroIsInsideRaisedSurface: Bool = false
}

/// `true` for every descendant of an `astroRecessedSurface`, and the exact
/// counterpart of `astroIsInsideRaisedSurface` above. A well inside a well is
/// the same defect as a box inside a box: two fills of the same colour meet,
/// so the inner one is invisible and only its doubled gutter shows.
///
/// Note what this flag deliberately does NOT do: it does not clear
/// `astroIsInsideRaisedSurface`. Content inside a well inside a card is still
/// inside a card, so an `astroRaisedSurface` reached through a well must
/// still collapse.
extension EnvironmentValues {
    @Entry var astroIsInsideRecessedSurface: Bool = false
}

struct AstroRaisedSurface: ViewModifier {
    let fit: AstroSurfaceFit

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.astroIsInsideRaisedSurface) private var isNested

    private var shape: RoundedRectangle { astroSurfaceShape }

    private var inset: CGFloat { fit.inset }

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

struct AstroRecessedSurface: ViewModifier {
    let fit: AstroSurfaceFit

    @Environment(\.astroIsInsideRecessedSurface) private var isNested

    private var shape: RoundedRectangle { astroSurfaceShape }

    private var inset: CGFloat { fit.inset }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isNested {
            // Same guarantee as the raised treatment's point 3, for the same
            // reason: keep the caller's intended breathing room, paint
            // nothing. Two identical fills meeting produces no second well,
            // only a doubled gutter, so the collapsed form is what the
            // nested caller visually meant anyway.
            content.padding(inset)
        } else {
            content
                .padding(inset)
                .clipShape(shape)
                // No `.shadow` here at all, so unlike the raised treatment
                // there is no silhouette to rasterize and no reason to hoist
                // the fill onto a background shape for performance. The fill
                // still goes through the shape rather than through
                // `.background(_:in:)` so that the ONE shape value defined at
                // the top of this file is the only shape in play.
                .background { shape.fill(AstroTokens.Color.recess) }
                .containerShape(shape)
                .environment(\.astroIsInsideRecessedSurface, true)
        }
    }
}
