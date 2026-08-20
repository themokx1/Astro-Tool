import AstroCore
import Foundation

/// One deterministic, evidence-based guess for a capture group that's
/// missing signal mode and/or filter metadata -- e.g. every Canon CR3 night
/// group `ScanWorkflowMaterializer` can't classify past "unfiltered/
/// broadband" because there's no FITS header to read at all (see
/// `CaptureResolver`'s own doc comment). Always a SUGGESTION: the caller
/// (`MetadataFixerView`) shows it as a proposed rule the user must approve
/// before `CaptureAssignmentCommand.applyRule` ever writes anything.
public struct CaptureRuleSuggestion: Equatable, Sendable {
    public enum Basis: Equatable, Sendable {
        /// The capture group's own folder/slug name is itself evidence
        /// (e.g. `sv220_dual-band`) -- the same conservative vocabulary
        /// `ScanWorkflowMaterializer`'s fallback tail uses for a capture
        /// slug, applied here to the group's `slug` before any frame is
        /// scanned at all.
        case slugNameText
        /// Another capture group sharing this EXACT slug name (the same
        /// physical rig folder convention, reused on a different night)
        /// already has a declared filter, and every such sibling agrees --
        /// "this rig's `sv220_dual-band` folder always means SV220."
        case sameSlugOtherNight(sourceGroupID: Int64)
        /// The library's configured default imaging setup's own fallback
        /// filter, for an OSC group with nothing else to go on -- the same
        /// setup `ScanWorkflowMaterializer`'s absolute fallback level reads.
        case defaultImagingSetup
    }

    public let signalMode: SignalMode?
    public let filterManufacturer: String?
    public let filterModel: String?
    public let filterName: String?
    public let basis: Basis

    public init(
        signalMode: SignalMode?,
        filterManufacturer: String? = nil,
        filterModel: String? = nil,
        filterName: String? = nil,
        basis: Basis
    ) {
        self.signalMode = signalMode
        self.filterManufacturer = filterManufacturer
        self.filterModel = filterModel
        self.filterName = filterName
        self.basis = basis
    }
}

/// Pure, deterministic rule-suggestion logic -- no I/O, no database, so it's
/// trivially unit-testable and never duplicates a live query's own
/// filtering. Deliberately conservative: returns `nil` ("not enough
/// context") rather than guess, matching the spec's explicit "vegyes mappa
/// -> üres javaslat" (mixed folder -> empty suggestion) requirement.
public enum CaptureRuleSuggestionEngine {
    /// `allGroups` should be every OTHER capture group in the library (or at
    /// least every group sharing `group.slug`) -- used only for the
    /// same-slug-other-night evidence level.
    public static func suggest(
        for group: CaptureGroupRecord,
        allGroups: [CaptureGroupRecord],
        imagingSetups: [ImagingSetupProfile] = []
    ) -> CaptureRuleSuggestion? {
        guard needsFilling(group) else { return nil }

        if let inferred = inferredSignalMode(fromText: group.slug) {
            return CaptureRuleSuggestion(signalMode: inferred, basis: .slugNameText)
        }

        let siblings = allGroups.filter {
            $0.slug == group.slug && $0.id != group.id && !needsFilling($0)
        }
        if !siblings.isEmpty {
            let distinctSignals = Set(siblings.map(\.signalMode))
            let distinctFilters = Set(siblings.map { $0.filterLabel ?? "" })
            guard distinctSignals.count == 1, distinctFilters.count == 1, let sibling = siblings.first else {
                // Evidence disagrees across nights -- stay honest, no guess.
                return nil
            }
            return CaptureRuleSuggestion(
                signalMode: sibling.signalMode == .unknown ? nil : sibling.signalMode,
                filterManufacturer: sibling.filterManufacturer,
                filterModel: sibling.filterModel,
                filterName: sibling.filterName,
                basis: .sameSlugOtherNight(sourceGroupID: sibling.id ?? 0)
            )
        }

        if group.sensorMode == .osc,
           let setup = ImagingSetupProfile.defaultSetup(in: imagingSetups),
           setup.defaultFilterSignalMode != .unknown
        {
            return CaptureRuleSuggestion(
                signalMode: setup.defaultFilterSignalMode,
                filterName: setup.defaultFilterName,
                basis: .defaultImagingSetup
            )
        }

        return nil
    }

