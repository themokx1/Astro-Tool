import AstroCore
import SwiftUI

/// R11-T9/F5's "Előző éjszaka" morning-triage page (sidebar row conditional
/// on `AppState.freshSessionKeys` being non-empty, no `⌘`-shortcut -- see
/// `Page.previousNight`'s own doc comment): one card per session the last
/// scan reported a new/updated light frame for, each showing the exact same
/// key numbers `NightsPage`/`SessionsSegment` already show (frame count,
/// integration, `FilterBreakdown`, median FWHM) plus this run's cooler/focus
/// verdict and outlier ratio, with the three actions a morning routine
/// actually needs one click away: score it, blink through it, or write its
/// report.
struct PreviousNightPage: View {
    @Environment(AppState.self) private var appState
    @State private var reviewingSession: ReviewSessionID?

    private struct ReviewSessionID: Identifiable {
        let target: String
        let date: String
        var id: String { "\(target)|\(date)" }
    }

    var body: some View {
        Group {
            // F5 item 6: reachable even with zero fresh sessions (the
            // sidebar row itself hides, but a page already open when the
            // last fresh session gets rated/reviewed away must not vanish
            // out from under the user) -- same empty-state-over-navigating-
            // away stance every other page in this app takes.
            if appState.freshSessionKeys.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .onAppear { appState.loadPreviousNight() }
        // A rescan while this page is already open (or the "Új sessionök
        // pontozása" button's own post-rate rebuild) changes
        // `freshSessionKeys`/`previousNightCards` out from under a visit
        // that's already in progress -- reload so the cards never go stale
        // while the page sits on screen.
        .onChange(of: appState.freshSessionKeys) { _, _ in appState.loadPreviousNight() }
        .sheet(item: $reviewingSession) { session in
            PreviousNightReviewSheet(target: session.target, date: session.date)
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(appState.previousNightCards) { card in
                        cardView(card)
                    }
                }
                .padding(16)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("\(appState.freshSessionKeys.count) friss session az utolsó beolvasás óta")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Új sessionök pontozása") { appState.runRateFreshSessions() }
                .disabled(appState.isBusy || appState.db == nil)
        }
        .padding()
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nincs friss anyag", systemImage: "moon.zzz")
        } description: {
            Text("Az utolsó beolvasás óta nem érkezett új session.")
        } actions: {
            Button("Beolvasás") { appState.runScan() }
                .disabled(appState.isBusy || appState.db == nil)
        }
    }

    // MARK: - Card

    private func cardView(_ card: PreviousNightCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                appState.pendingTargetSegment = .sessions
                appState.pendingSessionSelection = card.date
                appState.currentPage = .target(card.target)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(card.displayName).font(.headline)
                    Text(card.date).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 20) {
                labeledStat("Keretek", "\(card.usableLightCount)")
                labeledStat("Integráció", TDFormat.hm(card.integrationSeconds))
                labeledStat("FWHM″", fwhmText(card))
            }

            if let filterText = TDFormat.filterBreakdownSummary(card.filterBreakdown) {
                Text("Szűrők: \(filterText)").font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                VerdictChip(verdict: card.coolerVerdict)
                VerdictChip(verdict: card.focusVerdict)
                outlierBadge(card)
            }

            HStack(spacing: 8) {
                Button("Pontozás") { appState.runRateFreshSession(target: card.target, date: card.date) }
                    .disabled(appState.isBusy)
                Button("Átnézés…") { reviewingSession = ReviewSessionID(target: card.target, date: card.date) }
                    .disabled(appState.isBusy || card.ratedFrameCount == 0)
                    .help(card.ratedFrameCount == 0 ? "Előbb pontozd a sessiont" : "")
                Button("Éjszaka-riport") { appState.exportNightReport(target: card.target, date: card.date) }
                    .disabled(appState.isBusy)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func labeledStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.subheadline).bold()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func fwhmText(_ card: PreviousNightCard) -> String {
        if let arcsec = card.medianFWHMArcsec { return String(format: "%.2f", arcsec) }
        if let px = card.medianFWHMPixels { return String(format: "%.2f px", px) }
        return TDFormat.missingTile
    }

    @ViewBuilder
    private func outlierBadge(_ card: PreviousNightCard) -> some View {
        if let ratio = card.outlierRatio {
            Text("Kiugró: \(TDFormat.percent(ratio * 100)) (\(card.ratedFrameCount) keret)")
                .font(.caption)
                .foregroundStyle(ratio > 0 ? .orange : .secondary)
        } else {
            Text("még nincs pontozva").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// "Átnézés…"'s own `FrameReviewSheet` wrapper -- loads
/// `AppState.reviewFrameScores` on appear (see that property's own doc
/// comment for why this doesn't just reuse `frameScores`/`loadFrameScores`),
/// showing a spinner until the load lands, same "load on appear, clear on
/// disappear" convention `PlateSolveSheet` already established.
private struct PreviousNightReviewSheet: View {
    @Environment(AppState.self) private var appState

    let target: String
    let date: String

    var body: some View {
        Group {
            if let frames = appState.reviewFrameScores {
                FrameReviewSheet(frames: frames, isReviewScoped: true)
            } else {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(appState.progressText).foregroundStyle(.secondary)
                }
                .frame(minWidth: 760, minHeight: 600)
            }
        }
        .onAppear { appState.loadReviewFrames(target: target, date: date) }
        // R12-U1 item 3: `cancelReviewFrames()` (cancels the in-flight load
        // + clears `reviewFrameScores`/`reviewFrameVerdicts`), not just
        // `appState.reviewFrameScores = nil` -- see that method's own doc
        // comment.
        .onDisappear { appState.cancelReviewFrames() }
    }
}
