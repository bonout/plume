import Foundation

/// Talks to one Nextcloud account: WebDAV for files, OCS for the rest.
/// Stateless apart from its URL session; safe to share between tasks.
public final class NextcloudClient: Sendable {
    public let account: Account
    /// For the push channel, which authenticates with its first messages.
    let credentials: Credentials
    let session: URLSession
    private let authorization: String

    /// Files above this size are sent in chunks (resumable server side, and
    /// below the request size limits of proxies in front of the server).
    static let chunkSize = 16 * 1024 * 1024

    static let davProperties = """
        <d:prop>
          <d:getlastmodified/><d:getetag/><d:getcontenttype/><d:resourcetype/><d:getcontentlength/>
          <oc:fileid/><oc:size/><oc:permissions/><oc:favorite/><nc:has-preview/>
        </d:prop>
        """

    static let namespaces = #"xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns""#

    public init(credentials: Credentials, userAgent: String = NextcloudClient.defaultUserAgent) {
        account = credentials.account
        self.credentials = credentials
        let token = Data("\(credentials.account.loginName):\(credentials.appPassword)".utf8).base64EncodedString()
        authorization = "Basic \(token)"
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        // The app password authenticates every request: no session cookie,
        // which Nextcloud would otherwise check against it.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration)
    }

    public static var defaultUserAgent: String {
        #if os(macOS)
        "Plume (macOS)"
        #else
        "Plume (iOS)"
        #endif
    }

    // MARK: URLs

    /// `<server>/remote.php/dav/files/<user>`
    public var filesURL: URL {
        account.server.appending(path: "remote.php/dav/files/\(account.userID)", directoryHint: .notDirectory)
    }

    public func url(for path: RemotePath) -> URL {
        guard !path.isRoot else { return filesURL.appending(path: "", directoryHint: .isDirectory) }
        var url = filesURL
        for component in path.components {
            url = url.appending(component: component, directoryHint: .notDirectory)
        }
        return url
    }

    // MARK: Listing

    /// The folder itself and its direct children.
    public func list(_ path: RemotePath) async throws -> (folder: RemoteItem, children: [RemoteItem]) {
        var target = url(for: path)
        if !path.isRoot { target = target.appending(path: "", directoryHint: .isDirectory) }
        let items = try await propfind(target, depth: "1")
        guard let folder = items.first(where: { $0.path == path }) else {
            throw PlumeError.invalidResponse("the folder is missing from its listing")
        }
        let children = items.filter { $0.path != path }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return (folder, children)
    }

    public func item(at path: RemotePath) async throws -> RemoteItem {
        guard let item = try await propfind(url(for: path), depth: "0").first else { throw PlumeError.notFound }
        return item
    }

    private func propfind(_ url: URL, depth: String) async throws -> [RemoteItem] {
        let data = try await propfindData(url, depth: depth, properties: Self.davProperties)
        return try DAVParser.parse(data, filesRoot: filesURL.path(percentEncoded: false))
    }

