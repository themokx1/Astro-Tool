import Foundation

// MARK: - `<frame>.info.txt` parsing

/// Star metrics DeepSkyStacker measured for one light frame, parsed from its
/// `<frame>.info.txt` sidecar. Every field is independently `nil`-able --
/// DSS's own info files vary in which lines they include, and this parser
/// is deliberately defensive (unknown lines, missing keys, and garbage
/// content all just leave the corresponding field `nil` rather than
/// throwing).
public struct DSSInfoMetrics: Equatable, Sendable {
    public var overallQuality: Double?
    public var skyBackground: Double?
    public var nrStars: Int?
    public var meanRadius: Double?
    public var circularity: Double?
    /// Mean of `min(a, b) / max(a, b)` over every per-star `Axises = a, b`
    /// line found in the file -- a roundness-like fallback used only when
    /// `circularity` itself is absent (see `roundness`).
    public var meanAxisRatio: Double?

    public init(
        overallQuality: Double? = nil,
        skyBackground: Double? = nil,
        nrStars: Int? = nil,
        meanRadius: Double? = nil,
        circularity: Double? = nil,
        meanAxisRatio: Double? = nil
    ) {
        self.overallQuality = overallQuality
        self.skyBackground = skyBackground
        self.nrStars = nrStars
        self.meanRadius = meanRadius
        self.circularity = circularity
        self.meanAxisRatio = meanAxisRatio
    }

    /// Derived FWHM: `2 × MeanRadius` (radius -> diameter approximation --
    /// DSS reports a per-star Gaussian radius, not a diameter, so this is an
    /// approximation, not an exact conversion). `nil` when `meanRadius`
    /// itself is `nil`.
    public var fwhm: Double? { meanRadius.map { $0 * 2 } }

    /// Derived roundness (0...1, higher is rounder): `circularity` when
    /// present, else `meanAxisRatio` as a fallback, else `nil`.
    public var roundness: Double? { circularity ?? meanAxisRatio }

    public var starCount: Int? { nrStars }
}

/// Parses a DeepSkyStacker `<frame>.info.txt` sidecar's `Key = value` lines.
/// Not a strict grammar: any line that doesn't look like `key = value` is
/// silently ignored, and every recognized value is parsed defensively (a
/// malformed number just leaves that field `nil`).
public enum DSSInfoParser {
    /// Read cap -- info.txt files are always small (a handful of KB even
    /// with many per-star blocks), so a file far larger than this is either
    /// not what it claims to be or has far more per-star data than is worth
    /// scanning; capping keeps a pathological file from blowing up parse
    /// time or memory.
    public static let maxBytes = 256 * 1024

    public static func parse(data: Data) -> DSSInfoMetrics {
        let capped = data.count > maxBytes ? data.prefix(maxBytes) : data
        guard let text = String(data: Data(capped), encoding: .utf8)
            ?? String(data: Data(capped), encoding: .isoLatin1)
        else {
            return DSSInfoMetrics()
        }

        var overallQuality: Double?
        var skyBackground: Double?
        var nrStars: Int?
        var meanRadius: Double?
        var circularity: Double?
        var axisRatios: [Double] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let valueString = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "OverallQuality":
                if let v = Double(valueString) { overallQuality = v }
            case "Quality":
                // Alias, lower priority than an explicit `OverallQuality`
                // line elsewhere in the same file.
                if overallQuality == nil, let v = Double(valueString) { overallQuality = v }
            case "SkyBackground":
                if let v = Double(valueString) { skyBackground = v }
            case "NrStars":
                if let v = Int(valueString) { nrStars = v }
            case "MeanRadius":
                if let v = Double(valueString) { meanRadius = v }
            case "Circularity":
                if let v = Double(valueString) { circularity = v }
            case "Axises":
                let parts = valueString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), a > 0, b > 0 {
                    axisRatios.append(min(a, b) / max(a, b))
                }
            default:
                continue
            }
        }

        let meanAxisRatio: Double? = axisRatios.isEmpty ? nil : axisRatios.reduce(0, +) / Double(axisRatios.count)

        return DSSInfoMetrics(
            overallQuality: overallQuality,
            skyBackground: skyBackground,
            nrStars: nrStars,
            meanRadius: meanRadius,
            circularity: circularity,
            meanAxisRatio: meanAxisRatio
        )
    }
}

// MARK: - `.dssfilelist` parsing

