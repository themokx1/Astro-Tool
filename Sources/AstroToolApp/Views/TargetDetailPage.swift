import AstroCore
import SwiftUI

/// R9-T3/A.3 -- "the app's most valuable new surface": one target's fixed
/// header (identity, five headline tiles, next-step sentence) above a
/// segmented Áttekintés/Sessionök/Minőség/Stackek/Jegyzetek picker. Absorbs
/// the deleted `QualityView` (its frame table + exposure advisor now live
/// in `QualitySegment`/`OverviewSegment`) and supersedes the on-screen need
/// for `TargetReport`'s HTML (this page shows everything that report
/// composes, live and editable where relevant).
struct TargetDetailPage: View {
    enum Segment: String, CaseIterable, Hashable {
        case overview = "Áttekintés"
        case sessions = "Sessionök"
        case quality = "Minőség"
        case stacks = "Stackek"
        case notes = "Jegyzetek"
    }

    @Environment(AppState.self) private var appState
    let target: String

    @State private var segment: Segment = .overview
    /// R10-B7: drives `.sheet(item:)` presenting the app's single
    /// `GoalEditSheet` -- this header's pencil/"Nincs cél" button used to
    /// present its own private `popover`-based editor (`goalHours`/
    /// `goalPopoverPresented`); killed in favor of the exact same sheet
    /// `TonightPage`'s plan table and `AllTargetsPage`'s context menu
    /// already present, so there's one goal editor in the app, not three.
    @State private var goalEditingTarget: GoalEditingTarget?
    @State private var todosExpanded = false

    // Row-scoped sheet triggers, shared with every segment/context menu that
    // can open the same underlying sheet (`Views/TargetDetail/Shared.swift`).
    @State private var linkingSession: LinkingSession?
    @State private var solvingTarget: SolvingTarget?
    @State private var stackListingSession: LinkingSession?

    private var stat: TargetStats? { appState.stats.first { $0.target == target } }
    private var projectState: ProjectState? { appState.projectStates.first { $0.target == target } }
    private var sessions: [SessionDetail] { appState.sessionDetailsByTarget[target] ?? [] }
    private var bestSession: SessionQualitySummary? { appState.qualitySummaries.first { $0.rankAmongSessions == 1 } }
    private var latestSessionDate: String? { sessions.map(\.dateRaw).max() ?? stat?.lastSessionDate }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Divider()

            Picker("", selection: $segment) {
                ForEach(Segment.allCases, id: \.self) { seg in
                    Text(seg.rawValue).tag(seg)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            segmentContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            appState.loadTargetDetail(target: target)
            // R9-T6/B3: a search-result row (session or note hit) requests
            // a specific segment before navigating here -- consumed once so
            // a later plain sidebar click into this same target doesn't
            // keep jumping back to it.
            if let pendingSegment = appState.pendingTargetSegment {
                segment = pendingSegment
                appState.pendingTargetSegment = nil
            }
        }
        .sheet(item: $linkingSession) { session in CalibLinkSheet(target: session.target, date: session.date) }
        .sheet(item: $solvingTarget) { solving in PlateSolveSheet(target: solving.target) }
        .sheet(item: $stackListingSession) { session in StackListSheet(target: session.target, date: session.date) }
        .sheet(item: $goalEditingTarget) { editing in
            GoalEditSheet(target: editing.target, initialHours: editing.currentHours)
        }
    }

    @ViewBuilder
    private var segmentContent: some View {
        switch segment {
        case .overview:
            OverviewSegment(target: target, solvingTarget: $solvingTarget)
        case .sessions:
            SessionsSegment(target: target, linkingSession: $linkingSession, stackListingSession: $stackListingSession)
        case .quality:
            QualitySegment(target: target)
        case .stacks:
            StacksSegment(target: target)
        case .notes:
            NotesSegment(target: target)
        }
    }

