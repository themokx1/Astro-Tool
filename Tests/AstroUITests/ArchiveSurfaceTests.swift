@testable import AstroUI
import AstroApplication
import Foundation
import Testing

struct ArchiveStripLayoutTests {
    @Test("Slice fractions sum to one")
    func fractionsSumToOne() {
        let layout = ArchiveStripLayout(slices: [
            .init(archiveClass: .light, fileCount: 1, bytes: 300),
            .init(archiveClass: .stack, fileCount: 1, bytes: 600),
            .init(archiveClass: .calibration, fileCount: 1, bytes: 100),
        ])
        #expect(abs(layout.segments.reduce(0) { $0 + $1.fraction } - 1.0) < 0.0001)
        #expect(layout.segments.map(\.archiveClass) == [.light, .stack, .calibration])
    }

    @Test("Slices under half a percent merge into one residual segment")
    func tinySlicesMerge() {
        let layout = ArchiveStripLayout(slices: [
            .init(archiveClass: .light, fileCount: 1, bytes: 99_800),
            .init(archiveClass: .stack, fileCount: 1, bytes: 100),
            .init(archiveClass: .calibration, fileCount: 1, bytes: 100),
        ])
        #expect(layout.segments.count == 2, "the two 0.1% slices collapse into one residual")
        #expect(layout.segments.last?.isResidual == true)
        #expect(abs(layout.segments.reduce(0) { $0 + $1.fraction } - 1.0) < 0.0001)
    }

    @Test("An empty archive produces no segments and never divides by zero")
    func emptyArchiveHasNoSegments() {
        #expect(ArchiveStripLayout(slices: []).segments.isEmpty)
        #expect(ArchiveStripLayout(slices: [.init(archiveClass: .light, fileCount: 0, bytes: 0)]).segments.isEmpty)
    }
}

/// W4-7 item 1 (owner review): "the archive map's colored strip ... explains
/// nothing on the page". `ArchiveStripView`'s legend renders straight off
/// `ArchiveStripLayout(slices:)` -- the exact same struct `ArchiveStripLayoutTests`
/// above already covers -- so these are source-text checks (this repo's own
/// "surface test" convention, see `ArchiveViewSurfaceTests`'s header) that the
/// legend exists, is wired to the same `layout.segments` the strip itself
/// draws from (never a parallel hardcoded class list), and that the red
/// underline segment is labeled rather than left as an unexplained bar.
struct ArchiveStripLegendSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source() throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/Features/Archive/ArchiveStripView.swift"),
            encoding: .utf8
        )
    }

    @Test("The legend is generated from the same layout.segments the strip itself draws, never a second hardcoded list")
    func legendIsGeneratedFromTheSameSegments() throws {
        let text = try source()
        #expect(text.contains("private var legend:"), "ArchiveStripView must expose a legend under the strip")
        #expect(text.contains("ForEach(Array(layout.segments.enumerated())"), "legend construction must be visible")
        // The legend's own ForEach must be the same `layout.segments` the
        // strip's ForEach above already iterates -- two separate ForEach
        // call sites over the same property, not a second array literal.
        let occurrences = text.components(separatedBy: "ForEach(Array(layout.segments.enumerated())").count - 1
        #expect(occurrences == 2, "expected exactly one ForEach for the strip and one for the legend, both over layout.segments")
        #expect(!text.contains("ArchiveClass.allCases"), "the legend must not build its own class list -- it must only ever show classes actually present in layout.segments")
    }

    @Test("Each legend entry reuses detailText(for:), so its size figure can never drift from the strip's own tooltip")
    func legendReusesDetailText() throws {
        let text = try source()
        #expect(text.contains("detailText(for: segment)"), "the legend row must reuse the strip's own bytes/file-count text, not a re-derived copy")
    }

    @Test("The red underline segment is labeled in the legend, reusing the rail's own reclaim text")
    func reclaimRailIsLabeledInTheLegend() throws {
        let text = try source()
        #expect(text.contains("reclaimLegendEntry"), "the legend must have its own entry for the reclaim rail")
        #expect(text.contains("reclaimHelpText") && text.contains("private var reclaimLegendEntry"),
                "the reclaim legend entry must reuse reclaimHelpText, the same sentence already explaining the rail's tooltip")
    }

    @Test("Every legend entry carries its own accessibility identifier")
    func legendEntriesAreIdentifiable() throws {
        let text = try source()
        #expect(text.contains("\"v2.archive.strip.legend\""))
        #expect(text.contains("v2.archive.strip.legend.reclaimable"))
        #expect(text.contains("v2.archive.strip.legend.\\(identifier)"))
    }

    /// W5-2 finding 1 (owner pixel review): the legend's reclaim entry and
    /// its first chip both rendered with a mid-sentence "…" -- `.lineLimit(1)`
    /// forces a single line no matter how wide the entry's own text actually
    /// is. A legend must never lose information to truncation; entries that
    /// don't fit one line must wrap onto a second line inside their own grid
    /// cell instead.
    @Test("No legend entry caps itself at one line -- truncation in a legend is never acceptable")
    func legendEntriesNeverTruncate() throws {
        let text = try source()
        let legendRange = try #require(text.range(of: "private var legend:"))
        let legendSection = text[legendRange.lowerBound...]
        #expect(!legendSection.contains(".lineLimit(1)"), "a legend entry must wrap, not truncate with an ellipsis")
    }

    @Test("The legend's adaptive column is wide enough for a real entry to fit one line at the page's normal width")
    func legendColumnIsWideEnoughForRealText() throws {
        let text = try source()
        // 168pt was proven too narrow by the owner's own screenshot
        // ("Light frame-ek · 237,74 GB · 4 255 fájl" truncated even before
        // wrapping kicked in); 220pt is the corrected minimum.
        #expect(!text.contains(".adaptive(minimum: 168)"), "168pt was too narrow for real Hungarian entry text")
        #expect(text.contains(".adaptive(minimum: 220)"))
    }
}