/// One data row of a DeepSkyStacker `.dssfilelist`: `CHECKED\tTYPE\tFILE`.
public struct DSSFilelistRow: Equatable, Sendable {
    public var checked: Bool
    public var type: String
    /// Verbatim FILE field, relative to the `.dssfilelist`'s own directory
    /// -- not yet resolved against anything.
    public var relativePath: String

    public init(checked: Bool, type: String, relativePath: String) {
        self.checked = checked
        self.type = type
        self.relativePath = relativePath
    }
}

/// Parses a DeepSkyStacker `.dssfilelist`: line 1 `"DSS file list"`, line 2
/// the `CHECKED\tTYPE\tFILE` header, then one tab-separated data row per
/// tracked file. `TYPE` may be `light`, `dark`, `flat`, `bias`, or `offset`
/// -- only `light` rows carry the user's own accept/reject decision that
/// `DSSIngest` cares about.
public enum DSSFilelistParser {
    /// Every data row (line 3 onward), regardless of `TYPE` -- tolerant of
    /// CRLF line endings (each line is trimmed of surrounding whitespace,
    /// which absorbs a trailing `\r`) and blank lines.
    public static func parseRows(text: String) -> [DSSFilelistRow] {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0) }
        guard lines.count > 2 else { return [] }

        var rows: [DSSFilelistRow] = []
        for rawLine in lines.dropFirst(2) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 3 else { continue }
            let checkedText = fields[0].trimmingCharacters(in: .whitespaces)
            guard let checkedInt = Int(checkedText) else { continue }
            let type = fields[1].trimmingCharacters(in: .whitespaces)
            let path = fields[2].trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            rows.append(DSSFilelistRow(checked: checkedInt != 0, type: type, relativePath: path))
        }
        return rows
    }

    /// Every `light`-typed row (case-insensitive `TYPE` match; dark/flat/
    /// bias/offset rows are dropped), with `relativePath` resolved against
    /// `baseDir` (the `.dssfilelist`'s own root-relative directory) into a
    /// root-relative path directly comparable to `FileRecord.path`.
    /// Tolerates a Windows-style (DSS's native platform) backslash
    /// separator in the FILE field, and normalizes `.`/`..` components.
    public static func resolvedLightRows(text: String, baseDir: String) -> [(path: String, checked: Bool)] {
        parseRows(text: text)
            .filter { $0.type.caseInsensitiveCompare("light") == .orderedSame }
            .map { (resolvePath(baseDir: baseDir, relative: $0.relativePath), $0.checked) }
    }

    /// Combines `baseDir` and `relative` (normalizing `\` to `/` first),
    /// then collapses `.`/`..` components manually -- these are root-
    /// relative library paths, not real filesystem paths to hand to
    /// `URL`/`FileManager`, so a plain component-stack normalization is
    /// simpler and has no surprises around symlinks or the current
    /// directory.
    static func resolvePath(baseDir: String, relative: String) -> String {
        let normalizedRelative = relative.replacingOccurrences(of: "\\", with: "/")
        let combined = baseDir.isEmpty ? normalizedRelative : baseDir + "/" + normalizedRelative

        var stack: [String] = []
        for component in combined.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            stack.append(String(component))
        }
        return stack.joined(separator: "/")
    }
}

// MARK: - Ingest

/// Result of one `DSSIngest.ingest` run.
public struct DSSIngestSummary: Codable, Equatable, Sendable {
    public var infoFilesParsed: Int
    public var ratingsUpserted: Int
    public var filelistsParsed: Int
    public var verdictsRecorded: Int
    public var skipped: Int

    public init(
        infoFilesParsed: Int = 0,
        ratingsUpserted: Int = 0,
        filelistsParsed: Int = 0,
        verdictsRecorded: Int = 0,
        skipped: Int = 0
    ) {
        self.infoFilesParsed = infoFilesParsed
        self.ratingsUpserted = ratingsUpserted
        self.filelistsParsed = filelistsParsed
        self.verdictsRecorded = verdictsRecorded
        self.skipped = skipped
    }
}

