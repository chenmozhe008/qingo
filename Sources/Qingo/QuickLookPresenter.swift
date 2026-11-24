import AppKit
@preconcurrency import Quartz

/// Minimal native macOS Quick Look preview helper for inspecting files before deletion.
final class QuickLookPreviewController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    @MainActor static let shared = QuickLookPreviewController()

    private nonisolated(unsafe) var previewURL: URL?

    @MainActor
    func preview(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible && panel.dataSource === self {
            panel.reloadData()
        } else {
            panel.dataSource = self
            panel.delegate = self
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }
}
