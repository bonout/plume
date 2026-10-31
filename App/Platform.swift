import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The few things done differently on each platform.
@MainActor
enum Platform {
    static func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// The system share sheet for a local file ("Open in…", AirDrop, Mail…).
    static func share(_ url: URL) {
        #if os(macOS)
        guard let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1),
                    of: view, preferredEdge: .minY)
        #else
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = top.view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
        top.present(controller, animated: true)
        #endif
    }

    #if os(macOS)
    /// Opens or reveals the item through Finder's Plume location, where
    /// changes made by other apps are synced back.
    static func openInFinder(_ url: URL, reveal: Bool) {
        if reveal {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }
    #endif
}