    private static func needsFilling(_ group: CaptureGroupRecord) -> Bool {
        group.signalMode == .unknown || group.filterLabel == nil
    }

    /// Same conservative marker vocabulary `ScanWorkflowMaterializer`'s
    /// capture-slug fallback level uses -- kept as its own copy (rather than
    /// a shared helper) because the two call sites read fundamentally
    /// different inputs (a live scanned frame's slug vs. a stored group's
    /// slug) and this codebase's convention is a small, file-local copy over
    /// a premature shared abstraction for a three-line classifier.
    private static func inferredSignalMode(fromText rawText: String) -> SignalMode? {
        let normalized = rawText.lowercased()
        if normalized.contains("sv220") || normalized.contains("dual") || normalized.contains("duo") { return .dualBand }
        if ["ha", "halpha", "h-alpha", "oiii", "sii"].contains(where: normalized.contains) { return .narrowband }
        return nil
    }
}

/// One folder/date/rig scope whose light frames have no resolved filter --
/// the row shape `MetadataFixerView`'s batched "missing filters" list
/// groups by. `groupID` is `nil` when the frames don't belong to any
/// capture group yet (a classic, non-capture-aware session folder) --
/// `CaptureAssignmentCommand.assign` still accepts this by creating/reusing
/// a group first, but the gap listing itself never fabricates one.
public struct CaptureFilterGap: Equatable, Sendable, Identifiable {
    public let target: String
    public let date: String
    public let label: String
    public let instrument: String?
    public let groupID: Int64?
    public let paths: [String]

    public var id: String { "\(target)|\(date)|\(label)" }

    public init(target: String, date: String, label: String, instrument: String?, groupID: Int64?, paths: [String]) {
        self.target = target
        self.date = date
        self.label = label
        self.instrument = instrument
        self.groupID = groupID
        self.paths = paths
    }
}

public enum CaptureAssignmentCommandError: Error, Equatable, Sendable, LocalizedError {
    case noMatchingFrames
    case groupNotFound(Int64)
    case groupScopeMismatch(groupID: Int64)

    public var errorDescription: String? {
        switch self {
        case .noMatchingFrames:
            return "None of the selected frames are indexed in this library yet."
        case let .groupNotFound(id):
            return "Capture group \(id) does not exist."
        case let .groupScopeMismatch(id):
            return "Capture group \(id) does not belong to the selected session."
        }
    }
}

/// Receipt for one `CaptureAssignmentCommand.assign`/`applyRule` call --
/// deliberately minimal (paths + group), since `assigned_at`/
/// `assignment_source` on `file_capture_assignments` itself is already this
/// write's own durable, queryable log -- no separate journal table is
/// needed for "naplózott visszavonhatóság" (logged revocability): the same
/// row that recorded the override is the row `clear` deletes.
public struct CaptureAssignmentReceipt: Equatable, Sendable {
    public let groupID: Int64
    public let assignedPaths: [String]

    public init(groupID: Int64, assignedPaths: [String]) {
        self.groupID = groupID
        self.assignedPaths = assignedPaths
    }
}

/// V2's entry point for V1's manual capture-metadata override write path
/// (`AppState.assignCaptureMetadata`/the `astrotool` CLI) -- the exact same
/// UPSERT into `file_capture_assignments`
/// (`Database.upsertFileCaptureAssignment`), never a second, parallel write
/// path. This table is what makes a manual override survive a rescan (V1
/// always has) and what `ScanWorkflowMaterializer`'s `CaptureResolver`
/// routing (see that file's own doc comment) now makes visible to V2 too.
///
/// This writes only this library's OWN external index database, never a
/// file inside the library root -- by `SensorMeasurementCommand`'s own
/// precedent that would normally mean skipping the `LibraryAccessMode`
/// gate entirely. The V3 5.4 spec explicitly overrides that precedent here:
/// every downstream statistic (session grouping, filter breakdowns, night
/// reports) changes once an assignment is written, so this command gates on
/// `accessMode` and stays revocable/typed like every other mutation, not
/// just the ones that touch the filesystem.
public struct CaptureAssignmentCommand: Sendable {
    private let db: Database
    private let config: AstroConfig
    private let accessMode: LibraryAccessMode

