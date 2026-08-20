import AstroApplication
import Darwin
import Foundation

public enum V2UITestFixtureError: Error, Equatable, Sendable, LocalizedError {
    case missingArgumentValue(String)
    case incompleteConfiguration
    case nonTemporaryLibrary(String)
    case overlappingRoots
    case fixtureAlreadyExists(String)
    case rootIdentityChanged(String)

    public var errorDescription: String? {
        switch self {
        case .missingArgumentValue(let argument):
            "UI-test fixture argument has no value: \(argument)"
        case .incompleteConfiguration:
            "UI-test fixture mode requires both -UITestFixtureRoot and -UITestAppSupport."
        case .nonTemporaryLibrary(let path):
            "UI-test fixture mode refused a real or non-temporary library path: \(path)"
        case .overlappingRoots:
            "UI-test fixture and application-support roots must be separate temporary directories."
        case .fixtureAlreadyExists(let path):
            "UI-test fixture mode refuses to reuse an existing fixture: \(path)"
        case .rootIdentityChanged(let path):
            "UI-test fixture root changed after it was pinned: \(path)"
        }
    }
}

public struct V2UITestFixture: Sendable {
    public let libraryRoot: URL
    public let applicationSupport: URL
    public let caches: URL

    public func makeMetadataStore() throws -> MetadataStore {
        let identity = LibraryIdentity(rootURL: libraryRoot)
        let storage = try AppStoragePaths(
            applicationSupport: applicationSupport,
            caches: caches,
            libraryID: identity,
            libraryRoot: libraryRoot
        )
        return try MetadataStore(storagePaths: storage)
    }

    public func seedReviewMetadata() async throws {
        let metadata = try makeMetadataStore()
        let project = ProjectRecord(
            id: UUID(uuidString: "13960000-0000-5000-8000-000000000001")!,
            catalogID: "IC 1396",
            displayName: "IC 1396 · Elefántormány-köd",
            phase: .collecting
        )
        let night = NightRecord(
            id: UUID(uuidString: "13960000-0000-5000-8000-000000000002")!,
            localDate: "2026-08-08",
            timeZoneID: "Europe/Budapest"
        )
        let exposures = [30.0, 120.0, 300.0]
        let series = exposures.enumerated().map { index, exposure in
            SeriesRecord(
                id: UUID(uuidString: String(format: "13960000-0000-5000-8000-%012d", index + 10))!,
                projectID: project.id,
                nightID: night.id,
                setupID: "asi2600mc-261",
                setupDescriptor: "ZWO ASI2600MC Pro · 261 mm",
                sensorMode: .osc,
                passband: exposure == 30 ? .broadband : .dualBand,
                exposureSeconds: exposure,
                filterName: exposure == 30 ? nil : "SV220",
                filterID: exposure == 30 ? nil : "svbony-sv220",
                gain: 100,
                offset: 50,
                binning: "1x1"
            )
        }
        var decisions: [FrameDecisionRecord] = []
        for (seriesIndex, item) in series.enumerated() {
            for frameIndex in 1...3 {
                decisions.append(FrameDecisionRecord(
                    id: UUID(uuidString: String(
                        format: "13960000-0000-5000-8%03d-%012d",
                        seriesIndex,
                        frameIndex
                    ))!,
                    seriesID: item.id,
                    relativePath: "sessions/IC_1396/2026-08-08/lights/frame_\(Int(item.exposureSeconds))s_\(frameIndex).fit",
                    verdict: frameIndex == 3 ? .rejected : .undecided,
                    logicallyExcluded: frameIndex == 3
                ))
            }
        }
        try await metadata.save(MetadataWriteBatch(
            projects: [project], nights: [night], series: series, frameDecisions: decisions
        ))
    }

    @MainActor
    public func makeOnboardingStore() -> OnboardingStore {
        let identity = LibraryIdentity(rootURL: libraryRoot)
        let snapshot = LibrarySnapshot(
            libraryID: identity,
            revision: 1,
            projectCount: 1,
            nightCount: 1,
            frameCount: 1
        )
        return OnboardingStore(
            sessionFactory: OnboardingSessionFactory { root, _ in
                guard LibraryIdentity(rootURL: root) == identity else {
                    throw V2UITestSessionError.unexpectedLibrary(root.path)
                }
                return OnboardingSessionClient(accessMode: .readOnly) { progress in
                    progress(LibraryScanProgress(scanned: 0, total: 1))
                    progress(LibraryScanProgress(scanned: 1, total: 1))
                    return snapshot
                }
            },
            storageFactory: OnboardingStorageFactory { root in
                try AppStoragePaths(
                    applicationSupport: applicationSupport,
                    caches: caches,
                    libraryID: LibraryIdentity(rootURL: root),
                    libraryRoot: root
                )
            },
            securityScopedAccess: .inactive,
            bookmarkStore: .inactive
        )
    }
}

