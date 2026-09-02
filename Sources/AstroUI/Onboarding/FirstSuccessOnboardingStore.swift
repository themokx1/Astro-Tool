import Foundation
import Observation

/// Navigation state for the shared first-run/help onboarding. Business
/// operations stay in their existing commands and stores; this type records
/// only the user's path and honest completion facts.
@MainActor
@Observable
public final class FirstSuccessOnboardingStore {
    public enum Mode: Equatable, Sendable {
        case firstRun
        case help
    }

    public enum EntryChoice: Equatable, Sendable {
        case createLibrary
        case openLibrary
        case understand
    }

    public enum Step: Equatable, Sendable {
        case landing
        case understanding(Int)
        case createLibrary
        case openLibrary
        case importOffer
        case importFlow
        case completion
    }

    /// What the import wizard's own "Create Structure" step actually wrote
    /// to disk during this journey, if anything -- item 3 (2026-09-02 v5
    /// flow fixes): `CaptureImportStore` is `@State` inside `CaptureImportView`,
    /// so it dies the moment the user backs out to `.importOffer`
    /// (`cancelImport()`); without this, the completion screen had no way
    /// to know a real session/capture folder tree was already created, even
    /// when it plainly was, and said "No project or capture was created"
    /// regardless.
    public struct CreatedStructureSummary: Equatable, Sendable {
        public let targetFolder: String
        public let date: String
        public let captureSlug: String?

        public init(targetFolder: String, date: String, captureSlug: String?) {
            self.targetFolder = targetFolder
            self.date = date
            self.captureSlug = captureSlug
        }
    }

    public let mode: Mode
    public private(set) var step: Step = .landing
    public private(set) var hasOpenedLibrary = false
    public private(set) var didSkipImport = false
    public private(set) var didCreateFirstProject = false
    /// 2026-09-02 audit, fix C: the guided first success cannot run
    /// read-only -- the optional import step right after a ready library
    /// copies files into it -- so every path to `libraryBecameReady()` has
    /// to turn write operations on. The host owns the actual flag (an
    /// `@AppStorage` this store cannot see), but the requirement is recorded
    /// here so "the create path enables writes, the open-existing path
    /// forgot to" is a testable fact rather than something only a view knew.
    public private(set) var requiresWriteOperations = false
    public private(set) var errorMessage: String?
    public private(set) var createdStructure: CreatedStructureSummary?

    public init(mode: Mode) {
        self.mode = mode
    }

    public func chooseEntry(_ choice: EntryChoice) {
        errorMessage = nil
        // A fresh entry choice starts a new journey attempt -- whatever the
        // PREVIOUS attempt's wizard created (or didn't) no longer describes
        // what this one will do.
        createdStructure = nil
        switch choice {
        case .createLibrary: step = .createLibrary
        case .openLibrary: step = .openLibrary
        case .understand: step = .understanding(0)
        }
    }

    public func advanceUnderstanding(pageCount: Int) {
        guard case .understanding(let page) = step, pageCount > 0 else { return }
        step = .understanding(min(page + 1, pageCount - 1))
    }

    public func finishUnderstanding() {
        step = .landing
    }

    public func libraryBecameReady() {
        hasOpenedLibrary = true
        requiresWriteOperations = true
        errorMessage = nil
        step = .importOffer
    }

    public func startImport() {
        guard hasOpenedLibrary else { return }
        step = .importFlow
    }

    public func skipImport() {
        guard hasOpenedLibrary else { return }
        didSkipImport = true
        didCreateFirstProject = false
        step = .completion
    }

    public func importCompleted(createdFirstProject: Bool) {
        didSkipImport = false
        didCreateFirstProject = createdFirstProject
        step = .completion
    }

    public func cancelImport() {
        guard hasOpenedLibrary else { return }
        didSkipImport = false
        didCreateFirstProject = false
        step = .importOffer
    }

    public func returnToLanding() {
        errorMessage = nil
        step = .landing
    }

    public func reportError(_ message: String) {
        errorMessage = message
    }

    public func clearError() {
        errorMessage = nil
    }

    /// Called by the import wizard's own Create Structure step once it
    /// actually wrote a session/capture folder tree -- the one fact the
    /// completion screen needs to stay honest even if the user cancels
    /// everything else afterward.
    public func recordCreatedStructure(targetFolder: String, date: String, captureSlug: String?) {
        createdStructure = CreatedStructureSummary(targetFolder: targetFolder, date: date, captureSlug: captureSlug)
    }

    /// Called once the wizard's own Undo removes the structure `
    /// recordCreatedStructure` reported -- the completion screen must not
    /// keep claiming folders exist that the user just removed.
    public func clearCreatedStructure() {
        createdStructure = nil
    }
}
