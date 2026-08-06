import AppKit
import Quartz

/// R9-T6/B7's Quick Look entry point: opens the shared `QLPreviewPanel` for
/// one file. Documented choice (per the task's own scope note): wiring the
/// Space key directly into a SwiftUI `Table`'s selection/responder chain
/// proved too fiddly to do reliably (a `Table` row has no stable
/// `NSResponder` this type could attach `acceptsPreviewPanelControl`/
/// `beginPreviewPanelControl` to without fighting the table's own event
/// handling) -- so every call site instead offers a plain "Nagy előnézet"
/// context-menu item that calls `preview(_:)` directly. One-shot: each call
/// installs a fresh single-item data source/delegate pair and shows the
/// panel, which is enough for "preview this one file", not a scrubbable
/// multi-item gallery.
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var previewURL: URL?

    func preview(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}
