@preconcurrency import FileProvider
import Foundation
import OSLog
import PlumeKit

/// The File Provider domain: "Plume" in Finder's sidebar and in the Files
/// app's locations. One domain, for the signed-in account.
enum FileProviderControl {
    static let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("plume"), displayName: "Plume")

    private static let log = Logger(subsystem: "Plume", category: "FileProvider")

    static func register() async {
        do {
            try await NSFileProviderManager.add(domain)
            log.info("File Provider domain added")
        } catch {
            log.error("File Provider domain not added: \(error, privacy: .public)")
        }
    }

    /// Removes the domain and the files the system downloaded for it.
    #if DEBUG
    static func removeAllAndWait() {
        let done = DispatchSemaphore(value: 0)
        NSFileProviderManager.removeAllDomains { _ in done.signal() }
        _ = done.wait(timeout: .now() + 10)
    }
    #endif

    static func removeAll() async {
        try? await NSFileProviderManager.removeAllDomains()
    }

    /// Asks the extension to look for changes on the server.
    static func signalChanges() {
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
    }

    /// The item's location in Finder / Files, when the system knows it.
    static func userVisibleURL(for item: RemoteItem) async -> URL? {
        guard let manager = NSFileProviderManager(for: domain) else { return nil }
        let identifier: NSFileProviderItemIdentifier =
            item.path.isRoot ? .rootContainer : NSFileProviderItemIdentifier(item.fileID)
        return try? await manager.getUserVisibleURL(for: identifier)
    }
}