/// `ArchiveVerdict` is the one sentence at the top of the Archive page --
/// pure data, built once from already-loaded `ArchiveTask`/`ArchiveMapSnapshot`
/// state, so it is tested branch-by-branch here without rendering anything.
/// Task 9's own prerequisite note: `IntegrityState` is three-state, not a
/// boolean, because "no verify run has ever happened" (the real library's own
/// state) must never be read as "nothing is corrupted" -- that would be an
/// unearned claim about data the app never looked at.
struct ArchiveVerdictTests {
    @Test("The headline has one deterministic branch per library state")
    func verdictHeadlineBranches() {
        #expect(ArchiveVerdict(tasks: [], snapshot: .stub(lastAuditAt: nil)).headline == .neverChecked)
        #expect(ArchiveVerdict(tasks: [], snapshot: .stub()).headline == .allClear)
        #expect(ArchiveVerdict(tasks: [.stub(kind: .intermediateFiles)], snapshot: .stub()).headline == .oneTask)
        #expect(ArchiveVerdict(
            tasks: [.stub(kind: .intermediateFiles), .stub(kind: .duplicateContent)],
            snapshot: .stub()
        ).headline == .manyTasks(2))
        #expect(ArchiveVerdict(
            tasks: [],
            snapshot: .stub(lastScanAt: Date(timeIntervalSince1970: 2000), lastAuditAt: Date(timeIntervalSince1970: 1000))
        ).headline == .stale)
    }

    @Test("'Never checked' outranks every other branch, including a library with no tasks at all")
    func neverCheckedOutranksAllClear() {
        // No audit ever ran AND no tasks -- if this read as `.allClear` it
        // would claim a clean bill of health for a library the app never
        // looked at. `.neverChecked` must win.
        let verdict = ArchiveVerdict(tasks: [], snapshot: .stub(lastAuditAt: nil))
        #expect(verdict.headline == .neverChecked)
    }

    @Test("Integrity state is corruptionFound only when a corruption task is present")
    func integrityStateCorruptionFound() {
        let verdict = ArchiveVerdict(
            tasks: [.stub(kind: .corruption, affectedFileCount: 3)],
            snapshot: .stub(lastVerifyAt: Date(timeIntervalSince1970: 5000))
        )
        #expect(verdict.detail.integrityState == .corruptionFound)
        #expect(verdict.detail.corruptionFileCount == 3)
    }

    @Test("Integrity state is verifiedClean when a verify run happened and found no corruption")
    func integrityStateVerifiedClean() {
        let verdict = ArchiveVerdict(tasks: [], snapshot: .stub(lastVerifyAt: Date(timeIntervalSince1970: 5000)))
        #expect(verdict.detail.integrityState == .verifiedClean)
    }

    @Test("Integrity state is neverVerified when no verify run has ever happened -- the real library's own state")
    func integrityStateNeverVerified() {
        // This is the branch the real 612 GB reference library actually
        // hits: it has never had a `verify`-kind run. The detail sentence
        // for this branch must say plainly that nothing was checked, never
        // "nothing is corrupted".
        let verdict = ArchiveVerdict(tasks: [], snapshot: .stub(lastVerifyAt: nil))
        #expect(verdict.detail.integrityState == .neverVerified)
    }

    @Test("corruptionFound always outranks neverVerified, even without a verify run recorded")
    func corruptionOutranksNeverVerifiedWhenBothCouldApply() {
        // A defensive case: a corruption task present but `lastVerifyAt` for
        // some reason still nil (e.g. a data migration edge case) must still
        // report the corruption, not silently fall back to "never checked".
        let verdict = ArchiveVerdict(tasks: [.stub(kind: .corruption)], snapshot: .stub(lastVerifyAt: nil))
        #expect(verdict.detail.integrityState == .corruptionFound)
    }

    @Test("The reclaim detail names the target holding the most reclaimable bytes")
    func reclaimDetailNamesTheWorstTarget() {
        let rows: [ArchiveTargetRow] = [
            .stub(target: "NGC_7000", displayName: "NGC 7000", totalBytes: 500, reclaimableBytes: 100),
            .stub(target: "M42", displayName: "M42", totalBytes: 900, reclaimableBytes: 400),
        ]
        let snapshot = ArchiveMapSnapshot.stub(rows: rows, reclaimableBytes: 500)
        let verdict = ArchiveVerdict(tasks: [], snapshot: snapshot)

        #expect(verdict.detail.reclaimableBytes == 500)
        #expect(verdict.detail.worstTargetName == "M42")
        #expect(verdict.detail.worstTargetBytes == 400)
    }

    @Test("Nothing reclaimable produces no worst-target clause at all")
    func noReclaimProducesNoWorstTarget() {
        let verdict = ArchiveVerdict(tasks: [], snapshot: .stub(rows: [], reclaimableBytes: 0))
        #expect(verdict.detail.worstTargetName == nil)
        #expect(verdict.detail.worstTargetBytes == 0)
    }

    @Test("The untargeted bucket can be the worst reclaim source, and carries no name to print")
    func untargetedBucketCanBeTheWorstTarget() {
        // `ArchiveTargetRow.displayName` is `nil` for the untargeted bucket
        // by design (it is not a catalog designation) -- the verdict must
        // still report the total honestly, just without a false name.
        let rows: [ArchiveTargetRow] = [
            .stub(target: nil, displayName: nil, totalBytes: 500, reclaimableBytes: 300),
            .stub(target: "M42", displayName: "M42", totalBytes: 900, reclaimableBytes: 50),
        ]
        let verdict = ArchiveVerdict(tasks: [], snapshot: .stub(rows: rows, reclaimableBytes: 350))
        #expect(verdict.detail.worstTargetName == nil)
        #expect(verdict.detail.worstTargetBytes == 0, "no name to attribute the clause to -- the view omits it entirely")
    }
}

