import AppKit
import Quartz
import SwiftUI

/// V2's Quick Look entry point: opens the shared `QLPreviewPanel` for one
/// file -- a straight port of V1's `QuickLookController`
/// (`Sources/AstroToolApp/Views/QuickLookController.swift`). One-shot: each
/// call installs a fresh single-item data source/delegate pair and shows
/// the panel -- enough for "preview this one file", not a scrubbable
/// multi-item gallery.
@MainActor
final class QuickLookPreviewController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreviewController()

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

/// The standard AppKit dance for a spacebar-triggered Quick Look, isolated
/// here so `ReviewWorkspace`/`ResultsView` never touch `NSEvent` directly.
/// A SwiftUI `Table` row has no stable `NSResponder` this could attach
/// `acceptsPreviewPanelControl`/`beginPreviewPanelControl` to without
/// fighting the table's own event handling (the same limitation V1's own
/// `QuickLookController` doc comment notes) -- so instead of hooking the
/// table's responder chain, this installs a local key-down monitor scoped
/// to the hosting window and only intercepts a bare space while: the host
/// view's window is key, `isEnabled()` reports a single selection exists,
/// and the current first responder isn't a text-editing view (so typing an
/// actual space into a filter/search field is never swallowed).
struct QuickLookSpacebarMonitor: NSViewRepresentable {
    let isEnabled: () -> Bool
    let onSpace: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitoringView()
        view.onSpace = onSpace
        view.isEnabledProvider = isEnabled
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MonitoringView else { return }
        view.onSpace = onSpace
        view.isEnabledProvider = isEnabled
    }

    final class MonitoringView: NSView {
        var onSpace: (() -> Void)?
        var isEnabledProvider: (() -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
                guard let self, let window, event.window === window,
                      self.isEnabledProvider?() == true,
                      event.charactersIgnoringModifiers == " ",
                      !(window.firstResponder is NSText) else {
                    return event
                }
                self.onSpace?()
                return nil
            }
        }

        // No `deinit` cleanup here: accessing a main-actor-isolated stored
        // property from a nonisolated `deinit` is a Swift 6 concurrency
        // error for an `Any` monitor token. `viewDidMoveToWindow(nil)` --
        // which AppKit already calls when this view leaves its window,
        // before it's ever deallocated -- removes the monitor above instead.

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
