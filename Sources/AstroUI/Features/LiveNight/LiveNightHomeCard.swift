import AstroApplication
import AstroCore
import SwiftUI

/// V3 pre-stack program, section 5.6 (Élő éjszaka-mód): registers the live-
/// session Home card through the Wave 0 `HomeCardProviding` seam -- this is
/// the ONE file 5.6 ever needs to touch to add its own card, never
/// `HomeView`'s shared body (see that protocol's own doc comment,
/// `Sources/AstroUI/Features/Home/HomeCardProviding.swift`, and
/// `IngestHomeCardProvider` for 5.1's own worked example of the same seam).
@MainActor
public struct LiveNightHomeCardProvider: HomeCardProviding {
    private let watcher: LiveNightWatcher

    public init(watcher: LiveNightWatcher) {
        self.watcher = watcher
    }

    /// "Nothing real, nothing shown" -- `nil` whenever nothing is being
    /// watched right now, the same contract `IngestHomeCardProvider.card`
    /// follows for its own candidate.
    public func card(store: HomeStore) -> AnyView? {
        guard watcher.folderURL != nil else { return nil }
        return AnyView(LiveNightCard(watcher: watcher))
    }
}

/// "Élő éjszaka: 42 fény, cél 68%, becslés kész 03:40" -- the spec's own
/// example copy, composed here from already-pre-formatted fragments
/// (`AstroFormat.count`/`.percent`/`.fwhmPixels`, this file's own
/// `hmFormatter`) rather than raw numbers interpolated directly into a
/// `Text("...")` literal -- the exact "pre-format numbers before
/// interpolation" rule this codebase's own `HomeView` doc comments repeat
/// throughout (e.g. "Moon interferes tonight" -- multiple raw numbers must
/// never share one interpolated sentence).
private struct LiveNightCard: View {
    @Bindable var watcher: LiveNightWatcher

    var body: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            HStack(spacing: 8) {
                Image(systemName: statusSystemImage)
                    .foregroundStyle(statusColor)
                Text("Live night").font(.headline)
                Spacer()
                statusCaption
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            frameCountLine
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("v2.home.live-night-frames")
            fwhmLine
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("v2.home.live-night-fwhm")
            if let goalLine {
                goalLine
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("v2.home.live-night-goal")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
        .accessibilityIdentifier("v2.home.live-night-card")
    }

    private var session: LiveNightSessionModel { watcher.session }

    private var statusSystemImage: String {
        switch session.connectionState {
        case .watching: "dot.radiowaves.left.and.right"
        case .idleTooLong: "moon.zzz"
        case .disconnected: "wifi.slash"
        }
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .watching: AstroTokens.Color.ok
        case .idleTooLong: AstroTokens.Color.attention
        case .disconnected: AstroTokens.Color.critical
        }
    }

    @ViewBuilder
    private var statusCaption: some View {
        switch session.connectionState {
        case .watching: Text("Watching")
        case .idleTooLong: Text("No new frames — is the night over?")
        case .disconnected: Text("Connection lost")
        }
    }

    /// "42 frames" alone for a single-format night, or "42 frames (30 FITS,
    /// 12 CR3)" once both formats appear -- both counts pre-formatted via
    /// `AstroFormat.count` before interpolation.
    private var frameCountLine: Text {
        let totalText = AstroFormat.count(session.totalFrameCount)
        guard session.fitsFrameCount > 0, session.cr3FrameCount > 0 else {
            return Text("\(totalText) frames captured tonight")
        }
        let fitsText = AstroFormat.count(session.fitsFrameCount)
        let cr3Text = AstroFormat.count(session.cr3FrameCount)
        return Text("\(totalText) frames captured tonight (\(fitsText) FITS, \(cr3Text) CR3)")
    }

    /// Always labeled "(proxy)", per `QuickStarProxy`'s own doc comment --
    /// never presented as the real, Siril-computed measurement. CR3-only
    /// nights (no FITS frames at all yet) get the spec's own honest "n/a —
    /// CR3" line rather than a blank or a guessed value (see the 5.6/5.4
    /// "CR3-korlát" notes: native pixel decoding, which the proxy needs, is
    /// structurally unavailable for CR3).
    @ViewBuilder
    private var fwhmLine: some View {
        if session.fitsFrameCount == 0 {
            Text("FWHM (proxy): n/a — CR3")
        } else if let radius = session.medianQuickProxyRadiusPixels {
            Text("FWHM (proxy): \(AstroFormat.fwhmPixels(radius))")
        } else {
            Text("FWHM (proxy): not measured yet")
        }
    }

    /// `nil` whenever `LiveNightWatcher.currentGoalEstimate()` has nothing
    /// honest to project (no matched project, no goal set, or not enough
    /// pace data yet) -- the Home card's own "nothing real, nothing shown"
    /// branch, matching `IngestVolumeCard`'s own optional-prefill handling.
    private var goalLine: Text? {
        guard let estimate = watcher.currentGoalEstimate() else { return nil }
        let percentText = AstroFormat.percent(min(estimate.progressFraction, 1) * 100)
        guard let eta = estimate.etaDate, let remaining = estimate.remainingFrameCount, remaining > 0 else {
            return Text("Goal: \(percentText)")
        }
        let etaText = Self.timeFormatter.string(from: eta)
        // Both halves pre-formatted into their own already-localized-number-
        // free `String`s before entering this ONE interpolated sentence --
        // the "one %@, never two raw numbers in the same fragment" rule
        // `HomeView`'s "Moon interferes tonight" comment documents for the
        // identical reason.
        let combined = "\(percentText) · ready ~\(etaText)"
        return Text("Goal: \(combined)")
    }

    /// Same `HH:mm`, `en_US_POSIX`, current-time-zone shape as
    /// `NightContextRail.hmFormatter` (`HomeView.swift`) -- one canonical
    /// time-of-day rendering, not a second hand-rolled one.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
