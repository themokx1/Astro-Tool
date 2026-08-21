import Foundation
import Testing

@Suite("V2 package surface")
struct V2PackageSurfaceTests {
    private func removingComments(from source: String) throws -> String {
        let comments = try NSRegularExpression(
            pattern: #"/\*[\s\S]*?\*/|//[^\r\n]*"#
        )
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        return comments.stringByReplacingMatches(
            in: source,
            range: fullRange,
            withTemplate: ""
        )
    }

    @Test("Package declares V2 boundaries")
    func packageDeclaresV2Boundaries() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let package = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let compactPackage = try removingComments(from: package)
            .filter { !$0.isWhitespace }

        let requiredDeclarations = [
            ".target(name:\"AstroApplication\",dependencies:[\"AstroCore\"])",
            ".target(name:\"AstroUI\",dependencies:[\"AstroApplication\"],linkerSettings:[.linkedFramework(\"WebKit\"),.linkedFramework(\"PDFKit\")])",
            ".executableTarget(name:\"AstroToolApp\",dependencies:[\"AstroCore\",\"AstroApplication\",\"AstroUI\"],resources:[.process(\"Resources\")])",
            ".testTarget(name:\"AstroApplicationTests\",dependencies:[\"AstroApplication\",\"AstroCore\"])",
            ".testTarget(name:\"AstroUITests\",dependencies:[\"AstroUI\",\"AstroApplication\"])",
        ]

        for declaration in requiredDeclarations {
            #expect(
                compactPackage.components(separatedBy: declaration).count == 2,
                Comment(rawValue: "Expected exactly one declaration: \(declaration)")
            )
        }
    }
}
