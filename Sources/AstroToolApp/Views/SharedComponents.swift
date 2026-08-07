import AstroCore
import SwiftUI

// MARK: - Action column width (R11-T1)

/// Every table's trailing "⋯" row-actions column (`TonightPage`'s `planTable`
/// and `calendarTable`, `AllTargetsPage`, `CalibrationPage`, `DiscoveryPage`,
/// `NightsPage`, `SessionsSegment`, `QualitySegment`, `StacksSegment`) used to
/// each hardcode their own `.width(36)` -- one shared constant so the width
/// can never quietly drift apart table-to-table again.
let actionColumnWidth: CGFloat = 28

// MARK: - Error advice (R11-T1)

/// A one-sentence Hungarian "Mit tehetsz: …" follow-up for the common
/// `AstroError` cases -- separate from `describeSettingsError` (which just
/// translates the error itself into Hungarian for the Settings tabs'
/// inline error text): this is the actionable NEXT STEP, shown only in
/// `AppState`'s activity-log popover entries (`MainShellView
/// .ActivityLogPopover`) alongside that short message, never in the toast
/// (kept short on purpose, see `AppState.endOperation`) nor in any of this
/// app's other plain `lastError`/`describeSettingsError` displays. `nil`
/// for cases whose message already says what to fix (`invalidInput`'s
/// associated reason IS the actionable text).
func errorAdvice(for error: AstroError) -> String? {
    switch error {
    case .sirilNotFound:
        return "Ellenőrizd a Siril útvonalát a Beállítások ▸ Pontozás fülön."
    case .accessDenied:
        return "Rendszerbeállítások ▸ Adatvédelem és biztonság ▸ Teljes lemezhozzáférés alatt engedélyezd az alkalmazást, majd indítsd újra."
    case .volumeNotMounted:
        return "Csatlakoztasd a kötetet a Finderben -- az app automatikusan folytatja, mihelyt megjelenik."
    case .writeForbidden:
        return "Ellenőrizd a célmappa írási jogosultságát (Finder ▸ Adatok megjelenítése ▸ Megosztás és engedélyek)."
    case .pathNotFound:
        return "Ellenőrizd, hogy az útvonal létezik-e, és nem mozgatták/törölték-e időközben."
    case .corruptFITS:
        return "A fájl a könyvtárban marad, az app nem törli -- nyisd meg egy másik eszközzel a sérülés ellenőrzéséhez."
    case .databaseError:
        return "Indítsd újra az alkalmazást; ha a hiba ismétlődik, futtass egy új beolvasást a helyi adatbázis frissítéséhez."
    case .invalidInput:
        return nil
    }
}

// MARK: - Stat tile (R10-B7)

/// Shared headline stat tile -- unifies what were eight near-identical
/// private per-page types/functions (`AuditPage.StatTile`,
/// `CalibrationPage.CalibStatTile`, `AllTargetsPage.AllTargetsStatTile`,
/// `NightsPage.NightsStatTile`, `SensorPage.SensorStatTile`,
/// `TonightPage.tile()`, `DiscoveryPage.tile()`, `TargetDetailPage.tile()`)
/// into one component, single source of truth for the look.
///
/// Two visual sizes existed in practice, kept here (rather than collapsed
/// into one look) since neither reads as an accident:
/// - the bigger `.title2` headline-dashboard tile (Audit/Calibration/
///   AllTargets/Nights/Sensor -- the majority, so it's this type's default,
///   `compact: false`);
/// - the smaller `.title3` compact info tile (Tonight/Discovery/
///   TargetDetail), opted into via `compact: true`.
///
/// `color` drives the value text's tint always, and (only when
/// `tintsBackground` is true, the default) the tile's own background tint
/// too -- `nil` (the default) renders "the neutral secondary style": value
/// text at its normal primary weight, background tinted a plain secondary
/// gray. `TargetDetailPage`'s tiles never tint their background (even the
/// "Hiányzik" tile's orange-when-overdue value color), so those call sites
/// pass `tintsBackground: false` to keep that pixel-equivalent.
struct StatTile: View {
    let title: String
    let value: String
    var color: Color? = nil
    var caption: String? = nil
    var compact: Bool = false
    var tintsBackground: Bool = true

