import AppKit
import AstroApplication
import SwiftUI
import UniformTypeIdentifiers

/// Writes an export's rendered content to a caller-chosen destination --
/// separated from `ExportMenu`'s own `NSSavePanel` call so the actual write
/// path is unit-testable (`NSSavePanel.runModal()` cannot run headlessly;
/// this function can), same shape `SupportDiagnosticsFileWriter` already
/// established for the Settings "Save Diagnostics" button. The panel only
/// ever supplies `url` -- this never invents a destination of its own,
/// matching this worktree's "file writes go ONLY to user-chosen NSSavePanel
/// destinations" rule.
public enum ExportFileWriter {
    public static func write(content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// One entry in an `ExportMenu` -- either a file the user saves through an
/// `NSSavePanel`, or text that goes straight to the general pasteboard.
/// `make` runs lazily, right when the user actually picks the item, so it
/// always reflects whatever's on screen at that moment rather than data
/// captured when the menu was built.
public enum ExportMenuItem: Identifiable {
    /// A file export: `make` renders the content once the user picks this
    /// item, returning content, a suggested `NSSavePanel` filename, and any
    /// warning lines to surface afterward (e.g. an unmapped AstroBin filter)
    /// -- `warnings` is `[]` for every export that has nothing to warn about.
    case file(
        title: String,
        systemImage: String,
        contentType: UTType,
        make: () throws -> (content: String, suggestedFilename: String, warnings: [String])
    )
    /// A clipboard export: `make` renders the text to copy.
    case clipboard(title: String, systemImage: String, make: () throws -> String)
    case divider

    /// Stable per case -- `title` is unique within one `ExportMenu`'s own
    /// item list by construction (each call site lists its own distinct
    /// export actions), and every `ExportMenu` only ever has at most one
    /// `.divider` between its file and clipboard groups, so a fixed string
    /// never collides. Deliberately NOT a fresh `UUID()` per access: that
    /// would change on every `body` evaluation and defeat `ForEach`'s own
    /// diffing for no benefit.
    public var id: String {
        switch self {
        case let .file(title, _, _, _): "file:\(title)"
        case let .clipboard(title, _, _): "clipboard:\(title)"
        case .divider: "divider"
        }
    }
}

/// Wave 4 (post-20014) fix: `WorkspaceActionExportMenu` -- the data-driven
/// export-menu payload `WorkspaceActionCenter` compares to decide whether a
/// republish actually changed anything -- needs `ExportMenuItem` to be
/// `Equatable`. Every case's own `id` already uniquely identifies it within
/// one menu's item list (see `id`'s own doc comment), so comparing by `id`
/// alone is enough; the `make`/render closures are neither comparable nor
/// worth comparing.
extension ExportMenuItem: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

/// A reusable "Export" `Menu` -- every V2 export surface (Project workspace,
/// Night workspace, Home's tonight section, Results) builds the exact same
/// component, differing only in which `ExportMenuItem`s they pass in. Wires
/// each item to the right sink (`NSSavePanel` + `ExportFileWriter` for a
/// file, `NSPasteboard` for clipboard text), and posts a success/failure
/// toast through `OperationHost` after every attempt -- a non-empty
/// `warnings` list (currently only ever the unmapped-AstroBin-filter case)
/// additionally raises a detail alert, since a toast alone scrolls past too
/// quickly for something the user needs to act on in Settings.
public struct ExportMenu: View {
    let title: String
    let systemImage: String
    let items: [ExportMenuItem]
    let accessibilityID: String
    @Environment(OperationHost.self) private var operationHost
    @State private var pendingWarning: String?

    public init(
        title: String = "Export",
        systemImage: String = "square.and.arrow.up",
        items: [ExportMenuItem],
        accessibilityID: String
    ) {
        self.title = title
        self.systemImage = systemImage
        self.items = items
        self.accessibilityID = accessibilityID
    }

    public var body: some View {
        Menu {
            ForEach(items) { item in
                switch item {
                case let .file(itemTitle, itemImage, contentType, make):
                    Button {
                        performFile(title: itemTitle, contentType: contentType, make: make)
                    } label: {
                        Label(itemTitle, systemImage: itemImage)
                    }
                case let .clipboard(itemTitle, itemImage, make):
                    Button {
                        performClipboard(title: itemTitle, make: make)
                    } label: {
                        Label(itemTitle, systemImage: itemImage)
                    }
                case .divider:
                    Divider()
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .disabled(items.isEmpty)
        .accessibilityIdentifier(accessibilityID)
        .alert(
            "Export Warning",
            isPresented: Binding(
                get: { pendingWarning != nil },
                set: { presented in if !presented { pendingWarning = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pendingWarning ?? "")
        }
    }

    private func performFile(
        title: String,
        contentType: UTType,
        make: () throws -> (content: String, suggestedFilename: String, warnings: [String])
    ) {
        do {
            let rendered = try make()
            let panel = NSSavePanel()
            panel.title = title
            panel.nameFieldStringValue = rendered.suggestedFilename
            panel.allowedContentTypes = [contentType]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try ExportFileWriter.write(content: rendered.content, to: url)
            operationHost.notify(.success, message: "Exported \(url.lastPathComponent)")
            if !rendered.warnings.isEmpty {
                pendingWarning = rendered.warnings.joined(separator: "\n")
            }
        } catch {
            operationHost.notify(.failure, message: "\(title) failed: \(error.localizedDescription)")
        }
    }

    private func performClipboard(title: String, make: () throws -> String) {
        do {
            let text = try make()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            operationHost.notify(.success, message: "\(title) copied to clipboard")
        } catch {
            operationHost.notify(.failure, message: "\(title) failed: \(error.localizedDescription)")
        }
    }
}