    public init(db: Database, config: AstroConfig, accessMode: LibraryAccessMode) {
        self.db = db
        self.config = config
        self.accessMode = accessMode
    }

    public static func production(rootURL: URL, accessMode: LibraryAccessMode) throws -> Self {
        let root = rootURL.standardizedFileURL
        let identity = LibraryIdentity(rootURL: root)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: root)
        let database = try Database(path: storage.indexDatabase.path)
        let configURL = root.appendingPathComponent(".astro_tool/config.json")
        var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
        config.rootPath = root.path
        return Self(db: database, config: config, accessMode: accessMode)
    }

    // MARK: - Reads (always available, any access mode)

    /// This session's own capture groups, for the "assign to a group" picker.
    public func groups(target: String, date: String) throws -> [CaptureGroupRecord] {
        try db.captureGroups(target: target, date: date)
    }

    /// Every light frame in the library with its fully resolved capture
    /// metadata (manual override > capture group > FITS header), via the
    /// SAME `CaptureResolver` `ScanWorkflowMaterializer` now routes through
    /// -- this command never re-derives its own copy of that precedence.
    public func resolvedFrames() throws -> [(file: FileRecord, resolved: ResolvedCaptureMetadata)] {
        let resolver = try CaptureResolver.load(db: db)
        return try db.allFiles(includeMissing: false)
            .filter { $0.role == .light && $0.area == .sessions && $0.target != nil && $0.sessionDate != nil }
            .map { file in
                let meta = try? db.fitsMeta(fileID: file.id ?? -1)
                return (file, resolver.resolve(file: file, meta: meta))
            }
    }

    /// The batched "Hiányzó szűrők" (missing filters) list: every light
    /// frame whose resolved filter is still empty, grouped by target/date/
    /// folder label (capture slug, legacy label, or "session" when neither
    /// applies)/instrument -- exactly the grouping the spec's `Metaadat
    /// javítása` batched view asks for.
    public func filterGaps() throws -> [CaptureFilterGap] {
        struct Key: Hashable { let target: String; let date: String; let label: String; let instrument: String? }
        var byKey: [Key: (groupID: Int64?, paths: [String])] = [:]
        for (file, resolved) in try resolvedFrames() where resolved.filterName == nil && !resolved.hasConflict {
            guard let target = file.target, let date = file.sessionDate else { continue }
            let pathInfo = PathClassifier.classify(relativePath: file.path)
            let label = resolved.slug ?? pathInfo.captureSlug ?? pathInfo.legacyCaptureLabel ?? "session"
            let instrument = (try? db.fitsMeta(fileID: file.id ?? -1))?.instrume
            let key = Key(target: target, date: date, label: label, instrument: instrument)
            var entry = byKey[key] ?? (resolved.groupID, [])
            entry.paths.append(file.path)
            byKey[key] = entry
        }
        return byKey.map { key, value in
            CaptureFilterGap(
                target: key.target, date: key.date, label: key.label,
                instrument: key.instrument, groupID: value.groupID, paths: value.paths.sorted()
            )
        }.sorted { ($0.target, $0.date, $0.label) < ($1.target, $1.date, $1.label) }
    }

    /// The rule-suggestion engine's verdict for one existing capture group,
    /// supplying it every sibling group in the library as same-slug
    /// evidence.
    public func suggestRule(groupID: Int64) throws -> CaptureRuleSuggestion? {
        guard let group = try db.captureGroup(id: groupID) else { return nil }
        let allGroups = try db.allCaptureGroups()
        return CaptureRuleSuggestionEngine.suggest(
            for: group, allGroups: allGroups, imagingSetups: config.imagingSetups
        )
    }

    // MARK: - Writes (gated on accessMode)

    /// Assigns exactly `paths` (no implicit folder expansion) to `groupID`
    /// with the given overrides -- the literal `Database.
    /// upsertFileCaptureAssignment` UPSERT `AppState.assignCaptureMetadata`
    /// already uses for V1, so a V1 and a V2 override are indistinguishable
    /// rows. An explicit `.unfiltered` `signalOverride` with every filter
    /// override left `nil` is how the UI expresses "this file does NOT
    /// inherit the group's duoband filter" -- `CaptureResolver.resolve`
    /// already treats that combination as "explicitly no filter" (see its
    /// own `explicitNoFilter` handling), not as "no override at all".
    @discardableResult
    public func assign(
        target: String,
        date: String,
        paths: [String],
        groupID: Int64,
        sensorOverride: SensorMode? = nil,
        signalOverride: SignalMode? = nil,
        filterManufacturerOverride: String? = nil,
        filterModelOverride: String? = nil,
        filterNameOverride: String? = nil
    ) throws -> CaptureAssignmentReceipt {
        guard accessMode == .mutationEnabled else { throw LibraryMutationError.readOnly }
        guard !paths.isEmpty else { throw CaptureAssignmentCommandError.noMatchingFrames }
        guard let group = try db.captureGroup(id: groupID) else {
            throw CaptureAssignmentCommandError.groupNotFound(groupID)
        }
        guard group.target == target, group.sessionDate == date else {
            throw CaptureAssignmentCommandError.groupScopeMismatch(groupID: groupID)
        }

        let assignedAt = Date().timeIntervalSince1970
        var assigned: [String] = []
        for path in Array(Set(paths)).sorted() {
            guard let file = try db.file(path: path), let fileID = file.id,
                  file.target == target, file.sessionDate == date
            else { continue }
            try db.upsertFileCaptureAssignment(FileCaptureAssignmentRecord(
                fileID: fileID,
                captureGroupID: groupID,
                sensorModeOverride: sensorOverride,
                signalModeOverride: signalOverride,
                filterManufacturerOverride: Self.nonBlank(filterManufacturerOverride),
                filterModelOverride: Self.nonBlank(filterModelOverride),
                filterNameOverride: Self.nonBlank(filterNameOverride),
                assignmentSource: "app",
                assignedAt: assignedAt
            ))
            assigned.append(path)
        }
        guard !assigned.isEmpty else { throw CaptureAssignmentCommandError.noMatchingFrames }
        return CaptureAssignmentReceipt(groupID: groupID, assignedPaths: assigned)
    }

    /// Applies a previously-suggested (and user-approved) `CaptureRuleSuggestion`
    /// to every path in the gap -- the same `assign` write path, just with
    /// the suggestion's fields spread into the override arguments so the UI
    /// never has to build a `FileCaptureAssignmentRecord` itself.
    @discardableResult
    public func applyRule(
        _ suggestion: CaptureRuleSuggestion,
        target: String, date: String, paths: [String], groupID: Int64
    ) throws -> CaptureAssignmentReceipt {
        try assign(
            target: target, date: date, paths: paths, groupID: groupID,
            signalOverride: suggestion.signalMode,
            filterManufacturerOverride: suggestion.filterManufacturer,
            filterModelOverride: suggestion.filterModel,
            filterNameOverride: suggestion.filterName
        )
    }

    /// Revokes a manual override for exactly `paths`, restoring whatever
    /// `CaptureResolver` would resolve without it (capture group, then FITS
    /// header, then V2's own fallback tail) -- `Database.
    /// clearFileCaptureAssignment` deletes the row outright rather than
    /// nulling its columns, so this is a true, complete undo.
    public func clear(paths: [String]) throws {
        guard accessMode == .mutationEnabled else { throw LibraryMutationError.readOnly }
        for path in Array(Set(paths)).sorted() {
            guard let file = try db.file(path: path), let fileID = file.id else { continue }
            try db.clearFileCaptureAssignment(fileID: fileID)
        }
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
