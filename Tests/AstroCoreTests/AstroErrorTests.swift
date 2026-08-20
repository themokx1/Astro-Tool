import Foundation
import Testing
@testable import AstroCore

/// Task 14 (2026-08-16, owner screenshot): `AstroError` was not
/// `LocalizedError`, so `localizedDescription` fell back to Swift's default
/// `"AstroCore.AstroError error 4"` -- an internal type name and case index
/// shown to the user, while the case's own associated value (the actual
/// explanation) was silently discarded. These tests pin the fix: every case
/// produces an honest, non-empty sentence that never names the Swift type or
/// a case index, and carries its own payload where it has one. `recovery`
/// is tested separately since it drives the dialog's buttons, not its text
/// (Step 1 of the plan) -- a wrong diagnosis must become a wrong BUTTON,
/// something noticeable, not just a wrong sentence.
@Suite("AstroError descriptions and recovery")
struct AstroErrorTests {
    private static let allCases: [AstroError] = [
        .accessDenied(path: "/Volumes/Archive/M31"),
        .volumeNotMounted(path: "/Volumes/Archive"),
        .pathNotFound(path: "/Volumes/Archive/M31/missing"),
        .corruptFITS(path: "/Volumes/Archive/light_0001.fits", reason: "truncated header"),
        .databaseError("disk I/O error"),
        .writeForbidden(path: "/Volumes/Archive/readonly.txt"),
        .sirilNotFound(path: "/usr/local/bin/siril-cli"),
        .invalidInput("A pontozási worker pozitív legyen."),
    ]

    @Test("Every case has a non-empty errorDescription")
    func everyCaseHasNonEmptyDescription() {
        for error in Self.allCases {
            let description = error.errorDescription
            #expect(description != nil, "\(error) has no errorDescription")
            #expect(!(description ?? "").isEmpty, "\(error) has an empty errorDescription")
        }
    }

    @Test("No description names the Swift type or a raw case index")
    func noDescriptionLeaksSwiftInternals() {
        for error in Self.allCases {
            let description = error.errorDescription ?? ""
            #expect(!description.contains("AstroError"), "\(error) leaks its own type name: \(description)")
            #expect(!description.contains("AstroCore"), "\(error) leaks its module name: \(description)")
        }
    }

    @Test("localizedDescription now resolves through errorDescription, not Swift's default")
    func localizedDescriptionUsesErrorDescription() {
        // This is the exact defect from the owner's screenshot: `.databaseError`
        // (case index 4) rendered as "AstroCore.AstroError error 4" because
        // AstroError was not LocalizedError.
        let error = AstroError.databaseError("disk I/O error")
        #expect(error.localizedDescription == error.errorDescription)
        #expect(!error.localizedDescription.contains("error 4"))
    }

    @Test("databaseError surfaces its own detail instead of discarding it")
    func databaseErrorShowsItsOwnDetail() {
        let error = AstroError.databaseError("disk I/O error")
        #expect(error.errorDescription?.contains("disk I/O error") == true)
    }

    @Test("Every case's description mentions its own path or detail, not a generic sentence")
    func everyCaseMentionsItsOwnPayload() {
        #expect(AstroError.accessDenied(path: "/a/b").errorDescription?.contains("/a/b") == true)
        #expect(AstroError.volumeNotMounted(path: "/a/b").errorDescription?.contains("/a/b") == true)
        #expect(AstroError.pathNotFound(path: "/a/b").errorDescription?.contains("/a/b") == true)
        #expect(AstroError.corruptFITS(path: "/a/b", reason: "bad header").errorDescription?.contains("/a/b") == true)
        #expect(AstroError.corruptFITS(path: "/a/b", reason: "bad header").errorDescription?.contains("bad header") == true)
        #expect(AstroError.writeForbidden(path: "/a/b").errorDescription?.contains("/a/b") == true)
        #expect(AstroError.sirilNotFound(path: "/a/b").errorDescription?.contains("/a/b") == true)
        #expect(AstroError.invalidInput("custom detail").errorDescription?.contains("custom detail") == true)
    }

    @Test("recovery matches the plan's mapping: only a stale bookmark or a transient failure gets an actionable button")
    func recoveryMapping() {
        #expect(AstroError.accessDenied(path: "/a").recovery == .rechooseLibrary)
        #expect(AstroError.pathNotFound(path: "/a").recovery == .rechooseLibrary)
        #expect(AstroError.volumeNotMounted(path: "/a").recovery == .retry)
        #expect(AstroError.databaseError("x").recovery == .retry)
        #expect(AstroError.corruptFITS(path: "/a", reason: "x").recovery == .none)
        #expect(AstroError.writeForbidden(path: "/a").recovery == .none)
        #expect(AstroError.sirilNotFound(path: "/a").recovery == .none)
        #expect(AstroError.invalidInput("x").recovery == .none)
    }
}
