import Foundation

/// The client, a metadata store and the local copies, put together: what the
/// app and the File Provider extension work with.
public final class Repository: Sendable {
    public let client: NextcloudClient
    public let store: MetadataStore
    public let files: LocalFiles
    /// Told about every item that appears, changes or disappears locally,
    /// whatever caused it (a folder opened, a sync, an upload…): what keeps
    /// Spotlight in step.
    private let onChange: (@Sendable (Changes) -> Void)?

    public init(client: NextcloudClient, store: MetadataStore, files: LocalFiles = LocalFiles(),
                onChange: (@Sendable (Changes) -> Void)? = nil) {
        self.client = client
        self.store = store
        self.files = files
        self.onChange = onChange
    }

    private func notify(updated: [RemoteItem] = [], removed: [RemoteItem] = []) {
        guard let onChange, !(updated.isEmpty && removed.isEmpty) else { return }
        onChange(Changes(updated: updated, removed: removed))
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
        let (listedFolder, listedChildren) = try await client.list(path)
        let folder = store.identified([listedFolder])[0]
        let children = store.identified(listedChildren)
        let before = onChange == nil ? [:] : Dictionary(store.children(of: path).map { ($0.path, $0) },
                                                         uniquingKeysWith: { a, _ in a })
        let removed = store.replaceChildren(of: folder, with: children)
        for item in removed where !item.isDirectory { files.removeCopies(fileID: item.fileID) }
        notify(updated: children.filter { before[$0.path] != $0 }, removed: removed)
        return Listing(folder: folder, children: children, removed: removed)
    }

    public struct Changes: Sendable {
        /// New or changed items, folders included.
        public var updated: [RemoteItem] = []
        public var removed: [RemoteItem] = []
        /// The etag of the starting folder after the walk.
        public var etag: String = ""

        public init(updated: [RemoteItem] = [], removed: [RemoteItem] = [], etag: String = "") {
            self.updated = updated
            self.removed = removed
            self.etag = etag
        }
    }

    /// Mirrors the whole tree below `path`: lists every folder whose
    /// contents changed since its last listing (all of them the first time),
    /// several at a time. Once everything is known, one request when nothing
    /// changed. Returns how many folders were listed.
    @discardableResult
    public func syncTree(from path: RemotePath = .root, concurrency: Int = 6) async throws -> Int {
        var pending = [path]
        var running = 0
        var listed = 0
        try await withThrowingTaskGroup(of: (listed: Bool, folders: [RemotePath]).self) { group in
            while !pending.isEmpty || running > 0 {
                while running < concurrency, let folder = pending.popLast() {
                    running += 1
                    group.addTask { try await self.visit(folder, force: folder == path) }
                }
                guard let result = try await group.next() else { break }
                running -= 1
                if result.listed { listed += 1 }
                pending += result.folders
            }
        }
        return listed
    }

    /// Lists a folder if its contents changed; returns its subfolders.
    private func visit(_ folder: RemotePath, force: Bool) async throws -> (listed: Bool, folders: [RemotePath]) {
        if !force, client.account.isNextcloud, let item = store.item(at: folder),
           store.listedEtag(of: folder) == item.etag {
            return (false, store.children(of: folder).filter(\.isDirectory).map(\.path))
        }
        do {
            let listing = try await refresh(folder)
            return (true, listing.children.filter(\.isDirectory).map(\.path))
        } catch PlumeError.notFound {
            // Gone meanwhile: its parent's next listing forgets it.
            return (false, [])
        }
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
            if child.isDirectory, let listed = store.listedEtag(of: child.path),
               listed != child.etag || !client.account.isNextcloud {
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
        let item = store.upsert(try await client.item(at: path))
        guard item.isDirectory else {
            try await keepOfflineCopy(of: item)
            return
        }
        try await syncTree(from: path)
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
                let item = store.upsert(try await client.upload(file, to: folder.appending(candidate),
                                                                overwrite: false, progress: progress))
                notify(updated: [item])
                return item
            } catch PlumeError.alreadyExists {
                continue
            }
        }
        throw PlumeError.alreadyExists
    }

    public func createFolder(named name: String, in folder: RemotePath) async throws -> RemoteItem {
        let item = store.upsert(try await client.createFolder(at: folder.appending(name)))
        notify(updated: [item])
        return item
    }

    public func rename(_ item: RemoteItem, to name: String) async throws -> RemoteItem {
        let parent = item.path.parent ?? .root
        let destination = parent.appending(name)
        let renamed = try await client.move(item.path, to: destination)
        store.move(item.path, to: destination)
        let moved = store.upsert(renamed)
        notify(updated: store.subtree(of: destination))
        if store.pinnedPaths().contains(item.path) {
            store.unpin(item.path)
            store.pin(moved.path)
        }
        return moved
    }

    public func delete(_ item: RemoteItem) async throws {
        try await client.delete(item.path)
        let removed = store.remove(item.path)
        for file in removed where !file.isDirectory {
            files.removeCopies(fileID: file.fileID)
        }
        notify(removed: removed)
        store.unpin(item.path)
    }

    public func setFavorite(_ favorite: Bool, for item: RemoteItem) async throws -> RemoteItem {
        try await client.setFavorite(favorite, at: item.path)
        var updated = item
        updated.isFavorite = favorite
        store.upsert(updated)
        notify(updated: [updated])
        return updated
    }
}
