import Foundation

public struct SessionConversionScope: Codable, Equatable, Hashable, Sendable {
    public var target: String
    public var date: String

    public init(target: String, date: String) {
        self.target = target
        self.date = date
    }
}

public enum SessionConversionMode: String, Codable, CaseIterable, Sendable {
    case logicalOnly = "logical_only"
    case physical
}

public enum ConversionConfidence: String, Codable, Sendable {
    case strong
    case suggested
    case review
}

public struct ConversionSourceMapping: Codable, Equatable, Sendable {
    public var relativePath: String
    public var role: FrameRole

    public init(relativePath: String, role: FrameRole) {
        self.relativePath = relativePath
        self.role = role
    }
}

public struct DetectedCaptureCluster: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var proposedGroupSlug: String
    public var sourcePrefixes: [String]
    public var rawFramePaths: [String]
    public var artifactPaths: [String]
    public var exposureBreakdown: [String: Int]
    public var integrationSeconds: Double
    public var totalBytes: Int64
    public var evidence: [String]
    public var confidence: ConversionConfidence

    public init(
        id: String,
        title: String,
        proposedGroupSlug: String,
        sourcePrefixes: [String],
        rawFramePaths: [String],
        artifactPaths: [String],
        exposureBreakdown: [String: Int],
        integrationSeconds: Double,
        totalBytes: Int64,
        evidence: [String],
        confidence: ConversionConfidence
    ) {
        self.id = id
        self.title = title
        self.proposedGroupSlug = proposedGroupSlug
        self.sourcePrefixes = sourcePrefixes
        self.rawFramePaths = rawFramePaths
        self.artifactPaths = artifactPaths
        self.exposureBreakdown = exposureBreakdown
        self.integrationSeconds = integrationSeconds
        self.totalBytes = totalBytes
        self.evidence = evidence
        self.confidence = confidence
    }
}

public struct ProposedCaptureGroup: Codable, Equatable, Sendable, Identifiable {
    public var draft: CaptureGroupDraft
    public var sourceMappings: [ConversionSourceMapping]
    public var evidence: [String]
    public var confidence: ConversionConfidence

    public var id: String { draft.slug }

    public init(
        draft: CaptureGroupDraft,
        sourceMappings: [ConversionSourceMapping] = [],
        evidence: [String] = [],
        confidence: ConversionConfidence = .review
    ) {
        self.draft = draft
        self.sourceMappings = sourceMappings
        self.evidence = evidence
        self.confidence = confidence
    }
}

public struct ConversionAssignment: Codable, Equatable, Sendable, Identifiable {
    public var fileID: Int64?
    public var path: String
    public var role: FrameRole
    public var groupSlug: String
    public var reason: String

    public var id: String { path }

    public init(fileID: Int64?, path: String, role: FrameRole, groupSlug: String, reason: String) {
        self.fileID = fileID
        self.path = path
        self.role = role
        self.groupSlug = groupSlug
        self.reason = reason
    }
}

public struct ConversionDirectoryCreation: Codable, Equatable, Sendable, Identifiable {
    public var relativePath: String
    public var reason: String
    public var id: String { relativePath }

    public init(relativePath: String, reason: String) {
        self.relativePath = relativePath
        self.reason = reason
    }
}

public struct ConversionMove: Codable, Equatable, Sendable, Identifiable {
    public var sourceRelative: String
    public var destinationRelative: String
    public var sizeBytes: Int64
    public var role: FrameRole
    public var groupSlug: String
    public var reason: String
    public var id: String { sourceRelative }

    public init(
        sourceRelative: String,
        destinationRelative: String,
        sizeBytes: Int64,
        role: FrameRole,
        groupSlug: String,
        reason: String
    ) {
        self.sourceRelative = sourceRelative
        self.destinationRelative = destinationRelative
        self.sizeBytes = sizeBytes
        self.role = role
        self.groupSlug = groupSlug
        self.reason = reason
    }
}

public struct ConversionUnchangedItem: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var reason: String
    public var id: String { path }

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public enum ConversionAmbiguityKind: String, Codable, Sendable {
    case calibrationAssignment = "calibration_assignment"
    case artifactAssignment = "artifact_assignment"
    case mixedEvidence = "mixed_evidence"
}

