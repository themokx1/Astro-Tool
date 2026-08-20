import AstroCore
import Foundation

public struct LibraryCreationPreview: Equatable, Sendable {
    public let root: URL
    public let missingRelativePaths: [String]
    public let existingRelativePaths: [String]

    public init(root: URL, missingRelativePaths: [String], existingRelativePaths: [String]) {
        self.root = root
        self.missingRelativePaths = missingRelativePaths
        self.existingRelativePaths = existingRelativePaths
    }
}

public struct LibraryCreationReceipt: Equatable, Sendable {
    public let root: URL
    public let createdRelativePaths: [String]
    public let existingRelativePaths: [String]

    public init(root: URL, createdRelativePaths: [String], existingRelativePaths: [String]) {
        self.root = root
        self.createdRelativePaths = createdRelativePaths
        self.existingRelativePaths = existingRelativePaths
    }
}

/// Creates the canonical empty AstroTool library without modifying anything
/// already present at the selected location. Preview is always read-only;
/// creation requires the same explicit mutation mode as the other V2 writes.
public struct LibraryCreationCommand: Sendable {
    private let root: URL
    private let accessMode: LibraryAccessMode

    public init(root: URL, accessMode: LibraryAccessMode) {
        self.root = root
        self.accessMode = accessMode
    }

    public func preview() throws -> LibraryCreationPreview {
        let fm = FileManager.default
        var rootIsDirectory: ObjCBool = false
        if fm.fileExists(atPath: root.path, isDirectory: &rootIsDirectory), !rootIsDirectory.boolValue {
            throw AstroError.writeForbidden(path: root.path)
        }

        var missing: [String] = []
        var existing: [String] = []
        for relativePath in WriteGuard.libraryScaffoldRelativePaths {
            let url = root.appendingPathComponent(relativePath, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else {
                    throw AstroError.writeForbidden(path: url.path)
                }
                existing.append(relativePath)
            } else {
                missing.append(relativePath)
            }
        }
        return LibraryCreationPreview(
            root: root,
            missingRelativePaths: missing,
            existingRelativePaths: existing
        )
    }

    public func create() throws -> LibraryCreationReceipt {
        guard accessMode == .mutationEnabled else {
            throw LibraryMutationError.readOnly
        }
        let before = try preview()
        let createdURLs = try WriteGuard(root: root).createLibraryScaffold()
        let createdPaths = WriteGuard.libraryScaffoldRelativePaths.filter { relativePath in
            createdURLs.contains { $0.standardizedFileURL == root.appendingPathComponent(relativePath).standardizedFileURL }
        }
        return LibraryCreationReceipt(
            root: root,
            createdRelativePaths: createdPaths,
            existingRelativePaths: before.existingRelativePaths
        )
    }
}
