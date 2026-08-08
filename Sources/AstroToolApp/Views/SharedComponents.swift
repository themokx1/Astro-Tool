import AstroCore
import SwiftUI

// MARK: - Action column width (R11-T1)

/// Every table's trailing "⋯" row-actions column (`TonightPage`'s `planTable`
/// and `calendarTable`, `AllTargetsPage`, `CalibrationPage`, `DiscoveryPage`,
/// `NightsPage`, `SessionsSegment`, `QualitySegment`, `StacksSegment`) used to
/// each hardcode their own `.width(36)` -- one shared constant so the width
/// can never quietly drift apart table-to-table again.
let actionColumnWidth: CGFloat = 28

// MARK: - Site chip (R12-U1 item 6)

/// A small, non-interactive "Helyszín: <name>" reminder -- `DiscoveryPage`
/// (which has no site-Picker of its own, unlike `TonightPage`) and
/// `TonightPage`'s Naptár segment (whose own calendar table has no other
/// on-screen confirmation of which site its Sötét/Hold/Felhő columns were
/// computed against, even though the interactive site-Picker up top --
/// shared with "Ma este" -- already lets a user CHANGE it). Both callers
/// only ever show this when `appState.config.sites.count > 1` -- a single
/// (or zero) configured site has nothing to disambiguate.
struct SiteChip: View {
    let name: String