public struct ConversionAmbiguity: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: ConversionAmbiguityKind
    public var title: String
    public var explanation: String
    public var affectedPaths: [String]
    public var candidateGroupSlugs: [String]
    public var isBlocking: Bool

    public init(
        id: String,
        kind: ConversionAmbiguityKind,
        title: String,
        explanation: String,
        affectedPaths: [String],
        candidateGroupSlugs: [String],
        isBlocking: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.explanation = explanation
        self.affectedPaths = affectedPaths
        self.candidateGroupSlugs = candidateGroupSlugs
        self.isBlocking = isBlocking
    }
}

public struct ConversionConflict: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var message: String
    public var id: String { path + message }

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public struct SessionConversionSummary: Codable, Equatable, Sendable {
    public var rawFrameCount: Int
    public var artifactCount: Int
    public var calibrationFrameCount: Int
    public var integrationSeconds: Double
    public var fileAssignmentCount: Int
    public var directoryCount: Int
    public var moveCount: Int
    public var bytesToMove: Int64
    public var unchangedCount: Int

    public init(
        rawFrameCount: Int = 0,
        artifactCount: Int = 0,
        calibrationFrameCount: Int = 0,
        integrationSeconds: Double = 0,
        fileAssignmentCount: Int = 0,
        directoryCount: Int = 0,
        moveCount: Int = 0,
        bytesToMove: Int64 = 0,
        unchangedCount: Int = 0
    ) {
        self.rawFrameCount = rawFrameCount
        self.artifactCount = artifactCount
        self.calibrationFrameCount = calibrationFrameCount
        self.integrationSeconds = integrationSeconds
        self.fileAssignmentCount = fileAssignmentCount
        self.directoryCount = directoryCount
        self.moveCount = moveCount
        self.bytesToMove = bytesToMove
        self.unchangedCount = unchangedCount
    }
}

public struct ConversionSourceFingerprint: Codable, Equatable, Sendable {
    public var fileCount: Int
    public var totalBytes: Int64
    public var latestMtime: Double
    public var stableHash: String

    public init(fileCount: Int, totalBytes: Int64, latestMtime: Double, stableHash: String) {
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.latestMtime = latestMtime
        self.stableHash = stableHash
    }
}

public struct SessionConversionPlan: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: Int
    public var id: String
    public var scope: SessionConversionScope
    public var mode: SessionConversionMode
    public var detectedClusters: [DetectedCaptureCluster]
    public var proposedGroups: [ProposedCaptureGroup]
    public var assignments: [ConversionAssignment]
    public var directoryCreations: [ConversionDirectoryCreation]
    public var moves: [ConversionMove]
    public var unchangedItems: [ConversionUnchangedItem]
    public var ambiguities: [ConversionAmbiguity]
    public var conflicts: [ConversionConflict]
    public var summary: SessionConversionSummary
    public var sourceFingerprint: ConversionSourceFingerprint
    public var humanSummaryHU: String

    public var canApply: Bool {
        conflicts.isEmpty && !ambiguities.contains(where: \.isBlocking)
    }

    public init(
        schemaVersion: Int = 1,
        id: String,
        scope: SessionConversionScope,
        mode: SessionConversionMode,
        detectedClusters: [DetectedCaptureCluster],
        proposedGroups: [ProposedCaptureGroup],
        assignments: [ConversionAssignment],
        directoryCreations: [ConversionDirectoryCreation],
        moves: [ConversionMove],
        unchangedItems: [ConversionUnchangedItem],
        ambiguities: [ConversionAmbiguity],
        conflicts: [ConversionConflict],
        summary: SessionConversionSummary,
        sourceFingerprint: ConversionSourceFingerprint,
        humanSummaryHU: String
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.scope = scope
        self.mode = mode
        self.detectedClusters = detectedClusters
        self.proposedGroups = proposedGroups
        self.assignments = assignments
        self.directoryCreations = directoryCreations
        self.moves = moves
        self.unchangedItems = unchangedItems
        self.ambiguities = ambiguities
        self.conflicts = conflicts
        self.summary = summary
        self.sourceFingerprint = sourceFingerprint
        self.humanSummaryHU = humanSummaryHU
    }
}

