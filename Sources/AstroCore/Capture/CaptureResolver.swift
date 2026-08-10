import Foundation

/// Resolves capture membership and metadata from one preloaded snapshot.
/// Callers that process many files load once, avoiding an N+1 database query
/// pattern across quality/stat/report tables.
public struct CaptureResolver: Sendable {
    private let groupsByID: [Int64: CaptureGroupRecord]
    private let groupsByScopeSlug: [String: CaptureGroupRecord]
    private let sources: [CaptureSourceRecord]
    private let assignments: [Int64: FileCaptureAssignmentRecord]

    public init(
        groups: [CaptureGroupRecord],
        sources: [CaptureSourceRecord],
        assignments: [Int64: FileCaptureAssignmentRecord]
    ) {
        self.groupsByID = Dictionary(uniqueKeysWithValues: groups.compactMap { group in
            group.id.map { ($0, group) }
        })
        self.groupsByScopeSlug = Dictionary(uniqueKeysWithValues: groups.map { group in
            (Self.scopeKey(target: group.target, date: group.sessionDate, slug: group.slug), group)
        })
        // Longest prefix wins, so a specific nested source can deliberately
        // override a broader legacy mapping.
        self.sources = sources.sorted {
            if $0.relativePath.count != $1.relativePath.count {
                return $0.relativePath.count > $1.relativePath.count
            }
            return $0.relativePath < $1.relativePath
        }
        self.assignments = assignments
    }

    public static func load(db: Database) throws -> CaptureResolver {
        try CaptureResolver(
            groups: db.allCaptureGroups(),
            sources: db.allCaptureSources(),
            assignments: db.allFileCaptureAssignments()
        )
    }

