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

        let parent = destination.standardizedFileURL.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(
            ".astrotool-briefing-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer {
            // This directory was created by this export invocation. Never
            // clean a user-selected final destination, even after failure.
            try? fileManager.removeItem(at: staging)
        }

        let stagedPDF = staging.appendingPathComponent("briefing.pdf")
        if pdfURL != nil {
            try pdfData.write(to: stagedPDF, options: .atomic)
        }

        let stagedPages = staging.appendingPathComponent("pages", isDirectory: true)
        for (index, data) in pngPages.enumerated() {
            if index == 0 {
                try fileManager.createDirectory(at: stagedPages, withIntermediateDirectories: false)
            }
            let url = stagedPages.appendingPathComponent("page-\(index + 1).png")
            try data.write(to: url, options: .atomic)
        }

        if let pdfURL {
            try commit(stagedPDF, to: pdfURL)
        }
        guard let pngDirectory else {
            return BriefingExportResult(pdfURL: pdfURL, pngURLs: [])
        }
        try commit(stagedPages, to: pngDirectory)
        let urls = pngPages.indices.map {
            pngDirectory.appendingPathComponent("page-\($0 + 1).png")
        }
        return BriefingExportResult(pdfURL: pdfURL, pngURLs: urls)
    }

    private func commit(_ staged: URL, to final: URL) throws {
        do {
            try fileManager.moveItem(at: staged, to: final)
        } catch {
            if fileManager.fileExists(atPath: final.path) {
                throw NightBriefingExportError.outputAlreadyExists(final)
            }
            throw error
        }
    }
}
