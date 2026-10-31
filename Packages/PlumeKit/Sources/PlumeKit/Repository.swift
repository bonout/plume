import Foundation

/// The client, a metadata store and the local copies, put together: what the
/// app and the File Provider extension work with.
public final class Repository: Sendable {
    public let client: NextcloudClient
    public let store: MetadataStore
    public let files: LocalFiles

    public init(client: NextcloudClient, store: MetadataStore, files: LocalFiles = LocalFiles()) {
        self.client = client
        self.store = store
        self.files = files
    }

    public struct Listing: Sendable {
        public var folder: RemoteItem
        public var children: [RemoteItem]
        /// Items known before and gone now (with their subtrees).
        public var removed: [RemoteItem]
    }

    /// Lists a folder from the server and records it.
    @discardableResult
    public func refresh(_ path: RemotePath) async throws -> Listing {
        let (folder, children) = try await client.list(path)
        let removed = store.replaceChildren(of: folder, with: children)
        for item in removed where !item.isDirectory { files.removeCopies(fileID: item.fileID) }
        return Listing(folder: folder, children: children, removed: removed)
    }

    public struct Changes: Sendable {
        /// New or changed items, folders included.
        public var updated: [RemoteItem] = []
        public var removed: [RemoteItem] = []
        /// The etag of the starting folder after the walk.
        public var etag: String = ""
    }

    /// Finds what changed below `path` since the store last saw it, by
    /// following etags: only folders that were listed before and whose etag
    /// moved are listed again. One request when nothing changed.
    public func changes(under path: RemotePath) async throws -> Changes {
        let before = Dictionary(store.children(of: path).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let listing = try await refresh(path)
        var changes = Changes(etag: listing.folder.etag)
        changes.removed = listing.removed
        var descend: [RemotePath] = []
        for child in listing.children {
            let old = before[child.path]
            if old != child { changes.updated.append(child) }
            // A folder known inside whose etag moved: something changed below.
            if child.isDirectory, let listed = store.listedEtag(of: child.path), listed != child.etag {
                descend.append(child.path)
            }
        }
        try await withThrowingTaskGroup(of: Changes.self) { group in
            for folder in descend {
                group.addTask { try await self.changes(under: folder) }
            }
            for try await nested in group {
                changes.updated += nested.updated
                changes.removed += nested.removed
            }
        }
        return changes
    }

    // MARK: Contents

    /// A current local copy of the file: an existing one, or downloaded now
    /// (into `Offline` when the file is pinned, the cache otherwise).
    public func localCopy(of item: RemoteItem, progress: Progress? = nil) async throws -> URL {
        if let url = files.existingCopy(of: item) {
            files.touch(url)
            return url
        }
        let destination = store.isPinned(item.path) ? files.offlineURL(for: item) : files.cacheURL(for: item)
        try await client.download(item.path, to: destination, progress: progress)
        files.removeOtherVersions(of: item, keeping: destination)
        files.touch(destination)
        return destination
    }

    // MARK: Available offline

    public func makeAvailableOffline(_ item: RemoteItem) async throws {
        store.pin(item.path)
        try await syncOffline(item.path)
    }

    public func removeFromOffline(_ item: RemoteItem) {
        store.unpin(item.path)
        for file in store.subtree(of: item.path) where !file.isDirectory && !store.isPinned(file.path) {
            files.demote(file)
        }
        files.trimCache()
    }

    /// Brings every pinned file up to date (new folders' contents included).
    public func syncAllOffline() async {
        for path in store.pinnedPaths() {
            do {
                try await syncOffline(path)
            } catch PlumeError.notFound {
                store.unpin(path)
            } catch {
                // Offline or failing: next time.
            }
        }
    }

    private func syncOffline(_ path: RemotePath) async throws {
        let item = try await client.item(at: path)
        store.upsert(item)
        guard item.isDirectory else {
            try await keepOfflineCopy(of: item)
            return
        }
        // List every folder whose contents moved since its last listing (all
        // of them the first time), then fetch the files that changed.
        var folders = [path]
        while let folder = folders.popLast() {
            let current = store.item(at: folder)
            if let current, store.listedEtag(of: folder) == current.etag, folder != path {
                folders += store.children(of: folder).filter(\.isDirectory).map(\.path)
                continue
            }
            let listing = try await refresh(folder)
            folders += listing.children.filter(\.isDirectory).map(\.path)
        }
        for file in store.subtree(of: path) where !file.isDirectory {
            try await keepOfflineCopy(of: file)
        }
    }

    private func keepOfflineCopy(of item: RemoteItem) async throws {
        if files.isAvailableOffline(item) { return }
        if files.promote(item) {
            files.removeOtherVersions(of: item, keeping: files.offlineURL(for: item))
            return
        }
        let destination = files.offlineURL(for: item)
        try await client.download(item.path, to: destination)
        files.removeOtherVersions(of: item, keeping: destination)
    }

    // MARK: Changes from the app

    /// Uploads under `folder`; when the name is taken, tries "name 2.ext",
    /// "name 3.ext"… (nothing is ever overwritten).
    @discardableResult
    public func upload(_ file: URL, named name: String, into folder: RemotePath,
                       progress: Progress? = nil) async throws -> RemoteItem {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for attempt in 1...100 {
            let candidate = attempt == 1 ? name : (ext.isEmpty ? "\(base) \(attempt)" : "\(base) \(attempt).\(ext)")
            do {
                let item = try await client.upload(file, to: folder.appending(candidate), overwrite: false,
                                                   progress: progress)
                store.upsert(item)
                return item
            } catch PlumeError.alreadyExists {
                continue
            }
        }
        throw PlumeError.alreadyExists
    }

    public func createFolder(named name: String, in folder: RemotePath) async throws -> RemoteItem {
        let item = try await client.createFolder(at: folder.appending(name))
        store.upsert(item)
        return item
    }

    public func rename(_ item: RemoteItem, to name: String) async throws -> RemoteItem {
        let parent = item.path.parent ?? .root
        let moved = try await client.move(item.path, to: parent.appending(name))
        store.remove(item.path)
        store.upsert(moved)
        if store.pinnedPaths().contains(item.path) {
            store.unpin(item.path)
            store.pin(moved.path)
        }
        return moved
    }

    public func delete(_ item: RemoteItem) async throws {
        try await client.delete(item.path)
        for removed in store.remove(item.path) where !removed.isDirectory {
            files.removeCopies(fileID: removed.fileID)
        }
        store.unpin(item.path)
    }

    public func setFavorite(_ favorite: Bool, for item: RemoteItem) async throws -> RemoteItem {
        try await client.setFavorite(favorite, at: item.path)
        var updated = item
        updated.isFavorite = favorite
        store.upsert(updated)
        return updated
    }
}
