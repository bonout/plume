import Foundation

/// Downloaded contents, in the group container so that the app and the File
/// Provider extension reuse each other's downloads. A copy's location names
/// the version it holds — `<area>/<file id>/<etag>/<name>` — so a copy is
/// valid exactly when it exists at the path of the item's current etag.
///
/// - `Offline`: files the user made available offline, never evicted.
/// - `Library/Caches/Files`: files opened recently, evicted oldest first,
///   and purgeable by the system.
public struct LocalFiles: Sendable {
    public let offlineRoot: URL
    public let cacheRoot: URL
    /// Above this, the cache drops its least recently used files.
    public var cacheLimit: Int64 = 2 * 1024 * 1024 * 1024

    public init(container: URL = AppGroup.containerURL, caches: URL = AppGroup.cachesURL) {
        offlineRoot = container.appending(path: "Offline", directoryHint: .isDirectory)
        cacheRoot = caches.appending(path: "Files", directoryHint: .isDirectory)
    }

    public func offlineURL(for item: RemoteItem) -> URL { url(for: item, in: offlineRoot) }
    public func cacheURL(for item: RemoteItem) -> URL { url(for: item, in: cacheRoot) }

    /// A current local copy of the item, offline or cached.
    public func existingCopy(of item: RemoteItem) -> URL? {
        for url in [offlineURL(for: item), cacheURL(for: item)]
        where FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return url
        }
        return nil
    }

    public func isAvailableOffline(_ item: RemoteItem) -> Bool {
        FileManager.default.fileExists(atPath: offlineURL(for: item).path(percentEncoded: false))
    }

    /// Removes older versions of the file in `area`, before a new one lands.
    public func removeOtherVersions(of item: RemoteItem, keeping url: URL) {
        let folder = url.deletingLastPathComponent().deletingLastPathComponent()
        let current = url.deletingLastPathComponent().lastPathComponent
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        for version in versions where version != current {
            try? FileManager.default.removeItem(at: folder.appending(path: version))
        }
    }

    /// Drops every local copy of the file (offline and cached).
    public func removeCopies(fileID: String) {
        guard !fileID.isEmpty else { return }
        for root in [offlineRoot, cacheRoot] {
            try? FileManager.default.removeItem(at: root.appending(path: fileID, directoryHint: .isDirectory))
        }
    }

    /// Moves a copy out of `Offline` into the cache (no longer pinned, but
    /// still fast to open).
    public func demote(_ item: RemoteItem) {
        let source = offlineURL(for: item)
        let destination = cacheURL(for: item)
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path(percentEncoded: false)) else { return }
        try? manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try? manager.moveItem(at: source, to: destination)
        }
        try? manager.removeItem(at: offlineRoot.appending(path: item.fileID, directoryHint: .isDirectory))
    }

    /// Promotes a cached copy into `Offline` (pinning a file already opened).
    public func promote(_ item: RemoteItem) -> Bool {
        let source = cacheURL(for: item)
        let destination = offlineURL(for: item)
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path(percentEncoded: false)) else { return false }
        try? manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? manager.moveItem(at: source, to: destination)) != nil
    }

    public func size(of root: URL) -> Int64 {
        files(in: root).reduce(0) { $0 + $1.size }
    }

    /// Keeps the cache under its limit, least recently opened first.
    public func trimCache() {
        var entries = files(in: cacheRoot)
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > cacheLimit else { return }
        entries.sort { $0.used < $1.used }
        for entry in entries where total > cacheLimit {
            try? FileManager.default.removeItem(at: entry.url.deletingLastPathComponent())
            total -= entry.size
        }
    }

    public func clearCache() {
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: offlineRoot)
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    /// Marks a copy as just used (cache eviction order).
    public func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: url.deletingLastPathComponent().path(percentEncoded: false))
    }

    private func url(for item: RemoteItem, in root: URL) -> URL {
        let version = item.etag.filter { $0.isLetter || $0.isNumber }
        return root
            .appending(path: item.fileID.isEmpty ? "unknown" : item.fileID, directoryHint: .isDirectory)
            .appending(path: version.isEmpty ? "0" : version, directoryHint: .isDirectory)
            .appending(component: item.name, directoryHint: .notDirectory)
    }

    private func files(in root: URL) -> [(url: URL, size: Int64, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return []
        }
        var result: [(URL, Int64, Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let used = (try? url.deletingLastPathComponent().resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            result.append((url, Int64(values.fileSize ?? 0), used))
        }
        return result
    }
}
