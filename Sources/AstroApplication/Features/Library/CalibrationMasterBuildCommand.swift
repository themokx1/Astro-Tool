import AstroCore
import Foundation

/// Read-only preview of what a `CalibrationMasterBuildCommand.buildDarkMaster`
/// call for one dark `CalibNeed` would actually do -- always available
/// regardless of `LibraryAccessMode`, same "plan first, apply separately"
/// shape `CalibrationLinkCommand.plan`/`.apply` already use. The UI
/// (`CalibrationView`'s "Build Master…" sheet) reads this to decide whether
/// to enable the build action at all and, if not, to show the SAME honest
/// reason inline rather than only discovering it after a failed attempt.
public struct CalibrationMasterBuildPreview: Equatable, Sendable {
    public let exposureSeconds: Double
    public let tempC: Double?
    public let sourceFrameCount: Int
    public let minimumFrameCount: Int
    /// Non-empty when the matching source darks are NOT electronically
    /// homogeneous (`CalibAnalyzer.darkMasterSources`'s own doc comment) --
    /// mutually exclusive with a `sourceFrameCount` that would otherwise be
    /// enough to build.
    public let mismatchReasons: [String]
    public let sirilAvailable: Bool
    public let autoBuildEnabled: Bool

    public init(
        exposureSeconds: Double,
        tempC: Double?,
        sourceFrameCount: Int,
        minimumFrameCount: Int,
        mismatchReasons: [String],
        sirilAvailable: Bool,
        autoBuildEnabled: Bool
    ) {
        self.exposureSeconds = exposureSeconds
        self.tempC = tempC
        self.sourceFrameCount = sourceFrameCount
        self.minimumFrameCount = minimumFrameCount
        self.mismatchReasons = mismatchReasons
        self.sirilAvailable = sirilAvailable
        self.autoBuildEnabled = autoBuildEnabled
    }

    /// `true` exactly when `buildDarkMaster` would actually attempt a build
    /// for this combo (still subject to `LibraryAccessMode.mutationEnabled`,
    /// which this preview does not know about -- the caller layers that gate
    /// on top, same as `CalibrationLinkCommand.apply`'s own `accessMode`
    /// check happening only at apply time, never at plan time).
    public var canBuild: Bool {
        sirilAvailable && autoBuildEnabled && mismatchReasons.isEmpty && sourceFrameCount >= minimumFrameCount
    }
}

public struct CalibrationMasterBuildReceipt: Equatable, Sendable {
    public let masterPath: String
    public let sourceFrameCount: Int

    public init(masterPath: String, sourceFrameCount: Int) {
        self.masterPath = masterPath
        self.sourceFrameCount = sourceFrameCount
    }
}

/// Every honest way `buildDarkMaster` can fail without ever leaving a
/// half-written master behind -- deliberately not `AstroError` (adapter-
/// internal failure modes, same reasoning as `SirilCLI.ProcessError`'s own
/// doc comment).
public enum CalibrationMasterBuildError: Error, Equatable, Sendable {
    case insufficientFrames(have: Int, minimum: Int)
    case heterogeneousSources(reasons: [String])
    /// The combo has no temperature at all (`CalibNeed.tempC == nil`) -- the
    /// `calibration_library/darks/<exp>sec_<temp>deg` directory grammar
    /// (`CalibAnalyzer.parseMasterDirName`) has no slot for a temperature-
    /// less master, so there is nowhere honest to place one.
    case noTemperature
    case autoBuildDisabled
    case sirilUnavailable(path: String)
    /// `SirilMasterBuilder.BuildError`'s own description, carried through
    /// verbatim -- see that type's doc comment for why its own subprocess
    /// failures are never re-derived here.
    case buildFailed(String)
}

/// Queues a Siril-backed master-dark build for one `CalibAnalyzer.coverage()`
/// gap and writes the result into `calibration_library/darks/`, gated on
/// `LibraryAccessMode.mutationEnabled` AND `AstroConfig.CalibRule
/// .autoMasterBuildEnabled` (the Wave 0 seam this feature was built to fill --
/// see that field's own doc comment). Never bypasses `WriteGuard` and never
/// re-derives `CalibAnalyzer`'s own matching/grouping logic.
///
/// V1 scope (this command): DARK masters only, matching `CalibAnalyzer
/// .coverage()`'s own dark-only v1 scope and this feature's own spec risk
/// mitigation ("az első verzió induljon csak azokra a kombinációkra, ahol a
/// bemenet homogén") -- flat/bias master building is deliberately deferred;
/// `SirilMasterBuilder` itself is already kind-agnostic for whenever that
/// lands.
public struct CalibrationMasterBuildCommand: Sendable {
    private let db: Database
    private let config: AstroConfig
    private let root: URL
    private let accessMode: LibraryAccessMode
    /// The actual Siril-stacking call, injected as a closure (not a
    /// `SirilMasterBuilder` factory) specifically so tests can substitute a
    /// fake that never shells out to a real `siril-cli` binary --
    /// `CalibrationMasterBuildCommandTests` exercises every honest failure
    /// state (insufficient/heterogeneous sources, disabled gates, a build
    /// that never produces its output file) without needing Siril installed
    /// on the test machine, the same "inject the boundary, not the concrete
    /// type" shape `CommandFactory`/`metadataFactory` already use elsewhere
    /// in this module.
    private let masterBuilder: @Sendable (_ kind: FrameRole, _ sourceURLs: [URL], _ workDir: URL) throws -> URL
    private let now: @Sendable () -> Date

