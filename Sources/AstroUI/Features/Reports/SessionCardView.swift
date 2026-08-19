import AppKit
import Foundation
import SwiftUI

/// The shareable "session card" itself -- expert ideation spec #4. Renders
/// `SessionCardContent` at a fixed 1200x675 size (a common social-share
/// aspect) so `ImageRenderer` always produces the same PNG dimensions no
/// matter what the app's own window is doing at export time.
///
/// Deliberately single-appearance dark, like `ReportComponents.swift`'s own
/// report sections read against `AstroTokens.Color.ground`/`.surface` --
/// this is a PNG someone shares outside the app, so it must look right
/// regardless of the VIEWER's OS appearance, not just the exporting user's.
/// Forcing `.environment(\.colorScheme, .dark)` here is what makes every
/// `AstroTokens.Color` token (all built via `NSColor(name:dynamicProvider:)`,
/// see that type's own doc comment) resolve to its dark-appearance hex no
/// matter which appearance the host window is in when `ImageRenderer`
/// snapshots this view.
public struct SessionCardView: View {
    /// Fixed render size -- `ImageRenderer(content:)`'s only source of
    /// dimensions is this view's own proposed/explicit frame, so every
    /// export comes out exactly this size regardless of window size.
    public static let cardSize = CGSize(width: 1200, height: 675)

    let content: SessionCardContent
    /// Resolved and awaited (with a timeout) by the caller BEFORE this view
    /// is ever handed to `ImageRenderer` -- see `SessionCardThumbnailLoader`
    /// (`SessionCardExport.swift`) for why: `ImageRenderer` snapshots a
    /// view's state synchronously, so loading the thumbnail through
    /// `FrameThumbnailCell`'s own `.task`-driven async body here would risk
    /// losing that race and baking its `ProgressView` placeholder into the
    /// exported PNG instead of the real thumbnail (or nothing at all).
    /// `nil` -- no thumbnail path, load failure, or timeout -- renders the
    /// card without one, all three indistinguishable from each other: the
    /// current no-thumbnail layout.
    let preloadedThumbnail: NSImage?

    public init(content: SessionCardContent, preloadedThumbnail: NSImage? = nil) {
        self.content = content
        self.preloadedThumbnail = preloadedThumbnail
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            AstroTokens.Color.ground
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
                header
                Spacer(minLength: 0)
                HStack(alignment: .top, spacing: AstroTokens.Spacing.section) {
                    thumbnail
                    VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                        Text(content.targetName)
                            .font(.system(size: 44, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(AstroTokens.Color.ink)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                        Text(content.dateText)
                            .font(.title3)
                            .foregroundStyle(AstroTokens.Color.inkDim)
                    }
                }
                Spacer(minLength: 0)
                statRow
            }
            .padding(AstroTokens.Spacing.spacious)
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("v2.night.session-card")
    }

    private var header: some View {
        HStack {
            Text(content.appName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AstroTokens.Color.inkFaint)
                .textCase(.uppercase)
            Spacer()
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let preloadedThumbnail {
            Image(nsImage: preloadedThumbnail)
                .resizable()
                .scaledToFit()
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel))
        }
    }

    private var statRow: some View {
        HStack(spacing: AstroTokens.Spacing.section) {
            statColumn(label: "Integration", value: content.integrationText)
            statColumn(label: "Median FWHM", value: content.fwhmText)
            statColumn(label: "Background", value: content.backgroundText)
            Spacer()
        }
    }

    private func statColumn(label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout)
                .foregroundStyle(AstroTokens.Color.inkDim)
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(AstroTokens.Color.ink)
        }
    }
}