    private var backgroundTintColor: Color {
        tintsBackground ? (color ?? .secondary) : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(compact ? .title3 : .title2)
                .bold()
                .foregroundStyle(color ?? .primary)
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(backgroundTintColor.opacity(compact ? 0.08 : 0.12)))
    }
}

// MARK: - Phase color/label/chip (R10-B7)

/// `ProjectPhase`'s color -- shared across the sidebar's phase dots and
/// every phase chip (unifies duplicated copies from `SidebarView`,
/// `TonightPage`, `AllTargetsPage`, `TargetDetailPage`). `nil` (no
/// `ProjectState` computed yet for the target) renders gray.
func phaseColor(_ phase: ProjectPhase?) -> Color {
    switch phase {
    case .collecting: return .blue
    case .readyToStack: return .yellow
    case .stacked: return .orange
    case .done: return .green
    case nil: return .gray
    }
}

/// `ProjectPhase`'s Hungarian label. `unknown` is the text for a `nil`
/// phase -- "-" (the majority convention: `TonightPage`'s/
/// `AllTargetsPage`'s compact table-chip wording) by default; pass
/// `unknown: "ismeretlen állapot"` for a fuller-sentence context like
/// `SidebarView`'s row tooltip.
func phaseLabel(_ phase: ProjectPhase?, unknown: String = TDFormat.missingCell) -> String {
    switch phase {
    case .collecting: return "gyűjtés"
    case .readyToStack: return "stackelhető"
    case .stacked: return "feldolgozásra vár"
    case .done: return "kész"
    case nil: return unknown
    }
}

/// Shared phase chip -- unifies `TonightPage`'s/`AllTargetsPage`'s identical
/// bold/0.15-opacity chip and `TargetDetailPage`'s slightly different
/// (non-bold, 0.2-opacity) header chip; the two call sites that differ pass
/// `bold`/`backgroundOpacity` explicitly to stay pixel-equivalent per surface.
struct PhaseChip: View {
    let phase: ProjectPhase?
    var bold: Bool = true
    var backgroundOpacity: Double = 0.15

    var body: some View {
        Text(phaseLabel(phase))
            .font(bold ? .caption.bold() : .caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(phaseColor(phase).opacity(backgroundOpacity), in: Capsule())
            .foregroundStyle(phaseColor(phase))
    }
}

// MARK: - Session action menu (R11-T2)

/// The full session-row action set -- ONE builder shared by `NightsPage`,
/// `AllTargetsPage`'s session rows, and `SessionsSegment`, so the three
/// surfaces' action sets can never quietly drift apart again. Before this,
/// each page hand-rolled its own subset: `NightsPage` had no "Kalibráció
/// linkelése…"/"Stackelés előkészítése…"/"Keretek pontozása"/tag items at
/// all, `AllTargetsPage`'s session rows had no "Célpont megnyitása", and
/// `SessionsSegment`'s session rows had no tag add/remove. Used identically
/// by both a table's visible "⋯" `Menu` column and its row's
/// `.contextMenu(forSelectionType:)` -- exactly the "same content, two call
/// sites" shape those tables' target/plan-row menus already establish.
///
/// `showOpenTarget` gates "Célpont megnyitása" -- shown everywhere EXCEPT
/// `SessionsSegment` (that segment IS the target's own page already); when
/// shown, it preselects the Sessionök segment with this exact date before
/// navigating, the same `pendingTargetSegment`/`pendingSessionSelection`
/// hand-off `NightsPage`'s row primary-action already established.
///
/// `onRateFrames` is the one deliberate behavioral difference this action
/// still carries rather than being forced uniform: `SessionsSegment` runs
/// `AppState.runRate` right in place (there's a Minőség segment one tab
/// over to see the result in), while `NightsPage`/`AllTargetsPage` have no
/// frame table of their own -- their default (`nil`) navigates to the
/// target's Minőség segment with this date preselected instead.
struct SessionActionMenu: View {
    @Environment(AppState.self) private var appState

    let target: String
    let date: String
    let tags: [String]
    var showOpenTarget: Bool = true
    var onRateFrames: (() -> Void)?

    @Binding var linkingSession: LinkingSession?
    @Binding var stackListingSession: LinkingSession?
    @Binding var noteEditingSession: LinkingSession?
    @Binding var addingTag: AddTagTarget?

