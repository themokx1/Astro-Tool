import AstroApplication
import Foundation

public enum V2UITestFixtureError: Error, Equatable, Sendable, LocalizedError {
    case missingArgumentValue(String)
    case incompleteConfiguration
    case nonTemporaryLibrary(String)
    case overlappingRoots
    case fixtureAlreadyExists(String)

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
        }
    }
}

public struct V2UITestFixture: Sendable {
    public let libraryRoot: URL
    public let applicationSupport: URL
    public let caches: URL

    @MainActor
    public func makeOnboardingStore() -> OnboardingStore {
        OnboardingStore(
            sessionFactory: .production,
            storageFactory: OnboardingStorageFactory { root in
                try AppStoragePaths(
                    applicationSupport: applicationSupport,
                    caches: caches,
                    libraryID: LibraryIdentity(rootURL: root),
                    libraryRoot: root
                )
            },
            securityScopedAccess: .inactive
        )
    }
}

public enum V2PreviewFixtures {
    private static let fixtureRootArgument = "-UITestFixtureRoot"
    private static let appSupportArgument = "-UITestAppSupport"

    public static func fixture(
        arguments: [String],
        fileManager: FileManager = .default
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
            fileManager: fileManager
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
        fileManager: FileManager
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

        let libraryRoot = safeFixtureContainer
            .appendingPathComponent("DemoLibrary", isDirectory: true)
        let frame = libraryRoot
            .appendingPathComponent("DemoProject/DemoNight", isDirectory: true)
            .appendingPathComponent("DemoFrame.fit")
        let applicationSupport = safeSupportContainer
            .appendingPathComponent("ApplicationSupport", isDirectory: true)
        let caches = safeSupportContainer.appendingPathComponent("Caches", isDirectory: true)

        for url in [libraryRoot, frame, applicationSupport, caches] {
            try refuseRealLibrary(url, fileManager: fileManager)
        }
        guard !fileManager.fileExists(atPath: libraryRoot.path) else {
            throw V2UITestFixtureError.fixtureAlreadyExists(libraryRoot.path)
        }

        try fileManager.createDirectory(
            at: frame.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: caches, withIntermediateDirectories: true)
        try Data("AstroTool deterministic read-only UI fixture\n".utf8).write(to: frame)

        for url in [libraryRoot, applicationSupport, caches] {
            try refuseRealLibrary(url, fileManager: fileManager)
        }
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
