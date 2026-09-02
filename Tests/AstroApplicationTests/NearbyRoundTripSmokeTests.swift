import CryptoKit
import Foundation
import Testing
@testable import AstroApplication
@testable import AstroMobileDomain
@testable import AstroMobileTransport

/// The Wave 2 machine gate's deterministic proof: the REAL Mac
/// `NearbySyncCoordinator` wired to the REAL phone `NearbyPhoneSyncSession`
/// over an in-memory duplex connection -- never a hand-rolled double
/// standing in for either side (unlike `NearbySyncCoordinatorTests`'
/// `runPhoneSession` and `NearbyPhoneSyncSessionTests`' `runMacSide`, which
/// each drive one real side against a shaped double for the other). Both
/// production actors run unmodified, exactly as they will in the shipping
/// apps, against a real temp-root library fixture.
///
/// One test, two nearby sessions on the same paired coordinator/session
/// instances:
/// 1. First pairing -- SAS codes compared equal on both sides, forward
///    package staged and imported on the phone, one checklist completion +
///    one note revision sent back, applied through the public
///    `MobileReturnApplicationCoordinator`, and both transferred package
///    byte-streams (forward + return) scanned for the fixture's forbidden
///    material at the point they are staged on the RECEIVING side -- the
///    actual wire-transferred bytes, reconstructed from the chunk stream,
///    not a pre-send export copy.
/// 2. A second session between the same two (now-trusted) identities --
///    this doubles as the "known peer, no SAS" proof the plan calls out as
///    a cheap addition (folding it in here avoids re-building the entire
///    fixture and first pairing a second time just to reach that state) --
///    whose forward publish is asserted to carry exactly the two applied
///    change IDs as `acknowledgedChangeIDs` (item 7 of the plan).
///
/// Finally the fixture's original files are re-hashed and must be
/// bit-identical to before either session ran.
@Suite("Nearby round trip: real Mac coordinator and real phone session")
struct NearbyRoundTripSmokeTests {
    @Test("real NearbySyncCoordinator <-> real NearbyPhoneSyncSession: paired SAS, forward+return round trip, acknowledgement on the next forward snapshot, zero residue, zero leaked secrets")
    func realCoordinatorAndPhoneSessionCompleteTheRoundTrip() async throws {
        let fixture = try await RoundTripFixture.make()
        defer { fixture.cleanUp() }

        let manifestBefore = try captureManifest(of: fixture.root)
        #expect(fixture.decoyRelativePaths.allSatisfy { manifestBefore[$0] != nil })

        let macIdentityStore = InMemoryDeviceIdentityStore()
        let macIdentity = try macIdentityStore.loadOrCreateOwnIdentity(displayName: "Zoltán Macje")
        let phoneIdentityStore = InMemoryDeviceIdentityStore()
        let phoneIdentity = try phoneIdentityStore.loadOrCreateOwnIdentity(displayName: "Zoltán iPhone")

        // The one real return coordinator both the Mac coordinator's closures
        // and this fixture's own snapshot composition target -- the same
        // public production initializer `MobilePackageSmokeTests` uses, so
        // the sent-base evidence, revision lease, and acknowledgement ledger
        // are exercised exactly as production wires them.
        let returnCoordinator = try MobileReturnApplicationCoordinator(rootURL: fixture.root)

        let (macConnection1, phoneConnection1) = InMemoryDuplexConnection.makePair()
        let (macConnection2, phoneConnection2) = InMemoryDuplexConnection.makePair()
        let listener = RoundTripScriptedListener(batches: [[macConnection1], [macConnection2]])
        let phoneConnections = RoundTripConnectionSource([phoneConnection1, phoneConnection2])

        let coordinator = NearbySyncCoordinator(
            identity: macIdentity,
            trustStore: macIdentityStore,
            listenerStart: { try await listener.start() },
            listenerStop: { await listener.stop() },
            stagingDirectory: fixture.macStagingDirectory,
            packageService: MobilePackageService(),
            publishForwardSnapshot: { snapshot, destination, wrapping in
                try await returnCoordinator.publishForwardSnapshot(snapshot, to: destination, wrapping: wrapping)
            },
            previewReturn: { source, wrapping in
                // The Mac's own staged copy of the wire-transferred return
                // package -- still on disk at this point, before
                // `NearbyPackageTransport.receiveOptionalReturn`'s cleanup
                // `defer` runs. This is the actual transferred bytes, not a
                // re-exported stand-in.
                try assertPackageBytesContainNoForbiddenMaterial(
                    at: source,
                    forbiddenStrings: fixture.forbiddenStrings,
                    forbiddenBinarySequences: [fixture.sentinelBinary]
                )
                return try await returnCoordinator.preview(from: source, wrapping: wrapping)
            },
            handshakeTimeout: .seconds(5)
        )

        let phoneSession = NearbyPhoneSyncSession(
            identity: phoneIdentity,
            trustStore: phoneIdentityStore,
            connect: { _ in phoneConnections.next() },
            packageService: MobilePackageService(),
            stagingDirectory: fixture.phoneStagingDirectory,
            timeout: .seconds(5)
        )

        let returnExchangeDirectory = fixture.root.appendingPathComponent("phone-return-exchange", isDirectory: true)
        try FileManager.default.createDirectory(at: returnExchangeDirectory, withIntermediateDirectories: true)
        let checklistChangeID = UUID()
        let noteChangeID = UUID()
        let deviceID = phoneIdentity.deviceID

        // --- Session 1: first pairing, forward publish + import, return
        // package built and sent back, applied through the public
        // coordinator. ---
        async let phoneCollected1: [NearbyPhoneSyncState] = Self.runPhoneFirstSession(
            session: phoneSession,
            fixture: fixture,
            checklistChangeID: checklistChangeID,
            noteChangeID: noteChangeID,
            deviceID: deviceID,
            returnExchangeDirectory: returnExchangeDirectory
        )

        let baseSnapshot = try await fixture.composeSnapshot()
        let macEvents1 = try await coordinator.startAdvertising(confirmedSnapshot: baseSnapshot)
        var macCollected1: [NearbySyncEvent] = []
        var macCode: String?
        var appliedReceipt: MobileChangeApplicationReceipt?
        for await event in macEvents1 {
            macCollected1.append(event)
            switch event {
            case .pairingCode(let code, _):
                macCode = code
                await coordinator.confirmPairing()
            case .receivedReturn(let review):
                #expect(review.changePreview.applicable.count == 2)
                let receipt = try await returnCoordinator.apply(review, resolutions: [:], confirmed: true)
                appliedReceipt = receipt
                await coordinator.reportReturnOutcome(.applied)
            default:
                break
            }
        }

        let phoneStates1 = try await phoneCollected1
        let phoneCode = phoneStates1.compactMap { state -> String? in
            if case .pairingCode(let code, _) = state { return code }
            return nil
        }.first

        // --- 3. Both sides derived the SAME six-digit SAS. ---
        #expect(try #require(phoneCode) == (try #require(macCode)))

        #expect(macCollected1.contains { if case .waitingForPhone = $0 { return true }; return false })
        #expect(macCollected1.contains { if case .pairingCode = $0 { return true }; return false })
        #expect(macCollected1.contains { if case .preparing = $0 { return true }; return false })
        #expect(macCollected1.contains { if case .transferring = $0 { return true }; return false })
        #expect(macCollected1.contains { if case .verifying = $0 { return true }; return false })
        #expect(macCollected1.contains { if case .receivedReturn = $0 { return true }; return false })
        #expect(macCollected1.last.map { if case .finished = $0 { return true }; return false } == true)

        #expect(phoneStates1.first == .searching)
        #expect(phoneStates1.contains(.connecting))
        #expect(phoneStates1.contains(.receiving))
        #expect(phoneStates1.contains(.staged))
        #expect(phoneStates1.contains(.sendingReturn))
        #expect(phoneStates1.last == .finished)

        // --- 6. Both changes applied through the real domain stores. ---
        #expect(Set(try #require(appliedReceipt).appliedChangeIDs) == Set([checklistChangeID, noteChangeID]))
        let updatedBriefing = try #require(await fixture.briefingStore.latest(id: fixture.briefingID))
        #expect(updatedBriefing.checklist.first?.items.first?.isCompleted == true)
        let updatedAnnotation = try #require(await fixture.metadataStore.projectAnnotation(projectID: fixture.project.id))
        #expect(updatedAnnotation.notes == "Phone annotation update")

        // --- Session 2: same two now-trusted identities. Doubles as the
        // "known peer, no SAS" proof, and its forward publish is the "next
        // forward snapshot" acknowledgement check (item 7). ---
        let secondSnapshot = try await fixture.composeSnapshot()
        async let secondResult: (states: [NearbyPhoneSyncState], envelope: MobilePackageEnvelope?) = Self.runPhoneSecondSession(
            session: phoneSession,
            fixture: fixture
        )

        let macEvents2 = try await coordinator.startAdvertising(confirmedSnapshot: secondSnapshot)
        var macCollected2: [NearbySyncEvent] = []
        for await event in macEvents2 {
            macCollected2.append(event)
            // Never expected to fire for a known peer, but if the handshake
            // logic ever regressed to re-prompting, this must not hang the
            // test waiting for a confirmation nobody sends.
            if case .pairingCode = event { await coordinator.confirmPairing() }
        }
        let (phoneStates2, secondEnvelope) = try await secondResult

        // --- 4 (bonus). Known-peer session: no SAS prompt on either side. ---
        #expect(!macCollected2.contains { if case .pairingCode = $0 { return true }; return false })
        #expect(!phoneStates2.contains { if case .pairingCode = $0 { return true }; return false })
        #expect(macCollected2.last.map { if case .finished = $0 { return true }; return false } == true)
        #expect(phoneStates2.last == .finished)
        #expect(try macIdentityStore.trustedPeers().count == 1)
        #expect(try phoneIdentityStore.trustedPeers().count == 1)

        // --- 7. The next forward snapshot carries exactly the two applied
        // change IDs as its acknowledgement list. ---
        let envelope = try #require(secondEnvelope)
        #expect(Set(envelope.acknowledgedChangeIDs) == Set([checklistChangeID, noteChangeID]))

        // --- 8. The fixture's original files are bit-identical; only a
        // known allowlist of app-state/exchange paths may be new. ---
        let manifestAfter = try captureManifest(of: fixture.root)
        for (path, before) in manifestBefore {
            let after = manifestAfter[path]
            #expect(after != nil, "original fixture file disappeared: \(path)")
            #expect(after?.sha256 == before.sha256, "original fixture file content changed: \(path)")
            #expect(after?.size == before.size, "original fixture file size changed: \(path)")
        }
        #expect(fixture.decoyRelativePaths.count == fixture.decoyRelativePaths.filter { manifestAfter[$0] != nil }.count)
        let newPaths = Set(manifestAfter.keys).subtracting(manifestBefore.keys)
        let allowedNewPathPrefixes = [
            ".astro-tool/mobile-sent-snapshot.json",
            ".astro-tool/mobile-snapshot-revision.json",
            ".astro-tool/mobile-domain-authority.lock",
            ".astro-tool/mobile-change-ledger.json",
            "phone-return-exchange/"
        ]
        for path in newPaths {
            #expect(
                allowedNewPathPrefixes.contains(where: { path == $0 || path.hasPrefix($0) }),
                "unexpected new file written under the fixture root: \(path)"
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.macStagingDirectory.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.phoneStagingDirectory.path).isEmpty)
    }

    // MARK: - Phone-side driving helpers

    /// Drives the phone's FIRST attempt through the real `NearbyPhoneSyncSession`:
    /// confirms the pairing code, scans the staged forward package bytes for
    /// the fixture's forbidden material (the actual wire-transferred bytes,
    /// still on disk inside `handleForwardPackage` before the transport's own
    /// cleanup runs), imports it exactly the way `NearbyPhoneSyncSessionTests`
    /// does (`MobilePackageService.authenticatePreview` +
    /// `commitImport`, never `MobileLibraryStore` -- out of this transport's
    /// scope), then builds and exports a return package containing one real
    /// checklist completion and one real note revision, based on the
    /// imported snapshot's own base revisions.
    private static func runPhoneFirstSession(
        session: NearbyPhoneSyncSession,
        fixture: RoundTripFixture,
        checklistChangeID: UUID,
        noteChangeID: UUID,
        deviceID: UUID,
        returnExchangeDirectory: URL
    ) async throws -> [NearbyPhoneSyncState] {
        var collected: [NearbyPhoneSyncState] = []
        for await state in await session.run(handleForwardPackage: { directory, wrapping in
            try assertPackageBytesContainNoForbiddenMaterial(
                at: directory,
                forbiddenStrings: fixture.forbiddenStrings,
                forbiddenBinarySequences: [fixture.sentinelBinary]
            )
            let service = MobilePackageService()
            let authenticated = try await service.authenticatePreview(from: directory, wrapping: wrapping)
            #expect(authenticated.preview.snapshotSummary.projectCount == 1)
            #expect(authenticated.preview.snapshotSummary.briefingCount == 1)
            let importedEnvelope = try await service.commitImport(token: authenticated.token)
            let importedSnapshot = try #require(importedEnvelope.snapshot)
            let checklistItem = try #require(importedSnapshot.briefings.first?.checklist.first?.items.first)
            let briefingID = try #require(importedSnapshot.briefings.first?.id)
            let projectNote = try #require(importedSnapshot.notes.first { $0.scope == .project })

            let checklistChange = MobileChange.checklistCompletion(.init(
                changeID: checklistChangeID,
                deviceID: deviceID,
                briefingID: briefingID,
                itemID: checklistItem.id,
                baseRevision: checklistItem.baseRevision,
                isCompleted: true,
                createdAt: fixture.now.addingTimeInterval(1)
            ))
            let noteChange = MobileChange.noteRevision(.init(
                changeID: noteChangeID,
                deviceID: deviceID,
                noteID: projectNote.id,
                ownerID: projectNote.ownerID,
                baseRevision: projectNote.baseRevision,
                text: "Phone annotation update",
                createdAt: fixture.now.addingTimeInterval(1)
            ))

            let returnKey = OneTimePackageKey()
            let returnDestination = returnExchangeDirectory.appendingPathComponent("return-\(UUID().uuidString).astromobile", isDirectory: true)
            let manifest = try await service.export(
                MobilePackageEnvelope(
                    purpose: .returnChanges,
                    snapshot: importedSnapshot,
                    baseSnapshotID: importedSnapshot.snapshotID,
                    changes: [checklistChange, noteChange],
                    acknowledgedChangeIDs: []
                ),
                to: returnDestination,
                wrapping: returnKey
            )
            let pairedWrapping = try PairedDeviceKeyWrapping(rawRepresentation: returnKey.rawRepresentation)
            return NearbyPhoneReturnPackage(packageDirectory: returnDestination, packageID: manifest.packageID, wrapping: pairedWrapping)
        }) {
            collected.append(state)
            if case .pairingCode = state { await session.confirmPairing() }
        }
        return collected
    }

    /// Drives the phone's SECOND attempt (same identity/trust store as the
    /// first -- a known peer to the Mac now): expects no pairing-code prompt,
    /// authenticates and commits the forward package to obtain its decrypted
    /// envelope (so the caller can inspect `acknowledgedChangeIDs`), and
    /// sends nothing back.
    private static func runPhoneSecondSession(
        session: NearbyPhoneSyncSession,
        fixture: RoundTripFixture
    ) async throws -> (states: [NearbyPhoneSyncState], envelope: MobilePackageEnvelope?) {
        var collected: [NearbyPhoneSyncState] = []
        let capturedEnvelope = RoundTripEnvelopeBox()
        for await state in await session.run(handleForwardPackage: { directory, wrapping in
            try assertPackageBytesContainNoForbiddenMaterial(
                at: directory,
                forbiddenStrings: fixture.forbiddenStrings,
                forbiddenBinarySequences: [fixture.sentinelBinary]
            )
            let service = MobilePackageService()
            let authenticated = try await service.authenticatePreview(from: directory, wrapping: wrapping)
            let envelope = try await service.commitImport(token: authenticated.token)
            capturedEnvelope.set(envelope)
            return nil
        }) {
            collected.append(state)
            if case .pairingCode = state { await session.confirmPairing() }
        }
        return (collected, capturedEnvelope.get())
    }
}