private enum V2UITestSessionError: Error, Sendable {
    case unexpectedLibrary(String)
}

public enum V2PreviewFixtures {
    private static let fixtureRootArgument = "-UITestFixtureRoot"
    private static let appSupportArgument = "-UITestAppSupport"

    public static func fixture(
        arguments: [String],
        fileManager: FileManager = .default
    ) throws -> V2UITestFixture? {
        try fixture(
            arguments: arguments,
            fileManager: fileManager,
            beforeMutation: { _, _ in }
        )
    }

    static func fixture(
        arguments: [String],
        fileManager: FileManager = .default,
        beforeMutation: (URL, URL) throws -> Void
    ) throws -> V2UITestFixture? {
        let fixtureContainer = try argumentValue(
            fixtureRootArgument,
            in: arguments
        )
        let supportContainer = try argumentValue(
            appSupportArgument,
            in: arguments
        )

        guard fixtureContainer != nil || supportContainer != nil else { return nil }
        guard let fixtureContainer, let supportContainer else {
            throw V2UITestFixtureError.incompleteConfiguration
        }

        return try makeFixture(
            fixtureContainer: URL(fileURLWithPath: fixtureContainer, isDirectory: true),
            supportContainer: URL(fileURLWithPath: supportContainer, isDirectory: true),
            fileManager: fileManager,
            beforeMutation: beforeMutation
        )
    }

    public static func currentOrTerminate(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        fileManager: FileManager = .default
    ) -> V2UITestFixture? {
        do {
            return try fixture(arguments: arguments, fileManager: fileManager)
        } catch {
            fatalError("AstroTool UI-test fixture configuration error: \(error.localizedDescription)")
        }
    }

    private static func argumentValue(
        _ argument: String,
        in arguments: [String]
    ) throws -> String? {
        guard let index = arguments.firstIndex(of: argument) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex,
              !arguments[valueIndex].hasPrefix("-")
        else {
            throw V2UITestFixtureError.missingArgumentValue(argument)
        }
        return arguments[valueIndex]
    }

    private static func makeFixture(
        fixtureContainer: URL,
        supportContainer: URL,
        fileManager: FileManager,
        beforeMutation: (URL, URL) throws -> Void
    ) throws -> V2UITestFixture {
        let safeFixtureContainer = try canonicalTemporaryURL(
            fixtureContainer,
            fileManager: fileManager
        )
        let safeSupportContainer = try canonicalTemporaryURL(
            supportContainer,
            fileManager: fileManager
        )
        guard !isContained(safeFixtureContainer, in: safeSupportContainer),
              !isContained(safeSupportContainer, in: safeFixtureContainer)
        else {
            throw V2UITestFixtureError.overlappingRoots
        }

        let fixtureRoot = try pinRoot(safeFixtureContainer)
        defer { Darwin.close(fixtureRoot.descriptor) }
        let supportRoot = try pinRoot(safeSupportContainer)
        defer { Darwin.close(supportRoot.descriptor) }

        try beforeMutation(safeFixtureContainer, safeSupportContainer)
        try verifyPinnedRoot(fixtureRoot)
        try verifyPinnedRoot(supportRoot)

        let libraryRoot = safeFixtureContainer
            .appendingPathComponent("DemoLibrary", isDirectory: true)
        let applicationSupport = safeSupportContainer
            .appendingPathComponent("ApplicationSupport", isDirectory: true)
        let caches = safeSupportContainer.appendingPathComponent("Caches", isDirectory: true)

        let libraryDescriptor = try createNewDirectory(
            named: "DemoLibrary",
            relativeTo: fixtureRoot.descriptor,
            existingPath: libraryRoot.path
        )
        defer { Darwin.close(libraryDescriptor) }
        let projectDescriptor = try createNewDirectory(
            named: "DemoProject",
            relativeTo: libraryDescriptor
        )
        defer { Darwin.close(projectDescriptor) }
        let nightDescriptor = try createNewDirectory(
            named: "DemoNight",
            relativeTo: projectDescriptor
        )
        defer { Darwin.close(nightDescriptor) }
        try createFixtureFrame(relativeTo: nightDescriptor)

        let applicationSupportDescriptor = try openOrCreateDirectory(
            named: "ApplicationSupport",
            relativeTo: supportRoot.descriptor
        )
        Darwin.close(applicationSupportDescriptor)
        let cachesDescriptor = try openOrCreateDirectory(
            named: "Caches",
            relativeTo: supportRoot.descriptor
        )
        Darwin.close(cachesDescriptor)

        try verifyPinnedRoot(fixtureRoot)
        try verifyPinnedRoot(supportRoot)
        return V2UITestFixture(
            libraryRoot: libraryRoot,
            applicationSupport: applicationSupport,
            caches: caches
        )
    }

