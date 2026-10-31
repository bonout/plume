import Foundation

/// An earlier state of a file, kept by Nextcloud's versions app.
public struct FileVersion: Identifiable, Hashable, Sendable {
    /// The version's name on the server (its timestamp).
    public var id: String
    /// Decoded path of the version, e.g. `/remote.php/dav/versions/alice/versions/42/1700000000`.
    public var path: String
    public var modified: Date?
    public var size: Int64
    public var author: String?
    /// A name the user gave this version on the web, if any.
    public var label: String?
}

/// A file or folder in the server's trash bin.
public struct TrashedItem: Identifiable, Hashable, Sendable {
    /// Its name in the trash bin (`name.d<timestamp>`), unique there.
    public var id: String
    /// Decoded path, e.g. `/remote.php/dav/trashbin/alice/trash/a.pdf.d1700000000`.
    public var path: String
    public var name: String
    /// Where it was before deletion, restored there.
    public var originalLocation: RemotePath
    public var deleted: Date?
    public var isDirectory: Bool
    public var size: Int64
    public var contentType: String?

    /// As an item, for its icon and summary.
    public var displayItem: RemoteItem {
        RemoteItem(path: originalLocation, fileID: "", isDirectory: isDirectory, size: size,
                   modified: deleted, etag: id, contentType: contentType)
    }
}

extension NextcloudClient {
    var davRoot: URL { account.server.appending(path: "remote.php/dav") }

    /// The server URL of a decoded DAV path (as found in hrefs).
    func davURL(_ path: String) -> URL {
        var url = account.server
        // Servers installed in a folder: the href already includes it.
        let base = account.server.path(percentEncoded: false)
        var relative = path
        if base.count > 1, relative.hasPrefix(base) { relative = String(relative.dropFirst(base.count)) }
        for component in relative.split(separator: "/") {
            url = url.appending(component: String(component), directoryHint: .notDirectory)
        }
        return url
    }

    // MARK: Versions

    /// Earlier versions of a file, newest first. The current contents are
    /// not among them (the server lists them too, named after the file's
    /// modification time, but can't serve them as a version).
    public func versions(of item: RemoteItem) async throws -> [FileVersion] {
        guard !item.fileID.isEmpty, !item.isDirectory else { return [] }
        let folder = davRoot.appending(path: "versions/\(account.userID)/versions/\(item.fileID)", directoryHint: .isDirectory)
        let data = try await propfindData(folder, depth: "1", properties: """
            <d:prop><d:getlastmodified/><d:getcontentlength/><nc:version-label/><nc:version-author/></d:prop>
            """)
        return try DAVParser.responses(data)
            // The versions folder itself answers too.
            .filter { !$0.isCollection && !$0.path.hasSuffix("/") && $0.props["getlastmodified"] != nil }
            .map { response in
                FileVersion(id: (response.path as NSString).lastPathComponent, path: response.path,
                            modified: DAVParser.date(response.props["getlastmodified"]),
                            size: Int64(response.props["getcontentlength"] ?? "") ?? 0,
                            author: response.props["version-author"].flatMap { $0.isEmpty ? nil : $0 },
                            label: response.props["version-label"].flatMap { $0.isEmpty ? nil : $0 })
            }
            .filter { version in
                guard let modified = item.modified else { return true }
                return version.id != String(Int(modified.timeIntervalSince1970))
            }
            // Named after their timestamp: a finer order than the dates.
            .sorted { (Int($0.id) ?? 0, $0.modified ?? .distantPast) > (Int($1.id) ?? 0, $1.modified ?? .distantPast) }
    }

    /// Makes `version` the current contents (the replaced contents become a
    /// version in turn).
    public func restore(_ version: FileVersion) async throws {
        var request = request(davURL(version.path), method: "MOVE")
        let target = davRoot.appending(path: "versions/\(account.userID)/restore/target")
        request.setValue(target.absoluteString, forHTTPHeaderField: "Destination")
        _ = try await send(request)
    }

    public func download(_ version: FileVersion, to destination: URL) async throws {
        let (temporary, response) = try await session.download(for: request(davURL(version.path), method: "GET"))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try check(response, data: nil)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    // MARK: Trash bin

    private var trashFolder: URL {
        davRoot.appending(path: "trashbin/\(account.userID)/trash", directoryHint: .isDirectory)
    }

    /// Everything in the trash bin, most recently deleted first.
    public func trash() async throws -> [TrashedItem] {
        let data = try await propfindData(trashFolder, depth: "1", properties: """
            <d:prop><nc:trashbin-filename/><nc:trashbin-original-location/><nc:trashbin-deletion-time/>
            <d:getcontentlength/><oc:size/><d:resourcetype/><d:getcontenttype/></d:prop>
            """)
        let root = trashFolder.path(percentEncoded: false)
        return try DAVParser.responses(data)
            .filter { $0.path.trimmingCharacters(in: ["/"]) != root.trimmingCharacters(in: ["/"]) }
            .compactMap { response -> TrashedItem? in
                guard let name = response.props["trashbin-filename"] else { return nil }
                let id = (response.path as NSString).lastPathComponent
                let size = Int64(response.props["getcontentlength"] ?? "") ?? Int64(response.props["size"] ?? "") ?? 0
                return TrashedItem(
                    id: id, path: response.path, name: name,
                    originalLocation: RemotePath(response.props["trashbin-original-location"] ?? name),
                    deleted: Double(response.props["trashbin-deletion-time"] ?? "").map(Date.init(timeIntervalSince1970:)),
                    isDirectory: response.isCollection, size: size,
                    contentType: response.props["getcontenttype"].flatMap { $0.isEmpty ? nil : $0 })
            }
            .sorted { ($0.deleted ?? .distantPast) > ($1.deleted ?? .distantPast) }
    }

    /// Puts the item back where it was (Nextcloud recreates missing folders,
    /// and renames it if the name is taken there).
    public func restore(_ item: TrashedItem) async throws {
        var request = request(davURL(item.path), method: "MOVE")
        let target = davRoot.appending(path: "trashbin/\(account.userID)/restore").appending(component: item.id)
        request.setValue(target.absoluteString, forHTTPHeaderField: "Destination")
        _ = try await send(request)
    }

    /// Deletes for good.
    public func deletePermanently(_ item: TrashedItem) async throws {
        _ = try await send(request(davURL(item.path), method: "DELETE"))
    }

    public func emptyTrash() async throws {
        _ = try await send(request(trashFolder, method: "DELETE"))
    }
}
