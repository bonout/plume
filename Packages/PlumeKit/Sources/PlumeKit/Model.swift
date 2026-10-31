import Foundation
import UniformTypeIdentifiers

/// A path inside the user's files, relative to their root: `""` is the root,
/// `"Documents/Taxes/2025.pdf"` a file. Never a leading or trailing slash.
public struct RemotePath: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ raw: String) {
        rawValue = raw.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    public init(components: [String]) {
        self.init(components.joined(separator: "/"))
    }

    public static let root = RemotePath("")

    public var isRoot: Bool { rawValue.isEmpty }
    public var components: [String] { rawValue.split(separator: "/").map(String.init) }
    public var name: String { components.last ?? "" }

    /// The containing folder; `nil` for the root.
    public var parent: RemotePath? {
        guard !isRoot else { return nil }
        return RemotePath(components: components.dropLast())
    }

    public func appending(_ name: String) -> RemotePath {
        RemotePath(isRoot ? name : rawValue + "/" + name)
    }

    /// True for this path itself and everything below it.
    public func contains(_ other: RemotePath) -> Bool {
        isRoot || other == self || other.rawValue.hasPrefix(rawValue + "/")
    }

    /// `/Documents/a.pdf`: the form the OCS API expects.
    public var absolute: String { "/" + rawValue }

    public var description: String { absolute }

    public static func < (lhs: RemotePath, rhs: RemotePath) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A file or folder as the server describes it (one WebDAV `<d:response>`).
public struct RemoteItem: Hashable, Sendable, Codable, Identifiable {
    public var path: RemotePath
    /// `oc:fileid`: stable across renames and moves.
    public var fileID: String
    public var isDirectory: Bool
    /// Bytes; for a folder, everything below it (`oc:size`).
    public var size: Int64
    public var modified: Date?
    /// Changes whenever the file changes; a folder's changes whenever
    /// anything below it changes (Nextcloud propagates it upwards).
    public var etag: String
    public var contentType: String?
    /// `oc:permissions`, e.g. `RGDNVW`: G read, W write, C/K create file /
    /// folder inside, D delete, N rename, V move, S shared with me, R reshare.
    public var permissions: String
    public var isFavorite: Bool
    public var hasPreview: Bool

    public init(path: RemotePath, fileID: String, isDirectory: Bool, size: Int64 = 0, modified: Date? = nil,
                etag: String, contentType: String? = nil, permissions: String = "RGDNVWCK",
                isFavorite: Bool = false, hasPreview: Bool = false) {
        self.path = path
        self.fileID = fileID
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.etag = etag
        self.contentType = contentType
        self.permissions = permissions
        self.isFavorite = isFavorite
        self.hasPreview = hasPreview
    }

    public var id: String { fileID.isEmpty ? "path:" + path.rawValue : fileID }
    public var name: String { path.name }
    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    public var utType: UTType {
        if isDirectory { return .folder }
        if let type = UTType(filenameExtension: fileExtension) { return type }
        if let mime = contentType, let type = UTType(mimeType: mime) { return type }
        return .data
    }

    public var canWrite: Bool { permissions.contains("W") }
    public var canDelete: Bool { permissions.contains("D") }
    public var canRename: Bool { permissions.contains("N") }
    public var canMove: Bool { permissions.contains("V") }
    public var canAddChildren: Bool { permissions.contains("C") || permissions.contains("K") }
    public var isShared: Bool { permissions.contains("S") }
}

public enum PlumeError: LocalizedError, Equatable, Sendable {
    case notSignedIn
    case unauthorized
    case notFound
    case alreadyExists
    case conflict
    case insufficientStorage
    case offline
    case http(Int)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in."
        case .unauthorized: "The server refused the credentials. Sign in again."
        case .notFound: "This item no longer exists on the server."
        case .alreadyExists: "An item with this name already exists."
        case .conflict: "The destination folder doesn't exist."
        case .insufficientStorage: "Not enough storage left on the server."
        case .offline: "The server can't be reached."
        case .http(let status): "The server answered with an error (HTTP \(status))."
        case .invalidResponse(let detail): "Unexpected server response: \(detail)"
        }
    }
}
