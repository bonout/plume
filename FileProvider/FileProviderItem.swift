@preconcurrency import FileProvider
import PlumeKit
import UniformTypeIdentifiers

/// A Nextcloud item as the system sees it.
final class FileProviderItem: NSObject, NSFileProviderItem {
    let remote: RemoteItem
    let parentItemIdentifier: NSFileProviderItemIdentifier

    init(_ remote: RemoteItem, parent: NSFileProviderItemIdentifier) {
        self.remote = remote
        parentItemIdentifier = parent
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        remote.path.isRoot ? .rootContainer : NSFileProviderItemIdentifier(remote.fileID)
    }

    var filename: String { remote.path.isRoot ? "Plume" : remote.name }
    var contentType: UTType { remote.utType }
    var documentSize: NSNumber? { remote.isDirectory ? nil : NSNumber(value: remote.size) }
    var contentModificationDate: Date? { remote.modified }
    var creationDate: Date? { remote.modified }

    /// The etag versions the contents; renames and moves change the metadata.
    var itemVersion: NSFileProviderItemVersion {
        let content = remote.isDirectory ? Data("folder".utf8) : Data(remote.etag.utf8)
        return NSFileProviderItemVersion(contentVersion: content,
                                         metadataVersion: Data((remote.etag + "/" + remote.path.rawValue).utf8))
    }

    var capabilities: NSFileProviderItemCapabilities {
        if remote.path.isRoot {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
        }
        var capabilities: NSFileProviderItemCapabilities = [.allowsReading]
        if remote.isDirectory {
            capabilities.insert(.allowsContentEnumerating)
            if remote.canAddChildren { capabilities.insert(.allowsAddingSubItems) }
        } else if remote.canWrite {
            capabilities.insert(.allowsWriting)
        }
        if remote.canDelete { capabilities.insert(.allowsDeleting) }
        if remote.canRename { capabilities.insert(.allowsRenaming) }
        if remote.canMove { capabilities.insert(.allowsReparenting) }
        return capabilities
    }

    #if os(iOS)
    /// Favorites from the server show up as such in the Files app.
    var favoriteRank: NSNumber? {
        remote.isFavorite ? NSNumber(value: NSFileProviderFavoriteRankUnranked) : nil
    }
    #endif
}
