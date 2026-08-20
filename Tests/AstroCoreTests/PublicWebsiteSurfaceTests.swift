import Foundation
import Testing

@Suite("Public website surface")
struct PublicWebsiteSurfaceTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("Every public page uses one responsive design system")
    func sharedDesignSystem() throws {
        let pages = ["index.html", "features.html", "first-steps.html", "tutorial.html", "cli.html", "privacy.html", "support.html"]
        for page in pages {
            let html = try source("docs/\(page)")
            #expect(html.contains("href=\"assets/site.css\""), Comment(rawValue: page))
            #expect(html.contains("class=\"site-header\""), Comment(rawValue: page))
            #expect(html.contains("class=\"site-footer\""), Comment(rawValue: page))
            #expect(html.contains("class=\"skip-link\""), Comment(rawValue: page))
            #expect(html.contains("id=\"main-content\""), Comment(rawValue: page))
            #expect(!html.contains("<style>"), Comment(rawValue: page))
        }
        let css = try source("docs/assets/site.css")
        #expect(css.contains(".skip-link:focus"))
        #expect(css.contains("prefers-reduced-motion"))
        #expect(css.contains("prefers-color-scheme"))
        #expect(css.contains("@media"))
    }

    @Test("First Steps mirrors the novice onboarding and its safety promises")
    func firstStepsMatchesTheApp() throws {
        let html = try source("docs/first-steps.html")
        #expect(html.contains("Új képkönyvtár létrehozása"))
        #expect(html.contains("Már van AstroTool-könyvtáram"))
        #expect(html.contains("Előbb szeretném megérteni"))
        #expect(html.contains("csak ellenőrzött másolatokat készít"))
        #expect(html.contains("A forrásaid változatlanok maradnak"))
        #expect(html.contains("nincs önálló törlés"))
        #expect(html.contains("<details"))
        #expect(html.contains("Mi jön létre a gépemen?"))

        let homepage = try source("docs/index.html")
        #expect(homepage.contains("href=\"first-steps.html\""))
    }

    @Test("Homepage describes the real 2.0 product and Universal download")
    func accurateHomepage() throws {
        let html = try source("docs/index.html")
        #expect(html.contains("AstroTool 2.0"))
        #expect(html.contains("Apple Silicon és Intel"))
        #expect(html.contains("A képeid a Maceden maradnak"))
        #expect(html.contains("Az audit nem töröl és nem mozgat"))
        #expect(!html.contains("jobbklikk"))
        #expect(!html.contains("nincs notarizálva"))
    }

    @Test("Public pages contain no personal library examples or claims")
    func noPersonalExamples() throws {
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let files = FileManager.default.enumerator(at: docs, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "html" }
        for file in files {
            let html = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["/Volumes/images", "167 GB", "42,5 h-ból 28 h", "Canon R8", "SV220", "IC 1396 · Elefántormány-köd", ">4:12<", ">3 gyűjtés<"] {
                #expect(!html.contains(forbidden), Comment(rawValue: "\(file.lastPathComponent): \(forbidden)"))
            }
        }
        let homepage = try source("docs/index.html")
        #expect(homepage.contains("Mintaadat"))
    }

    @Test("Privacy and support promises match the app")
    func truthfulPrivacyAndSupport() throws {
        let privacy = try source("docs/privacy.html")
        #expect(privacy.contains("Open-Meteo"))
        #expect(privacy.contains("kikapcsolva"))
        #expect(privacy.contains("FITS"))
        let support = try source("docs/support.html")
        #expect(support.contains("Biztonságos diagnosztika"))
        #expect(support.contains("Beállítások"))
    }
}