    public func resolve(file: FileRecord, meta: FITSMetaRecord?) -> ResolvedCaptureMetadata {
        let pathInfo = PathClassifier.classify(relativePath: file.path)
        let assignment = file.id.flatMap { assignments[$0] }
        var conflicts: [String] = []

        let canonicalGroup: CaptureGroupRecord? = {
            guard let target = file.target, let date = file.sessionDate, let slug = pathInfo.captureSlug else {
                return nil
            }
            return groupsByScopeSlug[Self.scopeKey(target: target, date: date, slug: slug)]
        }()

        let sourceGroup: CaptureGroupRecord? = {
            guard let source = sources.first(where: {
                $0.role == file.role && Self.path(file.path, isAtOrBelow: $0.relativePath)
            }) else { return nil }
            return groupsByID[source.captureGroupID]
        }()

        if let canonicalID = canonicalGroup?.id, let sourceID = sourceGroup?.id, canonicalID != sourceID {
            conflicts.append("A kanonikus capture-mappa és a mappaforrás eltérő gyűjtésre mutat.")
        }

        let group: CaptureGroupRecord? = {
            if let assignment {
                guard let assigned = groupsByID[assignment.captureGroupID] else {
                    conflicts.append("A fájl hozzárendelése nem létező gyűjtésre mutat.")
                    return canonicalGroup ?? sourceGroup
                }
                if assigned.target != file.target || assigned.sessionDate != file.sessionDate {
                    conflicts.append("A kézi hozzárendelés másik célpont vagy session gyűjtésére mutat.")
                }
                return assigned
            }
            return canonicalGroup ?? sourceGroup
        }()

        let legacyLabel = pathInfo.legacyCaptureLabel
        let fitsSensor = Self.sensorMode(from: meta)
        let fitsFilter = Self.nonBlank(meta?.filter)
        let fitsSignal = fitsFilter.flatMap(Self.signalMode(fromFilter:))

        var sensorMode: SensorMode = .unknown
        var sensorOrigin: CaptureMetadataOrigin = .unknown
        if let override = assignment?.sensorModeOverride {
            sensorMode = override
            sensorOrigin = .manualOverride
        } else if let group, group.sensorMode != .unknown {
            sensorMode = group.sensorMode
            sensorOrigin = .captureGroup
        } else if let fitsSensor {
            sensorMode = fitsSensor
            sensorOrigin = .fitsHeader
        } else if legacyLabel?.localizedCaseInsensitiveContains("osc") == true {
            sensorMode = .osc
            sensorOrigin = .pathInference
        }

        if let fitsSensor, sensorOrigin == .captureGroup, fitsSensor != sensorMode {
            conflicts.append("A FITS Bayer/szenzor adata és a gyűjtés szenzormódja eltér.")
        }

        var signalMode: SignalMode = .unknown
        var signalOrigin: CaptureMetadataOrigin = .unknown
        if let override = assignment?.signalModeOverride {
            signalMode = override
            signalOrigin = .manualOverride
        } else if let group, group.signalMode != .unknown {
            signalMode = group.signalMode
            signalOrigin = .captureGroup
        } else if let fitsSignal {
            signalMode = fitsSignal
            signalOrigin = .fitsHeader
        }

        let explicitNoFilter = assignment?.signalModeOverride == .unfiltered
        let manualFilterPresent = explicitNoFilter || [
            assignment?.filterManufacturerOverride,
            assignment?.filterModelOverride,
            assignment?.filterNameOverride,
        ].contains { Self.nonBlank($0) != nil }
        let groupFilterPresent = group?.filterLabel != nil

        var filterManufacturer: String?
        var filterModel: String?
        var filterName: String?
        var filterOrigin: CaptureMetadataOrigin = .unknown
        if manualFilterPresent {
            if !explicitNoFilter {
                filterManufacturer = Self.nonBlank(assignment?.filterManufacturerOverride) ?? Self.nonBlank(group?.filterManufacturer)
                filterModel = Self.nonBlank(assignment?.filterModelOverride) ?? Self.nonBlank(group?.filterModel)
                filterName = Self.nonBlank(assignment?.filterNameOverride) ?? Self.nonBlank(group?.filterName)
            }
            filterOrigin = .manualOverride
        } else if groupFilterPresent {
            filterManufacturer = Self.nonBlank(group?.filterManufacturer)
            filterModel = Self.nonBlank(group?.filterModel)
            filterName = Self.nonBlank(group?.filterName)
            filterOrigin = .captureGroup
        } else if let fitsFilter {
            filterName = fitsFilter
            filterOrigin = .fitsHeader
        }

        if let fitsFilter, filterOrigin == .captureGroup || filterOrigin == .manualOverride {
            let resolvedLabel = CaptureFilterLabel.make(
                manufacturer: filterManufacturer, model: filterModel, name: filterName
            )
            if let resolvedLabel, !Self.sameNormalizedText(resolvedLabel, fitsFilter) {
                conflicts.append("A FITS FILTER (\(fitsFilter)) és a feloldott filter (\(resolvedLabel)) eltér.")
            }
        }
        if let fitsSignal, signalOrigin == .captureGroup, fitsSignal != signalMode {
            conflicts.append("A FITS filterből következő fénysáv és a gyűjtés fénysávja eltér.")
        }

        return ResolvedCaptureMetadata(
            groupID: group?.id,
            slug: group?.slug,
            displayName: group?.displayName ?? legacyLabel,
            sensorMode: sensorMode,
            signalMode: signalMode,
            filterManufacturer: filterManufacturer,
            filterModel: filterModel,
            filterName: filterName,
            sensorOrigin: sensorOrigin,
            signalOrigin: signalOrigin,
            filterOrigin: filterOrigin,
            conflicts: conflicts
        )
    }

    private static func scopeKey(target: String, date: String, slug: String) -> String {
        "\(target)\u{1F}\(date)\u{1F}\(slug)"
    }

    private static func path(_ path: String, isAtOrBelow prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sensorMode(from meta: FITSMetaRecord?) -> SensorMode? {
        guard let json = meta?.headerJSON,
              let data = json.data(using: .utf8),
              let cards = try? JSONDecoder().decode([String: String].self, from: data),
              let rawPattern = cards["BAYERPAT"]
        else { return nil }

        let pattern = rawPattern
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"")))
            .lowercased()
        guard !pattern.isEmpty else { return nil }
        if pattern == "mono" || pattern == "none" { return .mono }
        return .osc
    }

    private static func signalMode(fromFilter rawFilter: String) -> SignalMode? {
        let filter = rawFilter.lowercased()
        let dualBandMarkers = ["l-extreme", "l-ultimate", "l-enhance", "dual", "sv220"]
        if dualBandMarkers.contains(where: filter.contains) { return .dualBand }

        let narrowbandMarkers = ["h-alpha", "halpha", "ha ", "ha-", "oiii", "o3", "sii", "s2", "narrow"]
        if narrowbandMarkers.contains(where: filter.contains) { return .narrowband }

        let broadbandMarkers = ["uv/ir", "uv-ir", "uv ir", "l-pro", "cls", "broadband"]
        if broadbandMarkers.contains(where: filter.contains) { return .broadband }
        return nil
    }

    private static func sameNormalizedText(_ lhs: String, _ rhs: String) -> Bool {
        func normalize(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        return normalize(lhs) == normalize(rhs)
    }
}