// MARK: - Scripted listener / connection source

/// Test double standing in for `NearbyBonjourListener`: each `start()` call
/// hands out the next scripted batch of connections as a fresh
/// `AsyncStream`. Mirrors `NearbySyncCoordinatorTests`' own `ScriptedListener`
/// (kept as a separate, differently-named type here since that one is
/// file-private to its own test file).
private final class RoundTripScriptedListener: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingBatches: [[any NearbyByteConnection]]
    private var continuations: [AsyncStream<any NearbyByteConnection>.Continuation] = []

    init(batches: [[any NearbyByteConnection]]) {
        self.pendingBatches = batches
    }

    func start() async throws -> AsyncStream<any NearbyByteConnection> {
        let batch: [any NearbyByteConnection] = lock.withLock {
            guard !pendingBatches.isEmpty else { return [] }
            return pendingBatches.removeFirst()
        }
        let (stream, continuation) = AsyncStream<any NearbyByteConnection>.makeStream()
        lock.withLock { continuations.append(continuation) }
        for connection in batch { continuation.yield(connection) }
        return stream
    }

    func stop() async {
        let toFinish: [AsyncStream<any NearbyByteConnection>.Continuation] = lock.withLock {
            let list = continuations
            continuations = []
            return list
        }
        for continuation in toFinish { continuation.finish() }
    }
}

