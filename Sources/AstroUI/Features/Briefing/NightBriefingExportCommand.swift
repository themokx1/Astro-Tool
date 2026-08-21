import AstroApplication
import Foundation

public enum BriefingExportFormat: Equatable, Sendable {
    case pdf
    case pdfAndPNG
    case pngOnly
}

public struct BriefingExportResult: Equatable, Sendable {
    public let pdfURL: URL?
    public let pngURLs: [URL]

    public init(pdfURL: URL?, pngURLs: [URL]) {
        self.pdfURL = pdfURL
        self.pngURLs = pngURLs
    }
}

public enum NightBriefingExportError: Error, Equatable, Sendable {
    case outputAlreadyExists(URL)
}

@MainActor
public struct NightBriefingExportCommand {
    private let pdfExporter: any NightBriefingPDFExporting
    private let pngExporter: NightBriefingPNGExporter
    private let fileManager: FileManager

    public init(
        pdfExporter: any NightBriefingPDFExporting = NightBriefingPDFExporter(),
        pngExporter: NightBriefingPNGExporter = .init(),
        fileManager: FileManager = .default
    ) {
        self.pdfExporter = pdfExporter
        self.pngExporter = pngExporter
        self.fileManager = fileManager
    }

    public func export(
        document: NightBriefingDocument,
        to destination: URL,
        format: BriefingExportFormat
    ) async throws -> BriefingExportResult {
        let pdfURL: URL? = format == .pngOnly ? nil : destination.standardizedFileURL
        let pngDirectory: URL? = format == .pdf
            ? nil
            : (format == .pngOnly
                ? destination.standardizedFileURL
                : destination.deletingPathExtension().appendingPathExtension("pages"))
        for url in [pdfURL, pngDirectory].compactMap({ $0 }) where fileManager.fileExists(atPath: url.path) {
            throw NightBriefingExportError.outputAlreadyExists(url)
        }

        let html = NightBriefingHTMLRenderer().render(document)
        let pdfData = try await pdfExporter.pdfData(html: html)
        let pngPages = pngDirectory == nil ? [] : try pngExporter.pages(from: pdfData, dpi: 144)

        if let pdfURL {
            try pdfData.write(to: pdfURL, options: .withoutOverwriting)
        }
        guard let pngDirectory else {
            return BriefingExportResult(pdfURL: pdfURL, pngURLs: [])
        }

        var completed = false
        try fileManager.createDirectory(at: pngDirectory, withIntermediateDirectories: false)
        defer {
            if !completed { try? fileManager.removeItem(at: pngDirectory) }
        }
        var urls: [URL] = []
        for (index, data) in pngPages.enumerated() {
            let url = pngDirectory.appendingPathComponent(String(format: "page-%02d.png", index + 1))
            try data.write(to: url, options: .withoutOverwriting)
            urls.append(url)
        }
        completed = true
        return BriefingExportResult(pdfURL: pdfURL, pngURLs: urls)
    }
}
