import AstroApplication
import Foundation
import Observation

/// Backs the sidebar's two numeric `.badge()` counts (Wave 3 Task 7):
/// "Nights" (how many nights still need a decision -- excluded frames or no
/// usable frames at all) and "Library" (the total affected-file count across
/// the Archive page's own "Needs you" cards).
///
/// W4-7 item 2 (owner report): the badge used to count
/// `LibraryHealthQuery.snapshot().items` -- a DIFFERENT query than the one
/// the Archive page's cards render (`ArchiveTaskQuery.summary()`), so the
/// sidebar said 364 while the visible cards summed to something else and
/// the number could not be derived from anything on screen. The badge now
/// reads the exact same summary the cards do: add up the numbers on the
/// cards and you get the badge.
///
/// Deliberately simple, per the plan's own "keep it simple" note: no
/// incremental diffing, no live subscription -- just `refresh(rootURL:
/// nights:)`, called by `V2RootView` on library open and again after a
/// rescan/audit operation completes.
@MainActor
@Observable
public final class SidebarBadgeStore {
    public typealias TaskSummaryFactory = @Sendable (URL) async throws -> ArchiveTaskSummary

    public private(set) var nightsNeedingAttention = 0
    public private(set) var libraryAttentionCount = 0

    private let taskSummaryFactory: TaskSummaryFactory

    public init(
        taskSummaryFactory: @escaping TaskSummaryFactory = { rootURL in
            try await ArchiveTaskQuery.production(rootURL: rootURL).summary()
        }
    ) {
        self.taskSummaryFactory = taskSummaryFactory
    }

    /// `nights` is every known night (NOT a UI-filtered subset like
    /// `NightsStore.visibleNights`, which respects a transient month
    /// picker) -- the sidebar badge always reflects the whole library.
    public func refresh(rootURL: URL, nights: [NightRow]) async {
        nightsNeedingAttention = nights.filter { $0.triageState != .ready }.count
        do {
            let summary = try await taskSummaryFactory(rootURL)
            libraryAttentionCount = summary.tasks.reduce(0) { $0 + $1.affectedFileCount }
        } catch {
            libraryAttentionCount = 0
        }
    }
}