    public init(
        db: Database,
        config: AstroConfig,
        root: URL,
        accessMode: LibraryAccessMode,
        masterBuilder: @escaping @Sendable (_ kind: FrameRole, _ sourceURLs: [URL], _ workDir: URL) throws -> URL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.db = db
        self.config = config
        self.root = root
        self.accessMode = accessMode
        self.masterBuilder = masterBuilder
        self.now = now
    }

    public static func production(rootURL: URL, accessMode: LibraryAccessMode) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        let database = try Database(path: storage.indexDatabase.path)
        let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
        var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
        config.rootPath = rootURL.path
        let sirilPath = config.rating.sirilPath
        return Self(
            db: database, config: config, root: rootURL, accessMode: accessMode,
            masterBuilder: { kind, sourceURLs, workDir in
                try SirilMasterBuilder(path: sirilPath).buildMaster(kind: kind, sourceURLs: sourceURLs, workDir: workDir)
            }
        )
    }

    /// Builds the preview for one dark `CalibNeed` -- always available,
    /// even in `.readOnly` mode; nothing is written by this call.
    public func preview(need: CalibNeed) throws -> CalibrationMasterBuildPreview {
        let selection = try CalibAnalyzer.darkMasterSources(
            exposureSeconds: need.exposureSeconds, tempC: need.tempC, db: db
        )
        let sirilAvailable = FileManager.default.isExecutableFile(atPath: config.rating.sirilPath)
        return CalibrationMasterBuildPreview(
            exposureSeconds: need.exposureSeconds,
            tempC: need.tempC,
            sourceFrameCount: selection.files.count,
            minimumFrameCount: SirilMasterBuilder.minimumFrameCount,
            mismatchReasons: selection.mismatchReasons,
            sirilAvailable: sirilAvailable,
            autoBuildEnabled: config.calib.autoMasterBuildEnabled
        )
    }

    /// Builds and installs a dark master for `need`. Throws
    /// `LibraryMutationError.readOnly` immediately (before any Siril call or
    /// filesystem access) unless `accessMode == .mutationEnabled`, and
    /// `CalibrationMasterBuildError.autoBuildDisabled` unless the owner has
    /// separately opted into `CalibRule.autoMasterBuildEnabled` -- two
    /// independent gates, neither one sufficient alone, matching this
    /// feature's own "no V3 feature turns writing on by itself" iron rule.
    ///
    /// Never leaves a partial/corrupt master in `calibration_library/`: the
    /// Siril build happens entirely inside a private scratch `workDir`
    /// (cleaned up on every exit path), and the ONLY write into the real
    /// library is `WriteGuard.writeCalibrationMaster`'s own temp+rename
    /// atomic move, which itself never overwrites an existing file. On
    /// success, the new master's own `calibration_library/darks/<dir>`
    /// subtree is rescanned (`LibraryScanner.scan(subpath:)`) so
    /// `CalibAnalyzer.coverage()` sees it on the very next read -- this
    /// feature's own "the gap list is the only source of truth, there is no
    /// separate 'done' flag" rule.
    @discardableResult
    public func buildDarkMaster(need: CalibNeed) throws -> CalibrationMasterBuildReceipt {
        guard accessMode == .mutationEnabled else { throw LibraryMutationError.readOnly }
        guard config.calib.autoMasterBuildEnabled else { throw CalibrationMasterBuildError.autoBuildDisabled }
        guard let tempC = need.tempC else { throw CalibrationMasterBuildError.noTemperature }

        let selection = try CalibAnalyzer.darkMasterSources(exposureSeconds: need.exposureSeconds, tempC: tempC, db: db)
        guard selection.mismatchReasons.isEmpty else {
            throw CalibrationMasterBuildError.heterogeneousSources(reasons: selection.mismatchReasons)
        }
        guard selection.files.count >= SirilMasterBuilder.minimumFrameCount else {
            throw CalibrationMasterBuildError.insufficientFrames(
                have: selection.files.count, minimum: SirilMasterBuilder.minimumFrameCount
            )
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("astro-calib-build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let sourceURLs = selection.files.map { root.appendingPathComponent($0.path) }
        let producedURL: URL
        do {
            producedURL = try masterBuilder(.dark, sourceURLs, workDir)
        } catch AstroError.sirilNotFound {
            throw CalibrationMasterBuildError.sirilUnavailable(path: config.rating.sirilPath)
        } catch {
            throw CalibrationMasterBuildError.buildFailed(String(describing: error))
        }

        let dirName = "\(Self.formatted(need.exposureSeconds))sec_\(Self.formatted(tempC))deg"
        let timestamp = Self.timestampFormatter.string(from: now())
        let fileName = "MasterDark_\(Self.formatted(need.exposureSeconds))s_\(Self.formatted(tempC))C_\(timestamp).\(producedURL.pathExtension)"
        let destRelative = "calibration_library/darks/\(dirName)/\(fileName)"

        let writeGuard = WriteGuard(root: root)
        guard try writeGuard.writeCalibrationMaster(destRelative: destRelative, tempURL: producedURL) != nil else {
            // A file already sits at this exact destination -- collides only
            // if the same combo is built twice within the same second, an
            // effectively impossible race for a manual button click. Honest
            // failure rather than silently overwriting or claiming success.
            throw CalibrationMasterBuildError.buildFailed("destination already exists: \(destRelative)")
        }

        // Rescan just the new master's own subtree so `CalibAnalyzer
        // .coverage()` picks it up immediately -- see this method's own doc
        // comment.
        let scanner = LibraryScanner(config: config, db: db)
        _ = try? scanner.scan(subpath: "calibration_library/darks/\(dirName)")

        return CalibrationMasterBuildReceipt(masterPath: destRelative, sourceFrameCount: selection.files.count)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func formatted(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
