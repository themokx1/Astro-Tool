@testable import AstroUI
import Foundation
import Testing

@Suite("ExportFileWriter")
struct ExportFileWriterTests {
    @Test("Writing content to a file round-trips its exact text")
    func writeRoundTrips() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appendingPathComponent("export.csv")

        try ExportFileWriter.write(content: "a,b,c\n1,2,3\n", to: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == "a,b,c\n1,2,3\n")
    }

    @Test("Writing to a non-existent directory throws instead of silently failing")
    func writeToMissingDirectoryThrows() throws {
        let fileManager = FileManager.default
        let missingDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = missingDirectory.appendingPathComponent("export.csv")

        #expect(throws: (any Error).self) {
            try ExportFileWriter.write(content: "content", to: url)
        }
    }
}
