import AppKit
import Foundation
import PDFKit
import WebKit

@MainActor
public protocol NightBriefingPDFExporting {
    func pdfData(html: String) async throws -> Data
}

public enum NightBriefingPDFExportError: Error, Equatable, Sendable {
    case navigationFailed
    case printingFailed
    case emptyPDF
}

@MainActor
public final class NightBriefingPDFExporter: NightBriefingPDFExporting {
    public init() {}

    public func pdfData(html: String) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let pageSize = CGSize(width: 595.28, height: 841.89)
        let webView = WKWebView(frame: CGRect(origin: .zero, size: pageSize), configuration: configuration)
        let navigation = NavigationWaiter()
        webView.navigationDelegate = navigation
        try await navigation.load(html: html, in: webView)

        let totalHeight = try await paginate(webView: webView, pageHeight: pageSize.height)
        let pageCount = max(1, Int(ceil(totalHeight / pageSize.height)))
        let combined = PDFDocument()
        for index in 0..<pageCount {
            let pdfConfiguration = WKPDFConfiguration()
            pdfConfiguration.rect = CGRect(
                x: 0,
                y: CGFloat(index) * pageSize.height,
                width: pageSize.width,
                height: pageSize.height
            )
            let pageData = try await webView.pdf(configuration: pdfConfiguration)
            guard let pageDocument = PDFDocument(data: pageData), let page = pageDocument.page(at: 0) else {
                throw NightBriefingPDFExportError.printingFailed
            }
            combined.insert(page, at: combined.pageCount)
        }
        guard let data = combined.dataRepresentation(), data.starts(with: Data("%PDF".utf8)) else {
            throw NightBriefingPDFExportError.printingFailed
        }
        guard !data.isEmpty else { throw NightBriefingPDFExportError.emptyPDF }
        return data
    }

    private func paginate(webView: WKWebView, pageHeight: CGFloat) async throws -> CGFloat {
        let script = """
        (() => {
          const pageHeight = \(pageHeight);
          document.documentElement.style.margin = '0';
          document.body.style.margin = '0';
          const sections = Array.from(document.body.children);
          let total = 0;
          for (const section of sections) {
            section.style.minHeight = '0px';
            section.style.height = 'auto';
            const pages = Math.max(1, Math.ceil(section.scrollHeight / pageHeight));
            section.style.height = `${pages * pageHeight}px`;
            section.style.overflow = 'hidden';
            total += pages * pageHeight;
          }
          return total;
        })()
        """
        let result = try await webView.evaluateJavaScript(script)
        guard let number = result as? NSNumber else {
            throw NightBriefingPDFExportError.navigationFailed
        }
        return CGFloat(number.doubleValue)
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(html: String, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            guard webView.loadHTMLString(html, baseURL: nil) != nil else {
                self.continuation = nil
                continuation.resume(throwing: NightBriefingPDFExportError.navigationFailed)
                return
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