    // MARK: - Fixed header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerRow1
            headerRow2
            headerRow3
        }
    }

    // MARK: Row 1 -- identity + report/export menus

    private var headerRow1: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(stat?.displayName ?? target).font(.title2).bold()
                    if stat?.isWideField == true {
                        Text("wide-field")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                    if let phase = projectState?.phase {
                        PhaseChip(phase: phase, bold: false, backgroundOpacity: 0.2)
                    }
                }
                if let stat, stat.displayName != stat.target {
                    Text(stat.target).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu("Riport…") {
                Button("Célpont-riport készítése") { appState.exportTargetReport(target: target) }
                if let latestSessionDate {
                    Button("Éjszaka-riport a legutóbbi sessionről") {
                        appState.exportNightReport(target: target, date: latestSessionDate)
                    }
                }
            }
            Menu("Exportálás…") {
                Button("AstroBin CSV") { appState.exportAcquisition(target: target, format: .astrobin) }
                Button("CSV") { appState.exportAcquisition(target: target, format: .csv) }
                Button("Markdown") { appState.exportAcquisition(target: target, format: .md) }
            }
            // R11-T3/F20: manual wide-field/deep-sky override, right next to
            // the "wide-field" badge it controls (line above) -- shared with
            // `AllTargetsPage`'s target row menu.
            WideFieldClassificationMenu(target: target)
        }
    }

    // MARK: Row 2 -- 5 headline tiles

    private var headerRow2: some View {
        HStack(spacing: 12) {
            StatTile(
                title: "Valós integráció",
                value: TDFormat.tile(stat.map { TDFormat.hm($0.usableIntegrationSeconds) }),
                caption: stat.map { "bruttó \(TDFormat.hm($0.grossIntegrationSeconds))" },
                compact: true,
                tintsBackground: false
            )
            goalTile
            StatTile(
                title: "Hiányzik",
                value: missingValueText,
                color: (projectState?.missingSeconds ?? 0) > 0 ? .orange : .primary,
                compact: true,
                tintsBackground: false
            )
            StatTile(
                title: "Sessionök",
                value: "\(stat?.sessionDates.count ?? 0)",
                caption: sessionSpanCaption,
                compact: true,
                tintsBackground: false
            )
            StatTile(
                title: "Legjobb session",
                value: TDFormat.tile(bestSession?.date),
                caption: bestSession.flatMap { summary in
                    summary.medianFWHMArcsec.map { String(format: "FWHM %.2f\"", $0) }
                },
                compact: true,
                tintsBackground: false
            )
        }
    }

    private var missingValueText: String {
        guard let missing = projectState?.missingSeconds else { return TDFormat.missingTile }
        return TDFormat.hm(missing)
    }

    private var sessionSpanCaption: String? {
        guard let stat, let first = stat.sessionDates.first, let last = stat.sessionDates.last else { return nil }
        return first == last ? first : "\(first) → \(last)"
    }

    /// R10-B7: the pencil/"Nincs cél" button now presents the app's single
    /// `GoalEditSheet` (via `goalEditingTarget`) instead of a private
    /// `popover`-based editor -- same sheet `TonightPage`'s plan table and
    /// `AllTargetsPage`'s context menu already use, defaulting to 10h same
    /// as those call sites' own "no goal yet" default.
    private var goalTile: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cél").font(.caption).foregroundStyle(.secondary)
            if let goalSeconds = projectState?.goalSeconds {
                HStack(spacing: 4) {
                    Text(TDFormat.hm(goalSeconds)).font(.title3).bold()
                    Button {
                        goalEditingTarget = GoalEditingTarget(target: target, currentHours: goalSeconds / 3600.0)
                    } label: {
                        Image(systemName: "pencil.circle").font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    goalEditingTarget = GoalEditingTarget(target: target, currentHours: 10)
                } label: {
                    Text("Nincs cél · Beállítás").font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    // MARK: Row 3 -- next step

    private struct NextStep {
        let text: String
        let actionLabel: String?
        let action: (() -> Void)?
    }

    private var nextStep: NextStep? {
        guard let projectState, let first = projectState.todos.first else { return nil }

        if first.hasPrefix("készíts stacket:"), let date = first.split(separator: "/").last.map(String.init) {
            return NextStep(text: first, actionLabel: "Stackelés előkészítése…") {
                stackListingSession = LinkingSession(target: target, date: date)
            }
        }
        if first.hasPrefix("dolgozd fel:") {
            return NextStep(text: first, actionLabel: "Stackek megnyitása") { segment = .stacks }
        }
        // The spec's own example ("flat-hiány → Kalibráció linkelése…") isn't
        // literally one of `ProjectStatusQueries`' todo sentences -- derive
        // it instead from the latest session's actual calibration status
        // (missing flats, or no matched dark at all) whenever THAT'S the
        // most actionable gap, regardless of which todo sentence is first.
        if let latest = sessions.max(by: { $0.dateRaw < $1.dateRaw }),
           let calib = appState.targetSessionCalibrations.first(where: { $0.date == latest.dateRaw }),
           calib.flats.isEmpty || (calib.darks.isEmpty && calib.libraryDark == nil)
        {
            return NextStep(text: first, actionLabel: "Kalibráció linkelése…") {
                linkingSession = LinkingSession(target: target, date: latest.dateRaw)
            }
        }
        return NextStep(text: first, actionLabel: nil, action: nil)
    }

    private var remainingTodosCount: Int {
        max(0, (projectState?.todos.count ?? 0) - 1)
    }

    /// R11-T2: card-style background (a faint tint of the header's own
    /// `PhaseChip` color) so this row reads as the page's action-driving
    /// focus instead of blending into the plain header background the way
    /// every other row here does -- it was the one row on this page whose
    /// content (a next-step sentence + action button) is genuinely more
    /// important than a tile or a phase chip, yet visually weighed the
    /// least.
    private var headerRow3: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let nextStep {
                HStack {
                    Text("Következő lépés:").bold()
                    Text(nextStep.text)
                    if let actionLabel = nextStep.actionLabel, let action = nextStep.action {
                        Button(actionLabel, action: action)
                            .buttonStyle(.link)
                    }
                    Spacer()
                }
                .font(.callout)
            } else {
                Text("Következő lépés: nincs teendő.").font(.callout).foregroundStyle(.secondary)
            }

            if remainingTodosCount > 0 {
                DisclosureGroup("További \(remainingTodosCount) teendő", isExpanded: $todosExpanded) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array((projectState?.todos.dropFirst() ?? []).enumerated()), id: \.offset) { _, todo in
                            Text("•  \(todo)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(phaseColor(projectState?.phase).opacity(0.1)))
    }
}
