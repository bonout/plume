import Foundation

/// A share of a file or folder: a public link, or access given to a user or
/// a group of the server.
public struct Share: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case user, group, link, email, other(Int)

        init(_ type: Int) {
            switch type {
            case 0: self = .user
            case 1: self = .group
            case 3: self = .link
            case 4: self = .email
            default: self = .other(type)
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var permissions: Int
    public var expiration: Date?
    public var hasPassword: Bool
    public var url: URL?
    /// The user or group it is shared with.
    public var shareWith: String?
    public var displayName: String?
    public var label: String?

    public var canEdit: Bool { permissions & (Permission.update | Permission.create) != 0 }
}

/// OCS share permission bits.
public enum Permission {
    public static let read = 1
    public static let update = 2
    public static let create = 4
    public static let delete = 8
    public static let share = 16

    /// What "can edit" means for a file or a folder.
    public static func edit(isDirectory: Bool) -> Int {
        isDirectory ? read | update | create | delete : read | update
    }
}

/// Someone the server offers to share with.
public struct Sharee: Identifiable, Hashable, Sendable {
    public var id: String { "\(isGroup ? "g" : "u"):\(shareWith)" }
    public var shareWith: String
    public var label: String
    public var isGroup: Bool
}

/// What the server allows or requires, from its capabilities.
public struct ServerCapabilities: Sendable {
    /// notify_push's websocket, when the server has the app.
    public var pushURL: URL?
    public var linkPasswordRequired = false
    /// Days a link may last at most, when an expiry is enforced.
    public var linkMaxDays: Int?
    public var linksEnabled = true
    public var versions = true
    public var trash = true
    public var sharing = true
    public var favorites = true

    public init() {}

    public init(account: Account) {
        guard !account.isNextcloud else { return }
        linksEnabled = false
        versions = false
        trash = false
        sharing = false
        favorites = false
    }
}

extension NextcloudClient {
    private static let sharesEndpoint = "ocs/v2.php/apps/files_sharing/api/v1/shares"

    public func capabilities() async throws -> ServerCapabilities {
        guard account.isNextcloud else { return ServerCapabilities(account: account) }
        let data = try await ocs("ocs/v2.php/cloud/capabilities", method: "GET") as? [String: Any]
        let all = data?["capabilities"] as? [String: Any] ?? [:]
        var result = ServerCapabilities()
        if let push = all["notify_push"] as? [String: Any],
           let endpoints = push["endpoints"] as? [String: Any],
           let socket = (endpoints["websocket"] as? String).flatMap(URL.init(string:)) {
            result.pushURL = socket
        }
        let files = all["files"] as? [String: Any]
        result.versions = files?["versioning"] as? Bool ?? true
        result.trash = files?["undelete"] as? Bool ?? true
        let publicSharing = (all["files_sharing"] as? [String: Any])?["public"] as? [String: Any]
        result.linksEnabled = publicSharing?["enabled"] as? Bool ?? true
        result.linkPasswordRequired = ((publicSharing?["password"] as? [String: Any])?["enforced"] as? Bool) ?? false
        if let expiry = publicSharing?["expire_date"] as? [String: Any], expiry["enforced"] as? Bool == true {
            result.linkMaxDays = (expiry["days"] as? NSNumber)?.intValue ?? Int(expiry["days"] as? String ?? "")
        }
        return result
    }

    /// The shares the user made of this item.
    public func shares(of path: RemotePath) async throws -> [Share] {
        let data = try await ocs(Self.sharesEndpoint, method: "GET",
                                 query: [.init(name: "path", value: path.absolute),
                                         .init(name: "reshares", value: "false")])
        return (data as? [[String: Any]] ?? []).compactMap(Self.share)
    }

    /// A new public link.
    public func createLink(for path: RemotePath, permissions: Int = Permission.read,
                           password: String? = nil, expiration: Date? = nil) async throws -> Share {
        var form = ["path": path.absolute, "shareType": "3", "permissions": String(permissions)]
        if let password, !password.isEmpty { form["password"] = password }
        if let expiration { form["expireDate"] = Self.day(expiration) }
        return try await createShare(form)
    }

    /// Gives a user or a group of the server access.
    public func share(_ path: RemotePath, with sharee: Sharee, permissions: Int) async throws -> Share {
        try await createShare(["path": path.absolute, "shareType": sharee.isGroup ? "1" : "0",
                               "shareWith": sharee.shareWith, "permissions": String(permissions)])
    }

    private func createShare(_ form: [String: String]) async throws -> Share {
        guard let created = try await ocs(Self.sharesEndpoint, method: "POST", form: form) as? [String: Any],
              let share = Self.share(created) else { throw PlumeError.invalidResponse("share") }
        return share
    }

    /// Changes a share. `password: ""` removes the password,
    /// `expiration: .some(nil)` the expiry.
    public func update(_ share: Share, permissions: Int? = nil, password: String? = nil,
                       expiration: Date?? = nil) async throws -> Share {
        var form: [String: String] = [:]
        if let permissions { form["permissions"] = String(permissions) }
        if let password { form["password"] = password }
        if let expiration { form["expireDate"] = expiration.map(Self.day) ?? "" }
        var result = share
        // One field per request: what every server version accepts.
        for (key, value) in form {
            guard let updated = try await ocs("\(Self.sharesEndpoint)/\(share.id)", method: "PUT",
                                              form: [key: value]) as? [String: Any],
                  let parsed = Self.share(updated) else { throw PlumeError.invalidResponse("share") }
            result = parsed
        }
        return result
    }

    public func delete(_ share: Share) async throws {
        _ = try await ocs("\(Self.sharesEndpoint)/\(share.id)", method: "DELETE")
    }

    /// Users and groups matching `term`, for sharing.
    public func sharees(matching term: String, isDirectory: Bool) async throws -> [Sharee] {
        let data = try await ocs("ocs/v2.php/apps/files_sharing/api/v1/sharees", method: "GET",
                                 query: [.init(name: "search", value: term),
                                         .init(name: "itemType", value: isDirectory ? "folder" : "file"),
                                         .init(name: "perPage", value: "20")]) as? [String: Any] ?? [:]
        let exact = data["exact"] as? [String: Any] ?? [:]
        var seen = Set<String>()
        var result: [Sharee] = []
        for source in [exact, data] {
            for (key, isGroup) in [("users", false), ("groups", true)] {
                for entry in source[key] as? [[String: Any]] ?? [] {
                    guard let value = entry["value"] as? [String: Any],
                          let with = value["shareWith"] as? String else { continue }
                    let sharee = Sharee(shareWith: with, label: entry["label"] as? String ?? with, isGroup: isGroup)
                    if seen.insert(sharee.id).inserted { result.append(sharee) }
                }
            }
        }
        return result
    }

    private static func share(_ json: [String: Any]) -> Share? {
        guard let id = json["id"].map({ "\($0)" }) else { return nil }
        let type = (json["share_type"] as? NSNumber)?.intValue ?? Int(json["share_type"] as? String ?? "") ?? -1
        let password = json["password"] as? String
        return Share(
            id: id, kind: Share.Kind(type),
            permissions: (json["permissions"] as? NSNumber)?.intValue ?? Permission.read,
            expiration: (json["expiration"] as? String).flatMap(parseExpiration),
            hasPassword: !(password ?? "").isEmpty,
            url: (json["url"] as? String).flatMap(URL.init(string:)),
            shareWith: type == 3 ? nil : json["share_with"] as? String,
            displayName: json["share_with_displayname"] as? String,
            label: (json["label"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func parseExpiration(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
