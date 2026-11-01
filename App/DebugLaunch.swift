#if os(macOS)
import AppKit
#endif
import PlumeKit
import SwiftUI

/// Debug builds only: launch arguments that put the app in a given state,
/// for screenshots and manual tests against a throwaway server
/// (fastlane snapshot, scripts/mac-store-captures.sh). Release builds ignore them.
///
///   -PlumeInitialTab favorites       Mac: section shown at launch
///   -PlumeSearch "lisbon"            search typed at launch
///   -PlumeInitialPath "Lisbon 2026"  folder opened in the Files tab
///   -PlumePreview "Taxes/x.pdf"      file shown in Quick Look
///   -PlumePin "Lisbon 2026"          made available offline
///   -PlumeSnapshot /tmp/mac.png      Mac: the window saved as PNG, then quit
///   -PlumeSheet trash                a screen opened at launch: trash,
///               versions:<path>, sharing:<path>
enum DebugLaunch {
    private static func value(_ key: String) -> String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: key)
        #else
        nil
        #endif
    }

    static var initialSection: AppModel.Section {
        value("PlumeInitialTab").flatMap(AppModel.Section.init(rawValue:)) ?? .files
    }

    /// The folder and its parents, as a navigation stack.
    static var initialPath: [RemotePath] {
        value("PlumeInitialPath").map { RemotePath($0).ancestry } ?? []
    }

    static var initialSearch: String { value("PlumeSearch") ?? "" }

    static var preview: RemotePath? { value("PlumePreview").map(RemotePath.init) }
    static var pin: RemotePath? { value("PlumePin").map(RemotePath.init) }
    static var sheet: (kind: String, path: RemotePath?)? {
        value("PlumeSheet").map { value in
            let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? RemotePath(parts[1]) : nil)
        }
    }

    static var resetAccount: Bool { value("PlumeResetAccount") == "YES" }
    static var importSample: String? { value("PlumeImportSample") }
    static var serverField: String? { value("PlumeServerField") }

    static var snapshot: URL? { value("PlumeSnapshot").map { URL(filePath: $0) } }

    /// Applies the arguments that act on the account once signed in.
    @MainActor
    static func apply(to model: AppModel) async {
        guard let repository = model.repository else { return }
        if let pin, let item = (try? await repository.client.item(at: pin)).map({ repository.store.upsert($0) }) {
            try? await repository.makeAvailableOffline(item)
        }
        if let importSample {
            let url = FileManager.default.temporaryDirectory.appending(path: importSample)
            try? Data("Plume".utf8).write(to: url)
            try? await Task.sleep(for: .seconds(2))
            model.pendingImports = [url]
        }
        if let preview, let item = (try? await repository.client.item(at: preview)).map({ repository.store.upsert($0) }) {
            // After the initial navigation, or Quick Look is dropped.
            try? await Task.sleep(for: .seconds(2))
            model.open(item)
        }
    }

    #if os(macOS)
    /// Saves the app's window, title bar included, without the screen
    /// recording permission a screenshot would need.
    @MainActor
    static func takeSnapshot() async {
        guard let url = snapshot else { return }
        // Light: the translucent sidebar is drawn as a plain light area.
        NSApp.appearance = NSAppearance(named: .aqua)
        try? await Task.sleep(for: .seconds(8))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let frame = window.contentView?.superview,
              let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        NSApp.terminate(nil)
    }
    #endif
}
