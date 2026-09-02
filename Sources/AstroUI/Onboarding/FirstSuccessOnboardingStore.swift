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

    public init(mode: Mode) {
        self.mode = mode
    }

    public func chooseEntry(_ choice: EntryChoice) {
        errorMessage = nil
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
}
