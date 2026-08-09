import Foundation

/// One capture group's operational roll-up inside a single target/date
/// session. The classic session remains the aggregate boundary; these rows
/// expose the physically meaningful sub-collections below it.
public struct CaptureGroupSummary: Codable, Equatable, Sendable, Identifiable {
    public var groupID: Int64?
    public var slug: String?
    public var displayName: String
    public var isImplicit: Bool
    public var sensorModes: [SensorMode]
    public var signalModes: [SignalMode]
    public var filters: [String]
    public var rawLightCount: Int
    public var usableLightCount: Int
    public var rejectedCount: Int
    public var duplicateLinkCount: Int
    public var artifactCount: Int
    public var flatCount: Int
    public var darkCount: Int
    public var biasCount: Int
    public var stackCount: Int
    public var processedCount: Int
    public var integrationSeconds: Double
    public var exposureBreakdown: [String: Int]
    public var cameras: [String]
    public var metadataConflictCount: Int

    public var id: String { groupID.map(String.init) ?? "implicit" }

    public init(
        groupID: Int64? = nil,
        slug: String? = nil,
        displayName: String,
        isImplicit: Bool,
        sensorModes: [SensorMode] = [],
        signalModes: [SignalMode] = [],
        filters: [String] = [],
        rawLightCount: Int = 0,
        usableLightCount: Int = 0,
        rejectedCount: Int = 0,
        duplicateLinkCount: Int = 0,
        artifactCount: Int = 0,
        flatCount: Int = 0,
        darkCount: Int = 0,
        biasCount: Int = 0,
        stackCount: Int = 0,
        processedCount: Int = 0,
        integrationSeconds: Double = 0,
        exposureBreakdown: [String: Int] = [:],
        cameras: [String] = [],
        metadataConflictCount: Int = 0
    ) {
        self.groupID = groupID
        self.slug = slug
        self.displayName = displayName
        self.isImplicit = isImplicit
        self.sensorModes = sensorModes
        self.signalModes = signalModes
        self.filters = filters
        self.rawLightCount = rawLightCount
        self.usableLightCount = usableLightCount
        self.rejectedCount = rejectedCount
        self.duplicateLinkCount = duplicateLinkCount
        self.artifactCount = artifactCount
        self.flatCount = flatCount
        self.darkCount = darkCount
        self.biasCount = biasCount
        self.stackCount = stackCount
        self.processedCount = processedCount
        self.integrationSeconds = integrationSeconds
        self.exposureBreakdown = exposureBreakdown
        self.cameras = cameras
        self.metadataConflictCount = metadataConflictCount
    }
}

/// Read-only capture-group reporting. All metadata and assignments are
/// preloaded in batches, so a session with thousands of files does not turn
/// into one SQLite lookup per frame.
public enum CaptureQueries {
    public static func summaries(
        target: String,
        date: String,
        db: Database,
        config: AstroConfig
    ) throws -> [CaptureGroupSummary] {
        let files = try db.allFiles(includeMissing: false).filter {
            $0.target == target && $0.sessionDate == date
                && ($0.area == .sessions || $0.area == .stacks || $0.area == .processed)
        }
        let meta = try db.fitsMetaBatch(fileIDs: files.compactMap(\.id))
        let resolver = try CaptureResolver.load(db: db)
        let groups = try db.captureGroups(target: target, date: date)
        return summarize(files: files, meta: meta, resolver: resolver, groups: groups, config: config)
    }