/// Hands out one pre-wired connection per `NearbyPhoneSyncSession.run` call,
/// in order -- the phone-side equivalent of `RoundTripScriptedListener`,
/// needed because `NearbyPhoneSyncSession`'s production usage pattern is to
/// call `run` again on the SAME actor instance for each new sync attempt
/// (its own doc comment says so), so its `connect` closure must return a
/// different connection each time rather than the first session's now-closed
/// one.
private final class RoundTripConnectionSource: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [any NearbyByteConnection]

    init(_ connections: [any NearbyByteConnection]) {
        self.connections = connections
    }

    func next() -> any NearbyByteConnection {
        lock.withLock {
            precondition(!connections.isEmpty, "RoundTripConnectionSource exhausted")
            return connections.removeFirst()
        }
    }
}

/// Thread-safe single-slot box: `handleForwardPackage` runs on a different
/// task than the `for await` loop consuming the state stream, so a plain
/// captured `var` cannot be mutated from inside the closure.
private final class RoundTripEnvelopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MobilePackageEnvelope?

    func set(_ envelope: MobilePackageEnvelope) {
        lock.withLock { value = envelope }
    }

    func get() -> MobilePackageEnvelope? {
        lock.withLock { value }
    }
}

// MARK: - Fixture

/// A real temp-root library fixture (crib `NearbySyncCoordinatorTests`' own
/// fixture shape) holding a briefing+checklist and a project annotation
/// (crib `MobilePackageSmokeTests`' domain data), plus decoy sensitive-named
/// binary files sharing a byte sentinel (crib `MobilePackageSmokeTests`'
/// `MobileSmokeFixture`) so the byte-scan assertions have something concrete
/// to fail on if the "package pipeline never reads the filesystem, only
/// typed domain records" invariant is ever violated.
private struct RoundTripFixture {
    let root: URL
    let macStagingDirectory: URL
    let phoneStagingDirectory: URL
    let decoyRelativePaths: [String]
    let sentinelBinary: [UInt8]
    let forbiddenStrings: [String]
    let now: Date
    let libraryID: PortableLibraryID
    let metadataStore: MetadataStore
    let briefingStore: NightBriefingRevisionStore
    let briefingID: UUID
    let project: ProjectRecord
    let revisionStore: MobileSnapshotRevisionStore

