@preconcurrency import FileProvider
import PlumeKit

/// Lists a folder, or (with no folder) the working set: what changed
/// anywhere the system has already looked, found by following etags down
/// from the root. The app signals the working set when it becomes active
/// and periodically while it runs.
final class Enumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private unowned let owner: FileProviderExtension
    private let repository: Repository
    private let folder: RemotePath?

    init(extension owner: FileProviderExtension, repository: Repository, folder: RemotePath?) {
        self.owner = owner
        self.repository = repository
        self.folder = folder
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let observer = UncheckedBox(observer)
        guard let folder else {
            // The working set starts empty: it is made of the changes
            // reported later, for folders the system already knows.
            observer.value.finishEnumerating(upTo: nil)
            return
        }
        Task {
            do {
                let listing = try await repository.refresh(folder)
                let items = listing.children
                    .filter { !FileProviderExtension.isExcluded($0.name) }
                    .map { FileProviderItem($0, parent: owner.parentIdentifier(of: $0, in: repository)) }
                observer.value.didEnumerate(items)
                observer.value.finishEnumerating(upTo: nil)
            } catch {
                observer.value.finishEnumeratingWithError(FileProviderExtension.providerError(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let observer = UncheckedBox(observer)
        Task {
            do {
                let changes = try await repository.changes(under: folder ?? .root)
                let updated = changes.updated
                    .filter { !FileProviderExtension.isExcluded($0.name) }
                    .map { FileProviderItem($0, parent: owner.parentIdentifier(of: $0, in: repository)) }
                let removed = changes.removed
                    .filter { !$0.fileID.isEmpty }
                    .map { NSFileProviderItemIdentifier($0.fileID) }
                if !updated.isEmpty { observer.value.didUpdate(updated) }
                if !removed.isEmpty { observer.value.didDeleteItems(withIdentifiers: removed) }
                observer.value.finishEnumeratingChanges(upTo: Self.anchor(changes.etag), moreComing: false)
            } catch {
                observer.value.finishEnumeratingWithError(FileProviderExtension.providerError(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let etag = repository.store.listedEtag(of: folder ?? .root) ?? ""
        completionHandler(Self.anchor(etag))
    }

    private static func anchor(_ etag: String) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(("etag:" + etag).utf8))
    }
}
