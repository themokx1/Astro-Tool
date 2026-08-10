import Foundation
import Testing

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func detachedTaskBodies(in source: String) -> [Substring] {
    var bodies: [Substring] = []
    var searchStart = source.startIndex

    while let taskRange = source.range(of: "Task.detached", range: searchStart..<source.endIndex),
          let openingBrace = source[taskRange.upperBound...].firstIndex(of: "{") {
        var depth = 0
        var cursor = openingBrace

        while cursor < source.endIndex {
            switch source[cursor] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    bodies.append(source[source.index(after: openingBrace)..<cursor])
                    searchStart = source.index(after: cursor)
                    break
                }
            default: break
            }

            if depth == 0 { break }
            cursor = source.index(after: cursor)
        }

        if depth != 0 { break }
    }

    return bodies
}

@Test func appPreviewWorkersDoNotCreateNonSendableNSImages() throws {
    let root = repositoryRoot()
    let paths = [
        "Sources/AstroToolApp/Views/ThumbnailCell.swift",
        "Sources/AstroToolApp/Views/FrameReviewSheet.swift",
    ]

    for path in paths {
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        let taskBodies = detachedTaskBodies(in: source)
        #expect(!taskBodies.isEmpty, "Expected background preview work in \(path)")
        #expect(
            taskBodies.allSatisfy { !$0.contains("NSImage") },
            "NSImage is not Sendable; detached workers must return CGImage or Data and create NSImage on the main actor in \(path)"
        )
    }
}

@Test func quickLookContinuationDoesNotTransportNonSendableNSImage() throws {
    let sourceURL = repositoryRoot()
        .appendingPathComponent("Sources/AstroToolApp/Views/ThumbnailCell.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(
        !source.contains("CheckedContinuation<NSImage"),
        "Quick Look callbacks run on an arbitrary queue; their continuation must transport CGImage, not NSImage"
    )
}

@Test func quickLookCompletionBridgeIsExplicitlyNonisolated() throws {
    let sourceURL = repositoryRoot()
        .appendingPathComponent("Sources/AstroToolApp/Views/ThumbnailCell.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(
        source.contains("enum QuickLookThumbnailBridge"),
        "The arbitrary-queue Quick Look callback must live outside the main-actor-inferred SwiftUI View"
    )
    #expect(
        source.contains("nonisolated static func cgImage"),
        "Swift 6 must see an explicit nonisolated boundary before Quick Look invokes its completion handler"
    )
}

@Test func everyAppDiscoveryLoadUsesTheManualFirstFOVResolver() throws {
    let sourceURL = repositoryRoot()
        .appendingPathComponent("Sources/AstroToolApp/AppState.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    let resolverCallCount = source.components(separatedBy: "FieldGeometry.discoveryFOV(").count - 1
    #expect(resolverCallCount == 3, "loadDiscovery, header-site recognition, and site-scoped refresh must resolve the same setup FOV")
    #expect(!source.contains("let fov = try FieldGeometry.dominantFOV"))
    #expect(source.contains("selectedImagingSetupIDKey"))
    #expect(source.contains("discoveryFocalLengthsBySetup"))
}

@Test func discoveryPageExposesSetupSelectionZoomControlAndEquipmentDeepLink() throws {
    let sourceURL = repositoryRoot()
        .appendingPathComponent("Sources/AstroToolApp/Views/DiscoveryPage.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("setupPicker"))
    #expect(source.contains("focalLengthDraftBinding(for: setup)"))
    #expect(source.contains("appState.settingsTab = .equipment"))
    #expect(source.contains("nincs kézi setup vagy WCS-adat"))
}

@Test func discoveryZoomEditingUsesAnAppliedDraftAndInvalidSetupsRemainRecoverable() throws {
    let sourceURL = repositoryRoot()
        .appendingPathComponent("Sources/AstroToolApp/Views/DiscoveryPage.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("@State private var focalLengthDraftMM"))
    #expect(source.contains("applyFocalLength"))
    #expect(source.contains("activeManualSetupIsValid"))
    #expect(source.contains("Érvénytelen setup javítása…"))
    #expect(source.contains("setup.name) — \\(setup.cameraName"))
}

@Test func equipmentChangesQueueDiscoveryRefreshAcrossBusyOperations() throws {
    let appStateURL = repositoryRoot()
        .appendingPathComponent("Sources/AstroToolApp/AppState.swift")
    let settingsURL = repositoryRoot()
        .appendingPathComponent("Sources/AstroToolApp/Views/Settings/EquipmentSettingsView.swift")
    let appStateSource = try String(contentsOf: appStateURL, encoding: .utf8)
    let settingsSource = try String(contentsOf: settingsURL, encoding: .utf8)

    #expect(appStateSource.contains("pendingDiscoveryRefreshAfterEquipmentChange"))
    #expect(appStateSource.contains("refreshDiscoveryAfterEquipmentChange"))
    #expect(appStateSource.contains("flushPendingDiscoveryRefresh"))
    #expect(settingsSource.contains("appState.refreshDiscoveryAfterEquipmentChange()"))
    #expect(!settingsSource.contains("appState.discovery != nil, !appState.isBusy"))
}

@Test func setupAndFocalChangesInvalidateTheOldDiscoveryResultBeforeReloading() throws {
    let sourceURL = repositoryRoot()
        .appendingPathComponent("Sources/AstroToolApp/AppState.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("invalidateDiscoveryForSetupChange"))
    #expect(source.contains("let shouldReload = discovery != nil"))
    #expect(source.contains("discovery = nil\n        discoveryFOV = nil"))
}
