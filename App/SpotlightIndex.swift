import CoreSpotlight
import Foundation
import PlumeKit

/// Every file and folder of the account in Spotlight (iPhone, iPad and
/// Mac): names, kinds, dates, sizes, and the thumbnail when the app has one.
/// Fed by the repository's changes; a result opens Plume on the item
/// (`CSSearchableItemActionType`, handled by RootView).
actor SpotlightIndex {
    /// Bumped when what an entry holds changes: everything is indexed again.
    static let version = 1
    private static let versionKey = "spotlightIndexVersion"

    private let index = CSSearchableIndex(name: "Plume")

    var isCurrent: Bool { AppGroup.defaults.integer(forKey: Self.versionKey) == Self.version }

    func apply(_ changes: Repository.Changes) async {
        let updatedIDs = Set(changes.updated.map(\.fileID))
        let removed = changes.removed.map(\.fileID).filter { !$0.isEmpty && !updatedIDs.contains($0) }
        if !removed.isEmpty {
            try? await index.deleteSearchableItems(withIdentifiers: removed)
        }
        await add(changes.updated)
    }

    /// Indexes everything the store knows (first run, or a new version).
    func reindex(_ items: [RemoteItem]) async {
        try? await index.deleteAllSearchableItems()
        await add(items)
        AppGroup.defaults.set(Self.version, forKey: Self.versionKey)
    }

    func removeAll() async {
        try? await index.deleteAllSearchableItems()
        AppGroup.defaults.removeObject(forKey: Self.versionKey)
    }

    private func add(_ items: [RemoteItem]) async {
        let entries = items.filter { !$0.fileID.isEmpty && !$0.path.isRoot }.map(Self.entry)
        for start in stride(from: 0, to: entries.count, by: 500) {
            try? await index.indexSearchableItems(Array(entries[start..<min(start + 500, entries.count)]))
        }
    }

    private static func entry(_ item: RemoteItem) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: item.utType)
        attributes.title = item.name
        attributes.displayName = item.name
        let parent = item.path.parent ?? .root
        attributes.contentDescription = parent.isRoot ? "Plume" : "Plume › " + parent.components.joined(separator: " › ")
        attributes.contentModificationDate = item.modified
        if !item.isDirectory { attributes.fileSize = NSNumber(value: item.size) }
        if let thumbnail = try? Data(contentsOf: ThumbnailCache.diskURL(for: item)) {
            attributes.thumbnailData = thumbnail
        }
        let entry = CSSearchableItem(uniqueIdentifier: item.fileID, domainIdentifier: "files",
                                     attributeSet: attributes)
        entry.expirationDate = .distantFuture
        return entry
    }
}
