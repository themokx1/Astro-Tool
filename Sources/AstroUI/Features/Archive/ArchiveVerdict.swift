import AstroApplication
import Foundation
import SwiftUI

// MARK: - ArchiveVerdict

/// The second line under the verdict: what is at stake, in facts the view
/// turns into a sentence. Separate from `ArchiveVerdict.Headline` because
/// these two answer different questions -- "do I have to do something?" and
/// "how much is it worth, and can I trust what I am being told?" -- and only
/// the headline is ever allowed to sound alarming.
struct ArchiveVerdictDetail: Equatable {
    /// Three states, not a boolean. A verify pass either found corruption,
    /// found none, or never ran at all -- and the real 612 GB reference
    /// library has never had a `verify`-kind run, which makes
    /// `.neverVerified` the branch an actual owner will see. Collapsing this
    /// to "no corruption found" would assert something about data the app
    /// never read: the exact "0 issues" overclaim this redesign exists to
    /// remove (the old Health page's "0 calibration issues").
    enum IntegrityState: Equatable {
        /// A verify pass has run and found corruption.
        case corruptionFound
        /// A verify pass has run and found none.
        case verifiedClean
        /// No verify pass has ever run -- the app knows nothing about this
        /// library's integrity and must not imply otherwise.
        case neverVerified
    }

    let integrityState: IntegrityState
    /// Only meaningful when `integrityState == .corruptionFound` -- the
    /// corruption task's own affected-file count, carried here so the view
    /// never re-derives it from `tasks` a second time.
    let corruptionFileCount: Int
    let reclaimableBytes: Int64
    /// The display name of the row holding the most reclaimable bytes, when
    /// any row does. `nil` both when nothing is reclaimable AND when the
    /// worst row is the untargeted bucket (which has no catalog name of its
    /// own, by design -- see `ArchiveTargetRow.displayName`'s own doc
    /// comment): the view then prints only the total, never a fabricated
    /// name.
    let worstTargetName: String?
    let worstTargetBytes: Int64
}

/// The one sentence at the top of the Archive page. Pure, exhaustive, and
/// tested branch-by-branch (`ArchiveVerdictTests`): this is the sentence a
/// user can read and then close the app on, so it is built exactly once from
/// already-loaded store state and never assembled ad hoc inside a view body.
struct ArchiveVerdict: Equatable {
    enum Headline: Equatable {
        case neverChecked
        case stale
        case allClear
        case oneTask
        case manyTasks(Int)
    }

    let headline: Headline
    let detail: ArchiveVerdictDetail

    init(tasks: [ArchiveTask], snapshot: ArchiveMapSnapshot) {
        // Order matters: "never checked" outranks everything else, because
        // every other headline would be claiming knowledge about findings
        // the app does not have (there is no audit run to have found them).
        if snapshot.lastAuditAt == nil {
            headline = .neverChecked
        } else if snapshot.isAuditStale {
            headline = .stale
        } else if tasks.isEmpty {
            headline = .allClear
        } else if tasks.count == 1 {
            headline = .oneTask
        } else {
            headline = .manyTasks(tasks.count)
        }

        let corruptionTask = tasks.first { $0.kind == .corruption }
        let integrityState: ArchiveVerdictDetail.IntegrityState = if corruptionTask != nil {
            .corruptionFound
        } else if snapshot.lastVerifyAt != nil {
            .verifiedClean
        } else {
            .neverVerified
        }

        // The worst row is picked only among rows that actually hold
        // reclaimable bytes -- a max() over an all-zero collection would
        // otherwise "win" with a meaningless zero-byte row.
        let worstRow = snapshot.rows
            .filter { $0.reclaimableBytes > 0 }
            .max { $0.reclaimableBytes < $1.reclaimableBytes }
        // A `nil` name (the untargeted bucket has none, by design -- see
        // `ArchiveTargetRow.displayName`'s own doc comment) means there is
        // nothing honest to attribute the clause to, so the byte figure is
        // dropped along with the name rather than printed unattributed.
        let worstName = worstRow?.displayName

        detail = ArchiveVerdictDetail(
            integrityState: integrityState,
            corruptionFileCount: corruptionTask?.affectedFileCount ?? 0,
            reclaimableBytes: snapshot.reclaimableBytes,
            worstTargetName: worstName,
            worstTargetBytes: worstName != nil ? (worstRow?.reclaimableBytes ?? 0) : 0
        )
    }
}

/// Renders `ArchiveVerdict` as two lines of text. Every property below is a
/// trivial switch over already-computed data -- no query, no loop over the
/// library's rows -- the same "trivial" bar `ArchiveTaskCard`'s own
/// `title`/`explanation`/`actionTitle` computed properties already set.
struct ArchiveVerdictHeader: View {
    let verdict: ArchiveVerdict

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.system(.largeTitle, weight: .semibold))
                .accessibilityIdentifier("v2.archive.verdict.headline")
            detailText
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("v2.archive.verdict.detail")
        }
    }

    private var headline: LocalizedStringKey {
        switch verdict.headline {
        case .neverChecked: "I have not looked through this library yet."
        case .stale: "The last check is older than your most recent scan."
        case .allClear: "Nothing needs you right now."
        case .oneTask: "One thing needs you."
        case .manyTasks(let count): "\(count) things need you."
        }
    }

    private var integrityText: LocalizedStringKey {
        switch verdict.detail.integrityState {
        case .corruptionFound:
            "\(verdict.detail.corruptionFileCount) file(s) changed content since the last check."
        case .verifiedClean:
            "Nothing has been corrupted since the last check."
        case .neverVerified:
            "I have not checked this library's integrity yet."
        }
    }

    @ViewBuilder
    private var detailText: some View {
        if verdict.detail.reclaimableBytes > 0 {
            Text(integrityText) + Text(verbatim: " ") + reclaimText
        } else {
            Text(integrityText)
        }
    }

    private var reclaimText: Text {
        // Named `reclaimAmountText`, not `total`: a bare `total` collides
        // with `OperationHost.ActiveOperation.total: Int64?` in this
        // extraction script's own (deliberately best-effort, whole-codebase,
        // not per-scope) property-type index, which would otherwise infer
        // `%lld` for what is actually a pre-formatted `String` here and
        // produce a translation key that never matches at runtime.
        let reclaimAmountText = ByteCountFormatter.string(fromByteCount: verdict.detail.reclaimableBytes, countStyle: .file)
        if let name = verdict.detail.worstTargetName, verdict.detail.worstTargetBytes > 0 {
            let worstAmountText = ByteCountFormatter.string(fromByteCount: verdict.detail.worstTargetBytes, countStyle: .file)
            return Text("\(reclaimAmountText) can be reclaimed — \(worstAmountText) of it in \(name).")
        }
        return Text("\(reclaimAmountText) can be reclaimed.")
    }
}
