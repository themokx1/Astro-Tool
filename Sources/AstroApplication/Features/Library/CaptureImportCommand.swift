import AstroCore
import Foundation

/// One file the user has resolved to a definite role (light/flat/dark/
/// bias) and confirmed for import -- the Classify step's OUTPUT.
/// `CaptureImportCommand` never accepts an unresolved `DiscoveredCaptureFile`
/// (whose `proposedRole` can be `nil`): every item reaching `preview`/`copy`
/// already has a role, whether that came straight from the scanner's own
/// content-based proposal or from the user resolving an "unclassified" file
/// by hand. This is what keeps "never silently guessed" true all the way
/// through the pipeline, not just at the scan step.
public struct CaptureImportItem: Equatable, Sendable {
    public let sourceURL: URL
    public let relativeSourcePath: String
    public let fileName: String
    public let role: FrameRole
    public let sizeBytes: Int64

    public init(sourceURL: URL, relativeSourcePath: String, fileName: String, role: FrameRole, sizeBytes: Int64) {
        self.sourceURL = sourceURL
        self.relativeSourcePath = relativeSourcePath
        self.fileName = fileName
        self.role = role
        self.sizeBytes = sizeBytes
    }

    /// Builds the confirmed import item list from scanned files plus the
    /// user's classify-step decisions: `overrides` wins whenever present
    /// (including overriding an already-proposed role), `proposedRole`
    /// otherwise. A file with neither an override nor a proposed role is
    /// dropped -- exactly the "unclassified, excluded rather than guessed"
    /// outcome the owner's brief requires when the user chooses not to
    /// resolve it.
    public static func resolved(
        from discovered: [DiscoveredCaptureFile],
        overrides: [String: FrameRole]
    ) -> [CaptureImportItem] {
        discovered.compactMap { file in
            guard let role = overrides[file.id] ?? file.proposedRole else { return nil }
            return CaptureImportItem(
                sourceURL: file.sourceURL,
                relativeSourcePath: file.relativeSourcePath,
                fileName: file.fileName,
                role: role,
                sizeBytes: file.sizeBytes
            )
        }
    }
}

/// One source→destination mapping the Preview step shows -- the iron rule's
/// per-item ceremony, computed with the SAME path shape
/// `WriteGuard.copyCaptureFile`/`captureTreeRelativePaths` themselves use, so
/// a preview can never show a path the real copy wouldn't also use.
public struct CaptureImportPlanEntry: Equatable, Sendable, Identifiable {
    public var id: String { sourceURL.path }
    public let sourceURL: URL
    public let relativeSourcePath: String
    /// Root-relative destination, e.g.
    /// `sessions/IC1396/2026-08-16/captures/sv220-nb/lights/light_0001.fit`.
    public let destinationRelativePath: String
    public let sizeBytes: Int64
    /// `true` when a file already sits at `destinationRelativePath` -- this
    /// entry will be SKIPPED (never overwritten) when `copy` runs.
    public let collides: Bool

    public init(
        sourceURL: URL,
        relativeSourcePath: String,
        destinationRelativePath: String,
        sizeBytes: Int64,
        collides: Bool
    ) {
        self.sourceURL = sourceURL
        self.relativeSourcePath = relativeSourcePath
        self.destinationRelativePath = destinationRelativePath
        self.sizeBytes = sizeBytes
        self.collides = collides
    }
}

public struct CaptureImportPreview: Equatable, Sendable {
    public let target: String
    public let date: String
    public let slug: String
    public let entries: [CaptureImportPlanEntry]

    public init(target: String, date: String, slug: String, entries: [CaptureImportPlanEntry]) {
        self.target = target
        self.date = date
        self.slug = slug
        self.entries = entries
    }

    /// Total bytes across every entry, including the ones that will be
    /// skipped as collisions -- the preview's own honest "this is what's on
    /// the card for this destination" total; `totalBytesToCopy` below is
    /// what will actually move.
    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.sizeBytes } }
    public var totalBytesToCopy: Int64 { entries.filter { !$0.collides }.reduce(0) { $0 + $1.sizeBytes } }
    public var collisionCount: Int { entries.filter(\.collides).count }
}

