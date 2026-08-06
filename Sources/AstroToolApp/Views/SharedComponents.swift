import AstroCore
import SwiftUI

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
func phaseLabel(_ phase: ProjectPhase?, unknown: String = "-") -> String {
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
