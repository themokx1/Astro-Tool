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