/// What one `CaptureImportCommand.copy` call actually did -- files/bytes/
/// verification/destination paths for the Receipt step, and every copied
/// file's own checksum so a caller could, in principle, verify it again
/// later (see this type's own doc comment on undo for why that is as far as
/// this ships today).
public struct CaptureImportReceipt: Equatable, Sendable {
    public struct CopiedFile: Equatable, Sendable {
        public let sourceURL: URL
        public let destinationURL: URL
        public let sizeBytes: Int64
        public let sha256: String

        public init(sourceURL: URL, destinationURL: URL, sizeBytes: Int64, sha256: String) {
            self.sourceURL = sourceURL
            self.destinationURL = destinationURL
            self.sizeBytes = sizeBytes
            self.sha256 = sha256
        }
    }

    public struct FailedFile: Equatable, Sendable {
        public let sourceURL: URL
        public let reason: String

        public init(sourceURL: URL, reason: String) {
            self.sourceURL = sourceURL
            self.reason = reason
        }
    }

    public let target: String
    public let date: String
    public let slug: String
    public let copied: [CopiedFile]
    /// Root-relative destination paths that already existed and were left
    /// untouched.
    public let skippedCollisions: [String]
    public let failed: [FailedFile]
    /// `true` when `copy(...)` stopped early because `shouldCancel` returned
    /// `true`, rather than running every item in `items` -- W-fix (item 1):
    /// this used to be a plain `throw CancellationError()`, which discarded
    /// every already-verified `copied`/`skippedCollisions`/`failed` entry
    /// accumulated so far and left the caller with no receipt at all, even
    /// though real files had already been copied and checksum-verified into
    /// the library. A cancelled receipt is still an honest receipt: it
    /// reports exactly what happened before the stop, same as a completed
    /// one, just flagged so the UI can say "stopped", not "failed".
    public let wasCancelled: Bool

    public init(
        target: String,
        date: String,
        slug: String,
        copied: [CopiedFile],
        skippedCollisions: [String],
        failed: [FailedFile],
        wasCancelled: Bool = false
    ) {
        self.target = target
        self.date = date
        self.slug = slug
        self.copied = copied
        self.skippedCollisions = skippedCollisions
        self.failed = failed
        self.wasCancelled = wasCancelled
    }

    public var totalBytesCopied: Int64 { copied.reduce(0) { $0 + $1.sizeBytes } }
}