/// Harvests star metrics and the user's own accept/reject decisions that
/// already sit in the library as DeepSkyStacker byproducts: every tracked
/// `<frame>.info.txt` sidecar (DSS writes one next to each light it
/// measured) becomes a `ratings` row with `source == "dss"`, and every
/// tracked `.dssfilelist`'s `CHECKED` column becomes a `user_verdicts` row.
/// Both walks start from `Database`, not the filesystem -- the scanner
/// already tracks every `.txt`/`.dssfilelist` file it sees (as `kind ==
/// "text"`/`"other"` respectively) as an ordinary `files` row, so finding
/// them needs no extra disk traversal. Reading each *file's own content*
/// (the info.txt's lines, the filelist's rows) does still touch disk --
/// read-only, exactly like `SensorProfiler.measure`.
public enum DSSIngest {
    private static let infoTxtSuffix = ".info.txt"
    private static let filelistSuffix = ".dssfilelist"

    @discardableResult
    public static func ingest(
        db: Database,
        config: AstroConfig,
        root: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> DSSIngestSummary {
        var summary = DSSIngestSummary()

        let allFiles = try db.allFiles(includeMissing: false)
        var byPath: [String: FileRecord] = [:]
        byPath.reserveCapacity(allFiles.count)
        for file in allFiles { byPath[file.path] = file }

        try ingestInfoFiles(allFiles: allFiles, byPath: byPath, db: db, root: root, progress: progress, summary: &summary)
        try ingestFilelists(allFiles: allFiles, byPath: byPath, db: db, root: root, progress: progress, summary: &summary)

        return summary
    }

    // MARK: - (a) info.txt -> ratings

    private static func ingestInfoFiles(
        allFiles: [FileRecord],
        byPath: [String: FileRecord],
        db: Database,
        root: URL,
        progress: (@Sendable (String) -> Void)?,
        summary: inout DSSIngestSummary
    ) throws {
        let infoFiles = allFiles.filter { $0.path.hasSuffix(infoTxtSuffix) }.sorted { $0.path < $1.path }

        for infoFile in infoFiles {
            summary.infoFilesParsed += 1
            progress?("info.txt: \(infoFile.path)")

            let lightPath = String(infoFile.path.dropLast(infoTxtSuffix.count))
            guard let lightFile = byPath[lightPath], lightFile.role == .light, let lightID = lightFile.id else {
                summary.skipped += 1
                continue
            }

            let url = root.appendingPathComponent(infoFile.path)
            guard let data = try? Data(contentsOf: url) else {
                summary.skipped += 1
                continue
            }

            let inputSig = "\(lightFile.size)-\(Int(lightFile.mtime.rounded()))"
            if let existing = try db.rating(fileID: lightID) {
                if existing.source == nil {
                    // A real astrotool/Siril rating already exists for this
                    // frame -- never clobber it with DSS-derived metrics.
                    summary.skipped += 1
                    continue
                }
                if existing.source == "dss", existing.inputSig == inputSig {
                    // Already ingested from this exact frame, unchanged.
                    summary.skipped += 1
                    continue
                }
            }

            let metrics = DSSInfoParser.parse(data: data)
            let record = RatingRecord(
                fileID: lightID,
                fwhm: metrics.fwhm,
                roundness: metrics.roundness,
                starCount: metrics.starCount,
                background: nil,
                saturatedFraction: nil,
                score: nil,
                ratedAt: Date().timeIntervalSince1970,
                sirilVersion: nil,
                inputSig: inputSig,
                source: "dss"
            )
            try db.upsertRating(record)
            summary.ratingsUpserted += 1
        }
    }

    // MARK: - (b) .dssfilelist -> user_verdicts

    private static func ingestFilelists(
        allFiles: [FileRecord],
        byPath: [String: FileRecord],
        db: Database,
        root: URL,
        progress: (@Sendable (String) -> Void)?,
        summary: inout DSSIngestSummary
    ) throws {
        let filelistFiles = allFiles.filter { $0.path.hasSuffix(filelistSuffix) }.sorted { $0.path < $1.path }

        for listFile in filelistFiles {
            summary.filelistsParsed += 1
            progress?(".dssfilelist: \(listFile.path)")

            let url = root.appendingPathComponent(listFile.path)
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else {
                summary.skipped += 1
                continue
            }

            let baseDir = (listFile.path as NSString).deletingLastPathComponent
            let rows = DSSFilelistParser.resolvedLightRows(text: text, baseDir: baseDir)

            for row in rows {
                guard let file = byPath[row.path], let fileID = file.id else {
                    summary.skipped += 1
                    continue
                }
                try db.upsertUserVerdict(
                    UserVerdictRecord(
                        fileID: fileID,
                        accepted: row.checked,
                        source: "dssfilelist",
                        recordedAt: Date().timeIntervalSince1970
                    )
                )
                summary.verdictsRecorded += 1
            }
        }
    }
}
