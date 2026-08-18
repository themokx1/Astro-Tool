import SwiftUI

/// Wave 2 Task 8 (motion pass): the app's one motion vocabulary. It shipped
/// with almost no deliberate motion at all -- this gives it the macOS 26
/// native minimum (glass morphing, numeric content transitions, a short
/// route/tab content swap) through exactly one curve, one duration, and one
/// gate, rather than each adoption site inventing its own.
///
/// The gate is the point: a call site never writes `withAnimation(.snappy(
/// ...))` or `.animation(.spring(...), value:)` directly and never invents
/// its own `reduceMotion ? nil : ...` ternary (see `ArchiveStripView.swift`'s
/// pre-existing example of exactly that pattern, predating this task and
/// out of its file scope to migrate). It asks `AstroMotion` for the
/// animation/transition, passing the current
/// `\.accessibilityReduceMotion` reading, and gets back either the real
/// thing or `nil`/`.identity`/no motion at all -- there is no spelling of
/// "animate this" that skips the check, by construction, because the raw
/// SwiftUI API is never called at the adoption site. `AstroMotionTests`'
/// `noAnimationCallSiteInFeaturesBypassesTheHelper` gates this by scanning
/// `Sources/AstroUI/Features` source text for the two SwiftUI spellings
/// that bypass it.
public enum AstroMotion {
    /// The one duration every adoption in this pass uses: short enough to
    /// read as a state change, not a performance.
    public static let duration: Double = 0.22

    /// The one curve every adoption in this pass uses.
    public static let curve: Animation = .easeInOut(duration: duration)

    /// Resolves `curve` (or a caller-supplied animation) to `nil` under
    /// Reduce Motion, which collapses `.animation(...)`/`withAnimation`
    /// to an identity (immediate) change instead of animating. THE gate
    /// every animation in this pass routes through.
    public static func animation(_ base: Animation = curve, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : base
    }

    /// The reduce-motion resolution for a route/tab content swap, as a
    /// plain `Equatable` value rather than SwiftUI's own (non-`Equatable`)
    /// `AnyTransition` -- so `AstroMotionTests` can assert the identity
    /// resolution directly instead of only by proxy through source text.
    /// `.contentSwapTransition(reduceMotion:)` is what a view actually
    /// applies; this is the pure decision behind it.
    public enum ContentSwapStyle: Equatable, Sendable {
        /// An instant swap -- no motion at all.
        case identity
        /// A short fade-and-rise.
        case fadeAndRise
    }

    public static func contentSwapStyle(reduceMotion: Bool) -> ContentSwapStyle {
        reduceMotion ? .identity : .fadeAndRise
    }

    /// The standard content transition for a route/tab content swap. Pair
    /// with `.astroAnimation(reduceMotion:value:)` on the same view so the
    /// swap actually animates -- a `.transition` alone only takes effect
    /// inside an animated transaction.
    public static func contentSwapTransition(reduceMotion: Bool) -> AnyTransition {
        switch contentSwapStyle(reduceMotion: reduceMotion) {
        case .identity: .identity
        case .fadeAndRise: .opacity.combined(with: .move(edge: .bottom))
        }
    }

    /// The reduce-motion resolution for a `GlassEffectContainer` member's
    /// morph transition, as a plain `Equatable` value rather than SwiftUI's
    /// own (non-`Equatable`) `GlassEffectTransition` -- same reasoning as
    /// `ContentSwapStyle` above.
    public enum GlassMorphStyle: Equatable, Sendable {
        /// An instant pop -- no morph at all.
        case identity
        /// Matched-geometry morphing between appear/disappear/reflow.
        case matchedGeometry
    }

    public static func glassMorphStyle(reduceMotion: Bool) -> GlassMorphStyle {
        reduceMotion ? .identity : .matchedGeometry
    }

    /// The standard glass-morph transition for a `GlassEffectContainer`
    /// member: matched-geometry morphing between appear/disappear/reflow,
    /// or `.identity` (an instant pop, no morph) under Reduce Motion.
    public static func glassTransition(reduceMotion: Bool) -> GlassEffectTransition {
        switch glassMorphStyle(reduceMotion: reduceMotion) {
        case .identity: .identity
        case .matchedGeometry: .matchedGeometry
        }
    }
}

extension View {
    /// Applies `AstroMotion`'s one curve to `value`'s changes, or no
    /// animation at all under Reduce Motion -- the single call every
    /// animated `View` in this pass uses instead of a raw
    /// `.animation(...)`.
    public func astroAnimation<V: Equatable>(
        _ reduceMotion: Bool,
        value: V,
        _ base: Animation = AstroMotion.curve
    ) -> some View {
        animation(AstroMotion.animation(base, reduceMotion: reduceMotion), value: value)
    }

    /// Applies `AstroMotion`'s standard route/tab content-swap transition,
    /// or no transition under Reduce Motion. Combine with
    /// `.astroAnimation(reduceMotion:value:)` on the value that
    /// discriminates the swap so it actually animates.
    public func astroContentSwapTransition(_ reduceMotion: Bool) -> some View {
        transition(AstroMotion.contentSwapTransition(reduceMotion: reduceMotion))
    }

    /// Gives a `GlassEffectContainer` member a stable morph identity plus
    /// `AstroMotion`'s standard glass transition -- appearing, disappearing,
    /// or reflowing alongside its siblings morphs instead of popping,
    /// unless Reduce Motion is on, in which case the transition resolves to
    /// `.identity` (the id is harmless to keep set either way).
    public func astroGlassMorph(
        id: some Hashable & Sendable,
        in namespace: Namespace.ID,
        reduceMotion: Bool
    ) -> some View {
        glassEffectID(id, in: namespace)
            .glassEffectTransition(AstroMotion.glassTransition(reduceMotion: reduceMotion))
    }
}