    var body: some View {
        // Split into two `Group`s -- a plain `@ViewBuilder` block (unlike
        // `TableColumnBuilder`, which the R10-B7 comments elsewhere in this
        // file call out by name) still only has `buildBlock` overloads up
        // to 10 children; this menu's full action set is 12 statements, so
        // one `Group` alone won't type-check.
        Group {
            if showOpenTarget {
                Button("Célpont megnyitása") {
                    appState.pendingTargetSegment = .sessions
                    appState.pendingSessionSelection = date
                    appState.currentPage = .target(target)
                }
            }
            Button("Megnyitás Finderben") { appState.revealPathInFinder("sessions/\(target)/\(date)") }
            Divider()
            Button("Kalibráció linkelése…") { linkingSession = LinkingSession(target: target, date: date) }
            Button("Stackelés előkészítése…") { stackListingSession = LinkingSession(target: target, date: date) }
            Divider()
            Button("Keretek pontozása") {
                if let onRateFrames {
                    onRateFrames()
                } else {
                    appState.pendingQualityDate = date
                    appState.pendingTargetSegment = .quality
                    appState.currentPage = .target(target)
                }
            }
            Button("Éjszaka-riport készítése") { appState.exportNightReport(target: target, date: date) }
            Button("Éjszaka-jegyzet szerkesztése…") { noteEditingSession = LinkingSession(target: target, date: date) }
        }
        Group {
            Divider()
            Button("Címke hozzáadása…") { addingTag = AddTagTarget(target: target, date: date) }
            if !tags.isEmpty {
                Menu("Címke eltávolítása") {
                    ForEach(tags, id: \.self) { tag in
                        Button(tag) { appState.removeTag(target: target, date: date, tag: tag) }
                    }
                }
            }
        }
    }
}

// MARK: - Verdict chip (R10 review)

/// Shared "tonight verdict" chip -- unifies three near-identical copies
/// (`TonightPage.planTable`'s `verdictChip`/`verdictColor`,
/// `DiscoveryPage.table`'s identical pair, and `OverviewSegment`'s own
/// "Láthatóság ma este" card, which only ever distinguished green/"ma jó"
/// from gray/everything-else -- Hold-zavar and alacsony/nem-látszik verdicts
/// there rendered the same flat gray as "nincs koordináta"). Every verdict
/// string this is ever handed comes from `NightSweep`'s fixed vocabulary
/// (`Planner.plan`/`DiscoveryPlanner.discover` both route through it): "ma
/// jó", "Hold zavar (…°, …%)", "alacsony (max …°)", "nem látszik ma éjjel",
/// "nincs koordináta" -- matched by prefix rather than full equality for the
/// two that carry a parenthetical, so a changed number inside it still
/// colors correctly.
///
/// R11-T1: also the "SessionsSegment Hűtés/Fókusz columns" now route through
/// this same chip, rather than a bespoke colored-text-only cell -- so the
/// dictionary below also covers `NightHealth`'s cooler/focus vocabulary
/// ("stabil" / "stabil fókusz", "hűtő nem tartja a célhőmérsékletet (…)",
/// "fókuszcsúszás gyanú (…)", "javuló FWHM (lehűlés/seeing) (…)", "n/a — …").
struct VerdictChip: View {
    let verdict: String

    var body: some View {
        Text(verdict)
            .font(.caption.bold())
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Self.color(for: verdict).opacity(0.15), in: Capsule())
            .foregroundStyle(Self.color(for: verdict))
    }

    static func color(for verdict: String) -> Color {
        if verdict == "ma jó" { return .green }
        if verdict.hasPrefix("Hold zavar") { return .yellow }
        if verdict.hasPrefix("alacsony") || verdict == "nem látszik ma éjjel" { return .orange }
        // R11-T1: `NightHealth` cooler/focus verdicts (`SessionsSegment`'s
        // Hűtés/Fókusz columns) -- "stabil" also matches "stabil fókusz"'s
        // prefix, so one check covers both.
        if verdict.hasPrefix("stabil") { return .green }
        if verdict.contains("nem tartja") || verdict.contains("gyanú") { return .orange }
        return .gray // "nincs koordináta" / üstökös / "n/a — …" / "javuló FWHM …"
    }
}