    static func make() async throws -> RoundTripFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nearby-round-trip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let sentinelText = "SENTINEL-DO-NOT-LEAK-nearby-9f3c2a11"
        let sentinelBinary: [UInt8] = [0x0B, 0xAD, 0xC0, 0xDE, 0xFE, 0xED, 0xFA, 0xCE, 0x13, 0x37, 0x00, 0xFF, 0x42, 0x99, 0x7A, 0x3D]
        let decoys = [
            "Projects/M31-Andromeda/Lights/secret-target-2026.fits",
            "Projects/M31-Andromeda/Lights/IMG_0091.CR3",
            "Projects/M31-Andromeda/Calibration/master-dark-secret.fits"
        ]
        for relative in decoys {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var content = Data("FIXTURE-DECOY-\(relative)-".utf8)
            content.append(Data(sentinelText.utf8))
            content.append(Data(sentinelBinary))
            content.append(Data(repeating: 0xAB, count: 64))
            try content.write(to: url)
        }
        let forbidden = decoys
            + decoys.map { URL(fileURLWithPath: $0).lastPathComponent }
            + [root.path, sentinelText, "/Users/", "file://", ".fits", ".CR3", "securityScopedBookmark", "SIMPLE  ="]

        let identityStore = PortableLibraryIdentityStore()
        let identityPreview = try identityStore.preview(root: root)
        let libraryID = try identityStore.loadOrCreate(root: root, confirmedID: identityPreview.proposedID)
        let paths = try AppStoragePaths.production(libraryID: LibraryIdentity(rootURL: root), libraryRoot: root)
        let metadataStore = try MetadataStore(storagePaths: paths)
        let project = ProjectRecord(id: UUID(), catalogID: "M31", displayName: "Andromeda Galaxy", phase: .collecting)
        try await metadataStore.save(project)
        try await metadataStore.createProjectAnnotation(.init(
            projectID: project.id,
            integrationGoalHours: 8,
            notes: "Initial field note",
            updatedAt: now
        ))

