import AstroCore
import Foundation

/// Pre-flight Checklist ("Indulás előtti lista", ideation #1, usefulness
/// 5/5): one collapsible strip on V2 Home synthesizing four facts
/// `HomeStore` already computes into a ✓/✗ ritual before the owner drags
/// gear outside:
///
/// 1. Darks/flats current -- no `CalibShoppingList.build` items left.
/// 2. Sky clear tonight -- `HomeSnapshot.NightCloud.isCloudyTonight`, the
///    same `ClearNightOutlook.cloudyThresholdPercent` gate.
/// 3. Moon impact tonight -- the tonight-list's own TOP recommendation's
///    `SkyVerdictKind` (already computed by `Planner.plan`, never
///    re-derived here).
/// 4. When that same top recommendation clears the imaging altitude
///    threshold -- read straight off its own already-rendered
///    `visibleWindow` string ("HH:mm–HH:mm"), never a new sweep.
///
/// `build(...)` performs NO query of its own -- every input is a value
/// `HomeStore.configure` already resolved onto `HomeSnapshot` -- the same
/// "extract the pure decision, test it directly" shape
/// `HomeStore.cloudOutlook`/`HomeStore.composeHighlights` already use.
/// Lives in `AstroApplication` (not `AstroUI`, where `HomeSnapshot` itself
/// lives) so its inputs are plain values/`SkyVerdictKind` (an `AstroCore`
/// type both modules already share) rather than `AstroUI`'s own
/// `HomeSnapshot`, which `AstroApplication` cannot depend on.
public struct PreflightChecklist: Equatable, Sendable {
    /// Three honest outcomes per item -- never a bare `Bool`, because
    /// "nothing to say yet" (no weather fetched, no tonight plan) is a
    /// genuinely different state from "checked, and it's a problem": a
    /// missing input must never be presented as a red ✗.
    public enum Status: Equatable, Sendable {
        /// The fact is known, and it is good.
        case ready
        /// The fact is known, and it is exactly what should give the
        /// owner pause before heading out tonight.
        case attention
        /// The input this item needs was never loaded (no weather fetch,
        /// no tonight plan) -- there is nothing wrong, just nothing
        /// honest to report yet.
        case notApplicable
    }