    private static func canonicalTemporaryURL(
        _ url: URL,
        fileManager: FileManager
    ) throws -> URL {
        try refuseRealLibrary(url, fileManager: fileManager)
        return canonicalPath(url)
    }

    private struct DirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        init(descriptor: Int32) throws {
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0 else {
                throw posixError()
            }
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw POSIXError(.ENOTDIR)
            }
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
        }
    }

    private struct PinnedRoot {
        let url: URL
        let descriptor: Int32
        let identity: DirectoryIdentity
    }

    private static func pinRoot(_ url: URL) throws -> PinnedRoot {
        let parentDescriptor = try openExistingDirectory(
            url.deletingLastPathComponent()
        )
        defer { Darwin.close(parentDescriptor) }
        let descriptor = try openOrCreateDirectory(
            named: url.lastPathComponent,
            relativeTo: parentDescriptor
        )
        return try PinnedRoot(
            url: url,
            descriptor: descriptor,
            identity: DirectoryIdentity(descriptor: descriptor)
        )
    }

    private static func verifyPinnedRoot(_ root: PinnedRoot) throws {
        let currentDescriptor: Int32
        do {
            currentDescriptor = try openExistingDirectory(root.url)
        } catch {
            throw V2UITestFixtureError.rootIdentityChanged(root.url.path)
        }
        defer { Darwin.close(currentDescriptor) }
        guard try DirectoryIdentity(descriptor: currentDescriptor) == root.identity else {
            throw V2UITestFixtureError.rootIdentityChanged(root.url.path)
        }
    }

    private static func openExistingDirectory(_ url: URL) throws -> Int32 {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }

        do {
            for component in descriptorPathComponents(for: url) {
                let nextDescriptor = component.withCString { name in
                    Darwin.openat(
                        descriptor,
                        name,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard nextDescriptor >= 0 else { throw posixError() }
                Darwin.close(descriptor)
                descriptor = nextDescriptor
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func descriptorPathComponents(for url: URL) -> [String] {
        var components = Array(url.standardizedFileURL.pathComponents.dropFirst())
        if components.first == "tmp" || components.first == "var" {
            components.insert("private", at: 0)
        }
        return components
    }

    private static func openOrCreateDirectory(
        named name: String,
        relativeTo parentDescriptor: Int32
    ) throws -> Int32 {
        var descriptor = name.withCString { component in
            Darwin.openat(
                parentDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if descriptor < 0, errno == ENOENT {
            let result = name.withCString { component in
                Darwin.mkdirat(parentDescriptor, component, mode_t(S_IRWXU))
            }
            guard result == 0 || errno == EEXIST else { throw posixError() }
            descriptor = name.withCString { component in
                Darwin.openat(
                    parentDescriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
        }
        guard descriptor >= 0 else { throw posixError() }
        return descriptor
    }

    private static func createNewDirectory(
        named name: String,
        relativeTo parentDescriptor: Int32,
        existingPath: String? = nil
    ) throws -> Int32 {
        let result = name.withCString { component in
            Darwin.mkdirat(parentDescriptor, component, mode_t(S_IRWXU))
        }
        guard result == 0 else {
            if errno == EEXIST, let existingPath {
                throw V2UITestFixtureError.fixtureAlreadyExists(existingPath)
            }
            throw posixError()
        }
        return try openOrCreateDirectory(named: name, relativeTo: parentDescriptor)
    }

    private static func createFixtureFrame(relativeTo directoryDescriptor: Int32) throws {
        let descriptor = "DemoFrame.fit".withCString { name in
            Darwin.openat(
                directoryDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }

        let data = Data("AstroTool deterministic read-only UI fixture\n".utf8)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                guard count >= 0 else {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                written += count
            }
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    fileprivate static func canonicalPath(_ url: URL) -> URL {
        url.standardizedFileURL.pathComponents.dropFirst().reduce(
            URL(fileURLWithPath: "/", isDirectory: true)
        ) { resolvedPrefix, component in
            resolvedPrefix
                .appendingPathComponent(component)
                .resolvingSymlinksInPath()
        }
    }

    fileprivate static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.path
        let rootPath = root.path
        guard candidatePath != rootPath else { return true }
        return candidatePath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }
}

/// Refuse known real-library locations and everything outside a uniquely named
/// UI-test root beneath canonical `/private/tmp`, the component-validated
/// macOS `/private/var/folders/<bucket>/<run>/T` hierarchy, or the exact
/// UI-test runner container's `Data/tmp` directory. This contract does not
/// compare process-specific `TMPDIR` values. Canonicalizing each existing path
/// prefix prevents a temporary symlink from escaping to a real root.
public func refuseRealLibrary(
    _ url: URL,
    fileManager: FileManager = .default
) throws {
    let candidate = V2PreviewFixtures.canonicalPath(url)
    // `canonicalPath` resolves symlinks component-by-component via
    // `resolvingSymlinksInPath()`, which silently leaves a DANGLING link
    // unresolved -- its target does not exist (yet), which is exactly the
    // state a soon-to-be-created home library is in. A fixture tree never
    // legitimately contains symlinks, so any link component still present
    // in the canonical path is refused outright instead of trusting the
    // partially resolved result. (Caught on CI: the escape test's ~/Astro
    // target exists on no GitHub runner, the link stayed unresolved, and
    // the guard waved the escape through.)
    if containsSymlinkComponent(candidate, fileManager: fileManager) {
        throw V2UITestFixtureError.nonTemporaryLibrary(candidate.path)
    }
    let mountedLibrary = URL(fileURLWithPath: "/Volumes/images", isDirectory: true)
    let home = V2PreviewFixtures.canonicalPath(fileManager.homeDirectoryForCurrentUser)
    let homeAstroFolders = [
        home.appendingPathComponent("Astro", isDirectory: true),
        home.appendingPathComponent("Pictures/Astro", isDirectory: true),
        home.appendingPathComponent("Documents/Astro", isDirectory: true),
    ].map(V2PreviewFixtures.canonicalPath)

    guard isControlledUITestTemporaryPath(candidate, home: home),
          !V2PreviewFixtures.isContained(candidate, in: mountedLibrary),
          !homeAstroFolders.contains(where: {
              V2PreviewFixtures.isContained(candidate, in: $0)
          })
    else {
        throw V2UITestFixtureError.nonTemporaryLibrary(candidate.path)
    }
}

/// Whether any component of `url` is itself a symbolic link.
/// `attributesOfItem` does not follow links, so a dangling link (the case
/// `canonicalPath` cannot resolve) still reports `.typeSymbolicLink`;
/// components that do not exist at all simply report nothing and pass.
private func containsSymlinkComponent(_ url: URL, fileManager: FileManager) -> Bool {
    // `/tmp`, `/var` and `/etc` are the OS's own aliases into `/private`;
    // `resolvingSymlinksInPath()` deliberately never resolves them (it
    // REMOVES a `/private` prefix instead), so a canonical path may keep
    // them as its first component. They are not escape vectors --
    // `isControlledUITestTemporaryPath` already treats the two hierarchies
    // as one -- so only links deeper in the path count.
    let rootAliases: Set<String> = ["tmp", "var", "etc"]
    var prefix = URL(fileURLWithPath: "/", isDirectory: true)
    for (index, component) in url.pathComponents.dropFirst().enumerated() {
        prefix.appendPathComponent(component)
        if index == 0, rootAliases.contains(component) { continue }
        if let type = (try? fileManager.attributesOfItem(atPath: prefix.path))?[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            return true
        }
    }
    return false
}

private func isControlledUITestTemporaryPath(_ url: URL, home: URL) -> Bool {
    var components = url.pathComponents
    guard components.first == "/" else { return false }
    components.removeFirst()

    // Foundation may canonicalize the aliases in either direction, so compare
    // the same physical hierarchy after removing only the leading `private`.
    if components.first == "private" {
        components.removeFirst()
    }

    if components.first == "tmp" {
        guard components.count >= 2 else { return false }
        return hasSingleFixtureRoot(in: components, at: 1)
    }

    if components.count >= 6,
       components[0] == "var",
       components[1] == "folders",
       components[2].count == 2,
       components[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
       !components[3].isEmpty,
       components[4] == "T" {
        return hasSingleFixtureRoot(in: components, at: 5)
    }

    guard V2PreviewFixtures.isContained(url, in: home) else { return false }
    let relative = Array(url.pathComponents.dropFirst(home.pathComponents.count))
    guard relative.count >= 6,
          relative[0] == "Library",
          relative[1] == "Containers",
          relative[2] == "com.astrotool.app.UITests.xctrunner",
          relative[3] == "Data",
          relative[4] == "tmp"
    else {
        return false
    }
    return hasSingleFixtureRoot(in: relative, at: 5)
}

private func hasSingleFixtureRoot(in components: [String], at index: Int) -> Bool {
    let prefix = "AstroTool-V2-UI-"
    guard components.indices.contains(index),
          components[index].hasPrefix(prefix)
    else {
        return false
    }
    return !components.dropFirst(index + 1).contains(where: { $0.hasPrefix(prefix) })
}