        let briefingStore = NightBriefingRevisionStore(directory: paths.briefings)
        let briefingID = UUID()
        _ = try await briefingStore.create(NightBriefingDraft(
            id: briefingID,
            savedAt: now,
            checklist: [BriefingChecklistSection(
                id: "setup",
                title: "Setup",
                items: [BriefingChecklistItem(id: "focus", title: "Focus")]
            )],
            notes: "Mac briefing note"
        ))

        let revisionStore = MobileSnapshotRevisionStore(
            fileURL: root.appendingPathComponent(".astro-tool/mobile-snapshot-revision.json")
        )

        return RoundTripFixture(
            root: root,
            macStagingDirectory: root.appendingPathComponent("mac-staging", isDirectory: true),
            phoneStagingDirectory: root.appendingPathComponent("phone-staging", isDirectory: true),
            decoyRelativePaths: decoys,
            sentinelBinary: sentinelBinary,
            forbiddenStrings: forbidden,
            now: now,
            libraryID: libraryID,
            metadataStore: metadataStore,
            briefingStore: briefingStore,
            briefingID: briefingID,
            project: project,
            revisionStore: revisionStore
        )
    }

    /// A fresh snapshot of the LIVE domain state (recomposed from the real
    /// stores every call, so the second session's forward snapshot reflects
    /// the checklist completion and note update the first session applied),
    /// with the next revision this fixture's own `MobileSnapshotRevisionStore`
    /// will actually accept for publication.
    func composeSnapshot() async throws -> MobileLibrarySnapshot {
        let revision = try await revisionStore.next()
        let projects = try await metadataStore.projects()
        var annotations: [ProjectAnnotationRecord] = []
        for candidate in projects {
            if let annotation = try await metadataStore.projectAnnotation(projectID: candidate.id) {
                annotations.append(annotation)
            }
        }
        let briefings = try await briefingStore.latestRevisions()
        return try MobileSnapshotComposer().compose(
            input: .init(
                libraryID: libraryID,
                revision: revision,
                projects: projects,
                nights: [],
                captures: [],
                annotations: annotations,
                briefings: briefings,
                integrationSecondsByCaptureID: [:]
            ),
            now: now
        )
    }

    /// Best-effort cleanup of both the fixture root and the real
    /// per-library Application Support / Caches directories that
    /// `AppStoragePaths.production` creates outside `root`.
    func cleanUp() {
        let identity = LibraryIdentity(rootURL: root)
        try? FileManager.default.removeItem(at: root)
        guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        for base in [applicationSupport, caches] {
            let libraryDirectory = base
                .appendingPathComponent("AstroTool", isDirectory: true)
                .appendingPathComponent("Libraries", isDirectory: true)
                .appendingPathComponent(identity.id, isDirectory: true)
            try? FileManager.default.removeItem(at: libraryDirectory)
        }
    }
}

