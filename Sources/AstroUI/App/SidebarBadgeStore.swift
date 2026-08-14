import AstroApplication
import Foundation
import Observation

/// Backs the sidebar's two numeric `.badge()` counts (Wave 3 Task 7):
/// "Nights" (how many nights still need a decision -- excluded frames or no
/// usable frames at all) and "Library" (a single combined count of
/// unacknowledged health findings needing attention, which already includes
/// calibration gaps -- `LibraryHealthQuery`'s flat/dark-missing items are
/// `.warning`-severity items like any other finding, so counting every
/// non-`.healthy` item is already the "audit findings + calibration gaps"
/// combined number, not a double-count of the two).
///
/// Deliberately simple, per the plan's own "keep it simple" note: no
/// incremental diffing, no live subscription -- just `refresh(rootURL:
/// nights:)`, called by `V2RootView` on library open and again after a
/// rescan/audit operation completes.
@MainActor
@Observable
public final class SidebarBadgeStore {
    public typealias HealthQueryFactory = @Sendable (URL) throws -> LibraryHealthQuery

    public private(set) var nightsNeedingAttention = 0
    public private(set) var libraryAttentionCount = 0

    private let healthQueryFactory: HealthQueryFactory

    public init(
        healthQueryFactory: @escaping HealthQueryFactory = { rootURL in try LibraryHealthQuery.production(rootURL: rootURL) }
    ) {
        self.healthQueryFactory = healthQueryFactory
    }

    /// `nights` is every known night (NOT a UI-filtered subset like
    /// `NightsStore.visibleNights`, which respects a transient month
    /// picker) -- the sidebar badge always reflects the whole library.
    public func refresh(rootURL: URL, nights: [NightRow]) async {
        nightsNeedingAttention = nights.filter { $0.triageState != .ready }.count
        do {
            let snapshot = try await healthQueryFactory(rootURL).snapshot()
            libraryAttentionCount = snapshot.items.filter { $0.severity != .healthy }.count
        } catch {
            libraryAttentionCount = 0
        }
    }
}