/// The card-import wizard's copy engine. `preview` is a pure, read-only
/// computation (only ever checks whether a destination file already exists,
/// same read-only spirit as `SessionCreationCommand.preview`); `copy` is the
/// only call that writes, and only ever through `WriteGuard.copyCaptureFile`
/// -- this type invents no filesystem-writing logic of its own.
///
/// The source card is NEVER touched: nothing here deletes, moves, or offers
/// to clear anything under a `CaptureImportItem.sourceURL`. Every write goes
/// to a NEW destination file; a destination that already exists is skipped,
/// never overwritten (the owner's "same-name file already there -> skip and
/// report" rule).
///
/// Verification: after each successful copy, this re-hashes BOTH the source
/// and the just-written destination with `DuplicateFinder.sha256Hash` (the
/// exact streaming SHA-256 `FixityVerifier` already re-hashes tracked
/// library files with) and compares them. A mismatch means the copy is
/// corrupt -- the destination file is deleted immediately (never left behind
/// half-trustworthy) and the item is reported as failed, while every OTHER
/// item keeps being processed; a full byte-for-byte copy is cheap enough
/// (already reading the whole file to write it) that re-hashing both ends
/// afterward, rather than only checking size, was judged worth the extra
/// pass for exactly the "hazza a kártyáról" moment this wizard exists for --
/// once the source card gets cleared by hand, there is no second chance to
/// notice a silently truncated copy.
///
/// No undo: verified copies are files newly created in a user-writable
/// destination — deleting them (even ones this command itself just created)
/// is the same category of action `SessionCreationCommand.undo` handles
/// today, but doing it *safely* here would require knowing that nothing
/// else has touched the destination folder since (a newer scan, a second
/// import into the same capture, a user drag-and-drop) — machinery this
/// codebase's receipt system does not have yet. Shipping a "delete these
/// files" button without that guarantee would be a dangerous fake-undo, not
/// a safety net, so `CaptureImportReceipt` intentionally carries no undo
/// action; the wizard's Receipt step says so plainly instead.
public enum CaptureImportCommand {
    /// Root-relative directory name for each role -- the same four this
    /// engine ever writes into (`WriteGuard.copyCaptureFile` itself refuses
    /// anything else).
    private static func directoryName(for role: FrameRole) throws -> String {
        switch role {
        case .light: return "lights"
        case .flat: return "flats"
        case .dark: return "darks"
        case .bias: return "biases"
        default:
            // W-fix (reverse leak): this used to be a hardcoded Hungarian
            // sentence -- an English-locale user importing a non-copyable
            // role would have seen this one line in Hungarian no matter
            // what. Same `NSLocalizedString` pattern as the checksum-
            // mismatch message below: `AstroApplication` cannot import
            // `AstroUI`, but `NSLocalizedString(_:bundle: .main,comment:)`
            // needs no such import, and `hu.lproj/Localizable.strings`
            // still ships inside the app's main bundle regardless of which
            // target the lookup runs from.
            throw AstroError.invalidInput(
                String(
                    format: NSLocalizedString(
                        "The %@ role cannot be copied into a capture.",
                        bundle: .main,
                        comment: ""
                    ),
                    role.rawValue
                )
            )
        }
    }

    public static func destinationRelativePath(
        target: String, date: String, slug: String, role: FrameRole, fileName: String
    ) throws -> String {
        let directory = try directoryName(for: role)
        return "sessions/\(target)/\(date)/captures/\(slug)/\(directory)/\(fileName)"
    }

    /// Read-only: for each item, computes the exact destination `copy` would
    /// use and whether a file already sits there. Never touches `root`
    /// beyond `FileManager.fileExists`.
    public static func preview(
        items: [CaptureImportItem],
        root: URL,
        target: String,
        date: String,
        slug: String
    ) throws -> CaptureImportPreview {
        let fm = FileManager.default
        let entries: [CaptureImportPlanEntry] = try items.map { item in
            let relativePath = try destinationRelativePath(
                target: target, date: date, slug: slug, role: item.role, fileName: item.fileName
            )
            let destinationURL = root.appendingPathComponent(relativePath)
            return CaptureImportPlanEntry(
                sourceURL: item.sourceURL,
                relativeSourcePath: item.relativeSourcePath,
                destinationRelativePath: relativePath,
                sizeBytes: item.sizeBytes,
                collides: fm.fileExists(atPath: destinationURL.path)
            )
        }
        return CaptureImportPreview(target: target, date: date, slug: slug, entries: entries)
    }