// MARK: - Manifest capture (crib of `MobilePackageSmokeTests`' own helper)

private func captureManifest(of root: URL) throws -> [String: (sha256: String, size: Int)] {
    let fileManager = FileManager.default
    var result: [String: (sha256: String, size: Int)] = [:]
    guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    ) else { return result }
    let rootPath = root.standardizedFileURL.path
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var relative = url.standardizedFileURL.path
        if relative.hasPrefix(rootPath) { relative.removeFirst(rootPath.count) }
        if relative.hasPrefix("/") { relative.removeFirst() }
        result[relative] = (digest, data.count)
    }
    return result
}

// MARK: - Raw package byte scanning (crib of `MobilePackageSmokeTests`' own helper)

/// Scans a package directory's `manifest.json` + encrypted payload bytes --
/// exactly the shape `NearbyPackageTransport` stages on disk while a
/// `handleForwardPackage`/`previewReturn` callback runs, i.e. the ACTUAL
/// wire-transferred bytes, before that transport's own cleanup `defer`
/// removes them -- for any of the fixture's forbidden decoy material.
private func assertPackageBytesContainNoForbiddenMaterial(
    at packageDirectory: URL,
    forbiddenStrings: [String],
    forbiddenBinarySequences: [[UInt8]]
) throws {
    for name in [MobilePackageService.manifestFileName, MobilePackageService.encryptedPayloadFileName] {
        let data = try Data(contentsOf: packageDirectory.appendingPathComponent(name))
        for forbidden in forbiddenStrings {
            #expect(data.range(of: Data(forbidden.utf8)) == nil, "\(name) leaked \(forbidden)")
        }
        for sequence in forbiddenBinarySequences {
            #expect(data.range(of: Data(sequence)) == nil, "\(name) leaked the binary sentinel")
        }
    }
}