/// Literal source-text checks for `ArchiveView.swift`, following this repo's
/// established "surface test" convention (`V2PolishSurfaceTests`,
/// `HelpSurfaceTests`): these assert on wiring/vocabulary/structure, not on a
/// rendered view tree, since SwiftUI view bodies in this codebase are not
/// snapshot-tested.
struct ArchiveViewSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func archiveSource() throws -> String {
        try contents("Sources/AstroUI/Features/Archive/ArchiveView.swift")
    }

    @Test("Every required state branch renders through ContentUnavailableView or ProgressView")
    func requiredStateBranchesArePresent() throws {
        let source = try archiveSource()
        #expect(source.contains("ContentUnavailableView"), "no ContentUnavailableView at all")
        #expect(source.contains("Choose Image Library"), "no-library state is missing its real copy")
        #expect(source.contains("ProgressView"), "the loading-with-no-snapshot state must be a ProgressView")
        #expect(source.contains("Try Again"), "the error state must offer a retry, not a dead end")
        #expect(source.contains("Nothing indexed yet"), "the empty-library state is missing its real copy")
        #expect(source.contains("Rescan"), "the empty-library state must offer a real rescan action")
    }

    @Test("The page publishes its toolbar actions from lifecycle events, never from body")
    func toolbarActionsPublishFromLifecycleEvents() throws {
        let source = try archiveSource()
        #expect(source.contains(".onAppear"), "must publish on appear, matching HealthView.publishWorkspaceActions()")
        #expect(source.contains(".onDisappear"), "must clear its owner on disappear")
        #expect(source.contains("workspaceActionCenter.clear(owner:"), "must clear by owner, not unconditionally")
        #expect(source.contains("\"v2.archive.check\""))
        #expect(source.contains("\"v2.archive.check.fast\""))
        #expect(source.contains("Fast (Skip Duplicate Scan)"))
        #expect(source.contains("\"v2.archive.rescan\""))
        #expect(source.contains("\"v2.archive.organize\""))
        #expect(source.contains("\"v2.archive.change\""))
    }

    @Test("The page root is a non-scrolling VStack with exactly one scrolling List")
    func rootIsNonScrollingWithOneList() throws {
        let source = try archiveSource()
        #expect(!source.contains("ScrollView"), "a List inside a ScrollView is given unbounded height and never virtualizes -- see WorkspaceTablePage's own doc comment")
        #expect(source.contains("List {") || source.contains("List{"))
        #expect(source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
    }

    @Test("The footer admits what the page does not cover, instead of silently capping coverage")
    func uncoveredFooterExists() throws {
        let source = try archiveSource()
        #expect(source.contains("store.uncovered"))
        #expect(source.contains(".isEmpty"))
        #expect(source.contains(".help("), "the category breakdown belongs in a tooltip, not the visible line")
    }

    @Test("No archive surface uses the engine's internal vocabulary")
    func archiveViewUsesHumanWords() throws {
        let banned = ["Triage", "Frame fill", "Photographable", "Residue", "Finding("]
        let source = try archiveSource()
        for word in banned {
            #expect(!source.contains("\"\(word)"), "ArchiveView.swift shows the user the word \(word)")
        }
    }

    @Test("No display text in ArchiveView is declared as a plain String -- LocalizedStringKey is required")
    func noPlainStringDisplayText() throws {
        let source = try archiveSource()
        for line in source.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            #expect(!trimmed.hasPrefix("var ") || !trimmed.contains(": String"),
                    "found a `var x: String` in ArchiveView.swift: \(trimmed)")
        }
    }

    // MARK: Task 10 prerequisite -- the duplicate card resolves through the
    // same previewQuarantine action, and its categories reach the route push

    @Test("compareDuplicates no longer exists as an action; the duplicate card's action carries its categories through to the route push")
    func previewQuarantineCarriesItsCategoriesThroughToTheRoutePush() throws {
        let source = try archiveSource()
        #expect(!source.contains("compareDuplicates"), "ArchiveTaskAction.compareDuplicates was deleted -- ArchiveView must not reference it")
        // `perform(_:)` must forward the categories the underlying
        // `ArchiveTaskAction.previewQuarantine(categories:)` already carries
        // to `openQuarantinePreview`, not discard them by calling it bare.
        #expect(source.contains("case .previewQuarantine(let categories):"))
        #expect(source.contains("openQuarantinePreview(Set(categories))"))
        // The closure itself now accepts the categories it is asked to
        // preselect, rather than the bare `() -> Void` an earlier version
        // of this page had.
        #expect(source.contains("let openQuarantinePreview: (Set<String>) -> Void"))
    }

    // MARK: Task 3 (wave 3) -- the card's own action forwards to the
    // "view all" route, not a bare Finder reveal, once its finding count is
    // greater than one.

    @Test("perform(_:) forwards .showFindings to openTaskDetail with the action's own kind")
    func showFindingsForwardsToOpenTaskDetail() throws {
        let source = try archiveSource()
        #expect(source.contains("case .showFindings(let kind):"))
        #expect(source.contains("openTaskDetail(kind)"))
        #expect(source.contains("let openTaskDetail: (ArchiveTaskKind) -> Void"))
    }
}

