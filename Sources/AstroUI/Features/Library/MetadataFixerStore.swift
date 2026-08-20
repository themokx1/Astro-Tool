import AstroApplication
import AstroCore
import Foundation
import Observation

/// Backs `MetadataFixerView`: loads the library-wide "missing filter" gap
/// list plus any resolver-flagged conflicts (`CaptureAssignmentCommand
/// .filterGaps`/`.resolvedFrames`), drives the rule-suggestion review for a
/// selected gap, and applies either the suggestion or a manual override
/// (`CaptureAssignmentCommand.applyRule`/`.assign`/`.clear`), gated on
/// `LibraryAccessMode`. Follows `CalibrationStore`'s query/command-factory
/// injection pattern so tests can supply a fixture-backed command without
/// touching the filesystem-resolving `production` constructor.
@MainActor
@Observable
public final class MetadataFixerStore {
    public typealias CommandFactory = @Sendable (URL, LibraryAccessMode) throws -> CaptureAssignmentCommand

    public private(set) var gaps: [CaptureFilterGap] = []
    /// Frames where `CaptureResolver` itself flagged a disagreement between
    /// sources (e.g. a capture group's declared filter and a manual
    /// override's filter conflict) -- shown as a standing warning list, per
    /// the spec's "never silently pick one side" requirement.
    public private(set) var conflicts: [(path: String, message: String)] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var accessMode: LibraryAccessMode = .readOnly

    public private(set) var selectedGapID: String?
    public private(set) var suggestion: CaptureRuleSuggestion?
    public private(set) var isSuggesting = false
    public private(set) var applyErrorMessage: String?
    public private(set) var lastReceipt: CaptureAssignmentReceipt?

    /// Fired after a successful apply/clear -- lets the host view refresh
    /// any badge/summary that counts outstanding metadata gaps, the same
    /// role `CalibrationStore.onLibraryFindingsChanged` plays.
    public var onLibraryFindingsChanged: (() -> Void)?

    private let commandFactory: CommandFactory
    private var rootURL: URL?

    public init(
        commandFactory: @escaping CommandFactory = { rootURL, accessMode in
            try CaptureAssignmentCommand.production(rootURL: rootURL, accessMode: accessMode)
        }
    ) {
        self.commandFactory = commandFactory
    }

    public var selectedGap: CaptureFilterGap? {
        gaps.first { $0.id == selectedGapID }
    }

    public func load(rootURL: URL, accessMode: LibraryAccessMode = .readOnly) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        self.rootURL = rootURL.standardizedFileURL
        self.accessMode = accessMode
        do {
            let command = try commandFactory(rootURL, accessMode)
            gaps = try command.filterGaps()
            conflicts = try command.resolvedFrames()
                .filter { $0.resolved.hasConflict }
                .flatMap { file, resolved in resolved.conflicts.map { (file.path, $0) } }
            if let selectedGapID, !gaps.contains(where: { $0.id == selectedGapID }) {
                self.selectedGapID = nil
                suggestion = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Selects `gap` and asks the rule-suggestion engine for it (only
    /// possible when the gap already belongs to a capture group -- a
    /// classic, non-capture-aware folder has no group id to suggest
    /// against, and this method leaves `suggestion` `nil` for it, exactly
    /// the "not enough context -> manual field only" case the spec calls
    /// out).
    public func selectGap(_ gap: CaptureFilterGap) async {
        selectedGapID = gap.id
        suggestion = nil
        applyErrorMessage = nil
        lastReceipt = nil
        guard let rootURL, let groupID = gap.groupID else { return }
        isSuggesting = true
        defer { isSuggesting = false }
        do {
            let command = try commandFactory(rootURL, accessMode)
            suggestion = try command.suggestRule(groupID: groupID)
        } catch {
            suggestion = nil
        }
    }

    /// Applies the currently-suggested rule (after the user has reviewed
    /// and approved it) to every path in the selected gap.
    public func applySuggestion() async {
        guard let gap = selectedGap, let groupID = gap.groupID, let suggestion else { return }
        await apply {
            try $0.applyRule(suggestion, target: gap.target, date: gap.date, paths: gap.paths, groupID: groupID)
        }
    }

    /// Applies a hand-entered override to every path in the selected gap.
    /// `signalOverride == .unfiltered` with every filter field left blank is
    /// how the UI expresses "this folder/rig explicitly does NOT inherit the
    /// group's duoband (or any other) filter" -- see `CaptureAssignmentCommand
    /// .assign`'s own doc comment for why `CaptureResolver` treats that
    /// combination as an explicit "no filter", not "no override at all".
    public func applyManualOverride(
        signalMode: SignalMode?,
        filterManufacturer: String,
        filterModel: String,
        filterName: String
    ) async {
        guard let gap = selectedGap, let groupID = gap.groupID else { return }
        await apply {
            try $0.assign(
                target: gap.target, date: gap.date, paths: gap.paths, groupID: groupID,
                signalOverride: signalMode,
                filterManufacturerOverride: filterManufacturer,
                filterModelOverride: filterModel,
                filterNameOverride: filterName
            )
        }
    }

    /// The explicit "does not inherit the group's duoband filter" one-click
    /// action: an unfiltered/no-filter override with no manufacturer/model/
    /// name, for every path in the selected gap.
    public func markDoesNotInheritGroupFilter() async {
        guard let gap = selectedGap, let groupID = gap.groupID else { return }
        await apply {
            try $0.assign(
                target: gap.target, date: gap.date, paths: gap.paths, groupID: groupID,
                signalOverride: .unfiltered
            )
        }
    }

    /// Revokes any manual override on the selected gap's paths, restoring
    /// whatever `CaptureResolver` would otherwise resolve.
    public func clearOverride() async {
        guard let rootURL, let gap = selectedGap else { return }
        do {
            let command = try commandFactory(rootURL, accessMode)
            try command.clear(paths: gap.paths)
            applyErrorMessage = nil
            lastReceipt = nil
            await load(rootURL: rootURL, accessMode: accessMode)
            onLibraryFindingsChanged?()
        } catch LibraryMutationError.readOnly {
            applyErrorMessage = "Requires write access. Enable write operations in Settings to edit capture metadata."
        } catch {
            applyErrorMessage = error.localizedDescription
        }
    }

    private func apply(_ work: (CaptureAssignmentCommand) throws -> CaptureAssignmentReceipt) async {
        guard let rootURL else { return }
        do {
            let command = try commandFactory(rootURL, accessMode)
            lastReceipt = try work(command)
            applyErrorMessage = nil
            await load(rootURL: rootURL, accessMode: accessMode)
            onLibraryFindingsChanged?()
        } catch LibraryMutationError.readOnly {
            applyErrorMessage = "Requires write access. Enable write operations in Settings to edit capture metadata."
        } catch {
            applyErrorMessage = error.localizedDescription
        }
    }
}