    /// The only call in this type that writes. Throws
    /// `LibraryMutationError.readOnly` before touching anything unless
    /// `accessMode == .mutationEnabled` -- same gate every other V2 write
    /// command uses. `progress`, when given, is called once per item
    /// processed (mirrors `FixityVerifier.verify`'s own `(completed, total)`
    /// contract) so a caller can relay it through
    /// `OperationHost.relayProgress`.
    ///
    /// One item's failure (a read error, a corrupt-copy hash mismatch)
    /// never stops the rest: every other item in `items` is still attempted,
    /// and the final `CaptureImportReceipt` reports exactly what succeeded,
    /// what was skipped as a collision, and what failed and why -- never a
    /// half-written file left behind for a failed one, since
    /// `WriteGuard.copyCaptureFile` itself only ever produces a complete
    /// file via its own temp-name-then-rename step, and a verification
    /// failure deletes that completed-but-wrong-content file immediately.
    ///
    /// `hash` defaults to the real `DuplicateFinder.sha256Hash` and exists as
    /// a parameter purely so a test can inject a hasher that disagrees for
    /// one specific source/destination pair -- simulating a corrupted copy
    /// deterministically, without needing to race a real file write.
    public static func copy(
        items: [CaptureImportItem],
        root: URL,
        accessMode: LibraryAccessMode,
        target: String,
        date: String,
        slug: String,
        progress: (@Sendable (Int, Int) -> Void)? = nil,
        shouldCancel: @Sendable () -> Bool = { false },
        hash: @Sendable (URL) throws -> String = { try DuplicateFinder.sha256Hash(of: $0) }
    ) throws -> CaptureImportReceipt {
        guard accessMode == .mutationEnabled else { throw LibraryMutationError.readOnly }

        let writeGuard = WriteGuard(root: root)
        var copied: [CaptureImportReceipt.CopiedFile] = []
        var skipped: [String] = []
        var failed: [CaptureImportReceipt.FailedFile] = []
        var wasCancelled = false
        let total = items.count

        for (index, item) in items.enumerated() {
            // W-fix (item 1): stop rather than throw. A thrown
            // `CancellationError()` here used to discard every
            // already-verified `copied`/`skipped`/`failed` entry accumulated
            // so far -- real files the loop had already copied and
            // checksum-verified into the library -- leaving the caller with
            // no receipt at all. Breaking out and returning the partial
            // receipt (flagged `wasCancelled`) below is still an honest
            // report of exactly what happened before the stop.
            if shouldCancel() {
                wasCancelled = true
                break
            }
            do {
                let directory = try directoryName(for: item.role)
                let destDirRelative = "sessions/\(target)/\(date)/captures/\(slug)/\(directory)"
                guard let destinationURL = try writeGuard.copyCaptureFile(
                    sourceURL: item.sourceURL,
                    destDirRelative: destDirRelative,
                    destFileName: item.fileName
                ) else {
                    skipped.append("\(destDirRelative)/\(item.fileName)")
                    progress?(index + 1, total)
                    continue
                }

                let sourceHash = try hash(item.sourceURL)
                let destinationHash = try hash(destinationURL)
                guard sourceHash == destinationHash else {
                    try? FileManager.default.removeItem(at: destinationURL)
                    failed.append(CaptureImportReceipt.FailedFile(
                        sourceURL: item.sourceURL,
                        // W6-D fix (reverse leak): this used to be a
                        // hardcoded Hungarian sentence reaching
                        // `CaptureImportView`'s `Text(verbatim: "\(failure
                        // .sourceURL.lastPathComponent): \(failure.reason)")`
                        // directly -- an English-locale user would have seen
                        // this one line in Hungarian no matter what.
                        // `AstroApplication` cannot import `AstroUI`
                        // (`OperationHost.localized`'s own module; the
                        // dependency only runs the other way), but that
                        // helper is itself just a thin
                        // `NSLocalizedString(_:bundle: .main,comment:)`
                        // wrapper, which needs no `AstroUI` import to call
                        // directly -- `hu.lproj/Localizable.strings` still
                        // ships inside the app's main bundle regardless of
                        // which target the lookup runs from.
                        reason: NSLocalizedString(
                            "the copy's checksum does not match the source -- the bad copy was deleted",
                            bundle: .main,
                            comment: ""
                        )
                    ))
                    progress?(index + 1, total)
                    continue
                }

                copied.append(CaptureImportReceipt.CopiedFile(
                    sourceURL: item.sourceURL,
                    destinationURL: destinationURL,
                    sizeBytes: item.sizeBytes,
                    sha256: destinationHash
                ))
            } catch {
                failed.append(CaptureImportReceipt.FailedFile(
                    sourceURL: item.sourceURL,
                    reason: (error as? AstroError).map(String.init(describing:)) ?? error.localizedDescription
                ))
            }
            progress?(index + 1, total)
        }

        return CaptureImportReceipt(
            target: target, date: date, slug: slug,
            copied: copied, skippedCollisions: skipped, failed: failed,
            wasCancelled: wasCancelled
        )
    }
}