/// Literal source-text checks for `ArchiveTaskDetailView.swift`, following
/// this file's own established "surface test" convention -- see
/// `ArchiveViewSurfaceTests`'s own header.
struct ArchiveTaskDetailViewSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source() throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/Features/Archive/ArchiveTaskDetailView.swift"),
            encoding: .utf8
        )
    }

    @Test("The findings table is never nested inside a ScrollView -- WorkspaceTablePage owns the bounded height")
    func tableIsNeverInsideAScrollView() throws {
        let text = try source()
        #expect(!text.contains("ScrollView"), "a Table inside a ScrollView is given unbounded height and never virtualizes -- see WorkspaceTablePage's own doc comment")
        #expect(text.contains("WorkspaceTablePage"))
        // W4-7 item 3 (owner review): grouped by parent folder now, so the
        // table is hierarchical (`store.rows`/`children:`), not the flat
        // `Table(store.findings)` this used to assert on.
        #expect(text.contains("Table(store.rows, children: \\.children"))
    }

    @Test("Findings group by parent folder -- a folder row is its own case, never a fake zero-byte file")
    func findingsGroupByParentFolder() throws {
        let text = try source()
        #expect(text.contains("ArchiveFindingRow"), "must render the grouped row type, not the flat ArchiveFinding array directly")
        #expect(text.contains("case .folder(let path, let fileCount, _):"), "a folder row must be its own case, not inferred from a file with 0 bytes")
    }

    @Test("The bulk quarantine action is gated on the page's own selection, never firing on an empty one")
    func quarantineActionIsGatedOnSelection() throws {
        let text = try source()
        #expect(text.contains("@State private var selection: Set<String> = []"))
        #expect(text.contains(".disabled(selection.isEmpty || accessMode != .mutationEnabled)"))
    }

    @Test("A finding kind with no sensible quarantine action explains what to do instead, never a dead-end page")
    func noQuarantineKindsExplainWhatToDoInstead() throws {
        let text = try source()
        #expect(text.contains("noQuarantineActionRow"))
        #expect(text.contains("case .unverified:"))
        #expect(text.contains("case .misplacedCalibration, .brokenNames, .corruption:"))
    }

    @Test("Findings load through the generation-guarded store, never in a computed getter or body")
    func findingsLoadThroughTheStore() throws {
        let text = try source()
        #expect(text.contains("@Bindable var store: ArchiveTaskDetailStore"))
        #expect(text.contains(".task { await store.load(rootURL: rootURL, kind: kind) }"))
    }

    @Test("The bulk quarantine action is gated by the kind's own capability, not hardcoded per view")
    func bulkActionIsGatedByKindCapability() throws {
        let text = try source()
        #expect(text.contains("kind.supportsBulkQuarantinePreview"))
        #expect(text.contains("openQuarantinePreview(Set(kind.findingCategories))"))
    }

    @Test("Each row carries its own reveal-in-Finder action, validated the same way ArchiveView's own reveal is")
    func eachRowRevealsItsOwnPath() throws {
        let text = try source()
        // W4-7 item 3: a row's reveal button now resolves its path from
        // either case of `ArchiveFindingRow.kind` (folder or finding), not
        // only `finding.path` -- see `revealButton(_:)`'s own local
        // `path` binding.
        #expect(text.contains("revealInFinder(path: path)"))
        #expect(text.contains("candidate.path.hasPrefix(root.path)"), "must confirm the resolved path never escapes the library root")
        #expect(text.contains("FileManager.default.fileExists(atPath: candidate.path)"))
    }
}