    var body: some View {
        Text("Helyszín: \(name)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

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
///
/// R12-U1 item 5: `setupDescriptor` (`SessionDetail.setupDescriptor`, or a
/// `NightsPage` row's own lookup into `sessionDetailsByTarget` -- see that
/// page's own doc comment) backs "Megnyitás a Trendeken", pre-filtering the
/// Trendek page to this exact session's dominant setup via `AppState
/// .pendingTrendsSetupFilter`. `nil` (the default) just means "no derivable
/// setup for this session" -- the action still navigates, unfiltered.
struct SessionActionMenu: View {
    @Environment(AppState.self) private var appState

    let target: String
    let date: String
    let tags: [String]
    var showOpenTarget: Bool = true
    var onRateFrames: (() -> Void)?
    var setupDescriptor: String? = nil

    @Binding var linkingSession: LinkingSession?
    @Binding var stackListingSession: LinkingSession?
    @Binding var noteEditingSession: LinkingSession?
    @Binding var addingTag: AddTagTarget?

    var body: some View {
        // Split into two `Group`s -- a plain `@ViewBuilder` block (unlike
        // `TableColumnBuilder`, which the R10-B7 comments elsewhere in this
        // file call out by name) still only has `buildBlock` overloads up
        // to 10 children; this menu's full action set is 13 statements, so
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
            // R12-U1 item 5: pre-filters via the same "set, navigate,
            // consume on appear" pending pattern `pendingTargetSegment`
            // already establishes.
            Button("Megnyitás a Trendeken") {
                appState.pendingTrendsSetupFilter = setupDescriptor
                appState.currentPage = .trends
            }
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

// MARK: - Wide-field classification menu (R11-T3/F20)

/// "Besorolás" submenu -- lets `AllTargetsPage`'s target row menu and
/// `TargetDetailPage`'s header override `WideFieldHeuristic`'s automatic
/// wide-field/deep-sky guess for one target, three mutually exclusive
/// options ("Automatikus (felismerés)" / "Wide-field" / "Deep-sky") with a
/// checkmark on whichever is currently in effect -- same "`if current ==
/// option { Image(systemName: "checkmark") }`" convention
/// `DiscoveryPage.kindFilterMenu` already uses for its own Menu. Reads
/// straight off `appState.config.wideField.overrides[target]` (no local
/// `@State` -- there's nothing to draft here, the choice IS the save) and
/// writes through `AppState.setWideFieldOverride(target:value:)`.
struct WideFieldClassificationMenu: View {
    @Environment(AppState.self) private var appState

    let target: String

    private var currentOverride: Bool? { appState.config.wideField.overrides[target] }

    var body: some View {
        Menu("Besorolás") {
            optionButton(title: "Automatikus (felismerés)", value: nil)
            optionButton(title: "Wide-field", value: true)
            optionButton(title: "Deep-sky", value: false)
        }
    }

    private func optionButton(title: String, value: Bool?) -> some View {
        Button {
            appState.setWideFieldOverride(target: target, value: value)
        } label: {
            HStack {
                if currentOverride == value { Image(systemName: "checkmark") }
                Text(title)
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
        // R11-T6/F3: `hasPrefix`, not `==` -- `FilterAdvisor.augmentedVerdict`
        // appends " — Ha-ra"-style filter suggestions onto a plain "ma jó"
        // verdict, which must still read green, not fall through to the
        // catch-all gray below.
        if verdict.hasPrefix("ma jó") { return .green }
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

// MARK: - Verdict explain popover (R11-T12/F11(d))

/// `VerdictChip`, made clickable: a popover spelling out the numbers behind
/// a sky verdict -- max magasság, látható órák, Hold-illum%, Hold-szeparáció
/// -- so "Hold zavar (23°, 87%)" reads as more than an unexplained color.
/// Backs `TonightPage.planTable`'s Döntés column, `OverviewSegment`'s
/// "Láthatóság ma este" card, and `DiscoveryPage.table`'s Döntés column --
/// the three call sites PLAN-R11's own UI-terv names for F11(d), all
/// sourced from `TargetPlan`/`DiscoveryRow` (`NightSweep`/`Planner`/
/// `DiscoveryPlanner`'s shared math).
///
/// Every parameter is optional because not every verdict has every number
/// (a "nincs koordináta" verdict has none of them; `DiscoveryRow` never
/// carries a Moon-illumination value at all, only a separation) -- whenever
/// ALL of them are `nil`, this renders a PLAIN `VerdictChip` instead of a
/// button wrapping an empty popover (spec: "ahol az adat nem elérhető, a
/// chip maradjon sima").
struct VerdictExplainPopover: View {
    let verdict: String
    var maxAltitudeDeg: Double?
    var visibleHours: Double?
    var moonIlluminationPercent: Double?
    var moonSeparationDeg: Double?

    @State private var showPopover = false

    private var hasAnyData: Bool {
        maxAltitudeDeg != nil || visibleHours != nil || moonIlluminationPercent != nil || moonSeparationDeg != nil
    }

    var body: some View {
        if hasAnyData {
            Button {
                showPopover = true
            } label: {
                VerdictChip(verdict: verdict)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPopover) {
                popoverContent
            }
        } else {
            VerdictChip(verdict: verdict)
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Miért ez a döntés?").font(.subheadline).bold()
            VStack(alignment: .leading, spacing: 4) {
                if let maxAltitudeDeg {
                    explainRow("Max. magasság", String(format: "%.0f°", maxAltitudeDeg))
                }
                if let visibleHours {
                    explainRow("Látható", String(format: "%.1f ó", visibleHours))
                }
                if let moonIlluminationPercent {
                    explainRow("Hold megvilágítottsága", "\(Int(moonIlluminationPercent.rounded()))%")
                }
                if let moonSeparationDeg {
                    explainRow("Hold-szeparáció", String(format: "%.0f°", moonSeparationDeg))
                }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 240)
    }

    private func explainRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}

// MARK: - Library percentile dot (R11-T12/F11(e))

/// A small color dot next to a FWHM″/Hatékonyság cell, showing where THIS
/// library's own distribution places the value -- green (best third),
/// yellow (middle third), orange (worst third), per `LibraryPercentiles
/// .evaluate`. Low samples render neutral gray with an explicit count.
/// Renders nothing at all when `result` is `nil` (the row itself has no comparable value -- e.g. a
/// px-fallback-only FWHM never gets a dot, since it was never in the
/// arcsec distribution to begin with).
struct LibraryPercentileDot: View {
    let result: LibraryPercentileResult?
    /// Appended after `medianValue` in the tooltip ("″" or "%").
    let unit: String

    var body: some View {
        if let result {
            Circle()
                .fill(result.isLowSample ? Color.gray : Self.color(for: result.band))
                .frame(width: 7, height: 7)
                .help(Self.tooltipText(result, unit: unit))
        }
    }

    private static func color(for band: PercentileBand) -> Color {
        switch band {
        case .best: return .green
        case .middle: return .yellow
        case .worst: return .orange
        }
    }

    private static func tooltipText(_ result: LibraryPercentileResult, unit: String) -> String {
        if result.isLowSample {
            return "kevés adat (\(result.sampleCount)/\(LibraryPercentiles.minimumSampleSize))"
        }
        let medianText = String(format: "%.1f", result.medianValue) + unit
        let prefix = "A könyvtárad mediánja \(medianText) — ez a session"
        switch result.band {
        case .best:
            let topPercent = max(1, min(33, Int(((1 - result.betterThanFraction) * 100).rounded())))
            return "\(prefix) a jobbik \(topPercent)%-ban van."
        case .middle:
            return "\(prefix) a középmezőnyben van."
        case .worst:
            return "\(prefix) a leggyengébb harmadban van."
        }
    }
}