    static func summarize(
        files: [FileRecord],
        meta: [Int64: FITSMetaRecord],
        resolver: CaptureResolver,
        groups: [CaptureGroupRecord],
        config: AstroConfig
    ) -> [CaptureGroupSummary] {
        enum BucketKey: Hashable {
            case group(Int64)
            case implicit
        }

        struct Builder {
            var summary: CaptureGroupSummary
            var sensorModes = Set<SensorMode>()
            var signalModes = Set<SignalMode>()
            var filters = Set<String>()
            var cameras = Set<String>()
            var lightFiles: [FileRecord] = []
        }

        let groupsByID = Dictionary(uniqueKeysWithValues: groups.compactMap { group in
            group.id.map { ($0, group) }
        })
        func key(for resolved: ResolvedCaptureMetadata) -> BucketKey {
            if let id = resolved.groupID, groupsByID[id] != nil { return .group(id) }
            return .implicit
        }

        var builders: [BucketKey: Builder] = [:]
        for group in groups {
            guard let id = group.id else { continue }
            var builder = Builder(
                summary: CaptureGroupSummary(
                    groupID: id,
                    slug: group.slug,
                    displayName: group.displayName,
                    isImplicit: false
                )
            )
            if group.sensorMode != .unknown { builder.sensorModes.insert(group.sensorMode) }
            if group.signalMode != .unknown { builder.signalModes.insert(group.signalMode) }
            if let filter = group.filterLabel { builder.filters.insert(filter) }
            builders[.group(id)] = builder
        }

        var resolvedByPath: [String: ResolvedCaptureMetadata] = [:]
        for file in files {
            guard file.role == .light || file.role == .flat || file.role == .dark
                    || file.role == .bias || file.role == .stack || file.role == .processed
            else { continue }
            let fileMeta = file.id.flatMap { meta[$0] }
            let resolved = resolver.resolve(file: file, meta: fileMeta)
            resolvedByPath[file.path] = resolved
            let bucketKey = key(for: resolved)
            if builders[bucketKey] == nil {
                builders[bucketKey] = Builder(
                    summary: CaptureGroupSummary(
                        displayName: "Nincs gyűjtéshez rendelve",
                        isImplicit: true
                    )
                )
            }

            var builder = builders[bucketKey]!
            if resolved.sensorMode != .unknown { builder.sensorModes.insert(resolved.sensorMode) }
            if resolved.signalMode != .unknown { builder.signalModes.insert(resolved.signalMode) }
            if let label = resolvedFilterLabel(resolved) { builder.filters.insert(label) }
            builder.summary.metadataConflictCount += resolved.conflicts.count

            switch file.role {
            case .light:
                builder.summary.rawLightCount += 1
                builder.lightFiles.append(file)
            case .flat: builder.summary.flatCount += 1
            case .dark: builder.summary.darkCount += 1
            case .bias: builder.summary.biasCount += 1
            case .stack:
                builder.summary.stackCount += 1
                builder.summary.artifactCount += 1
            case .processed:
                builder.summary.processedCount += 1
                builder.summary.artifactCount += 1
            default: break
            }
            builders[bucketKey] = builder
        }

        let allLights = files.filter { $0.area == .sessions && $0.role == .light }
        let globalBuckets = FrameSet.lightBuckets(files: allLights, meta: meta, config: config)

        func addFrame(_ file: FileRecord, rejected: Bool) {
            let resolved = resolvedByPath[file.path] ?? resolver.resolve(
                file: file,
                meta: file.id.flatMap { meta[$0] }
            )
            let bucketKey = key(for: resolved)
            guard var builder = builders[bucketKey] else { return }
            if rejected {
                builder.summary.rejectedCount += 1
            } else {
                builder.summary.usableLightCount += 1
                if let fileMeta = file.id.flatMap({ meta[$0] }) {
                    if let exptime = fileMeta.exptime {
                        builder.summary.integrationSeconds += exptime
                        builder.summary.exposureBreakdown[
                            NominalExposure.nominal(exptime).description,
                            default: 0
                        ] += 1
                    } else {
                        builder.summary.exposureBreakdown["unknown", default: 0] += 1
                    }
                    if let camera = nonBlank(fileMeta.instrume) { builder.cameras.insert(camera) }
                } else {
                    builder.summary.exposureBreakdown["unknown", default: 0] += 1
                }
            }
            builders[bucketKey] = builder
        }

        for file in globalBuckets.usable { addFrame(file, rejected: false) }
        for file in globalBuckets.rejected { addFrame(file, rejected: true) }

        for bucketKey in Array(builders.keys) {
            guard var builder = builders[bucketKey] else { continue }
            let localBuckets = FrameSet.lightBuckets(files: builder.lightFiles, meta: meta, config: config)
            builder.summary.artifactCount += localBuckets.nonFrameFileCount
            builder.summary.duplicateLinkCount = max(
                0,
                builder.summary.rawLightCount
                    - localBuckets.nonFrameFileCount
                    - builder.summary.usableLightCount
                    - builder.summary.rejectedCount
            )
            builder.summary.sensorModes = builder.sensorModes.sorted { $0.rawValue < $1.rawValue }
            builder.summary.signalModes = builder.signalModes.sorted { $0.rawValue < $1.rawValue }
            builder.summary.filters = builder.filters.sorted()
            builder.summary.cameras = builder.cameras.sorted()
            builders[bucketKey] = builder
        }

        let explicit = groups.compactMap { group -> CaptureGroupSummary? in
            guard let id = group.id else { return nil }
            return builders[.group(id)]?.summary
        }
        let implicit = builders[.implicit].map { [$0.summary] } ?? []
        return explicit + implicit
    }

    private static func resolvedFilterLabel(_ metadata: ResolvedCaptureMetadata) -> String? {
        let makeAndModel = [nonBlank(metadata.filterManufacturer), nonBlank(metadata.filterModel)]
            .compactMap { $0 }
            .joined(separator: " ")
        let name = nonBlank(metadata.filterName)
        if !makeAndModel.isEmpty, let name,
           normalized(makeAndModel) != normalized(name)
        {
            return "\(makeAndModel) \(name)"
        }
        if !makeAndModel.isEmpty { return makeAndModel }
        return name
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