private extension ArchiveMapSnapshot {
    static func stub(
        totalBytes: Int64 = 100,
        rows: [ArchiveTargetRow] = [],
        reclaimableBytes: Int64 = 0,
        lastScanAt: Date? = nil,
        lastAuditAt: Date? = .distantPast,
        lastVerifyAt: Date? = nil
    ) -> ArchiveMapSnapshot {
        ArchiveMapSnapshot(
            totalBytes: totalBytes, fileCount: 0, targetCount: rows.count(where: { !$0.isUntargeted }), nightCount: 0,
            slices: [], rows: rows,
            reclaimableBytes: reclaimableBytes, reclaimableFiles: 0,
            lastScanAt: lastScanAt, lastAuditAt: lastAuditAt, lastVerifyAt: lastVerifyAt
        )
    }
}

private extension ArchiveTargetRow {
    static func stub(
        target: String?, displayName: String?,
        totalBytes: Int64 = 0, reclaimableBytes: Int64 = 0
    ) -> ArchiveTargetRow {
        ArchiveTargetRow(
            target: target, displayName: displayName, nightCount: 0, fileCount: 0,
            totalBytes: totalBytes, slices: [],
            reclaimableBytes: reclaimableBytes, reclaimableFiles: 0
        )
    }
}

private extension ArchiveTask {
    static func stub(kind: ArchiveTaskKind, affectedFileCount: Int = 0, bytes: Int64 = 0) -> ArchiveTask {
        ArchiveTask(
            kind: kind, severity: .reclaim,
            affectedFileCount: affectedFileCount, bytes: bytes,
            evidencePaths: [], action: .unavailable
        )
    }
}