private enum LightSourceKind: Int, Comparable {
    case existing = 0
    case canonical = 1
    case legacy = 2
    case classic = 3

    static func < (lhs: LightSourceKind, rhs: LightSourceKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

private struct LightSeed {
    var key: String
    var kind: LightSourceKind
    var sourcePrefix: String
    var label: String?
    var existingGroup: CaptureGroupRecord?
    var files: [FileRecord]
}

private struct GroupOption {
    var slug: String
    var displayName: String
    var hints: Set<String>
}

/// Produces a fully serializable preview for one exact target/date scope.
/// The core `plan` overload is a pure function over supplied records and
/// never reads or writes the filesystem.
public enum SessionConversionPlanner {
    public static func plan(
        target: String,
        date: String,
        db: Database,
        config: AstroConfig,
        mode: SessionConversionMode
    ) throws -> SessionConversionPlan {
        let scope = SessionConversionScope(target: target, date: date)
        let allFiles = try db.allFiles(includeMissing: false)
        let scopedFiles = allFiles.filter { file in
            file.target == target && file.sessionDate == date
                && (file.area == .sessions || file.area == .stacks || file.area == .processed)
        }
        let meta = try db.fitsMetaBatch(fileIDs: scopedFiles.compactMap(\.id))
        return try plan(
            scope: scope,
            files: scopedFiles,
            meta: meta,
            existingGroups: db.captureGroups(target: target, date: date),
            existingSources: db.allCaptureSources(),
            assignments: db.fileCaptureAssignments(fileIDs: scopedFiles.compactMap(\.id)),
            mode: mode,
            occupiedPaths: Set(allFiles.map(\.path)),
            config: config
        )
    }

    public static func plan(
        scope: SessionConversionScope,
        files: [FileRecord],
        meta: [Int64: FITSMetaRecord],
        existingGroups: [CaptureGroupRecord],
        existingSources: [CaptureSourceRecord],
        assignments: [Int64: FileCaptureAssignmentRecord],
        mode: SessionConversionMode,
        occupiedPaths: Set<String> = [],
        config: AstroConfig = AstroConfig()
    ) throws -> SessionConversionPlan {
        try validateScope(scope, files: files)
        let fingerprint = sourceFingerprint(files)
        let planID = "\(scope.target)-\(scope.date)-\(mode.rawValue)-\(fingerprint.stableHash)"
        guard !files.isEmpty else {
            return SessionConversionPlan(
                id: planID,
                scope: scope,
                mode: mode,
                detectedClusters: [],
                proposedGroups: [],
                assignments: [],
                directoryCreations: [],
                moves: [],
                unchangedItems: [],
                ambiguities: [],
                conflicts: [],
                summary: SessionConversionSummary(),
                sourceFingerprint: fingerprint,
                humanSummaryHU: "A kiválasztott sessionben nincs konvertálható fájl."
            )
        }

        let groupsByID = Dictionary(uniqueKeysWithValues: existingGroups.compactMap { group in
            group.id.map { ($0, group) }
        })
        let groupsBySlug = Dictionary(uniqueKeysWithValues: existingGroups.map { ($0.slug, $0) })
        let resolver = CaptureResolver(
            groups: existingGroups,
            sources: existingSources,
            assignments: assignments
        )

        var seedsByKey: [String: LightSeed] = [:]
        let lightFiles = files.filter { $0.area == .sessions && $0.role == .light }
        for file in lightFiles {
            let resolved = resolver.resolve(file: file, meta: file.id.flatMap { meta[$0] })
            let info = PathClassifier.classify(relativePath: file.path)
            let prefix = sessionRolePrefix(file.path)
            let seed: LightSeed
            if let id = resolved.groupID, let group = groupsByID[id] {
                seed = LightSeed(
                    key: "existing:\(id)",
                    kind: .existing,
                    sourcePrefix: prefix,
                    label: group.slug,
                    existingGroup: group,
                    files: []
                )
            } else if let slug = info.captureSlug {
                seed = LightSeed(
                    key: "canonical:\(slug)",
                    kind: .canonical,
                    sourcePrefix: prefix,
                    label: slug,
                    existingGroup: groupsBySlug[slug],
                    files: []
                )
            } else if let label = info.legacyCaptureLabel {
                seed = LightSeed(
                    key: "legacy:\(prefix)",
                    kind: .legacy,
                    sourcePrefix: prefix,
                    label: label,
                    existingGroup: nil,
                    files: []
                )
            } else {
                seed = LightSeed(
                    key: "classic:\(prefix)",
                    kind: .classic,
                    sourcePrefix: prefix,
                    label: nil,
                    existingGroup: nil,
                    files: []
                )
            }
            if seedsByKey[seed.key] == nil { seedsByKey[seed.key] = seed }
            seedsByKey[seed.key]?.files.append(file)
        }

        let sortedSeeds = seedsByKey.values.sorted {
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            return $0.sourcePrefix.localizedStandardCompare($1.sourcePrefix) == .orderedAscending
        }
        var usedSlugs = Set(existingGroups.map(\.slug))
        var clusters: [DetectedCaptureCluster] = []
        var proposed: [ProposedCaptureGroup] = []
        var assignmentsOut: [ConversionAssignment] = []
        var options: [GroupOption] = []
        var groupSlugBySeed: [String: String] = [:]
        var stackedArtifactCount = 0

        for seed in sortedSeeds {
            let buckets = FrameSet.lightBuckets(files: seed.files, meta: meta, config: config)
            let rawFiles = (buckets.usable + buckets.rejected).sorted { $0.path < $1.path }
            let artifacts = seed.files.filter { !FrameSet.isFrameCandidate($0) }.sorted { $0.path < $1.path }
            stackedArtifactCount += artifacts.filter {
                StackDiscovery.hasASIAirStackedPrefix(($0.path as NSString).lastPathComponent.lowercased())
            }.count
            let exposureBreakdown = breakdown(rawFiles, meta: meta)
            let integration = rawFiles.reduce(0.0) { partial, file in
                partial + (file.id.flatMap { meta[$0]?.exptime } ?? 0)
            }
            let exposureLabel = humanExposureLabel(exposureBreakdown)
            let inferred = inferredModes(files: rawFiles, meta: meta, resolver: resolver)

            let groupSlug: String
            let displayName: String
            let confidence: ConversionConfidence
            var evidence: [String] = []
            if let existing = seed.existingGroup {
                groupSlug = existing.slug
                displayName = existing.displayName
                confidence = .strong
                evidence.append("Már létező gyűjtés és hozzárendelés.")
            } else if seed.kind == .canonical, let label = seed.label {
                groupSlug = uniqueSlug(label, used: &usedSlugs)
                displayName = label.replacingOccurrences(of: "-", with: " ")
                confidence = .strong
                evidence.append("Kanonikus captures/\(label) útvonal.")
            } else if seed.kind == .legacy, let label = seed.label {
                let lower = label.lowercased()
                let base = lower.contains("osc") ? "osc" : CaptureGroupDraft.suggestedSlug(for: label)
                groupSlug = uniqueSlug("\(base)-\(slugExposureLabel(exposureBreakdown))", used: &usedSlugs)
                displayName = lower.contains("osc") ? "OSC \(exposureLabel)" : "\(label) · \(exposureLabel)"
                confidence = .suggested
                evidence.append("Örökölt \((seed.sourcePrefix as NSString).lastPathComponent) mappanév.")
            } else {
                groupSlug = uniqueSlug("capture-\(slugExposureLabel(exposureBreakdown))", used: &usedSlugs)
                let sensorLabel = inferred.sensor == .osc ? "OSC · " : ""
                displayName = "\(sensorLabel)filter ismeretlen · \(exposureLabel)"
                confidence = .review
                evidence.append("Klasszikus lights mappa; a 120/300 s expók egy forráscsomagban maradnak.")
            }
            groupSlugBySeed[seed.key] = groupSlug
            evidence.append("Expozíció: \(exposureLabel), \(rawFiles.count) valódi frame.")
            if !artifacts.isEmpty {
                evidence.append("\(artifacts.count) feldolgozott/stack artifact nem számít nyers lightnak.")
            }

            let title = seed.existingGroup?.displayName ?? displayName
            clusters.append(
                DetectedCaptureCluster(
                    id: stableIdentifier(seed.key),
                    title: title,
                    proposedGroupSlug: groupSlug,
                    sourcePrefixes: [seed.sourcePrefix],
                    rawFramePaths: rawFiles.map(\.path),
                    artifactPaths: artifacts.map(\.path),
                    exposureBreakdown: exposureBreakdown,
                    integrationSeconds: integration,
                    totalBytes: seed.files.reduce(0) { $0 + $1.size },
                    evidence: evidence,
                    confidence: confidence
                )
            )

            if seed.existingGroup == nil {
                let sourceMappings: [ConversionSourceMapping] = seed.kind == .canonical
                    ? []
                    : [ConversionSourceMapping(relativePath: seed.sourcePrefix, role: .light)]
                proposed.append(
                    ProposedCaptureGroup(
                        draft: CaptureGroupDraft(
                            slug: groupSlug,
                            displayName: displayName,
                            sensorMode: inferred.sensor,
                            signalMode: inferred.signal,
                            filterName: inferred.filter
                        ),
                        sourceMappings: sourceMappings,
                        evidence: evidence,
                        confidence: confidence
                    )
                )
            }

            var hints = Set([normalizedHint(groupSlug), normalizedHint(displayName)])
            if let label = seed.label { hints.insert(normalizedHint(label)) }
            if groupSlug.hasPrefix("osc-") { hints.insert("osc") }
            options.append(GroupOption(slug: groupSlug, displayName: displayName, hints: hints.filter { !$0.isEmpty }))

            for file in rawFiles {
                assignmentsOut.append(
                    ConversionAssignment(
                        fileID: file.id,
                        path: file.path,
                        role: .light,
                        groupSlug: groupSlug,
                        reason: "A \(seed.sourcePrefix) valódi light frame-je."
                    )
                )
            }
            for file in artifacts {
                assignmentsOut.append(
                    ConversionAssignment(
                        fileID: file.id,
                        path: file.path,
                        role: .stack,
                        groupSlug: groupSlug,
                        reason: "Stack/derivative artifact a light forrásmappában; nem nyers expozíció."
                    )
                )
            }
        }

        var unresolvedCalibration: [FrameRole: [FileRecord]] = [:]
        var unresolvedArtifacts: [FileRecord] = []
        let auxiliary = files.filter {
            $0.role == .flat || $0.role == .dark || $0.role == .bias
                || $0.role == .stack || $0.role == .processed
        }.sorted { $0.path < $1.path }

        for file in auxiliary {
            if let slug = matchedGroupSlug(
                file: file,
                meta: file.id.flatMap { meta[$0] },
                resolver: resolver,
                groupsByID: groupsByID,
                options: options
            ) {
                assignmentsOut.append(
                    ConversionAssignment(
                        fileID: file.id,
                        path: file.path,
                        role: file.role,
                        groupSlug: slug,
                        reason: auxiliaryReason(file.role)
                    )
                )
            } else if file.role == .flat || file.role == .dark || file.role == .bias {
                unresolvedCalibration[file.role, default: []].append(file)
            } else {
                unresolvedArtifacts.append(file)
            }
        }

        var ambiguities: [ConversionAmbiguity] = []
        for role in [FrameRole.flat, .dark, .bias] {
            guard let unresolved = unresolvedCalibration[role], !unresolved.isEmpty else { continue }
            ambiguities.append(
                ConversionAmbiguity(
                    id: "calibration-\(role.rawValue)",
                    kind: .calibrationAssignment,
                    title: "A(z) \(role.rawValue) frame-ek gyűjtése nem egyértelmű",
                    explanation: "A FITS fejléc és az útvonal nem mondja meg biztosan, melyik optikai/filteres gyűjtéshez tartoznak. Válassz gyűjtést az alkalmazás előtt.",
                    affectedPaths: unresolved.map(\.path).sorted(),
                    candidateGroupSlugs: options.map(\.slug).sorted(),
                    isBlocking: true
                )
            )
        }
        if !unresolvedArtifacts.isEmpty {
            ambiguities.append(
                ConversionAmbiguity(
                    id: "artifacts",
                    kind: .artifactAssignment,
                    title: "Stack/processed eredmények kézi döntést kérnek",
                    explanation: "A név és az útvonal több gyűjtéssel is összeegyeztethető.",
                    affectedPaths: unresolvedArtifacts.map(\.path).sorted(),
                    candidateGroupSlugs: options.map(\.slug).sorted(),
                    isBlocking: true
                )
            )
        }

        var directoryCreations: [ConversionDirectoryCreation] = []
        var moves: [ConversionMove] = []
        var unchanged: [ConversionUnchangedItem] = []
        var conflicts: [ConversionConflict] = []

        if mode == .physical {
            let assignedByPath = Dictionary(uniqueKeysWithValues: assignmentsOut.map { ($0.path, $0) })
            let filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
            let occupied = occupiedPaths.union(files.map(\.path))
            var plannedDestinations = Set<String>()
            var slugsWithMoves = Set<String>()

            for assignment in assignmentsOut.sorted(by: { $0.path < $1.path }) {
                guard let file = filesByPath[assignment.path] else { continue }
                let destination = destinationPath(
                    scope: scope,
                    file: file,
                    semanticRole: assignment.role,
                    slug: assignment.groupSlug
                )
                if destination == file.path {
                    unchanged.append(
                        ConversionUnchangedItem(path: file.path, reason: "Már a kanonikus gyűjtésútvonalon található.")
                    )
                    continue
                }
                slugsWithMoves.insert(assignment.groupSlug)
                if occupied.contains(destination) || !plannedDestinations.insert(destination).inserted {
                    conflicts.append(
                        ConversionConflict(
                            path: destination,
                            message: "A célútvonal már foglalt; a konverter nem ír felül fájlt."
                        )
                    )
                }
                moves.append(
                    ConversionMove(
                        sourceRelative: file.path,
                        destinationRelative: destination,
                        sizeBytes: file.size,
                        role: assignment.role,
                        groupSlug: assignment.groupSlug,
                        reason: assignment.reason
                    )
                )
            }
            for slug in slugsWithMoves.sorted() {
                directoryCreations.append(contentsOf: canonicalDirectories(scope: scope, slug: slug).map {
                    ConversionDirectoryCreation(relativePath: $0, reason: "A(z) \(slug) kanonikus gyűjtésfája.")
                })
            }
            for file in files where assignedByPath[file.path] == nil {
                unchanged.append(
                    ConversionUnchangedItem(
                        path: file.path,
                        reason: ambiguities.contains { $0.affectedPaths.contains(file.path) }
                            ? "Kézi döntésig változatlan."
                            : "Nem capture-adat vagy nincs szükség mozgatásra."
                    )
                )
            }
        } else {
            let assignedPaths = Set(assignmentsOut.map(\.path))
            for file in files.sorted(by: { $0.path < $1.path }) {
                let reason = assignedPaths.contains(file.path)
                    ? "Csak logikai besorolás; a fájl fizikai helye nem változik."
                    : "Kézi döntésig változatlan."
                unchanged.append(ConversionUnchangedItem(path: file.path, reason: reason))
            }
        }

        let rawCount = clusters.reduce(0) { $0 + $1.rawFramePaths.count }
        let integration = clusters.reduce(0.0) { $0 + $1.integrationSeconds }
        let artifactCount = clusters.reduce(0) { $0 + $1.artifactPaths.count }
            + files.filter { $0.role == .stack || $0.role == .processed }.count
        let calibrationCount = files.filter { $0.role == .flat || $0.role == .dark || $0.role == .bias }.count
        let summary = SessionConversionSummary(
            rawFrameCount: rawCount,
            artifactCount: artifactCount,
            calibrationFrameCount: calibrationCount,
            integrationSeconds: integration,
            fileAssignmentCount: assignmentsOut.count,
            directoryCount: directoryCreations.count,
            moveCount: moves.count,
            bytesToMove: moves.reduce(0) { $0 + $1.sizeBytes },
            unchangedCount: unchanged.count
        )
        let humanSummary = "\(rawCount) nyers expozíció \(clusters.count) gyűjtési csomagban; \(stackedArtifactCount) Stacked* fájl nem nyers light. \(calibrationCount) kalibrációs frame közül \(unresolvedCalibration.values.reduce(0) { $0 + $1.count }) kér kézi döntést. \(mode == .logicalOnly ? "Fájlmozgatás nem történik." : "\(moves.count) fájl mozgatása lenne szükséges.")"

        return SessionConversionPlan(
            id: planID,
            scope: scope,
            mode: mode,
            detectedClusters: clusters,
            proposedGroups: proposed,
            assignments: assignmentsOut.sorted { $0.path < $1.path },
            directoryCreations: directoryCreations,
            moves: moves,
            unchangedItems: unchanged.sorted { $0.path < $1.path },
            ambiguities: ambiguities,
            conflicts: conflicts,
            summary: summary,
            sourceFingerprint: fingerprint,
            humanSummaryHU: humanSummary
        )
    }

    private static func validateScope(_ scope: SessionConversionScope, files: [FileRecord]) throws {
        guard !scope.target.isEmpty, !scope.date.isEmpty else {
            throw AstroError.invalidInput("A konverterhez pontos célpont és sessiondátum szükséges.")
        }
        let prefixes = [
            "sessions/\(scope.target)/\(scope.date)/",
            "stacks/\(scope.target)/\(scope.date)/",
            "processed/\(scope.target)/\(scope.date)/",
        ]
        for file in files {
            guard file.target == scope.target,
                  file.sessionDate == scope.date,
                  prefixes.contains(where: file.path.hasPrefix)
            else {
                throw AstroError.invalidInput(
                    "A(z) \(file.path) kívül esik a kiválasztott \(scope.target) / \(scope.date) sessionön."
                )
            }
        }
    }

    private static func sessionRolePrefix(_ path: String) -> String {
        path.split(separator: "/").prefix(4).joined(separator: "/")
    }

    private static func breakdown(_ files: [FileRecord], meta: [Int64: FITSMetaRecord]) -> [String: Int] {
        var result: [String: Int] = [:]
        for file in files {
            if let exposure = file.id.flatMap({ meta[$0]?.exptime }) {
                result[NominalExposure.nominal(exposure).description, default: 0] += 1
            } else {
                result["unknown", default: 0] += 1
            }
        }
        return result
    }

    private static func inferredModes(
        files: [FileRecord],
        meta: [Int64: FITSMetaRecord],
        resolver: CaptureResolver
    ) -> (sensor: SensorMode, signal: SignalMode, filter: String?) {
        let resolved = files.map { file in
            resolver.resolve(file: file, meta: file.id.flatMap { meta[$0] })
        }
        let sensors = Set(resolved.map(\.sensorMode).filter { $0 != .unknown })
        let signals = Set(resolved.map(\.signalMode).filter { $0 != .unknown })
        let filters = Set(resolved.compactMap { $0.filterName?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        return (
            sensors.count == 1 ? sensors.first! : .unknown,
            signals.count == 1 ? signals.first! : .unknown,
            filters.count == 1 ? filters.first : nil
        )
    }

    private static func humanExposureLabel(_ breakdown: [String: Int]) -> String {
        let keys = sortedExposureKeys(breakdown)
        guard !keys.isEmpty else { return "expó ismeretlen" }
        return keys.map { key in
            guard let value = Double(key) else { return "ismeretlen" }
            return value.rounded() == value ? "\(Int(value)) s" : "\(value) s"
        }.joined(separator: "/")
    }

    private static func slugExposureLabel(_ breakdown: [String: Int]) -> String {
        let keys = sortedExposureKeys(breakdown)
        guard !keys.isEmpty else { return "unknown" }
        return keys.map { key in
            guard let value = Double(key) else { return "unknown" }
            let text = value.rounded() == value ? String(Int(value)) : String(value).replacingOccurrences(of: ".", with: "p")
            return text + "s"
        }.joined(separator: "-")
    }

    private static func sortedExposureKeys(_ breakdown: [String: Int]) -> [String] {
        breakdown.keys.sorted { lhs, rhs in
            switch (Double(lhs), Double(rhs)) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs < rhs
            }
        }
    }

    private static func uniqueSlug(_ raw: String, used: inout Set<String>) -> String {
        let base = CaptureGroupDraft.suggestedSlug(for: raw).isEmpty ? "capture" : CaptureGroupDraft.suggestedSlug(for: raw)
        var candidate = base
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func matchedGroupSlug(
        file: FileRecord,
        meta: FITSMetaRecord?,
        resolver: CaptureResolver,
        groupsByID: [Int64: CaptureGroupRecord],
        options: [GroupOption]
    ) -> String? {
        let resolved = resolver.resolve(file: file, meta: meta)
        if let id = resolved.groupID, let group = groupsByID[id] { return group.slug }
        let info = PathClassifier.classify(relativePath: file.path)
        if let slug = info.captureSlug,
           let exact = options.first(where: { $0.slug.caseInsensitiveCompare(slug) == .orderedSame })
        {
            return exact.slug
        }

        let normalizedPath = normalizedHint(file.path)
        let matches = options.filter { option in
            option.hints.contains { hint in
                hint.count >= 3 && normalizedPath.contains(hint)
            }
        }
        if matches.count == 1 { return matches[0].slug }
        if matches.isEmpty, options.count == 1 { return options[0].slug }
        return nil
    }

    private static func normalizedHint(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func auxiliaryReason(_ role: FrameRole) -> String {
        switch role {
        case .flat, .dark, .bias: return "Egyértelmű gyűjtéshez rendelhető kalibrációs frame."
        case .stack: return "Útvonal- vagy névjel alapján felismert stack eredmény."
        case .processed: return "Útvonal- vagy névjel alapján felismert feldolgozott eredmény."
        default: return "Felismert gyűjtéstartozás."
        }
    }

    private static func destinationPath(
        scope: SessionConversionScope,
        file: FileRecord,
        semanticRole: FrameRole,
        slug: String
    ) -> String {
        let name = (file.path as NSString).lastPathComponent
        switch semanticRole {
        case .light, .flat, .dark, .bias:
            let roleDirectory: String
            switch semanticRole {
            case .light: roleDirectory = "lights"
            case .flat: roleDirectory = "flats"
            case .dark: roleDirectory = "darks"
            case .bias: roleDirectory = "biases"
            default: roleDirectory = "other"
            }
            return "sessions/\(scope.target)/\(scope.date)/captures/\(slug)/\(roleDirectory)/\(name)"
        case .stack:
            return "stacks/\(scope.target)/\(scope.date)/\(slug)/\(name)"
        case .processed:
            return "processed/\(scope.target)/\(scope.date)/\(slug)/\(name)"
        default:
            return file.path
        }
    }

    private static func canonicalDirectories(scope: SessionConversionScope, slug: String) -> [String] {
        ["lights", "flats", "darks", "biases"].map {
            "sessions/\(scope.target)/\(scope.date)/captures/\(slug)/\($0)"
        } + [
            "stacks/\(scope.target)/\(scope.date)/\(slug)",
            "processed/\(scope.target)/\(scope.date)/\(slug)",
        ]
    }

    private static func sourceFingerprint(_ files: [FileRecord]) -> ConversionSourceFingerprint {
        let sorted = files.sorted { $0.path < $1.path }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for file in sorted {
            let line = "\(file.path)\u{1F}\(file.size)\u{1F}\(file.mtime)\n"
            for byte in line.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 1_099_511_628_211
            }
        }
        return ConversionSourceFingerprint(
            fileCount: sorted.count,
            totalBytes: sorted.reduce(0) { $0 + $1.size },
            latestMtime: sorted.map(\.mtime).max() ?? 0,
            stableHash: String(format: "%016llx", hash)
        )
    }

    private static func stableIdentifier(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