    /// One ritual line. `kind` carries both which of the four checks this
    /// is AND whatever numbers its own copy needs (the same
    /// `HomeSnapshot.Highlight.Kind` split: a domain payload, no display
    /// string of its own -- `HomeView` composes the actual `Text(_:)`).
    public struct Item: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            /// Item 1: `missingCount` is `CalibShoppingList.build`'s own
            /// item count -- `0` means darks/flats are current.
            case calibrationCurrent(missingCount: Int)
            /// Item 2: tonight's own dusk-to-dawn cloud picture. Carries
            /// no numbers of its own -- `HomeSnapshot.NightCloud`'s dusk/
            /// dawn percents are already shown on the night-context rail
            /// right above this card; this line only needs the verdict.
            case skyClear
            /// Item 3: the top tonight recommendation's own Moon numbers,
            /// present only when `status == .attention` (a `.goodTonight`
            /// verdict carries no separation/illumination to show).
            case moonImpact(separationDeg: Double?, illuminationPercent: Double?)
            /// Item 4: the top tonight recommendation's own display name
            /// and the local time its `visibleWindow` starts at -- both
            /// `nil` exactly when `status == .notApplicable`.
            case altitudeWindow(targetDisplayName: String?, clearsAtLocal: String?)
        }

        public let kind: Kind
        public let status: Status

        public init(kind: Kind, status: Status) {
            self.kind = kind
            self.status = status
        }

        public var id: String {
            switch kind {
            case .calibrationCurrent: "calibration"
            case .skyClear: "sky"
            case .moonImpact: "moon"
            case .altitudeWindow: "altitude"
            }
        }
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    /// `true` whenever nothing is a red ✗ -- an item that is honestly
    /// `.notApplicable` never blocks this on its own, the same way a
    /// missing weather fetch shouldn't read as "something's wrong".
    public var allClear: Bool {
        items.allSatisfy { $0.status != .attention }
    }

    /// What the expanded card actually renders once `allClear` is
    /// `false`: every `.attention` line first (in their own original
    /// order), then everything else -- "any red -> expanded with the
    /// failing lines first" from this feature's own spec.
    public var displayOrder: [Item] {
        items.filter { $0.status == .attention } + items.filter { $0.status != .attention }
    }

    /// One tonight recommendation's own already-computed facts -- exactly
    /// the fields `HomeTonightRecommendation` (`AstroUI`) already carries
    /// for its FIRST (best-ranked) row, handed down here as plain values
    /// rather than that `AstroUI`-only type.
    public struct TopRecommendation: Equatable, Sendable {
        public let displayName: String
        public let visibleWindow: String?
        public let verdict: SkyVerdictKind

        public init(displayName: String, visibleWindow: String?, verdict: SkyVerdictKind) {
            self.displayName = displayName
            self.visibleWindow = visibleWindow
            self.verdict = verdict
        }
    }

    /// The one composition point. `isCloudyTonight` is `nil` exactly when
    /// `HomeSnapshot.nightCloud` itself is `nil` (weather off, no site, or
    /// the fetch hasn't landed/failed) -- `HomeSnapshot.NightCloud
    /// .isCloudyTonight` otherwise. `topRecommendation` is `nil` exactly
    /// when `HomeSnapshot.tonightRecommendations` is empty.
    public static func build(
        calibrationMissingCount: Int,
        isCloudyTonight: Bool?,
        topRecommendation: TopRecommendation?
    ) -> PreflightChecklist {
        let calibrationItem = Item(
            kind: .calibrationCurrent(missingCount: calibrationMissingCount),
            status: calibrationMissingCount > 0 ? .attention : .ready
        )

        let skyStatus: Status = switch isCloudyTonight {
        case nil: .notApplicable
        case true?: .attention
        case false?: .ready
        }
        let skyItem = Item(kind: .skyClear, status: skyStatus)

        let moonStatus: Status
        let moonSeparationDeg: Double?
        let moonIlluminationPercent: Double?
        switch topRecommendation?.verdict {
        case .goodTonight:
            moonStatus = .ready
            moonSeparationDeg = nil
            moonIlluminationPercent = nil
        case let .moonInterferes(separationDeg, illuminationPercent):
            moonStatus = .attention
            moonSeparationDeg = separationDeg
            moonIlluminationPercent = illuminationPercent
        default:
            // `nil` (no tonight recommendation at all) or any other verdict
            // kind this app's own `isShootableTonight` filter would already
            // have excluded from `tonightRecommendations` -- an honest "we
            // can't say" rather than guessing at a classification the
            // engine never actually made for this row.
            moonStatus = .notApplicable
            moonSeparationDeg = nil
            moonIlluminationPercent = nil
        }
        let moonItem = Item(
            kind: .moonImpact(separationDeg: moonSeparationDeg, illuminationPercent: moonIlluminationPercent),
            status: moonStatus
        )

        let altitudeItem: Item
        if let topRecommendation, let clearsAtLocal = Self.windowStart(topRecommendation.visibleWindow) {
            altitudeItem = Item(
                kind: .altitudeWindow(targetDisplayName: topRecommendation.displayName, clearsAtLocal: clearsAtLocal),
                status: .ready
            )
        } else {
            altitudeItem = Item(kind: .altitudeWindow(targetDisplayName: nil, clearsAtLocal: nil), status: .notApplicable)
        }

        return PreflightChecklist(items: [calibrationItem, skyItem, moonItem, altitudeItem])
    }

    /// The local start time already embedded in a `"HH:mm–HH:mm"`
    /// `visibleWindow` string -- the exact instant `NightSweep.sweep`
    /// determined the target first cleared the imaging altitude threshold
    /// tonight (`Planner.plan`'s own `minAltitudeDeg`, this app's one fixed
    /// 30° value -- see `NightWorkspaceView`'s own "Below 30°" tile for the
    /// same fixed number). Splits on the same en dash
    /// `NightSweep.visibleWindowLocal` itself joins with -- the identical
    /// technique `PlanningCulminationDisplay.derive` already uses on this
    /// same string shape. `nil` for a missing or malformed window (never
    /// swept, or an empty start) -- an honest n/a rather than a guess.
    private static func windowStart(_ visibleWindow: String?) -> String? {
        guard let visibleWindow, let dashRange = visibleWindow.range(of: "–") else { return nil }
        let start = String(visibleWindow[..<dashRange.lowerBound])
        return start.isEmpty ? nil : start
    }
}