    func propfindData(_ url: URL, depth: String, properties: String) async throws -> Data {
        var request = request(url, method: "PROPFIND")
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <d:propfind \(Self.namespaces)>\(properties)</d:propfind>
            """.utf8)
        return try await send(request)
    }

    /// Files and folders whose name contains `term`, anywhere in the account.
    public func search(_ term: String, limit: Int = 100) async throws -> [RemoteItem] {
        let like = "%" + term
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "_", with: "") + "%"
        var request = request(account.server.appending(path: "remote.php/dav/"), method: "SEARCH")
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <d:searchrequest \(Self.namespaces)>
              <d:basicsearch>
                <d:select>\(Self.davProperties)</d:select>
                <d:from><d:scope><d:href>/files/\(xmlEscaped(account.userID))</d:href><d:depth>infinity</d:depth></d:scope></d:from>
                <d:where><d:like><d:prop><d:displayname/></d:prop><d:literal>\(xmlEscaped(like))</d:literal></d:like></d:where>
                <d:orderby><d:order><d:prop><d:getlastmodified/></d:prop><d:descending/></d:order></d:orderby>
                <d:limit><d:nresults>\(limit)</d:nresults></d:limit>
              </d:basicsearch>
            </d:searchrequest>
            """.utf8)
        let data = try await send(request)
        return try DAVParser.parse(data, filesRoot: filesURL.path(percentEncoded: false))
    }

    /// Everything marked as favorite, anywhere in the account.
    public func favorites() async throws -> [RemoteItem] {
        var request = request(url(for: .root), method: "REPORT")
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <oc:filter-files \(Self.namespaces)>
              \(Self.davProperties)
              <oc:filter-rules><oc:favorite>1</oc:favorite></oc:filter-rules>
            </oc:filter-files>
            """.utf8)
        let data = try await send(request)
        return try DAVParser.parse(data, filesRoot: filesURL.path(percentEncoded: false))
    }

    public func setFavorite(_ favorite: Bool, at path: RemotePath) async throws {
        var request = request(url(for: path), method: "PROPPATCH")
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <d:propertyupdate \(Self.namespaces)>
              <d:set><d:prop><oc:favorite>\(favorite ? 1 : 0)</oc:favorite></d:prop></d:set>
            </d:propertyupdate>
            """.utf8)
        _ = try await send(request)
    }

    // MARK: Changes

    public func createFolder(at path: RemotePath) async throws -> RemoteItem {
        do {
            _ = try await send(request(url(for: path), method: "MKCOL"))
        } catch PlumeError.http(405) {
            // MKCOL on an existing item.
            throw PlumeError.alreadyExists
        }
        return try await item(at: path)
    }

    /// Renames or moves; never replaces an existing item.
    public func move(_ source: RemotePath, to destination: RemotePath) async throws -> RemoteItem {
        var request = request(url(for: source), method: "MOVE")
        request.setValue(url(for: destination).absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        _ = try await send(request)
        return try await item(at: destination)
    }

    /// Moves to the server's trash bin (Nextcloud keeps deleted files).
    public func delete(_ path: RemotePath) async throws {
        do {
            _ = try await send(request(url(for: path), method: "DELETE"))
        } catch PlumeError.notFound {
            // Already gone: what was asked.
        }
    }

    // MARK: Contents

    /// Downloads the file to `destination` (replaced if present). `progress`,
    /// when given, follows the transfer.
    public func download(_ path: RemotePath, to destination: URL, progress: Progress? = nil) async throws {
        let request = request(url(for: path), method: "GET")
        let delegate = ProgressDelegate(parent: progress)
        let (temporary, response) = try await session.download(for: request, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try check(response, data: nil)
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: temporary, to: destination)
    }

    /// Uploads a local file. Without `overwrite`, an existing item at `path`
    /// fails with `.alreadyExists`. Large files go in chunks.
    @discardableResult
    public func upload(_ file: URL, to path: RemotePath, overwrite: Bool, modified: Date? = nil,
                       progress: Progress? = nil) async throws -> RemoteItem {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let mtime = modified ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        if size > Self.chunkSize {
            try await uploadInChunks(file, size: size, to: path, overwrite: overwrite, modified: mtime, progress: progress)
        } else {
            var request = request(url(for: path), method: "PUT")
            if !overwrite { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
            if let mtime { request.setValue(String(Int(mtime.timeIntervalSince1970)), forHTTPHeaderField: "X-OC-Mtime") }
            let delegate = ProgressDelegate(parent: progress)
            let (data, response) = try await session.upload(for: request, fromFile: file, delegate: delegate)
            try check(response, data: data)
        }
        return try await item(at: path)
    }

    /// Chunked upload v2: chunks go to a temporary folder of the uploads
    /// space, then one MOVE assembles them at the destination.
    private func uploadInChunks(_ file: URL, size: Int, to path: RemotePath, overwrite: Bool,
                                modified: Date?, progress: Progress?) async throws {
        let destination = url(for: path).absoluteString
        let folder = account.server
            .appending(path: "remote.php/dav/uploads/\(account.userID)")
            .appending(component: "plume-" + UUID().uuidString)
        var mkcol = request(folder, method: "MKCOL")
        mkcol.setValue(destination, forHTTPHeaderField: "Destination")
        _ = try await send(mkcol)

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let chunkCount = (size + Self.chunkSize - 1) / Self.chunkSize
        let overall = progress.map { parent in
            let child = Progress(totalUnitCount: Int64(size))
            parent.addChild(child, withPendingUnitCount: parent.totalUnitCount)
            return child
        }
        do {
            for index in 1...chunkCount {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
                var put = request(folder.appending(component: String(format: "%05d", index)), method: "PUT")
                put.setValue(destination, forHTTPHeaderField: "Destination")
                put.setValue(String(size), forHTTPHeaderField: "OC-Total-Length")
                let (data, response) = try await session.upload(for: put, from: chunk)
                try check(response, data: data)
                overall?.completedUnitCount += Int64(chunk.count)
            }
            var assemble = request(folder.appending(component: ".file"), method: "MOVE")
            assemble.setValue(destination, forHTTPHeaderField: "Destination")
            assemble.setValue(String(size), forHTTPHeaderField: "OC-Total-Length")
            assemble.setValue(overwrite ? "T" : "F", forHTTPHeaderField: "Overwrite")
            if let modified { assemble.setValue(String(Int(modified.timeIntervalSince1970)), forHTTPHeaderField: "X-OC-Mtime") }
            assemble.timeoutInterval = 600
            let (data, response) = try await session.data(for: assemble)
            try check(response, data: data)
        } catch {
            _ = try? await send(request(folder, method: "DELETE"))
            throw error
        }
    }

    /// A thumbnail rendered by the server, `nil` when it has none.
    public func preview(of item: RemoteItem, size: Int) async throws -> Data? {
        guard item.hasPreview, !item.fileID.isEmpty else { return nil }
        var components = URLComponents(url: account.server.appending(path: "index.php/core/preview"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "fileId", value: item.fileID),
            .init(name: "x", value: String(size)),
            .init(name: "y", value: String(size)),
            .init(name: "a", value: "1"),
            .init(name: "mode", value: "cover"),
            .init(name: "c", value: item.etag),
        ]
        let (data, response) = try await session.data(for: request(components.url!, method: "GET"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: OCS

    public struct UserInfo: Sendable {
        public var id: String
        public var displayName: String?
        public var quotaUsed: Int64?
        public var quotaTotal: Int64?
    }

    public func userInfo() async throws -> UserInfo {
        let json = try await ocs("ocs/v2.php/cloud/user", method: "GET")
        guard let data = json as? [String: Any], let id = data["id"] as? String else {
            throw PlumeError.invalidResponse("user")
        }
        let quota = data["quota"] as? [String: Any]
        let total = (quota?["total"] as? NSNumber)?.int64Value
        return UserInfo(id: id, displayName: data["display-name"] as? String ?? data["displayname"] as? String,
                        quotaUsed: (quota?["used"] as? NSNumber)?.int64Value,
                        quotaTotal: total.flatMap { $0 > 0 ? $0 : nil })
    }

    /// A public link to the item: the existing one if there is one, a new
    /// read-only one otherwise.
    public func publicLink(for path: RemotePath) async throws -> URL {
        let endpoint = "ocs/v2.php/apps/files_sharing/api/v1/shares"
        let existing = try await ocs(endpoint, method: "GET",
                                     query: [.init(name: "path", value: path.absolute),
                                             .init(name: "reshares", value: "false")])
        if let shares = existing as? [[String: Any]],
           let link = shares.first(where: { ($0["share_type"] as? NSNumber)?.intValue == 3 }),
           let url = (link["url"] as? String).flatMap(URL.init(string:)) {
            return url
        }
        let created = try await ocs(endpoint, method: "POST",
                                    form: ["path": path.absolute, "shareType": "3", "permissions": "1"])
        guard let share = created as? [String: Any], let url = (share["url"] as? String).flatMap(URL.init(string:)) else {
            throw PlumeError.invalidResponse("share")
        }
        return url
    }

    /// Revokes this app password on the server (sign out).
    public func revokeAppPassword() async throws {
        _ = try await ocs("ocs/v2.php/core/apppassword", method: "DELETE")
    }

    func ocs(_ endpoint: String, method: String, query: [URLQueryItem] = [],
                     form: [String: String]? = nil) async throws -> Any? {
        var components = URLComponents(url: account.server.appending(path: endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = query + [.init(name: "format", value: "json")]
        var request = request(components.url!, method: method)
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = Data((body.percentEncodedQuery ?? "")
                .replacingOccurrences(of: "+", with: "%2B").utf8)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw PlumeError.from(error)
        }
        let ocs = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["ocs"] as? [String: Any]
        // OCS explains a refusal (a weak password, an unknown user…): show it.
        if let status = (response as? HTTPURLResponse)?.statusCode, (400..<500).contains(status), status != 401,
           let message = (ocs?["meta"] as? [String: Any])?["message"] as? String, !message.isEmpty {
            throw PlumeError.refused(message)
        }
        try check(response, data: data)
        guard let ocs else { throw PlumeError.invalidResponse("OCS") }
        return ocs["data"]
    }

    // MARK: Plumbing

    func request(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    func send(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw PlumeError.from(error)
        }
        try check(response, data: data)
        return data
    }

    func check(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw PlumeError.invalidResponse("not HTTP") }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw PlumeError.unauthorized
        case 403: throw PlumeError.forbidden
        case 404: throw PlumeError.notFound
        case 409: throw PlumeError.conflict
        // If-None-Match: * on PUT, Overwrite: F on MOVE.
        case 412: throw PlumeError.alreadyExists
        case 503 where http.value(forHTTPHeaderField: "X-Nextcloud-Maintenance-Mode") != nil:
            throw PlumeError.maintenance
        case 507: throw PlumeError.insufficientStorage
        default: throw PlumeError.http(http.statusCode)
        }
    }

    func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Attaches each task's own progress to the caller's.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let parent: Progress?

    init(parent: Progress?) { self.parent = parent }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        guard let parent else { return }
        parent.addChild(task.progress, withPendingUnitCount: parent.totalUnitCount)
    }
}
