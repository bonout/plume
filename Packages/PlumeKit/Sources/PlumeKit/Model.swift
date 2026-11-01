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
    public var name: String {
        guard let slash = rawValue.lastIndex(of: "/") else { return rawValue }
        return String(rawValue[rawValue.index(after: slash)...])
    }

    /// The containing folder; `nil` for the root.
    public var parent: RemotePath? {
        guard !isRoot else { return nil }
        return RemotePath(components: components.dropLast())
    }

    public func appending(_ name: String) -> RemotePath {
        RemotePath(isRoot ? name : rawValue + "/" + name)
    }

    /// The folders from the top down to this one, root excluded: a
    /// navigation stack that shows it.
    public var ancestry: [RemotePath] {
        var chain: [RemotePath] = []
        var current: RemotePath? = self
        while let folder = current, !folder.isRoot {
            chain.insert(folder, at: 0)
            current = folder.parent
        }
        return chain
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
    static func from(_ error: URLError) -> Error {
        switch error.code {
        case .cancelled: CancellationError()
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .secureConnectionFailed:
            PlumeError.untrustedCertificate
        default: PlumeError.offline
        }
    }

    case notSignedIn
    case unauthorized
    case notFound
    case alreadyExists
    case conflict
    case insufficientStorage
    case offline
    case forbidden
    case maintenance
    case untrustedCertificate
    case notNextcloud
    case notWebDAV
    case unsupported
    case http(Int)
    case invalidResponse(String)
    /// The server refused, with its own explanation.
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: String(localized: "Not signed in.")
        case .unauthorized: String(localized: "The server refused the credentials. Sign in again.")
        case .notFound: String(localized: "This item no longer exists on the server.")
        case .alreadyExists: String(localized: "An item with this name already exists.")
        case .conflict: String(localized: "The destination folder doesn't exist.")
        case .insufficientStorage: String(localized: "Not enough storage left on the server.")
        case .offline: String(localized: "The server can't be reached. Check the address and your connection.")
        case .forbidden: String(localized: "You don't have permission to do this on the server.")
        case .maintenance: String(localized: "The server is in maintenance mode. Try again in a few minutes.")
        case .untrustedCertificate: String(localized: "The server's security certificate isn't trusted. Plume only connects to servers with a certificate from a recognized authority, such as Let's Encrypt.")
        case .notNextcloud: String(localized: "No Nextcloud server answered at this address. Enter the address you use to open Nextcloud in a browser, for example cloud.example.com.")
        case .notWebDAV: String(localized: "No WebDAV folder answered at this address. Enter the full address of the WebDAV folder, for example https://nas.example.com/webdav.")
        case .unsupported: String(localized: "This server doesn't support this action.")
        case .http(let status): String(localized: "The server answered with an error (HTTP \(status)).")
        case .invalidResponse(let detail): String(localized: "Unexpected server response: \(detail)")
        case .refused(let message): message
        }
    }
}
